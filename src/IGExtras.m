// IGExtras: reels sound on by default, optionally hide tab-bar buttons.
#import "igd_common.h"
#define BUILD @"x2"

// ---- sound on by default -----------------------------------------------------
// Instagram calls _setMuted:isUserInitiated:reason: both for automatic mute (reels open muted)
// and when you tap the speaker. Only the automatic ones are overridden.
static void hookUnmute(void) {
    SEL sel = sel_registerName("_setMuted:isUserInitiated:reason:");
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    int hooked = 0;
    for (unsigned i = 0; i < n; i++) {
        Class c = list[i];
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        Class sup = class_getSuperclass(c);
        Method sm = sup ? class_getInstanceMethod(sup, sel) : NULL;
        if (sm && method_getImplementation(sm) == method_getImplementation(m)) continue;   // inherited: hooked on the owner
        if (method_getNumberOfArguments(m) != 5) continue;
        IMP orig = method_getImplementation(m);
        IMP imp = imp_implementationWithBlock(^(id self, BOOL muted, BOOL user, long reason) {
            if (!user && raOn(@"x.unmute")) muted = NO;
            ((void (*)(id, SEL, BOOL, BOOL, long))orig)(self, sel, muted, user, reason);
        });
        method_setImplementation(m, imp);
        hooked++;
        [igdStatus() addObject:[NSString stringWithFormat:@"✓ %s _setMuted:isUserInitiated:reason:", class_getName(c)]];
    }
    free(list);
    if (!hooked) [igdStatus() addObject:@"✗ unmute (no class has _setMuted:isUserInitiated:reason:)"];
}

// ---- hide tab-bar buttons ----------------------------------------------------
static void hideTabs(UIView *v, int depth) {
    if (depth > 6) return;
    for (UIView *s in v.subviews) {
        NSString *cn = NSStringFromClass(s.class);
        if ([cn containsString:@"TabBarButton"]) {
            NSString *id_ = [[NSString stringWithFormat:@"%@ %@", s.accessibilityIdentifier ?: @"", s.accessibilityLabel ?: @""] lowercaseString];
            BOOL reels = [id_ containsString:@"reels"] || [id_ containsString:@"clips"] || [id_ containsString:@"ريلز"];
            BOOL explore = [id_ containsString:@"explore"] || [id_ containsString:@"search"] || [id_ containsString:@"بحث"] || [id_ containsString:@"استكشاف"];
            BOOL hide = (reels && raOn(@"x.hide.reels")) || (explore && raOn(@"x.hide.explore"));
            if (hide != s.hidden) s.hidden = hide;
        } else hideTabs(s, depth + 1);
    }
}

// ---- hide the "It's time to update Instagram Beta" screen ------------------------
static void dismissNag(UIViewController *vc) {
    if (!raOn(@"x.nonag")) return;
    vc.view.hidden = YES;
    UIWindow *w = vc.view.window;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vc.presentingViewController) [vc dismissViewControllerAnimated:NO completion:nil];
        else if (vc.parentViewController) { [vc willMoveToParentViewController:nil]; [vc.view removeFromSuperview]; [vc removeFromParentViewController]; }
        else if (w && w.rootViewController == vc) w.hidden = YES;
        else [vc.view removeFromSuperview];
    });
}
static void hookNag(void) {
    const char *C = "_TtC29IGCoreRootTestFlightNagPlugin35TestFlightUpdateNudgeViewController";
    for (const char *sel : (const char *[]){"viewDidLoad", "viewDidAppear:"}) {
        igdHook(C, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (ret != 'v') return nil;
            if (nargs == 0) return ^(UIViewController *self) { ((void (*)(id, SEL))orig)(self, s); dismissNag(self); };
            if (nargs == 1) return ^(UIViewController *self, BOOL a) { ((void (*)(id, SEL, BOOL))orig)(self, s, a); dismissNag(self); };
            return nil;
        });
    }
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"الواجهة", @"x.nonag", @"إخفاء تنبيه «حدّث Instagram Beta»", @"يمنع شاشة تحديث TestFlight من الظهور");
    raRegister(@"الصوت", @"x.unmute", @"تشغيل الريلز بصوت", @"يفك الكتم التلقائي (ضغطك على زر الصوت يبقى يشتغل)");
    raRegisterD(@"الواجهة", @"x.hide.reels", @"إخفاء تبويب الريلز", @"من الشريط السفلي", NO);
    raRegisterD(@"الواجهة", @"x.hide.explore", @"إخفاء تبويب البحث/الاستكشاف", @"من الشريط السفلي", NO);
    igdRun(@"IGExtras", BUILD, ^{
        static BOOL done;
        if (!done) { done = YES; hookUnmute(); hookNag(); }
        igdHook("IGTabBar", "layoutSubviews", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (ret != 'v' || nargs != 0) return nil;
            return ^(UIView *self) { ((void (*)(id, SEL))orig)(self, s); hideTabs(self, 0); };
        });
    });
}
