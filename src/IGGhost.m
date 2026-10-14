// IGGhost: stop broadcasting your activity — typing indicator and story "seen".
#import "igd_common.h"
#define BUILD @"g4"

// Make a method do nothing (void) or return NO (BOOL).
static void silence(const char *cls, const char *sel, NSString *key) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret == 'v') {
            if (nargs == 0) return ^(id self) { if (!raOn(key)) ((void (*)(id, SEL))orig)(self, s); };
            if (nargs == 1) return ^(id self, id a) { if (!raOn(key)) ((void (*)(id, SEL, id))orig)(self, s, a); };
            if (nargs == 2) return ^(id self, id a, id b) { if (!raOn(key)) ((void (*)(id, SEL, id, id))orig)(self, s, a, b); };
            return nil;
        }
        if (ret == 'B' || ret == 'c') {
            if (nargs == 0) return ^BOOL(id self) { return raOn(key) ? NO : ((BOOL (*)(id, SEL))orig)(self, s); };
            if (nargs == 1) return ^BOOL(id self, id a) { return raOn(key) ? NO : ((BOOL (*)(id, SEL, id))orig)(self, s, a); };
            return nil;
        }
        return nil;
    });
}


// ---- story seen: hidden by default, eye button marks the current story as seen -------------
static IMP gStoryOrig;
static __weak id gStoryCtl, gStoryA, gStoryB;
static __weak UIViewController *gStoryVC;
static UIButton *gStoryEye;

static void styleStoryEye(BOOL sent) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
    [gStoryEye setImage:[UIImage systemImageNamed:(sent ? @"eye.fill" : @"eye.slash") withConfiguration:cfg] forState:UIControlStateNormal];
    gStoryEye.tintColor = sent ? UIColor.systemGreenColor : UIColor.whiteColor;
}
static void sendStorySeen(void) {
    id c = gStoryCtl;
    if (!c || !gStoryOrig) { igdToast(@"IGGhost: ما في ستوري جاهز للتسجيل"); return; }
    ((void (*)(id, SEL, id, id))gStoryOrig)(c, sel_registerName("fullscreenSectionController:didMarkItemAsSeen:"), gStoryA, gStoryB);
    styleStoryEye(YES);
    igdToast(@"تم تسجيل مشاهدة الستوري");
}
static void placeStoryEye(void) {
    UIWindow *w = igdKeyWindow();
    if (!raOn(@"gh.story") || !gStoryVC || !gStoryVC.viewIfLoaded.window || !w) { gStoryEye.hidden = YES; return; }
    if (!gStoryEye) {
        gStoryEye = [UIButton buttonWithType:UIButtonTypeCustom];
        gStoryEye.bounds = CGRectMake(0, 0, 40, 40);
        gStoryEye.layer.cornerRadius = 20;
        gStoryEye.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        styleStoryEye(NO);
        [gStoryEye addAction:[UIAction actionWithHandler:^(UIAction *a) { sendStorySeen(); }] forControlEvents:UIControlEventTouchUpInside];
    }
    if (gStoryEye.superview != w) [w addSubview:gStoryEye];
    [w bringSubviewToFront:gStoryEye];
    gStoryEye.center = CGPointMake(w.bounds.size.width * 0.868, w.bounds.size.height * 0.90);   // above the like button
    gStoryEye.hidden = NO;
}
static void schedStoryEye(void) {
    for (NSNumber *d in @[@0.05, @0.4, @1.2])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ placeStoryEye(); });
}
static void hookStory(void) {
    const char *C = "IGStoryViewerViewController";
    igdHook(C, "fullscreenSectionController:didMarkItemAsSeen:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 2) return nil;
        gStoryOrig = orig;
        return ^(id self, id a, id b) {
            gStoryCtl = self; gStoryA = a; gStoryB = b;     // remember the latest item so the eye can send it
            styleStoryEye(NO);
            if (!raOn(@"gh.story")) ((void (*)(id, SEL, id, id))orig)(self, s, a, b);
        };
    });
    igdHook(C, "viewDidAppear:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        return ^(id self, BOOL a) { ((void (*)(id, SEL, BOOL))orig)(self, s, a); gStoryVC = self; schedStoryEye(); };
    });
    igdHook(C, "viewDidDisappear:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        return ^(id self, BOOL a) {
            ((void (*)(id, SEL, BOOL))orig)(self, s, a);
            if (gStoryVC == self) { gStoryVC = nil; gStoryEye.hidden = YES; }
        };
    });
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"الخصوصية", @"gh.typing", @"إخفاء \"يكتب الآن\"", @"الطرف الثاني ما يشوف إنك تكتب");
    raRegister(@"الخصوصية", @"gh.story", @"إخفاء مشاهدة الستوري", @"تشوف الستوري بدون ما تظهر في قائمة المشاهدين");
    igdRun(@"IGGhost", BUILD, ^{
        // typing indicator: drop "I'm typing" updates, still pass "stopped typing"
        igdHook("IGDirectTypingStatusService", "updateOutgoingStatusIsActive:threadKey:threadMetadata:typingStatusType:",
                ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (ret != 'v' || nargs != 4) return nil;
            return ^(id self, BOOL active, id key, id meta, long type) {
                if (active && raOn(@"gh.typing")) return;
                ((void (*)(id, SEL, BOOL, id, id, long))orig)(self, s, active, key, meta, type);
            };
        });
        // (DM "seen" is handled by IGSeen, which adds a manual eye button)
        // story seen
        hookStory();
    });
}
