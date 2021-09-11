//  Copyright © 2019 650 Industries. All rights reserved.

#import <EXUpdates/EXUpdatesAppController+Internal.h>
#import <EXUpdates/EXUpdatesAppLauncher.h>
#import <EXUpdates/EXUpdatesAppLauncherNoDatabase.h>
#import <EXUpdates/EXUpdatesAppLauncherWithDatabase.h>
#import <EXUpdates/EXUpdatesErrorRecovery.h>
#import <EXUpdates/EXUpdatesReaper.h>
#import <EXUpdates/EXUpdatesSelectionPolicyFactory.h>
#import <EXUpdates/EXUpdatesUtils.h>
#import <React/RCTAssert.h>
#import <React/RCTReloadCommand.h>

NS_ASSUME_NONNULL_BEGIN

static NSString * const EXUpdatesAppControllerErrorDomain = @"EXUpdatesAppController";

static NSString * const EXUpdatesUpdateAvailableEventName = @"updateAvailable";
static NSString * const EXUpdatesNoUpdateAvailableEventName = @"noUpdateAvailable";
static NSString * const EXUpdatesErrorEventName = @"error";

@interface EXUpdatesAppController () <EXUpdatesErrorRecoveryDelegate>

@property (nonatomic, readwrite, strong) EXUpdatesConfig *config;
@property (nonatomic, readwrite, strong, nullable) id<EXUpdatesAppLauncher> launcher;
@property (nonatomic, readwrite, strong) EXUpdatesDatabase *database;
@property (nonatomic, readwrite, strong) EXUpdatesSelectionPolicy *selectionPolicy;
@property (nonatomic, readwrite, strong) EXUpdatesSelectionPolicy *defaultSelectionPolicy;
@property (nonatomic, readwrite, strong) EXUpdatesErrorRecovery *errorRecovery;
@property (nonatomic, readwrite, strong) dispatch_queue_t controllerQueue;
@property (nonatomic, readwrite, strong) dispatch_queue_t assetFilesQueue;

@property (nonatomic, readwrite, strong) NSURL *updatesDirectory;

@property (nonatomic, strong) id<EXUpdatesAppLauncher> candidateLauncher;
@property (nonatomic, assign) BOOL hasLaunched;

@property (nonatomic, assign) BOOL isStarted;
@property (nonatomic, assign) BOOL isEmergencyLaunch;

@property (nonatomic, readwrite, assign) EXUpdatesRemoteLoadStatus remoteLoadStatus;
@property (nonatomic, copy) RCTFatalHandler previousFatalErrorHandler;
@property (nonatomic, copy) RCTFatalExceptionHandler previousFatalExceptionHandler;

@end

@implementation EXUpdatesAppController

+ (instancetype)sharedInstance
{
  static EXUpdatesAppController *theController;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (!theController) {
      theController = [[EXUpdatesAppController alloc] init];
    }
  });
  return theController;
}

- (instancetype)init
{
  if (self = [super init]) {
    _config = [EXUpdatesConfig configWithExpoPlist];
    _database = [[EXUpdatesDatabase alloc] init];
    _defaultSelectionPolicy = [EXUpdatesSelectionPolicyFactory filterAwarePolicyWithRuntimeVersion:[EXUpdatesUtils getRuntimeVersionWithConfig:_config]];
    _errorRecovery = [EXUpdatesErrorRecovery new];
    _errorRecovery.delegate = self;
    _assetFilesQueue = dispatch_queue_create("expo.controller.AssetFilesQueue", DISPATCH_QUEUE_SERIAL);
    _controllerQueue = dispatch_queue_create("expo.controller.ControllerQueue", DISPATCH_QUEUE_SERIAL);
    _isStarted = NO;
    _remoteLoadStatus = EXUpdatesRemoteLoadStatusIdle;
  }
  return self;
}

- (void)setConfiguration:(NSDictionary *)configuration
{
  if (_isStarted) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"EXUpdatesAppController:setConfiguration should not be called after start"
                                 userInfo:@{}];
  }
  [_config loadConfigFromDictionary:configuration];
  [self resetSelectionPolicyToDefault];
}

- (EXUpdatesSelectionPolicy *)selectionPolicy
{
  if (!_selectionPolicy) {
    _selectionPolicy = _defaultSelectionPolicy;
  }
  return _selectionPolicy;
}

- (void)setNextSelectionPolicy:(EXUpdatesSelectionPolicy *)nextSelectionPolicy
{
  _selectionPolicy = nextSelectionPolicy;
}

- (void)resetSelectionPolicyToDefault
{
  _selectionPolicy = nil;
}

- (void)start
{
  NSAssert(!_isStarted, @"EXUpdatesAppController:start should only be called once per instance");

  [self _setRCTErrorHandlers];

  if (!_config.isEnabled) {
    EXUpdatesAppLauncherNoDatabase *launcher = [[EXUpdatesAppLauncherNoDatabase alloc] init];
    _launcher = launcher;
    [launcher launchUpdateWithConfig:_config];

    if (_delegate) {
      [_delegate appController:self didStartWithSuccess:self.launchAssetUrl != nil];
    }

    return;
  }

  if (!_config.updateUrl) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"expo-updates is enabled, but no valid URL is configured under EXUpdatesURL. If you are making a release build for the first time, make sure you have run `expo publish` at least once."
                                 userInfo:@{}];
  }
  if (!_config.scopeKey) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"expo-updates was configured with no scope key. Make sure a valid URL is configured under EXUpdatesURL."
                                 userInfo:@{}];
  }

  _isStarted = YES;

  NSError *fsError;
  [self initializeUpdatesDirectoryWithError:&fsError];
  if (fsError) {
    [self _emergencyLaunchWithFatalError:fsError];
    return;
  }

  NSError *dbError;
  if (![self initializeUpdatesDatabaseWithError:&dbError]) {
    [self _emergencyLaunchWithFatalError:dbError];
    return;
  }

  EXUpdatesAppLoaderTask *loaderTask = [[EXUpdatesAppLoaderTask alloc] initWithConfig:_config
                                                                             database:_database
                                                                            directory:_updatesDirectory
                                                                      selectionPolicy:self.selectionPolicy
                                                                        delegateQueue:_controllerQueue];
  loaderTask.delegate = self;
  [loaderTask start];
}

- (void)startAndShowLaunchScreen:(UIWindow *)window
{
  NSBundle *mainBundle = [NSBundle mainBundle];
  UIViewController *rootViewController = [UIViewController new];
  NSString *launchScreen = (NSString *)[mainBundle objectForInfoDictionaryKey:@"UILaunchStoryboardName"] ?: @"LaunchScreen";
  
  if ([mainBundle pathForResource:launchScreen ofType:@"nib"] != nil) {
    NSArray *views = [mainBundle loadNibNamed:launchScreen owner:self options:nil];
    rootViewController.view = views.firstObject;
    rootViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  } else if ([mainBundle pathForResource:launchScreen ofType:@"storyboard"] != nil ||
             [mainBundle pathForResource:launchScreen ofType:@"storyboardc"] != nil) {
    UIStoryboard *launchScreenStoryboard = [UIStoryboard storyboardWithName:launchScreen bundle:nil];
    rootViewController = [launchScreenStoryboard instantiateInitialViewController];
  } else {
    NSLog(@"Launch screen could not be loaded from a .xib or .storyboard. Unexpected loading behavior may occur.");
    UIView *view = [UIView new];
    view.backgroundColor = [UIColor whiteColor];
    rootViewController.view = view;
  }
  
  window.rootViewController = rootViewController;
  [window makeKeyAndVisible];

  [self start];
}

- (void)requestRelaunchWithCompletion:(EXUpdatesAppRelaunchCompletionBlock)completion
{
  EXUpdatesAppLauncherWithDatabase *launcher = [[EXUpdatesAppLauncherWithDatabase alloc] initWithConfig:_config database:_database directory:_updatesDirectory completionQueue:_controllerQueue];
  _candidateLauncher = launcher;
  [launcher launchUpdateWithSelectionPolicy:self.selectionPolicy completion:^(NSError * _Nullable error, BOOL success) {
    if (success) {
      self->_launcher = self->_candidateLauncher;
      completion(YES);
      [self _setRCTErrorHandlers];
      RCTReloadCommandSetBundleURL(launcher.launchAssetUrl);
      RCTTriggerReloadCommandListeners(@"Requested by JavaScript - Updates.reloadAsync()");
      [self runReaper];
    } else {
      NSLog(@"Failed to relaunch: %@", error.localizedDescription);
      completion(NO);
    }
  }];
}

- (nullable EXUpdatesUpdate *)launchedUpdate
{
  return _launcher.launchedUpdate ?: nil;
}

- (nullable NSURL *)launchAssetUrl
{
  return _launcher.launchAssetUrl ?: nil;
}

- (nullable NSDictionary *)assetFilesMap
{
  return _launcher.assetFilesMap ?: nil;
}

- (BOOL)isUsingEmbeddedAssets
{
  if (!_launcher) {
    return YES;
  }
  return _launcher.isUsingEmbeddedAssets;
}

# pragma mark - EXUpdatesAppLoaderTaskDelegate

- (BOOL)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didLoadCachedUpdate:(nonnull EXUpdatesUpdate *)update
{
  return YES;
}

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didStartLoadingUpdate:(EXUpdatesUpdate *)update
{
  _remoteLoadStatus = EXUpdatesRemoteLoadStatusLoading;
}

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didFinishWithLauncher:(id<EXUpdatesAppLauncher>)launcher isUpToDate:(BOOL)isUpToDate
{
  _launcher = launcher;
  if (self->_delegate) {
    [EXUpdatesUtils runBlockOnMainThread:^{
      [self->_delegate appController:self didStartWithSuccess:YES];
    }];
  }
}

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didFinishWithError:(NSError *)error
{
  [self _emergencyLaunchWithFatalError:error];
}

- (void)appLoaderTask:(EXUpdatesAppLoaderTask *)appLoaderTask didFinishBackgroundUpdateWithStatus:(EXUpdatesBackgroundUpdateStatus)status update:(nullable EXUpdatesUpdate *)update error:(nullable NSError *)error
{
  if (status == EXUpdatesBackgroundUpdateStatusError) {
    _remoteLoadStatus = EXUpdatesRemoteLoadStatusIdle;
    NSAssert(error != nil, @"Background update with error status must have a nonnull error object");
    [EXUpdatesUtils sendEventToBridge:_bridge withType:EXUpdatesErrorEventName body:@{@"message": error.localizedDescription}];
  } else if (status == EXUpdatesBackgroundUpdateStatusUpdateAvailable) {
    _remoteLoadStatus = EXUpdatesRemoteLoadStatusNewUpdateLoaded;
    NSAssert(update != nil, @"Background update with error status must have a nonnull update object");
    [EXUpdatesUtils sendEventToBridge:_bridge withType:EXUpdatesUpdateAvailableEventName body:@{@"manifest": update.manifest.rawManifestJSON}];
  } else if (status == EXUpdatesBackgroundUpdateStatusNoUpdateAvailable) {
    _remoteLoadStatus = EXUpdatesRemoteLoadStatusIdle;
    [EXUpdatesUtils sendEventToBridge:_bridge withType:EXUpdatesNoUpdateAvailableEventName body:@{}];
  }
  [_errorRecovery notifyNewRemoteLoadStatus:_remoteLoadStatus];
}

# pragma mark - EXUpdatesAppController+Internal

- (BOOL)initializeUpdatesDirectoryWithError:(NSError ** _Nullable)error
{
  _updatesDirectory = [EXUpdatesUtils initializeUpdatesDirectoryWithError:error];
  return _updatesDirectory != nil;
}

- (BOOL)initializeUpdatesDatabaseWithError:(NSError ** _Nullable)error
{
  __block NSError *dbError;
  dispatch_semaphore_t dbSemaphore = dispatch_semaphore_create(0);
  dispatch_async(_database.databaseQueue, ^{
    [self->_database openDatabaseInDirectory:self->_updatesDirectory withError:&dbError];
    dispatch_semaphore_signal(dbSemaphore);
  });

  dispatch_semaphore_wait(dbSemaphore, DISPATCH_TIME_FOREVER);
  if (dbError && error) {
    *error = dbError;
  }
  return dbError == nil;
}

- (void)setDefaultSelectionPolicy:(EXUpdatesSelectionPolicy *)selectionPolicy
{
  _defaultSelectionPolicy = selectionPolicy;
}

- (void)setLauncher:(nullable id<EXUpdatesAppLauncher>)launcher
{
  _launcher = launcher;
}

- (void)setConfigurationInternal:(EXUpdatesConfig *)configuration
{
  _config = configuration;
}

- (void)setIsStarted:(BOOL)isStarted
{
  _isStarted = isStarted;
}

- (void)runReaper
{
  if (_launcher.launchedUpdate) {
    [EXUpdatesReaper reapUnusedUpdatesWithConfig:_config
                                        database:_database
                                       directory:_updatesDirectory
                                 selectionPolicy:self.selectionPolicy
                                  launchedUpdate:_launcher.launchedUpdate];
  }
}

# pragma mark - EXUpdatesErrorRecoveryDelegate

- (void)relaunchWithCompletion:(EXUpdatesAppLauncherCompletionBlock)completion
{
  EXUpdatesAppLauncherWithDatabase *launcher = [[EXUpdatesAppLauncherWithDatabase alloc] initWithConfig:_config database:_database directory:_updatesDirectory completionQueue:_controllerQueue];
  _candidateLauncher = launcher;
  [launcher launchUpdateWithSelectionPolicy:self.selectionPolicy completion:^(NSError * _Nullable error, BOOL success) {
    if (success) {
      self->_launcher = self->_candidateLauncher;
      [self _setRCTErrorHandlers];
      RCTReloadCommandSetBundleURL(launcher.launchAssetUrl);
      RCTTriggerReloadCommandListeners(@"Relaunch after fatal error");
      completion(nil, YES);
    } else {
      completion(error, NO);
    }
  }];
}

- (BOOL)relaunchUsingEmbeddedUpdate
{
  _isEmergencyLaunch = YES;

  EXUpdatesAppLauncherNoDatabase *launcher = [[EXUpdatesAppLauncherNoDatabase alloc] init];
  _launcher = launcher;
  [launcher launchUpdateWithConfig:_config];
  if (!launcher.launchAssetUrl) {
    return NO;
  }

  [self _setRCTErrorHandlers];
  RCTReloadCommandSetBundleURL(launcher.launchAssetUrl);
  RCTTriggerReloadCommandListeners(@"Relaunch after fatal error");

  return YES;
}

# pragma mark - internal

- (void)_emergencyLaunchWithFatalError:(NSError *)error
{
  _isEmergencyLaunch = YES;

  EXUpdatesAppLauncherNoDatabase *launcher = [[EXUpdatesAppLauncherNoDatabase alloc] init];
  _launcher = launcher;
  [launcher launchUpdateWithConfig:_config fatalError:error];

  if (_delegate) {
    [EXUpdatesUtils runBlockOnMainThread:^{
      [self->_delegate appController:self didStartWithSuccess:self.launchAssetUrl != nil];
    }];
  }
}

- (void)_registerObservers
{
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleJavaScriptDidLoad) name:RCTJavaScriptDidLoadNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleJavaScriptDidFailToLoad) name:RCTJavaScriptDidFailToLoadNotification object:nil];
}

- (void)_unregisterObservers
{
  [[NSNotificationCenter defaultCenter] removeObserver:self name:RCTJavaScriptDidLoadNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:RCTJavaScriptDidFailToLoadNotification object:nil];
}

- (void)_handleJavaScriptDidLoad
{
  [self _unregisterObservers];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), _controllerQueue, ^{
    [self _unsetRCTErrorHandlers];
  });
}

- (void)_handleJavaScriptDidFailToLoad
{
  [self _unregisterObservers];
}

- (void)_setRCTErrorHandlers
{
  [self _registerObservers];

  if (_previousFatalErrorHandler || _previousFatalExceptionHandler) {
    return;
  }

  _previousFatalErrorHandler = RCTGetFatalHandler();
  _previousFatalExceptionHandler = RCTGetFatalExceptionHandler();

  RCTFatalHandler fatalErrorHandler = ^(NSError *error) {
    [self->_errorRecovery handleError:error fromLaunchedUpdate:self.launchedUpdate];
  };
  RCTFatalExceptionHandler fatalExceptionHandler = ^(NSException *exception) {
    [self->_errorRecovery handleException:exception fromLaunchedUpdate:self.launchedUpdate];
  };
  RCTSetFatalHandler(fatalErrorHandler);
  RCTSetFatalExceptionHandler(fatalExceptionHandler);
}

- (void)_unsetRCTErrorHandlers
{
  RCTSetFatalHandler(_previousFatalErrorHandler);
  RCTSetFatalExceptionHandler(_previousFatalExceptionHandler);
  _previousFatalErrorHandler = nil;
  _previousFatalExceptionHandler = nil;
}

@end

NS_ASSUME_NONNULL_END
