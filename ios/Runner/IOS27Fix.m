#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ============================================================================
// PiliPlus iOS 27 Compatibility & Rotation Fix
// 1. Fixes Dynamic Island / Control Center / Lock Screen Now Playing tap-to-jump
//    and foreground Dynamic Island popup (#3108) when signed with P12 certificates
//    (e.g. QuanNengQian) where the certificate's provisioning profile
//    application-identifier differs from Info.plist's CFBundleIdentifier
//    (allowing PiliPlus and YouTube to use different CFBundleIdentifiers and coexist).
//    In iOS 27, mediaremoted derives the initial XPC client bundleIdentifier from
//    SecTaskCopyValueForEntitlement("application-identifier") via MSVBundleIDForAuditToken.
//    By calling MRMediaRemoteSetParentApplication(origin, appBundleID) and
//    MRMediaRemoteSetClientProperties(client, origin, queue, completion) with
//    Info.plist's CFBundleIdentifier (com.example.piliplus), SpringBoard and
//    mediaremoted associate the Now Playing session with PiliPlus's own Bundle ID.
// 2. Fixes iOS 27 portrait <-> landscape video rotation horizontal stretching
//    (#2780) by enforcing aspect-preserving contentsGravity (kCAGravityResizeAspect)
//    on FlutterView's CAMetalLayer and smoothing UIWindowScene rotation transitions.
// ============================================================================

static NSString *gAppBundleID = nil;
static NSString *gAppDisplayName = nil;

// Read the actual CFBundleIdentifier from Info.plist on disk so LaunchServices /
// SpringBoard and MediaRemote use the exact installed Bundle ID of PiliPlus.
static NSString *detectInstalledBundleIdentifier(void) {
    NSString *plistPath = [[NSBundle mainBundle] pathForResource:@"Info" ofType:@"plist"];
    if (plistPath) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString *bid = dict[@"CFBundleIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            return bid;
        }
    }
    CFBundleRef mainBundle = CFBundleGetMainBundle();
    if (mainBundle) {
        CFStringRef cfBid = CFBundleGetIdentifier(mainBundle);
        if (cfBid && CFStringGetLength(cfBid) > 0) {
            return (__bridge NSString *)cfBid;
        }
    }
    return @"com.example.piliplus";
}

// Synchronize MediaRemote MRClient & ParentApplication with PiliPlus's Info.plist CFBundleIdentifier
static void syncMediaRemoteNowPlayingClient(void) {
    if (!gAppBundleID.length) return;
    static void *mrHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mrHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    if (!mrHandle) return;

    @try {
        // Verified exact signatures from MediaRemote.framework disassembly:
        // void *MRMediaRemoteGetLocalOrigin(void);
        // void MRMediaRemoteSetParentApplication(void *origin, CFStringRef parentAppBundleID);
        // void MRMediaRemoteSetClientProperties(void *client, void *origin, dispatch_queue_t queue, void (^completion)(CFErrorRef));
        typedef void *(*MRGetLocalOriginFn)(void);
        typedef void (*MRSetParentAppFn)(void *origin, CFStringRef parentBundleID);
        typedef void (*MRSetClientPropsFn)(void *client, void *origin, dispatch_queue_t queue, void (^completion)(CFErrorRef));

        MRGetLocalOriginFn getLocalOrigin = (MRGetLocalOriginFn)dlsym(mrHandle, "MRMediaRemoteGetLocalOrigin");
        MRSetParentAppFn setParentApp = (MRSetParentAppFn)dlsym(mrHandle, "MRMediaRemoteSetParentApplication");
        MRSetClientPropsFn setClientProps = (MRSetClientPropsFn)dlsym(mrHandle, "MRMediaRemoteSetClientProperties");

        if (!getLocalOrigin) return;
        void *origin = getLocalOrigin();
        if (!origin) return;

        // 1. Set ParentApplication on LocalOrigin to PiliPlus's CFBundleIdentifier (com.example.piliplus).
        //    This updates MRDNowPlayingClient.parentApplicationBundleIdentifier in mediaremoted,
        //    which SpringBoard uses both to suppress foreground Dynamic Island (#3108) and to
        //    launch PiliPlus when tapping Dynamic Island / Control Center / Lock Screen controls.
        if (setParentApp) {
            setParentApp(origin, (__bridge CFStringRef)gAppBundleID);
        }

        // 2. Also update MRClient properties (bundleIdentifier, parentApplicationBundleIdentifier, displayName)
        Class mrClientCls = NSClassFromString(@"MRClient");
        if (mrClientCls && setClientProps) {
            id client = nil;
            SEL localClientSel = NSSelectorFromString(@"localClient");
            if ([mrClientCls respondsToSelector:localClientSel]) {
                id (*msgSend0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id sharedLocal = msgSend0(mrClientCls, localClientSel);
                if ([sharedLocal respondsToSelector:@selector(copy)]) {
                    client = [sharedLocal copy];
                }
            }
            if (!client) {
                client = [[mrClientCls alloc] init];
            }
            if (client) {
                @try { [client setValue:gAppBundleID forKey:@"bundleIdentifier"]; } @catch (__unused NSException *e) {}
                @try { [client setValue:gAppBundleID forKey:@"parentApplicationBundleIdentifier"]; } @catch (__unused NSException *e) {}
                if (gAppDisplayName.length) {
                    @try { [client setValue:gAppDisplayName forKey:@"displayName"]; } @catch (__unused NSException *e) {}
                }
                setClientProps((__bridge void *)client, origin, dispatch_get_main_queue(), nil);
            }
        }
    } @catch (__unused NSException *e) {}
}

// ============================================================================
// Part 1: MPNowPlayingInfoCenter & MRClient Hooks
// ============================================================================

static void (*orig_setNowPlayingInfo)(id self, SEL _cmd, NSDictionary *info) = NULL;
static void swizzled_setNowPlayingInfo(id self, SEL _cmd, NSDictionary *info) {
    if (info != nil) {
        syncMediaRemoteNowPlayingClient();
    }
    orig_setNowPlayingInfo(self, _cmd, info);
    if (info != nil) {
        syncMediaRemoteNowPlayingClient();
    }
}

static NSString *(*orig_MRClient_parentAppBundleID)(id self, SEL _cmd) = NULL;
static NSString *swizzled_MRClient_parentAppBundleID(id self, SEL _cmd) {
    NSString *orig = orig_MRClient_parentAppBundleID ? orig_MRClient_parentAppBundleID(self, _cmd) : nil;
    if (orig.length > 0) return orig;
    return gAppBundleID;
}

static NSString *(*orig_MRClient_bundleID)(id self, SEL _cmd) = NULL;
static NSString *swizzled_MRClient_bundleID(id self, SEL _cmd) {
    if (gAppBundleID.length > 0) {
        return gAppBundleID;
    }
    return orig_MRClient_bundleID ? orig_MRClient_bundleID(self, _cmd) : nil;
}

// ============================================================================
// Part 2: FlutterView / CAMetalLayer / FlutterViewController Rotation Fix (#2780)
// ============================================================================

static BOOL isFlutterViewLayer(CALayer *layer) {
    if (!layer) return NO;
    id delegate = layer.delegate;
    if (delegate) {
        NSString *clsName = NSStringFromClass([delegate class]);
        if ([clsName containsString:@"FlutterView"]) {
            return YES;
        }
    }
    return NO;
}

static void (*orig_CALayer_setContentsGravity)(CALayer *self, SEL _cmd, CALayerContentsGravity gravity) = NULL;
static void swizzled_CALayer_setContentsGravity(CALayer *self, SEL _cmd, CALayerContentsGravity gravity) {
    // Prevent FlutterView's backing CAMetalLayer from using kCAGravityResize (scaleToFill),
    // which stretches the portrait Metal drawable horizontally across the landscape screen
    // before the new orientation's frame finishes rasterizing on iOS 27.
    if (isFlutterViewLayer(self) && [gravity isEqualToString:kCAGravityResize]) {
        gravity = kCAGravityResizeAspect;
    }
    orig_CALayer_setContentsGravity(self, _cmd, gravity);
}

static id<CAAction> (*orig_CALayer_actionForKey)(CALayer *self, SEL _cmd, NSString *event) = NULL;
static id<CAAction> swizzled_CALayer_actionForKey(CALayer *self, SEL _cmd, NSString *event) {
    if (isFlutterViewLayer(self)) {
        // Suppress implicit CoreAnimation content-stretching actions during rotation
        if ([event isEqualToString:@"contents"] ||
            [event isEqualToString:@"bounds"] ||
            [event isEqualToString:@"position"]) {
            return (id<CAAction>)[NSNull null];
        }
    }
    return orig_CALayer_actionForKey(self, _cmd, event);
}

static void configureFlutterViewForRotation(UIView *view) {
    if (!view) return;
    view.backgroundColor = [UIColor blackColor];
    view.contentMode = UIViewContentModeScaleAspectFit;
    view.clipsToBounds = YES;
    view.layer.backgroundColor = [UIColor blackColor].CGColor;
    if (orig_CALayer_setContentsGravity) {
        orig_CALayer_setContentsGravity(view.layer, @selector(setContentsGravity:), kCAGravityResizeAspect);
    } else {
        view.layer.contentsGravity = kCAGravityResizeAspect;
    }
}

static void (*orig_FVC_viewDidLoad)(UIViewController *self, SEL _cmd) = NULL;
static void swizzled_FVC_viewDidLoad(UIViewController *self, SEL _cmd) {
    orig_FVC_viewDidLoad(self, _cmd);
    configureFlutterViewForRotation(self.view);
}

static void (*orig_FVC_viewWillTransition)(UIViewController *self, SEL _cmd, CGSize size, id<UIViewControllerTransitionCoordinator> coordinator) = NULL;
static void swizzled_FVC_viewWillTransition(UIViewController *self, SEL _cmd, CGSize size, id<UIViewControllerTransitionCoordinator> coordinator) {
    UIView *flutterView = self.view;
    configureFlutterViewForRotation(flutterView);

    orig_FVC_viewWillTransition(self, _cmd, size, coordinator);

    if (coordinator) {
        [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            configureFlutterViewForRotation(flutterView);
            [CATransaction commit];
        } completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            configureFlutterViewForRotation(flutterView);
        }];
    }
}

// ============================================================================
// Constructor Initialization
// ============================================================================

__attribute__((constructor))
static void PiliPlusIOS27FixInit(void) {
    @autoreleasepool {
        gAppBundleID = [detectInstalledBundleIdentifier() copy];
        gAppDisplayName = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                           ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"]
                           ?: @"PiliPlus" copy];

        // 1. Hook MediaRemote MRClient to ensure parentApplicationBundleIdentifier & bundleIdentifier
        //    always match PiliPlus's Info.plist CFBundleIdentifier (com.example.piliplus)
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        Class mrClientCls = NSClassFromString(@"MRClient");
        if (mrClientCls) {
            Method parentMethod = class_getInstanceMethod(mrClientCls, NSSelectorFromString(@"parentApplicationBundleIdentifier"));
            if (parentMethod) {
                orig_MRClient_parentAppBundleID = (NSString *(*)(id, SEL))method_getImplementation(parentMethod);
                method_setImplementation(parentMethod, (IMP)swizzled_MRClient_parentAppBundleID);
            }
            Method bidMethod = class_getInstanceMethod(mrClientCls, NSSelectorFromString(@"bundleIdentifier"));
            if (bidMethod) {
                orig_MRClient_bundleID = (NSString *(*)(id, SEL))method_getImplementation(bidMethod);
                method_setImplementation(bidMethod, (IMP)swizzled_MRClient_bundleID);
            }
        }

        // 2. Hook MPNowPlayingInfoCenter.setNowPlayingInfo: to sync MediaRemote MRClient
        Class npCls = [MPNowPlayingInfoCenter class];
        Method setNPMethod = class_getInstanceMethod(npCls, @selector(setNowPlayingInfo:));
        if (setNPMethod) {
            orig_setNowPlayingInfo = (void (*)(id, SEL, NSDictionary *))method_getImplementation(setNPMethod);
            method_setImplementation(setNPMethod, (IMP)swizzled_setNowPlayingInfo);
        }

        // 3. Hook CALayer contentsGravity & actionForKey: for FlutterView anti-stretch
        Method gravityMethod = class_getInstanceMethod([CALayer class], @selector(setContentsGravity:));
        if (gravityMethod) {
            orig_CALayer_setContentsGravity = (void (*)(CALayer *, SEL, CALayerContentsGravity))method_getImplementation(gravityMethod);
            method_setImplementation(gravityMethod, (IMP)swizzled_CALayer_setContentsGravity);
        }

        Method actionMethod = class_getInstanceMethod([CALayer class], @selector(actionForKey:));
        if (actionMethod) {
            orig_CALayer_actionForKey = (id<CAAction> (*)(CALayer *, SEL, NSString *))method_getImplementation(actionMethod);
            method_setImplementation(actionMethod, (IMP)swizzled_CALayer_actionForKey);
        }

        // 4. Hook FlutterViewController rotation lifecycle
        Class fvcCls = NSClassFromString(@"FlutterViewController");
        if (fvcCls) {
            Method vdlMethod = class_getInstanceMethod(fvcCls, @selector(viewDidLoad));
            if (vdlMethod) {
                orig_FVC_viewDidLoad = (void (*)(UIViewController *, SEL))method_getImplementation(vdlMethod);
                method_setImplementation(vdlMethod, (IMP)swizzled_FVC_viewDidLoad);
            }
            SEL vwtSel = @selector(viewWillTransitionToSize:withTransitionCoordinator:);
            Method vwtMethod = class_getInstanceMethod(fvcCls, vwtSel);
            if (vwtMethod) {
                orig_FVC_viewWillTransition = (void (*)(UIViewController *, SEL, CGSize, id<UIViewControllerTransitionCoordinator>))method_getImplementation(vwtMethod);
                method_setImplementation(vwtMethod, (IMP)swizzled_FVC_viewWillTransition);
            }
        }

        // 5. Sync MediaRemote on app launch / foreground activation
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            syncMediaRemoteNowPlayingClient();
        }];
    }
}
