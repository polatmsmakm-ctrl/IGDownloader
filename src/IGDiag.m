// IGDiag: "تقرير التشخيص" button in Ra Menu. Collects hook status, loaded dylibs, recent screens
// and a main-thread stall watchdog (with stack samples) so a hang can be located precisely.
#import "igd_common.h"
#include <execinfo.h>
#include <signal.h>
#include <pthread.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#define BUILD @"d1"

static pthread_t gMain;
static volatile CFAbsoluteTime gPong;
static CFAbsoluteTime gStart;
static volatile double gMaxStall;
static volatile int gStalls;
static NSString *volatile gStallVC;
static NSString *volatile gLastVC;
#define NSAMP 4
#define NFR 14
static void *gFrames[NSAMP][NFR];
static volatile int gFrameN[NSAMP];
static volatile int gSamples;
static volatile sig_atomic_t gWantSample;
static NSMutableArray *gVCLog;

static void onSig(int sig, siginfo_t *si, void *ctx) {
    int i = gSamples;
    if (i >= NSAMP || !gWantSample) return;
    gFrameN[i] = backtrace(gFrames[i], NFR);
    gSamples = i + 1;
    gWantSample = 0;
}

static void *watchdog(void *arg) {
    pthread_setname_np("ra.diag.watchdog");
    CFAbsoluteTime stallStart = 0; int sampled = 0;
    for (;;) {
        usleep(400000);
        dispatch_async(dispatch_get_main_queue(), ^{ gPong = CFAbsoluteTimeGetCurrent(); });
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (gPong == 0) continue;
        double lag = now - gPong;
        if (lag > 2.5) {
            if (!stallStart) { stallStart = now - lag; gStalls++; gStallVC = gLastVC; sampled = 0; }
            if (lag > gMaxStall) gMaxStall = lag;
            if (lag > 3.0 && sampled < 2 && gSamples < NSAMP && ((int)lag % 3 == 0 || sampled == 0)) {
                gWantSample = 1; sampled++;
                pthread_kill(gMain, SIGUSR2);
                usleep(600000);
            }
        } else stallStart = 0;
    }
    return NULL;
}

static NSString *symbolize(void *addr) {
    Dl_info d;
    if (dladdr(addr, &d) && d.dli_fname) {
        const char *base = strrchr(d.dli_fname, '/'); base = base ? base + 1 : d.dli_fname;
        return [NSString stringWithFormat:@"%s+0x%lx", base, (unsigned long)((uintptr_t)addr - (uintptr_t)d.dli_fbase)];
    }
    return [NSString stringWithFormat:@"%p", addr];
}

static NSString *buildReport(void) {
    NSMutableString *r = [NSMutableString new];
    char mach[64] = {0}; size_t sz = sizeof mach; sysctlbyname("hw.machine", mach, &sz, NULL, 0);
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    [r appendFormat:@"== Ra diag %@ ==\n%s | iOS %@ | IG %@ (%@)\n", BUILD, mach, UIDevice.currentDevice.systemVersion,
     info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
    [r appendFormat:@"uptime %.0fs\n\n", CFAbsoluteTimeGetCurrent() - gStart];

    [r appendString:@"-- injected dylibs --\n"];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && (strstr(n, "/Instagram.app/") || strstr(n, "Substrate") || strstr(n, "Ellekit"))
            && strstr(n, ".dylib")) [r appendFormat:@"%s\n", strrchr(n, '/') + 1];
    }

    [r appendString:@"\n-- main thread stalls --\n"];
    [r appendFormat:@"stalls>2.5s: %d | longest %.1fs | screen at first stall: %@\n", gStalls, gMaxStall, gStallVC ?: @"-"];
    for (int i = 0; i < gSamples && i < NSAMP; i++) {
        [r appendFormat:@"sample %d:\n", i + 1];
        for (int j = 0; j < gFrameN[i]; j++) [r appendFormat:@"  %@\n", symbolize(gFrames[i][j])];
    }

    [r appendString:@"\n-- recent screens --\n"];
    @synchronized (gVCLog) { for (NSString *s in gVCLog) [r appendFormat:@"%@\n", s]; }

    [r appendString:@"\n-- hooks --\n"];
    NSArray *st = [igdStatus() copy];
    NSUInteger bad = 0;
    for (NSString *s in st) if ([s hasPrefix:@"✗"]) { [r appendFormat:@"%@\n", s]; bad++; }
    [r appendFormat:@"ok %lu / failed %lu\n", (unsigned long)(st.count - bad), (unsigned long)bad];

    [r appendString:@"\n-- Ra switches --\n"];
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    for (NSString *k in [all.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if ([k hasPrefix:@"ra."] || [k containsString:@"UploadHighQuality"]) [r appendFormat:@"%@=%@\n", k, all[k]];
    return r;
}

static void showReport(UIViewController *over) {
    NSString *rep = buildReport();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"تقرير التشخيص" message:rep preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"مشاركة" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[rep] applicationActivities:nil];
        UIViewController *top = igdTopVC();
        vc.popoverPresentationController.sourceView = top.view;
        [top presentViewController:vc animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"نسخ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIPasteboard.generalPasteboard.string = rep; igdToast(@"تم النسخ");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *top = over ?: igdTopVC();
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void init(void) {
    gMain = pthread_self();
    gStart = CFAbsoluteTimeGetCurrent();
    gVCLog = [NSMutableArray new];
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = onSig; sa.sa_flags = SA_SIGINFO | SA_RESTART; sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR2, &sa, NULL);
    dispatch_async(dispatch_get_main_queue(), ^{
        gPong = CFAbsoluteTimeGetCurrent();
        pthread_t t; pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        pthread_create(&t, &at, watchdog, NULL);

        Method m = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(UIViewController *self, BOOL a) {
            ((void (*)(id, SEL, BOOL))orig)(self, @selector(viewDidAppear:), a);
            NSString *cn = NSStringFromClass(self.class);
            if ([cn hasPrefix:@"UI"] && ![cn containsString:@"Navigation"] && ![cn containsString:@"TabBar"]) return;
            gLastVC = cn;
            @synchronized (gVCLog) {
                [gVCLog addObject:[NSString stringWithFormat:@"%.1fs %@", CFAbsoluteTimeGetCurrent() - gStart, cn]];
                if (gVCLog.count > 25) [gVCLog removeObjectAtIndex:0];
            }
        }));
    });
    [NSNotificationCenter.defaultCenter addObserverForName:@"ra.diag" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        showReport([n.object isKindOfClass:[UIViewController class]] ? n.object : nil);
    }];
}
