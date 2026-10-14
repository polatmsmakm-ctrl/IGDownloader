// IGSeen: read DMs without sending "seen". An eye button in the chat header sends "seen" manually.
#import "igd_common.h"
#define BUILD @"s4"

@interface IGSeenHold : NSObject
+ (void)hold:(UILongPressGestureRecognizer *)g;
@end

static BOOL gAllow = NO;                 // YES only while the eye button is sending "seen"
static __weak UIViewController *gThread; // chat currently on screen
static UIButton *gEye;

@implementation IGSeenHold
+ (void)hold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !gThread) return;
    [NSNotificationCenter.defaultCenter postNotificationName:@"ra.chattools" object:gThread];   // IGTools listens
}
@end

// ---- gated hooks -----------------------------------------------------------
static void gateBool(const char *cls, const char *sel) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'B' && ret != 'c') return nil;
        if (nargs == 0) return ^BOOL(id self) { return (gAllow || !raOn(@"seen.dm")) ? ((BOOL (*)(id, SEL))orig)(self, s) : NO; };
        if (nargs == 1) return ^BOOL(id self, id a) { return (gAllow || !raOn(@"seen.dm")) ? ((BOOL (*)(id, SEL, id))orig)(self, s, a) : NO; };
        return nil;
    });
}
static void gateVoid(const char *cls, const char *sel) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 0) return nil;
        return ^(id self) { if (gAllow || !raOn(@"seen.dm")) ((void (*)(id, SEL))orig)(self, s); };
    });
}

// ---- finding things --------------------------------------------------------
static UIViewController *findListVC(UIViewController *vc, int depth) {
    if (!vc || depth > 6) return nil;
    if ([NSStringFromClass(vc.class) containsString:@"IGDirectMessageListViewController"]) return vc;
    for (UIViewController *c in vc.childViewControllers) {
        UIViewController *r = findListVC(c, depth + 1);
        if (r) return r;
    }
    return nil;
}

// ---- eye button ------------------------------------------------------------
static void styleEye(BOOL sent);
static void sendSeen(void) {
    UIViewController *list = findListVC(gThread, 0);
    SEL sel = sel_registerName("markLastMessageAsSeen");
    if (!list || ![list respondsToSelector:sel]) { igdToast(@"IGSeen: ما لقيت قائمة الرسائل"); return; }
    gAllow = YES;
    ((void (*)(id, SEL))objc_msgSend)(list, sel);
    styleEye(YES);
    igdToast(@"تم إرسال Seen");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gAllow = NO; });
}

static void styleEye(BOOL sent) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
    [gEye setImage:[UIImage systemImageNamed:(sent ? @"eye.fill" : @"eye.slash") withConfiguration:cfg] forState:UIControlStateNormal];
    gEye.tintColor = sent ? UIColor.systemGreenColor : UIColor.whiteColor;
}

static void placeEye(void) {
    UIWindow *w = igdKeyWindow();
    if (!raOn(@"seen.dm") || !gThread || !w || !gThread.viewIfLoaded.window) { gEye.hidden = YES; return; }
    if (!gEye) {
        gEye = [UIButton buttonWithType:UIButtonTypeCustom];
        gEye.bounds = CGRectMake(0, 0, 40, 40);
        gEye.layer.cornerRadius = 20;
        gEye.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        gEye.accessibilityIdentifier = @"igseen.eye";
        styleEye(NO);
        [gEye addAction:[UIAction actionWithHandler:^(UIAction *a) { sendSeen(); }] forControlEvents:UIControlEventTouchUpInside];
        [gEye addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:[IGSeenHold class] action:@selector(hold:)]];
    }
    if (gEye.superview != w) [w addSubview:gEye];
    [w bringSubviewToFront:gEye];
    // fixed spot in the chat header (left of the call icons), same row as the back button
    gEye.center = CGPointMake(w.bounds.size.width * 0.5625, w.safeAreaInsets.top + 22);
    gEye.hidden = NO;
}

static void schedulePlace(void) {
    for (NSNumber *d in @[@0.05, @0.4, @1.2]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ placeEye(); });
    }
}

static void hookThreadVC(void) {
    const char *C = "IGDirectThreadViewController";
    igdHook(C, "viewDidAppear:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        return ^(id self, BOOL a) { ((void (*)(id, SEL, BOOL))orig)(self, s, a); gThread = self; styleEye(NO); schedulePlace(); };
    });
    igdHook(C, "viewDidDisappear:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        return ^(id self, BOOL a) {
            ((void (*)(id, SEL, BOOL))orig)(self, s, a);
            if (gThread == self) { gThread = nil; gEye.hidden = YES; styleEye(NO); }
        };
    });
    igdHook(C, "updateThreadNavigationBar", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 0) return nil;
        return ^(id self) { ((void (*)(id, SEL))orig)(self, s); if (gThread == self) schedulePlace(); };
    });
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"الرسائل", @"seen.dm", @"إخفاء Seen في الرسائل", @"تقرأ بدون ما يطلع seen، وزر العين يرسله يدوياً. أطفيه إذا تبي seen عادي");
    igdRun(@"IGSeen", BUILD, ^{
        const char *LIST = "_TtC33IGDirectMessageListViewController33IGDirectMessageListViewController";
        gateBool("IGDirectThreadViewListAdapterDataSource", "shouldUpdateLastSeenMessage");
        gateVoid("IGDirectThreadLastSeenMessageTracker", "markLastMessageAsSeen");
        gateVoid(LIST, "markLastMessageAsSeen");
        gateBool(LIST, "messageListDataSourceShouldUpdateSeenState:");
        hookThreadVC();
    });
}
