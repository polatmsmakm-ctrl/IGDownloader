// IGExtras: reels sound on by default, optionally hide tab-bar buttons.
#import "igd_common.h"
#define BUILD @"x3"

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
    raRegisterD(@"الواجهة", @"x.hide.reels", @"إخفاء تبويب الريلز", @"من الشريط السفلي", NO);
    raRegisterD(@"الواجهة", @"x.hide.explore", @"إخفاء تبويب البحث/الاستكشاف", @"من الشريط السفلي", NO);
    igdRun(@"IGExtras", BUILD, ^{
        static BOOL done;
        if (!done) { done = YES; hookNag(); }
        igdHook("IGTabBar", "layoutSubviews", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (ret != 'v' || nargs != 0) return nil;
            return ^(UIView *self) { ((void (*)(id, SEL))orig)(self, s); hideTabs(self, 0); };
        });
    });
}
