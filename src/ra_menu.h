// "Ra Menu": one shared settings screen for all the tweaks. Every dylib registers its switches here;
// the first dylib to load installs the entry points (Settings screen button + 3-finger long press).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define RA_UNUSED __attribute__((unused))
#define RA_CREDIT @"من تطوير وإعداد راشد الشمِّري"

// Registry lives on NSProcessInfo so all dylibs share it (the key is a selector pointer, same in every image).
static NSMutableArray *raRegistry(void) RA_UNUSED;
static NSMutableArray *raRegistry(void) {
    NSProcessInfo *p = NSProcessInfo.processInfo;
    const void *k = (const void *)sel_registerName("ra.registry");
    NSMutableArray *a = objc_getAssociatedObject(p, k);
    if (!a) { a = [NSMutableArray new]; objc_setAssociatedObject(p, k, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return a;
}

static BOOL raOn(NSString *key) RA_UNUSED;
static BOOL raOn(NSString *key) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:[@"ra." stringByAppendingString:key]];
    if (v) return [v boolValue];
    for (NSDictionary *d in raRegistry()) if ([d[@"key"] isEqual:key]) return d[@"off"] ? NO : YES;   // default ON unless registered as off
    return YES;
}

static UIViewController *raTop(void) {
    UIWindow *w = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *x in ((UIWindowScene *)s).windows) { if (x.isKeyWindow) { w = x; break; } if (!w) w = x; }
    }
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

@interface RaMenuVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end
#ifndef RA_NO_IMPL
#import "ra_bg.h"
static UIColor *raAccent(void) { return [UIColor colorWithRed:0.55 green:0.58 blue:1.0 alpha:1]; }
static NSString *raIcon(NSString *k) {
    if ([k hasPrefix:@"dl"]) return @"arrow.down.circle.fill";
    if ([k hasPrefix:@"cf"]) return @"questionmark.circle.fill";
    if ([k hasPrefix:@"gh"] || [k hasPrefix:@"seen"]) return @"eye.slash.fill";
    if ([k hasPrefix:@"noads"]) return @"nosign";
    if ([k hasPrefix:@"lock"]) return @"lock.fill";
    if ([k hasPrefix:@"x.unmute"]) return @"speaker.wave.2.fill";
    if ([k hasPrefix:@"x.hide"]) return @"rectangle.bottomthird.inset.filled";
    return @"sparkles";
}

@implementation RaMenuVC {
    UITableView *_table;
    UIImageView *_bg;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // nebula background, slowly breathing, with a dark veil so the text stays readable
    NSData *jd = [[NSData alloc] initWithBase64EncodedString:kRaBgB64 options:0];
    _bg = [[UIImageView alloc] initWithImage:[UIImage imageWithData:jd]];
    _bg.contentMode = UIViewContentModeScaleAspectFill;
    _bg.clipsToBounds = YES;
    _bg.frame = self.view.bounds;
    _bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_bg];
    CABasicAnimation *z = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    z.fromValue = @1.0; z.toValue = @1.12; z.duration = 22; z.autoreverses = YES; z.repeatCount = HUGE_VALF;
    z.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_bg.layer addAnimation:z forKey:@"breathe"];
    UIView *veil = [[UIView alloc] initWithFrame:self.view.bounds];
    veil.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    veil.userInteractionEnabled = NO;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = UIScreen.mainScreen.bounds;
    g.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.30].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.62].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.82].CGColor];
    [veil.layer addSublayer:g];
    [self.view addSubview:veil];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.10];
    _table.dataSource = self; _table.delegate = self;
    _table.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_table];

    // header: glowing title
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 150)];
    UILabel *t = [UILabel new];
    t.text = @"Ra Menu";
    t.font = [UIFont systemFontOfSize:40 weight:UIFontWeightHeavy];
    t.textColor = UIColor.whiteColor;
    t.textAlignment = NSTextAlignmentCenter;
    t.layer.shadowColor = [UIColor colorWithRed:0.65 green:0.4 blue:1 alpha:1].CGColor;
    t.layer.shadowOpacity = 0.95; t.layer.shadowRadius = 14; t.layer.shadowOffset = CGSizeZero;
    t.frame = CGRectMake(0, 62, 100, 50);
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [h addSubview:t];
    UILabel *st = [UILabel new];
    st.text = @"تحكّم بكل ميزة";
    st.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    st.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    st.textAlignment = NSTextAlignmentCenter;
    st.frame = CGRectMake(0, 112, 100, 22);
    st.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [h addSubview:st];
    _table.tableHeaderView = h;

    // footer: credit
    UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 160)];
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 22, 60, 1)];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    line.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [f addSubview:line];
    UILabel *c = [UILabel new];
    c.text = RA_CREDIT;
    c.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    c.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    c.textAlignment = NSTextAlignmentCenter;
    c.frame = CGRectMake(0, 36, 100, 24);
    c.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [f addSubview:c];
    UIButton *dg = [UIButton buttonWithType:UIButtonTypeCustom];
    dg.bounds = CGRectMake(0, 0, 170, 34);
    dg.center = CGPointMake(50, 92);
    dg.layer.cornerRadius = 17;
    dg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    [dg setTitle:@"تقرير التشخيص" forState:UIControlStateNormal];
    dg.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [dg addTarget:self action:@selector(diag) forControlEvents:UIControlEventTouchUpInside];
    [f addSubview:dg];
    _table.tableFooterView = f;

    // close button
    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
    x.frame = CGRectMake(0, 0, 36, 36);
    x.layer.cornerRadius = 18;
    x.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    x.tintColor = UIColor.whiteColor;
    [x setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    [x addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
    x.tag = 77;
    [self.view addSubview:x];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    for (UIView *v in _table.tableHeaderView.subviews) v.frame = CGRectMake(0, v.frame.origin.y, w, v.frame.size.height);
    for (UIView *v in _table.tableFooterView.subviews) {
        if ([v isKindOfClass:[UILabel class]]) v.frame = CGRectMake(0, v.frame.origin.y, w, v.frame.size.height);
        else v.center = CGPointMake(w / 2, v.center.y);
    }
    UIView *x = [self.view viewWithTag:77];
    x.frame = CGRectMake(w - 52, self.view.safeAreaInsets.top + 10, 36, 36);
    [self.view bringSubviewToFront:x];
    ((CALayer *)self.view.subviews[1].layer.sublayers.firstObject).frame = self.view.bounds;
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)diag {
    // IGDiag listens; it presents the report on top of this menu
    [NSNotificationCenter.defaultCenter postNotificationName:@"ra.diag" object:self];
}
- (NSArray *)groups {
    NSMutableArray *names = [NSMutableArray new];
    for (NSDictionary *d in raRegistry()) if (![names containsObject:d[@"group"]]) [names addObject:d[@"group"]];
    return names;
}
- (NSArray *)itemsIn:(NSInteger)sec {
    NSString *g = [self groups][sec];
    NSMutableArray *r = [NSMutableArray new];
    for (NSDictionary *d in raRegistry()) if ([d[@"group"] isEqual:g]) [r addObject:d];
    return r;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return [self groups].count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return [self itemsIn:s].count; }
- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s {
    UILabel *l = [UILabel new];
    l.text = [NSString stringWithFormat:@"   %@", [self groups][s]];
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    l.textColor = raAccent();
    return l;
}
- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)s { return 34; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *d = [self itemsIn:ip.section][ip.row];
    NSString *key = d[@"key"];
    c.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.52];
    c.textLabel.text = d[@"title"];
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = d[@"sub"];
    c.detailTextLabel.font = [UIFont systemFontOfSize:12.5];
    c.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.62];
    c.detailTextLabel.numberOfLines = 0;
    c.imageView.image = [UIImage systemImageNamed:raIcon(key) withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium]];
    c.imageView.tintColor = raAccent();
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [UISwitch new];
    sw.onTintColor = raAccent();
    sw.on = raOn(key);
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [NSUserDefaults.standardUserDefaults setBool:((UISwitch *)a.sender).on forKey:[@"ra." stringByAppendingString:key]];
        [[UIImpactFeedbackGenerator new] impactOccurred];
    }] forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}
@end
#import "ra_logo.h"
UIImage *raLogoImage(void) {
    static UIImage *img; static dispatch_once_t o;
    dispatch_once(&o, ^{ NSData *d = [[NSData alloc] initWithBase64EncodedString:kRaLogoB64 options:0]; img = [UIImage imageWithData:d scale:3]; });
    return img;
}
#endif

static void raOpenMenu(void) RA_UNUSED;
static void raOpenMenu(void) {
    UIViewController *top = raTop();
    if (!top || [top isKindOfClass:[RaMenuVC class]]) return;
    RaMenuVC *m = [RaMenuVC new];
    m.modalPresentationStyle = UIModalPresentationFullScreen;
    m.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [top presentViewController:m animated:YES completion:nil];
}

@interface RaOpener : NSObject
+ (void)open:(id)sender;
+ (void)pan:(UIPanGestureRecognizer *)g;
@end
extern UIImage *raLogoImage(void);
#ifndef RA_NO_IMPL
@implementation RaOpener
+ (void)open:(id)sender { raOpenMenu(); }
+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view, *sup = v.superview;
    if (!sup) return;
    CGPoint t = [g translationInView:sup];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:sup];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat W = sup.bounds.size.width, H = sup.bounds.size.height;
        CGFloat x = v.center.x < W / 2 ? 34 : W - 34;                       // snap to the nearest side
        CGFloat y = MIN(MAX(v.center.y, sup.safeAreaInsets.top + 40), H - sup.safeAreaInsets.bottom - 70);
        [UIView animateWithDuration:0.22 animations:^{ v.center = CGPointMake(x, y); }];
        [NSUserDefaults.standardUserDefaults setObject:@[@(x / W), @(y / H)] forKey:@"ra.logo.pos"];
    }
}
@end
#endif

static void raInstallLogo(void) {
    NSMutableArray *reg = raRegistry();
    BOOL have = NO;
    for (NSDictionary *d in reg) if ([d[@"key"] isEqual:@"logo"]) have = YES;
    if (!have) [reg addObject:@{@"group": @"الواجهة", @"key": @"logo", @"title": @"الشعار العائم", @"sub": @"زر Ra المتحرك اللي يفتح المنيو. تقدر تسحبه لأي مكان"}];
    __block UIButton *btn = nil;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        UIWindow *w = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *x in ((UIWindowScene *)sc).windows) { if (x.isKeyWindow) { w = x; break; } if (!w) w = x; }
        }
        if (!w) return;
        BOOL show = raOn(@"logo") && ![raTop() isKindOfClass:[RaMenuVC class]];
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.bounds = CGRectMake(0, 0, 56, 56);
            btn.layer.cornerRadius = 28;
            btn.clipsToBounds = YES;
            btn.backgroundColor = UIColor.blackColor;
            UIImage *im = raLogoImage();
            btn.imageView.contentMode = UIViewContentModeScaleAspectFill;
            [btn setImage:im forState:UIControlStateNormal];
            btn.layer.borderWidth = 1.2;
            btn.layer.borderColor = [UIColor colorWithRed:1 green:0.55 blue:0.8 alpha:0.9].CGColor;
            btn.accessibilityIdentifier = @"ra.logo";
            [btn addTarget:[RaOpener class] action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
            [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:[RaOpener class] action:@selector(pan:)]];
            NSArray *pos = [NSUserDefaults.standardUserDefaults arrayForKey:@"ra.logo.pos"];
            CGSize S = w.bounds.size;
            btn.center = pos.count == 2 ? CGPointMake([pos[0] doubleValue] * S.width, [pos[1] doubleValue] * S.height) : CGPointMake(34, S.height * 0.28);
        }
        btn.hidden = !show;
        if (btn.superview != w) [w addSubview:btn];
        else if (w.subviews.lastObject != btn) [w bringSubviewToFront:btn];
    }];
}

static void raInstallEntryPoints(void) {
    NSProcessInfo *p = NSProcessInfo.processInfo;
    const void *k = (const void *)sel_registerName("ra.installed");
    if (objc_getAssociatedObject(p, k)) return;
    objc_setAssociatedObject(p, k, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    raInstallLogo();

    // 1) a "Ra" button on Instagram's Settings screens
    Method m = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(UIViewController *self, BOOL a) {
        ((void (*)(id, SEL, BOOL))orig)(self, @selector(viewDidAppear:), a);
        NSString *cn = NSStringFromClass(self.class);
        if ([cn containsString:@"Settings"] && self.navigationItem && ![cn hasPrefix:@"Ra"]) {
            for (UIBarButtonItem *b in self.navigationItem.rightBarButtonItems) if ([b.title isEqualToString:@"Ra"]) return;
            UIBarButtonItem *b = [[UIBarButtonItem alloc] initWithTitle:@"Ra" style:UIBarButtonItemStylePlain target:[RaOpener class] action:@selector(open:)];
            NSMutableArray *items = [(self.navigationItem.rightBarButtonItems ?: @[]) mutableCopy];
            [items addObject:b];
            self.navigationItem.rightBarButtonItems = items;
        }
    }));

    // 2) fallback: press and hold with three fingers anywhere
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (!w.isKeyWindow) continue;
                for (UIGestureRecognizer *g in w.gestureRecognizers) if ([g.name isEqualToString:@"ra.menu"]) return;
                UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[RaOpener class] action:@selector(open:)];
                lp.numberOfTouchesRequired = 3;
                lp.minimumPressDuration = 1.0;
                lp.cancelsTouchesInView = NO;
                lp.name = @"ra.menu";
                [w addGestureRecognizer:lp];
            }
        }
    }];
}

static void raRegisterD(NSString *group, NSString *key, NSString *title, NSString *sub, BOOL defaultOn) RA_UNUSED;
static void raRegisterD(NSString *group, NSString *key, NSString *title, NSString *sub, BOOL defaultOn) {
    NSMutableArray *r = raRegistry();
    for (NSDictionary *d in r) if ([d[@"key"] isEqual:key]) return;
    NSMutableDictionary *e = [@{@"group": group, @"key": key, @"title": title, @"sub": sub ?: @""} mutableCopy];
    if (!defaultOn) e[@"off"] = @YES;
    [r addObject:e];
    dispatch_async(dispatch_get_main_queue(), ^{ raInstallEntryPoints(); });
}
static void raRegister(NSString *group, NSString *key, NSString *title, NSString *sub) RA_UNUSED;
static void raRegister(NSString *group, NSString *key, NSString *title, NSString *sub) { raRegisterD(group, key, title, sub, YES); }
