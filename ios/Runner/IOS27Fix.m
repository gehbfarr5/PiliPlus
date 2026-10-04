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
//    (e.g. QuanNengQian / ESign / Feather) by synchronizing MediaRemote MRClient
//    and NSBundle mainBundle identifier with the provisioning profile's
//    application-identifier entitlement.
// 2. Fixes iOS 27 portrait <-> landscape video rotation horizontal stretching
//    (#2780) by enforcing aspect-preserving contentsGravity (kCAGravityResizeAspect)
//    on FlutterView's CAMetalLayer and smoothing UIWindowScene rotation transitions.
// ============================================================================

static NSString *gSignedBundleID = nil;
static NSString *gSignedDisplayName = nil;

// Extract the actual signed application-identifier from embedded.mobileprovision
// or LSApplicationProxy so it works with ANY P12 certificate automatically.
static NSString *detectSignedBundleIdentifier(void) {
    // 1. Try reading embedded.mobileprovision
    NSString *provisionPath = [[NSBundle mainBundle] pathForResource:@"embedded" ofType:@"mobileprovision"];
    if (provisionPath) {
        NSData *data = [NSData dataWithContentsOfFile:provisionPath];
        if (data.length > 0) {
            NSString *raw = [[NSString alloc] initWithBytes:data.bytes length:data.length encoding:NSISOLatin1StringEncoding];
            if (raw) {
                NSRange keyRange = [raw rangeOfString:@"<key>application-identifier</key>"];
                if (keyRange.location != NSNotFound) {
                    NSString *sub = [raw substringFromIndex:NSMaxRange(keyRange)];
                    NSRange sStart = [sub rangeOfString:@"<string>"];
                    NSRange sEnd = [sub rangeOfString:@"</string>"];
                    if (sStart.location != NSNotFound && sEnd.location != NSNotFound && sEnd.location > sStart.location) {
                        NSString *appId = [sub substringWithRange:NSMakeRange(NSMaxRange(sStart), sEnd.location - NSMaxRange(sStart))];
                        NSRange dot = [appId rangeOfString:@"."];
                        if (dot.location != NSNotFound) {
                            NSString *bundleId = [appId substringFromIndex:dot.location + 1];
                            if (bundleId.length > 0 && ![bundleId containsString:@"*"]) {
                                return bundleId;
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. Try LSApplicationProxy
    @try {
        Class proxyCls = NSClassFromString(@"LSApplicationProxy");
        SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyCls && [proxyCls respondsToSelector:sel]) {
            id (*msgSend)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id proxy = msgSend(proxyCls, sel, nil);
            SEL appIdSel = NSSelectorFromString(@"applicationIdentifier");
            if (proxy && [proxy respondsToSelector:appIdSel]) {
                id (*msgSend0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                NSString *appId = msgSend0(proxy, appIdSel);
                if ([appId isKindOfClass:[NSString class]] && appId.length > 0) {
                    return appId;
                }
            }
        }
    } @catch (__unused NSException *e) {}

    return [[NSBundle mainBundle] objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleIdentifierKey];
}

// Synchronize MediaRemote MRClient properties with the real signed Bundle ID
static void syncMediaRemoteNowPlayingClient(void) {
    if (!gSignedBundleID.length) return;
    static void *mrHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mrHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    if (!mrHandle) return;

    @try {
        typedef void *(*MRGetLocalOriginFn)(void);
        typedef void (*MRSetClientPropsFn)(void *origin, void *client, dispatch_queue_t queue, void (^completion)(CFErrorRef));
        typedef void (*MRSetParentAppFn)(void *client, CFStringRef parentBundleID);

        MRGetLocalOriginFn getLocalOrigin = (MRGetLocalOriginFn)dlsym(mrHandle, "MRMediaRemoteGetLocalOrigin");
        MRSetClientPropsFn setClientProps = (MRSetClientPropsFn)dlsym(mrHandle, "MRMediaRemoteSetClientProperties");
        MRSetParentAppFn setParentApp = (MRSetParentAppFn)dlsym(mrHandle, "MRMediaRemoteSetParentApplication");

        Class mrClientCls = NSClassFromString(@"MRClient");
        if (mrClientCls && getLocalOrigin && setClientProps) {
            void *origin = getLocalOrigin();
            id client = [[mrClientCls alloc] init];
            if (client) {
                @try { [client setValue:gSignedBundleID forKey:@"bundleIdentifier"]; } @catch (__unused NSException *e) {}
                if (gSignedDisplayName.length) {
                    @try { [client setValue:gSignedDisplayName forKey:@"displayName"]; } @catch (__unused NSException *e) {}
                }
                if (setParentApp) {
                    setParentApp((__bridge void *)client, (__bridge CFStringRef)gSignedBundleID);
                }
                setClientProps(origin, (__bridge void *)client, dispatch_get_main_queue(), nil);
            }
        }
    } @catch (__unused NSException *e) {}
}

// ============================================================================
// Part 1: NSBundle & MPNowPlayingInfoCenter Hooks
// ============================================================================

static NSString *(*orig_NSBundle_bundleIdentifier)(NSBundle *self, SEL _cmd) = NULL;
static NSString *swizzled_NSBundle_bundleIdentifier(NSBundle *self, SEL _cmd) {
    if (self == [NSBundle mainBundle] && gSignedBundleID.length > 0) {
        return gSignedBundleID;
    }
    return orig_NSBundle_bundleIdentifier(self, _cmd);
}

static void (*orig_setNowPlayingInfo)(id self, SEL _cmd, NSDictionary *info) = NULL;
static void swizzled_setNowPlayingInfo(id self, SEL _cmd, NSDictionary *info) {
    orig_setNowPlayingInfo(self, _cmd, info);
    if (info != nil) {
        syncMediaRemoteNowPlayingClient();
    }
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
        gSignedBundleID = [detectSignedBundleIdentifier() copy];
        gSignedDisplayName = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                              ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"]
                              ?: @"PiliPlus" copy];

        // 1. Hook NSBundle.bundleIdentifier to ensure runtime consistency with signed entitlement
        Method bundleIdMethod = class_getInstanceMethod([NSBundle class], @selector(bundleIdentifier));
        if (bundleIdMethod) {
            orig_NSBundle_bundleIdentifier = (NSString *(*)(NSBundle *, SEL))method_getImplementation(bundleIdMethod);
            method_setImplementation(bundleIdMethod, (IMP)swizzled_NSBundle_bundleIdentifier);
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
