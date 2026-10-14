// IGLock: Face ID / passcode lock for the app. Blurs the app switcher too.
#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import "ra_menu.h"
#define BUILD @"l1"
#define GRACE_SECONDS 15.0

static UIWindow *gCover;
static BOOL gLocked = YES, gAuthing = NO;
static NSDate *gBackgroundedAt;

static UIWindowScene *scene(void) {
    UIWindowScene *any = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (!any) any = (UIWindowScene *)s;
        if (s.activationState != UISceneActivationStateBackground) return (UIWindowScene *)s;
    }
    return any;
}

static void authenticate(void);

@interface IGLockVC : UIViewController
@end
@implementation IGLockVC
- (void)viewDidLoad {
    [super viewDidLoad];
    UIVisualEffectView *b = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    b.frame = self.view.bounds;
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:b];
    UIImageView *ic = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
    ic.tintColor = UIColor.whiteColor;
    ic.contentMode = UIViewContentModeScaleAspectFit;
    ic.frame = CGRectMake(0, 0, 54, 54);
    ic.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2 - 40);
    ic.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:ic];
    UIButton *u = [UIButton buttonWithType:UIButtonTypeSystem];
    [u setTitle:@"فتح القفل" forState:UIControlStateNormal];
    u.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    u.tintColor = UIColor.whiteColor;
    u.frame = CGRectMake(0, 0, 160, 44);
    u.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2 + 30);
    u.autoresizingMask = ic.autoresizingMask;
    [u addAction:[UIAction actionWithHandler:^(UIAction *a) { authenticate(); }] forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:u];
}
@end

static void showCover(void) {
    if (!raOn(@"lock")) return;
    if (gCover) { gCover.hidden = NO; return; }
    UIWindowScene *sc = scene();
    if (!sc) return;
    gCover = [[UIWindow alloc] initWithWindowScene:sc];
    gCover.frame = sc.coordinateSpace.bounds;
    gCover.windowLevel = UIWindowLevelAlert + 1000;
    gCover.rootViewController = [IGLockVC new];
    gCover.hidden = NO;
}
static void hideCover(void) { gCover.hidden = YES; }

static void authenticate(void) {
    if (gAuthing) return;
    LAContext *ctx = [LAContext new];
    NSError *e = nil;
    if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&e]) {
        gLocked = NO;   // device has no passcode: nothing to authenticate with
        hideCover();
        return;
    }
    gAuthing = YES;
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:@"افتح إنستغرام" reply:^(BOOL ok, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gAuthing = NO;
            if (ok) { gLocked = NO; hideCover(); }
        });
    }];
}

__attribute__((constructor)) static void init(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        showCover();   // hides content in the app switcher; stays hidden while the Face ID sheet is up
    }];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        gBackgroundedAt = [NSDate date];
    }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (raOn(@"lock") && gBackgroundedAt && -[gBackgroundedAt timeIntervalSinceNow] > GRACE_SECONDS) gLocked = YES;
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (gAuthing) return;
        if (!raOn(@"lock")) { hideCover(); return; }
        if (gLocked) { showCover(); authenticate(); }
        else hideCover();
    }];
    raRegister(@"الأمان", @"lock", @"قفل التطبيق", @"بصمة الوجه أو الرمز عند الفتح");
    NSLog(@"[IGLock %@] loaded", BUILD);
}
