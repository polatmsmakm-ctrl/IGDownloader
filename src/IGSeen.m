// IGSeen: read DMs without sending "seen". An eye button in the chat header sends "seen" manually.
#import "igd_common.h"
#define BUILD @"s1"

static BOOL gAllow = NO;                 // YES only while the eye button is sending "seen"
static __weak UIViewController *gThread; // chat currently on screen
static UIButton *gEye;

// ---- gated hooks -----------------------------------------------------------
static void gateBool(const char *cls, const char *sel) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'B' && ret != 'c') return nil;
        if (nargs == 0) return ^BOOL(id self) { return gAllow ? ((BOOL (*)(id, SEL))orig)(self, s) : NO; };
        if (nargs == 1) return ^BOOL(id self, id a) { return gAllow ? ((BOOL (*)(id, SEL, id))orig)(self, s, a) : NO; };
        return nil;
    });
}
static void gateVoid(const char *cls, const char *sel) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 0) return nil;
        return ^(id self) { if (gAllow) ((void (*)(id, SEL))orig)(self, s); };
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

static void collectCallButtons(UIView *v, UIWindow *w, NSMutableArray<NSValue *> *out, int depth) {
    if (depth > 12 || v.hidden || v.alpha < 0.05) return;
    CGRect r = [v convertRect:v.bounds toView:w];
    if (v != gEye && CGRectGetMinY(r) < w.safeAreaInsets.top + 80 && r.size.width < 90 && r.size.height < 90 && r.size.width > 14) {
        NSString *lab = [(v.accessibilityLabel ?: @"") lowercaseString];
        NSString *ident = [(v.accessibilityIdentifier ?: @"") lowercaseString];
        NSString *all = [lab stringByAppendingString:ident];
        if ([all containsString:@"call"] || [all containsString:@"video"] || [all containsString:@"audio"] ||
            [all containsString:@"مكالم"] || [all containsString:@"اتصال"] || [all containsString:@"فيديو"] || [all containsString:@"صوت"])
            [out addObject:[NSValue valueWithCGRect:r]];
    }
    for (UIView *s in v.subviews) collectCallButtons(s, w, out, depth + 1);
}

// ---- eye button ------------------------------------------------------------
static void sendSeen(void) {
    UIViewController *list = findListVC(gThread, 0);
    SEL sel = sel_registerName("markLastMessageAsSeen");
    if (!list || ![list respondsToSelector:sel]) { igdToast(@"IGSeen: ما لقيت قائمة الرسائل"); return; }
    gAllow = YES;
    ((void (*)(id, SEL))objc_msgSend)(list, sel);
    UIImage *on = [UIImage systemImageNamed:@"eye.fill"];
    [gEye setImage:on forState:UIControlStateNormal];
    gEye.tintColor = UIColor.systemGreenColor;
    igdToast(@"تم إرسال Seen");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gAllow = NO;
        [gEye setImage:[UIImage systemImageNamed:@"eye.slash"] forState:UIControlStateNormal];
        gEye.tintColor = UIColor.labelColor;
    });
}

static void placeEye(void) {
    UIWindow *w = igdKeyWindow();
    if (!gThread || !w || !gThread.viewIfLoaded.window) { gEye.hidden = YES; return; }
    if (!gEye) {
        gEye = [UIButton buttonWithType:UIButtonTypeSystem];
        gEye.bounds = CGRectMake(0, 0, 38, 38);
        gEye.tintColor = UIColor.labelColor;
        gEye.accessibilityIdentifier = @"igseen.eye";
        [gEye setImage:[UIImage systemImageNamed:@"eye.slash"] forState:UIControlStateNormal];
        [gEye addAction:[UIAction actionWithHandler:^(UIAction *a) { sendSeen(); }] forControlEvents:UIControlEventTouchUpInside];
    }
    if (gEye.superview != w) [w addSubview:gEye];
    [w bringSubviewToFront:gEye];
    NSMutableArray *rects = [NSMutableArray new];
    collectCallButtons(w, w, rects, 0);
    CGFloat top = w.safeAreaInsets.top + 22, x;
    if (rects.count) {
        CGFloat minX = CGFLOAT_MAX, maxX = 0, midY = 0;
        for (NSValue *v in rects) {
            CGRect r = v.CGRectValue;
            minX = MIN(minX, CGRectGetMinX(r)); maxX = MAX(maxX, CGRectGetMaxX(r)); midY += CGRectGetMidY(r);
        }
        top = midY / rects.count;
        x = (minX > 60) ? minX - 24 : maxX + 24;     // next to the call buttons, on the free side
    } else {
        x = 90;                                       // fallback: top-left corner
    }
    gEye.center = CGPointMake(x, top);
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
        return ^(id self, BOOL a) { ((void (*)(id, SEL, BOOL))orig)(self, s, a); gThread = self; schedulePlace(); };
    });
    igdHook(C, "viewDidDisappear:", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        return ^(id self, BOOL a) {
            ((void (*)(id, SEL, BOOL))orig)(self, s, a);
            if (gThread == self) { gThread = nil; gEye.hidden = YES; }
        };
    });
    igdHook(C, "updateThreadNavigationBar", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v' || nargs != 0) return nil;
        return ^(id self) { ((void (*)(id, SEL))orig)(self, s); if (gThread == self) schedulePlace(); };
    });
}

__attribute__((constructor)) static void init(void) {
    igdRun(@"IGSeen", BUILD, ^{
        const char *LIST = "_TtC33IGDirectMessageListViewController33IGDirectMessageListViewController";
        gateBool("IGDirectThreadViewListAdapterDataSource", "shouldUpdateLastSeenMessage");
        gateVoid("IGDirectThreadLastSeenMessageTracker", "markLastMessageAsSeen");
        gateVoid(LIST, "markLastMessageAsSeen");
        gateBool(LIST, "messageListDataSourceShouldUpdateSeenState:");
        hookThreadVC();
    });
}
