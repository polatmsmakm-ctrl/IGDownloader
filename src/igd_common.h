// Shared helpers for the small IGD tweaks (hook by replacing method IMPs through the ObjC runtime).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ra_menu.h"

#define IGD_UNUSED __attribute__((unused))

static NSMutableArray<NSString *> *igdStatus(void) IGD_UNUSED;
static NSMutableArray<NSString *> *igdStatus(void) {
    // shared by every module in the process (one list on NSProcessInfo), so the diagnostic report sees all hooks
    NSProcessInfo *p = NSProcessInfo.processInfo;
    const void *k = (const void *)sel_registerName("ra.status");
    @synchronized (p) {
        NSMutableArray *a = objc_getAssociatedObject(p, k);
        if (!a) { a = [NSMutableArray new]; objc_setAssociatedObject(p, k, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return a;
    }
}

static UIWindow *igdKeyWindow(void) IGD_UNUSED;
static UIWindow *igdKeyWindow(void) {
    UIWindow *first = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
            if (!first) first = w;
        }
    }
    return first;
}

static UIViewController *igdTopVC(void) IGD_UNUSED;
static UIViewController *igdTopVC(void) {
    UIViewController *v = igdKeyWindow().rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

static void igdToast(NSString *msg) IGD_UNUSED;
static void igdToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = igdKeyWindow();
        if (!w) return;
        UILabel *l = [UILabel new];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        l.layer.cornerRadius = 12;
        l.clipsToBounds = YES;
        l.text = [NSString stringWithFormat:@"  %@  ", msg];
        CGFloat maxW = w.bounds.size.width - 40;
        CGSize sz = [l sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
        l.frame = CGRectMake((w.bounds.size.width - MIN(sz.width, maxW)) / 2, w.safeAreaInsets.top + 8, MIN(sz.width, maxW), sz.height + 14);
        [w addSubview:l];
        [UIView animateWithDuration:0.4 delay:3.0 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f) { [l removeFromSuperview]; }];
    });
}

// Replace -[cls sel]. `make` receives (original IMP, selector, return-type char, extra-arg count)
// and returns a block to use as the new implementation (or nil if unsupported).
typedef id (^IGDMaker)(IMP orig, SEL sel, char ret, unsigned nargs);

static BOOL igdHook(const char *clsName, const char *selName, IGDMaker make) IGD_UNUSED;
static BOOL igdHook(const char *clsName, const char *selName, IGDMaker make) {
    Class c = objc_getClass(clsName);
    if (!c) { [igdStatus() addObject:[NSString stringWithFormat:@"✗ %s (no class)", clsName]]; return NO; }
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { [igdStatus() addObject:[NSString stringWithFormat:@"✗ %s %s (no method)", clsName, selName]]; return NO; }
    char *rt = method_copyReturnType(m);
    char ret = rt ? rt[0] : 'v';
    free(rt);
    id blk = make(method_getImplementation(m), sel, ret, method_getNumberOfArguments(m) - 2);
    if (!blk) { [igdStatus() addObject:[NSString stringWithFormat:@"✗ %s %s (unsupported signature)", clsName, selName]]; return NO; }
    IMP imp = imp_implementationWithBlock(blk);
    if (!class_addMethod(c, sel, imp, method_getTypeEncoding(m))) method_setImplementation(m, imp);
    [igdStatus() addObject:[NSString stringWithFormat:@"✓ %s %s", clsName, selName]];
    return YES;
}

// Install now and once more after 4s (some classes load late); show a one-time summary per build.
static void igdRun(NSString *name, NSString *build, void (^install)(void)) IGD_UNUSED;
static void igdRun(NSString *name, NSString *build, void (^install)(void)) {
    // each module gets a diagnostic switch in Ra Menu; turning it off (then reopening the app) skips its hooks entirely
    NSString *modKey = [@"mod." stringByAppendingString:name];
    raRegister(@"وحدات (للتشخيص)", modKey, name, @"أطفئه وأعد فتح التطبيق لتعطيل كل hooks هذي الوحدة");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!raOn(modKey)) { [igdStatus() addObject:[NSString stringWithFormat:@"⏸ %@ disabled by switch", name]]; return; }
        install();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSUInteger bad = 0, good = 0;
            for (NSString *s in igdStatus()) { if ([s hasPrefix:@"✗"]) bad++; else good++; }
            NSLog(@"[%@ %@]\n%@", name, build, [igdStatus() componentsJoinedByString:@"\n"]);
            NSString *key = [NSString stringWithFormat:@"igd.shown.%@.%@", name, build];
            if (bad) {
                [NSUserDefaults.standardUserDefaults setBool:YES forKey:key];
                igdToast([NSString stringWithFormat:@"%@ %@: %lu/%lu hooks%@", name, build, (unsigned long)good, (unsigned long)(good + bad),
                          bad ? @" (long NSLog has details)" : @""]);
            }
        });
    });
}
