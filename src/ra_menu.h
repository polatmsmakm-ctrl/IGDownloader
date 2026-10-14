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
    return v ? [v boolValue] : YES;   // everything defaults to ON
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

@interface RaMenuVC : UITableViewController
@end
@implementation RaMenuVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ra Menu";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    UILabel *f = [UILabel new];
    f.text = RA_CREDIT;
    f.textAlignment = NSTextAlignmentCenter;
    f.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    f.textColor = UIColor.secondaryLabelColor;
    f.frame = CGRectMake(0, 0, 100, 70);
    self.tableView.tableFooterView = f;
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
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
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return [self groups][s]; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *d = [self itemsIn:ip.section][ip.row];
    c.textLabel.text = d[@"title"];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = d[@"sub"];
    c.detailTextLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [UISwitch new];
    sw.on = raOn(d[@"key"]);
    NSString *key = d[@"key"];
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [NSUserDefaults.standardUserDefaults setBool:((UISwitch *)a.sender).on forKey:[@"ra." stringByAppendingString:key]];
    }] forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}
@end

static void raOpenMenu(void) RA_UNUSED;
static void raOpenMenu(void) {
    UIViewController *top = raTop();
    if (!top || [NSStringFromClass(top.class) isEqualToString:@"UINavigationController"] && [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:[RaMenuVC class]]) return;
    if ([top isKindOfClass:[UINavigationController class]] && [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:[RaMenuVC class]]) return;
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:[RaMenuVC new]];
    [top presentViewController:n animated:YES completion:nil];
}

@interface RaOpener : NSObject
+ (void)open:(id)sender;
@end
@implementation RaOpener
+ (void)open:(id)sender { raOpenMenu(); }
@end

static void raInstallEntryPoints(void) {
    NSProcessInfo *p = NSProcessInfo.processInfo;
    const void *k = (const void *)sel_registerName("ra.installed");
    if (objc_getAssociatedObject(p, k)) return;
    objc_setAssociatedObject(p, k, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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

static void raRegister(NSString *group, NSString *key, NSString *title, NSString *sub) RA_UNUSED;
static void raRegister(NSString *group, NSString *key, NSString *title, NSString *sub) {
    NSMutableArray *r = raRegistry();
    for (NSDictionary *d in r) if ([d[@"key"] isEqual:key]) return;
    [r addObject:@{@"group": group, @"key": key, @"title": title, @"sub": sub ?: @""}];
    dispatch_async(dispatch_get_main_queue(), ^{ raInstallEntryPoints(); });
}
