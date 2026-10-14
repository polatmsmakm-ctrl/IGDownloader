// IGDownloader r5-model
// Saves the Reel/video currently on screen to Photos.
//
// Method: do NOT read the URL from the video player (Instagram 450 uses its own
// AVSampleBufferDisplayLayer pipeline, so there is no AVURLAsset). Instead read
// Instagram's own data model:  on-screen view -> IGMedia -> [media video] -> URLs.
// No hooks / no Substrate: plain Objective-C runtime + a floating button.

#import "ra_menu.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <malloc/malloc.h>

#define IGD_BUILD @"r9-icon"

#pragma mark - Runtime helpers

// Call a no-argument selector that returns an object. Returns nil otherwise.
static id IGDSend(id o, const char *name) {
    if (!o) return nil;
    SEL s = sel_registerName(name);
    if (![o respondsToSelector:s]) return nil;
    Method m = class_getInstanceMethod(object_getClass(o), s);
    if (!m) return nil;
    char rt[16] = {0};
    method_getReturnType(m, rt, sizeof rt);
    if (rt[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(o, s); }
    @catch (__unused id e) { return nil; }
}

static BOOL IGDInterestingClass(Class c) {
    NSString *n = NSStringFromClass(c);
    return [n hasPrefix:@"IG"] || [n hasPrefix:@"_TtC"] || [n hasPrefix:@"FB"];
}

// All ivars of a class and its superclasses (cached).
static NSArray<NSValue *> *IGDIvars(Class cls) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    NSString *key = NSStringFromClass(cls);
    NSArray *hit = cache[key];
    if (hit) return hit;
    NSMutableArray *arr = [NSMutableArray new];
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned n = 0;
        Ivar *l = class_copyIvarList(c, &n);
        for (unsigned i = 0; i < n; i++) [arr addObject:[NSValue valueWithPointer:l[i]]];
        free(l);
    }
    cache[key] = arr;
    return arr;
}

static id IGDObjIvar(id o, Ivar iv) {
    const char *t = ivar_getTypeEncoding(iv);
    if (!t || t[0] != '@') return nil;
    return object_getIvar(o, iv);
}

// Swift-style ivars have no type encoding. Read the raw pointer, but only
// accept it if it is a live malloc'd object.
static id IGDRawObjIvar(id o, Ivar iv) {
    ptrdiff_t off = ivar_getOffset(iv);
    uintptr_t p = *(uintptr_t *)((uint8_t *)(__bridge void *)o + off);
    if (!p || (p & 0xF) || p < 0x100000000ULL) return nil;
    if (malloc_size((const void *)p) == 0) return nil;
    return (__bridge id)(void *)p;
}

static id IGDAnyObjIvar(id o, Ivar iv) {
    id r = IGDObjIvar(o, iv);
    if (r) return r;
    const char *t = ivar_getTypeEncoding(iv);
    const char *nm = ivar_getName(iv);
    if ((!t || !t[0]) && nm) {
        static const char *ok[] = {"_viewModel", "_media", "_allVideoURLs", "_mediaItem", "_item", "_model",
                                   "_video", "_feedItem", "_sundialItem", "_post", "_mediaViewModel"};
        for (size_t i = 0; i < sizeof ok / sizeof ok[0]; i++)
            if (!strcmp(nm, ok[i])) return IGDRawObjIvar(o, iv);
    }
    return nil;
}

// Read an object ivar by NAME (like MSHookIvar): works even when the ivar has no type encoding.
static id IGDIvarByName(id o, const char *name) {
    if (!o) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(o), name);
    if (!iv) return nil;
    const char *t = ivar_getTypeEncoding(iv);
    if (t && t[0] == '@') return object_getIvar(o, iv);
    return IGDRawObjIvar(o, iv);
}

#pragma mark - Finding the IGMedia on screen

static NSInteger gBudget;
static NSMutableDictionary *gHolderAreas;

static BOOL IGDIsMedia(id o) {
    if (!o) return NO;
    for (Class c = object_getClass(o); c; c = class_getSuperclass(c)) {
        NSString *n = NSStringFromClass(c);
        if ([n isEqualToString:@"IGMedia"] || [n hasSuffix:@".IGMedia"]) return YES;
    }
    return NO;
}

static BOOL IGDIsUI(id o) {
    return [o isKindOfClass:[UIResponder class]] || [o isKindOfClass:[CALayer class]];
}

static id IGDMediaFromHolder(id h, int depth, NSHashTable *seen) {
    if (!h || depth < 0 || [seen containsObject:h]) return nil;
    [seen addObject:h];
    if (IGDIsMedia(h)) return h;
    id viaSel = IGDSend(h, "media");
    if (IGDIsMedia(viaSel)) return viaSel;
    if (!IGDInterestingClass(object_getClass(h))) return nil;
    for (NSValue *v in IGDIvars(object_getClass(h))) {
        if (--gBudget < 0) return nil;
        Ivar iv = [v pointerValue];
        id o = IGDAnyObjIvar(h, iv);
        if (!o) continue;
        if (IGDIsMedia(o)) return o;
        if (depth > 0 && !IGDIsUI(o) && IGDInterestingClass(object_getClass(o))) {
            id r = IGDMediaFromHolder(o, depth - 1, seen);
            if (r) return r;
        }
    }
    return nil;
}

static NSHashTable *IGDNewSeen(void) {
    return [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaquePersonality | NSPointerFunctionsOpaqueMemory];
}

static void IGDWalk(UIView *v, NSMutableArray *cands, int *count) {
    if (v.hidden || v.alpha < 0.05 || ++(*count) > 6000) return;
    CGRect r = CGRectIntersection([v convertRect:v.bounds toView:nil], v.window.bounds);
    if (CGRectIsNull(r) || r.size.width * r.size.height < 2000) return;
    double area = r.size.width * r.size.height;
    NSString *holder = NSStringFromClass(object_getClass(v));
    if (IGDInterestingClass(object_getClass(v))) {
        double old = [gHolderAreas[holder] doubleValue];
        if (area > old) gHolderAreas[holder] = @(area);
    }
    id media = IGDMediaFromHolder(v, 3, IGDNewSeen());
    if (!media) {
        id nr = v.nextResponder;
        if ([nr isKindOfClass:[UIViewController class]] && ((UIViewController *)nr).view == v) {
            media = IGDMediaFromHolder(nr, 3, IGDNewSeen());
            holder = NSStringFromClass(object_getClass(nr));
        }
    }
    if (media) [cands addObject:@{@"media": media, @"area": @(area), @"holder": holder}];
    for (UIView *s in v.subviews) IGDWalk(s, cands, count);
}

static NSArray<UIWindow *> *IGDWindows(void) {
    NSMutableArray *out = [NSMutableArray new];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        [out addObjectsFromArray:((UIWindowScene *)s).windows];
    }
    return out;
}

static UIWindow *IGDKeyWindow(void) {
    for (UIWindow *w in IGDWindows()) if (w.isKeyWindow) return w;
    return IGDWindows().firstObject;
}

static void IGDDumpNoMedia(NSMutableString *rep) {
    unsigned n = 0;
    Class *all = objc_copyClassList(&n);
    NSMutableArray *m = [NSMutableArray new], *vid = [NSMutableArray new];
    for (unsigned i = 0; i < n; i++) {
        const char *nm = class_getName(all[i]);
        if (strstr(nm, "IGMedia") && m.count < 14) [m addObject:[NSString stringWithUTF8String:nm]];
        if (strstr(nm, "IGVideo") && vid.count < 10) [vid addObject:[NSString stringWithUTF8String:nm]];
    }
    free(all);
    [rep appendFormat:@"NSClassFromString(IGMedia): %@\nclasses with IGMedia: %@\nclasses with IGVideo: %@\n",
     NSClassFromString(@"IGMedia") ? @"found" : @"NIL", [m componentsJoinedByString:@", "], [vid componentsJoinedByString:@", "]];
    NSArray *top = [[gHolderAreas allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [gHolderAreas[b] compare:gHolderAreas[a]];
    }];
    int shown = 0;
    for (NSString *cn in top) {
        if (shown++ >= 10) break;
        Class c = NSClassFromString(cn);
        if (!c) continue;
        NSMutableArray *iv = [NSMutableArray new];
        for (NSValue *v in IGDIvars(c)) {
            if (iv.count >= 28) break;
            Ivar x = [v pointerValue];
            const char *t = ivar_getTypeEncoding(x);
            [iv addObject:[NSString stringWithFormat:@"%s:%.22s", ivar_getName(x) ?: "?", (t && t[0]) ? t : "-"]];
        }
        [rep appendFormat:@"\n[%@ area %.0f]\n%@\n", cn, [gHolderAreas[cn] doubleValue], [iv componentsJoinedByString:@"  "]];
    }
}

#pragma mark - Reels UFI registry (the proven path: UFI._viewModel._media)

static NSHashTable *gUFIs;
static IMP gOrigLayout, gOrigMove;
static NSString *gSwizzleStatus = @"not installed yet";

static void IGDRegister(id v) {
    if (!gUFIs) gUFIs = [NSHashTable weakObjectsHashTable];
    [gUFIs addObject:v];
}
static void igd_layout(id self, SEL _cmd) {
    if (gOrigLayout) ((void (*)(id, SEL))gOrigLayout)(self, _cmd);
    IGDRegister(self);
}
static void igd_move(id self, SEL _cmd) {
    if (gOrigMove) ((void (*)(id, SEL))gOrigMove)(self, _cmd);
    IGDRegister(self);
}

static BOOL IGDSwizzle(Class c, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    IMP cur = method_getImplementation(m);
    if (class_addMethod(c, sel, imp, method_getTypeEncoding(m))) *orig = cur;
    else *orig = method_setImplementation(m, imp);
    return YES;
}

static void IGDInstallHooks(void) {
    static BOOL done;
    if (done) return;
    Class c = NSClassFromString(@"IGSundialViewerVerticalUFI");
    if (!c) c = NSClassFromString(@"_TtC26IGSundialViewerVerticalUFI26IGSundialViewerVerticalUFI");
    if (!c) { gSwizzleStatus = @"UFI class NOT found"; return; }
    BOOL a = IGDSwizzle(c, @selector(layoutSubviews), (IMP)igd_layout, &gOrigLayout);
    BOOL b = IGDSwizzle(c, @selector(didMoveToWindow), (IMP)igd_move, &gOrigMove);
    done = YES;
    gSwizzleStatus = [NSString stringWithFormat:@"hooked %@ layout=%d move=%d", NSStringFromClass(c), a, b];
}

static id IGDMediaFromRegistry(NSMutableString *rep) {
    NSArray *all = gUFIs.allObjects;
    [rep appendFormat:@"hook: %@ | registered UFI views: %lu\n", gSwizzleStatus, (unsigned long)all.count];
    UIView *best = nil;
    double bestA = 0;
    for (UIView *v in all) {
        if (![v isKindOfClass:[UIView class]] || !v.window || v.hidden) continue;
        CGRect r = CGRectIntersection([v convertRect:v.bounds toView:nil], v.window.bounds);
        if (CGRectIsNull(r)) continue;
        double a = r.size.width * r.size.height;
        if (a > bestA) { bestA = a; best = v; }
    }
    if (!best) { [rep appendString:@"no visible UFI view\n"]; return nil; }
    id vm = IGDIvarByName(best, "_viewModel");
    id media = IGDIvarByName(vm, "_media");
    [rep appendFormat:@"UFI visible area %.0f | _viewModel: %@ | _media: %@\n", bestA,
     vm ? NSStringFromClass(object_getClass(vm)) : @"nil", media ? NSStringFromClass(object_getClass(media)) : @"nil"];
    return media;
}

static id IGDFindCurrentMedia(NSMutableString *rep) {
    NSMutableArray *cands = [NSMutableArray new];
    int count = 0;
    gBudget = 400000;
    gHolderAreas = [NSMutableDictionary new];
    id fromUFI = IGDMediaFromRegistry(rep);
    if (fromUFI) return fromUFI;
    [rep appendString:@"-- UFI path failed, trying view walk --\n"];
    for (UIWindow *w in IGDWindows()) IGDWalk(w, cands, &count);
    [rep appendFormat:@"views scanned: %d | media candidates: %lu\n", count, (unsigned long)cands.count];
    NSDictionary *best = nil;
    for (NSDictionary *c in cands) {
        if (!best || [c[@"area"] doubleValue] > [best[@"area"] doubleValue]) best = c;
    }
    if (best) {
        [rep appendFormat:@"best holder: %@ (visible area %.0f)\nmedia class: %@\n",
         best[@"holder"], [best[@"area"] doubleValue], NSStringFromClass(object_getClass(best[@"media"]))];
    }
    if (!best) IGDDumpNoMedia(rep);
    return best[@"media"];
}

#pragma mark - Extracting URLs

static void IGDCollect(id o, NSMutableOrderedSet *out, int depth) {
    if (!o || depth < 0) return;
    if ([o isKindOfClass:[NSURL class]]) {
        NSURL *u = o;
        if ([u.scheme hasPrefix:@"http"]) [out addObject:u];
    } else if ([o isKindOfClass:[NSString class]]) {
        if ([(NSString *)o hasPrefix:@"http"]) {
            NSURL *u = [NSURL URLWithString:o];
            if (u) [out addObject:u];
        }
    } else if ([o isKindOfClass:[NSSet class]] || [o isKindOfClass:[NSArray class]]) {
        int n = 0;
        for (id e in o) { if (++n > 60) break; IGDCollect(e, out, depth - 1); }
    } else if ([o isKindOfClass:[NSDictionary class]]) {
        int n = 0;
        for (id e in [o allValues]) { if (++n > 60) break; IGDCollect(e, out, depth - 1); }
    }
}

static NSInteger IGDScore(NSURL *u) {
    NSInteger sc = 0;
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *q in c.queryItems) {
        if (![q.name isEqualToString:@"efg"] || !q.value.length) continue;
        NSString *b = [[q.value stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                       stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
        while (b.length % 4) b = [b stringByAppendingString:@"="];
        NSData *d = [[NSData alloc] initWithBase64EncodedString:b options:0];
        NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        if (!s) continue;
        if ([s rangeOfString:@"progressive"].location != NSNotFound) sc += 1000000;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[._](\\d{3,4})[._]" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (m) sc += [[s substringWithRange:[m rangeAtIndex:1]] integerValue];
    }
    return sc;
}

// Remove byte-range parameters so we download the whole file.
static NSURL *IGDClean(NSURL *u) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
    NSMutableArray *keep = [NSMutableArray new];
    for (NSURLQueryItem *q in c.queryItems) {
        if ([q.name isEqualToString:@"bytestart"] || [q.name isEqualToString:@"byteend"]) continue;
        [keep addObject:q];
    }
    c.queryItems = keep.count ? keep : nil;
    return c.URL ?: u;
}

static NSString *IGDShort(NSURL *u) {
    NSString *s = u.absoluteString;
    return s.length > 110 ? [[s substringToIndex:110] stringByAppendingString:@"…"] : s;
}

static NSArray<NSURL *> *IGDURLsForMedia(id media, NSMutableString *rep) {
    NSMutableOrderedSet *all = [NSMutableOrderedSet new];
    NSArray *selNames = @[@"video", @"rawVideo"];
    BOOL sawVideo = NO;
    for (NSString *sn in selNames) {
        id video = IGDSend(media, sn.UTF8String);
        if (!video) continue;
        sawVideo = YES;
        [rep appendFormat:@"[%@] -> %@\n", sn, NSStringFromClass(object_getClass(video))];
        IGDCollect(IGDIvarByName(video, "_allVideoURLs"), all, 2);
        IGDCollect(IGDSend(video, "allVideoURLs"), all, 2);
        IGDCollect(IGDSend(video, "url"), all, 1);
        NSMutableArray *names = [NSMutableArray new];
        for (NSValue *v in IGDIvars(object_getClass(video))) {
            Ivar iv = [v pointerValue];
            const char *nm = ivar_getName(iv);
            [names addObject:[NSString stringWithUTF8String:nm ?: "?"]];
            IGDCollect(IGDAnyObjIvar(video, iv), all, 2);
        }
        [rep appendFormat:@"%@ ivars: %@\n", NSStringFromClass(object_getClass(video)), [names componentsJoinedByString:@","]];
    }
    if (!sawVideo) [rep appendString:@"media has no 'video' / 'rawVideo' object (photo?)\n"];

    NSMutableArray *good = [NSMutableArray new];
    for (NSURL *u in all) {
        NSString *s = u.absoluteString.lowercaseString;
        if ([s containsString:@".mpd"] || [s containsString:@".m3u8"]) continue;
        if ([s containsString:@".mp4"] || [s containsString:@"cdninstagram"] || [s containsString:@"fbcdn"]) [good addObject:IGDClean(u)];
    }
    [good sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSInteger x = IGDScore(a), y = IGDScore(b);
        return x == y ? NSOrderedSame : (x > y ? NSOrderedAscending : NSOrderedDescending);
    }];
    [rep appendFormat:@"urls found: %lu | usable: %lu\n", (unsigned long)all.count, (unsigned long)good.count];
    for (NSURL *u in good) [rep appendFormat:@"  • score %ld  %@\n", (long)IGDScore(u), IGDShort(u)];
    if (!good.count) for (NSURL *u in all) [rep appendFormat:@"  ✗ %@\n", IGDShort(u)];
    return good;
}

#pragma mark - UI helpers

static UIButton *gButton;
static UILabel *gToast;
static NSString *gLastReport;

static UIViewController *IGDTopVC(void) {
    UIViewController *v = IGDKeyWindow().rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

static void IGDToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = IGDKeyWindow();
        if (!w) return;
        if (!gToast) {
            gToast = [UILabel new];
            gToast.numberOfLines = 0;
            gToast.textAlignment = NSTextAlignmentCenter;
            gToast.textColor = UIColor.whiteColor;
            gToast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            gToast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
            gToast.layer.cornerRadius = 14;
            gToast.clipsToBounds = YES;
            gToast.userInteractionEnabled = NO;
        }
        gToast.text = [NSString stringWithFormat:@"  %@  ", msg];
        CGFloat maxW = w.bounds.size.width - 48;
        CGSize sz = [gToast sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
        gToast.frame = CGRectMake((w.bounds.size.width - MIN(sz.width, maxW)) / 2,
                                  w.bounds.size.height - w.safeAreaInsets.bottom - 150,
                                  MIN(sz.width, maxW), sz.height + 16);
        [w addSubview:gToast];
        gToast.alpha = 1;
        [NSObject cancelPreviousPerformRequestsWithTarget:gToast];
        [gToast performSelector:@selector(removeFromSuperview) withObject:nil afterDelay:3.0];
    });
}

static void IGDShowReport(NSString *rep) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *app = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *full = [NSString stringWithFormat:@"IGDownloader %@\nInstagram %@\niOS %@\n%@",
                          IGD_BUILD, app, UIDevice.currentDevice.systemVersion, rep ?: @"(no scan yet)"];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"IGDownloader report" message:full preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[full] applicationActivities:nil];
            UIViewController *top = IGDTopVC();
            vc.popoverPresentationController.sourceView = top.view;
            [top presentViewController:vc animated:YES completion:nil];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        [IGDTopVC() presentViewController:a animated:YES completion:nil];
    });
}

#pragma mark - Download + save

static void IGDSaveToPhotos(NSURL *file) {
    void (^save)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:file];
        } completionHandler:^(BOOL ok, NSError *err) {
            [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
            IGDToast(ok ? @"Saved to Photos ✓" : [NSString stringWithFormat:@"Save failed: %@", err.localizedDescription]);
        }];
    };
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus st) {
        if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) save();
        else IGDToast(@"Allow Photos access in Settings");
    }];
}

static NSString *gLastFail;

static void IGDDownloadFrom(NSArray<NSURL *> *urls, NSUInteger idx) {
    if (idx >= urls.count) {
        gLastReport = [NSString stringWithFormat:@"%@\nDOWNLOAD FAILED: %@\n", gLastReport ?: @"", gLastFail ?: @"?"];
        IGDToast([NSString stringWithFormat:@"All links failed (%@)", gLastFail ?: @"?"]);
        return;
    }
    IGDToast(urls.count > 1 ? [NSString stringWithFormat:@"Downloading… (%lu/%lu)", (unsigned long)idx + 1, (unsigned long)urls.count] : @"Downloading…");
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:urls[idx]];
    [req setValue:@"video/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    NSURLSessionDownloadTask *t = [[NSURLSession sharedSession] downloadTaskWithRequest:req
        completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSString *mime = resp.MIMEType.lowercaseString ?: @"";
        if (err || !loc || code >= 400 || [mime containsString:@"mpegurl"] || [mime containsString:@"dash"]) {
            gLastFail = err ? err.localizedDescription : [NSString stringWithFormat:@"HTTP %ld %@", (long)code, mime];
            IGDDownloadFrom(urls, idx + 1);
            return;
        }
        NSURL *dst = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"IGD-%u.mp4", arc4random()]]];
        [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
        if (![[NSFileManager defaultManager] moveItemAtURL:loc toURL:dst error:nil]) { IGDDownloadFrom(urls, idx + 1); return; }
        unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:dst.path error:nil] fileSize];
        NSData *head = [NSData dataWithContentsOfURL:dst options:NSDataReadingMappedIfSafe error:nil];
        BOOL isMP4 = head.length > 12 && memcmp((const char *)head.bytes + 4, "ftyp", 4) == 0;
        if (size < 20000 || !isMP4) {
            gLastFail = [NSString stringWithFormat:@"bad file (%llu bytes, mp4=%d, mime %@)", size, isMP4, mime];
            [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
            IGDDownloadFrom(urls, idx + 1);
            return;
        }
        IGDSaveToPhotos(dst);
    }];
    [t resume];
}

static void IGDTap(void) {
    NSMutableString *rep = [NSMutableString new];
    id media = IGDFindCurrentMedia(rep);
    if (!media) {
        gLastReport = rep;
        IGDToast(@"No video found on screen (hold button for report)");
        return;
    }
    NSArray *urls = IGDURLsForMedia(media, rep);
    gLastReport = rep;
    if (!urls.count) { IGDToast(@"Couldn't find a video link (hold button for report)"); return; }
    IGDDownloadFrom(urls, 0);
}

#pragma mark - Floating button

@interface IGDHandler : NSObject
+ (instancetype)shared;
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)hold:(UILongPressGestureRecognizer *)g;
@end

@implementation IGDHandler
+ (instancetype)shared { static IGDHandler *h; static dispatch_once_t o; dispatch_once(&o, ^{ h = [IGDHandler new]; }); return h; }
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view, *sup = v.superview;
    if (!sup) return;
    CGPoint d = [g translationInView:sup];
    CGPoint c = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    c.x = MIN(MAX(c.x, 30), sup.bounds.size.width - 30);
    c.y = MIN(MAX(c.y, 90), sup.bounds.size.height - 90);
    v.center = c;
    [g setTranslation:CGPointZero inView:sup];
}
- (void)hold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!gLastReport) { NSMutableString *r = [NSMutableString new]; id m = IGDFindCurrentMedia(r); if (m) IGDURLsForMedia(m, r); gLastReport = r; }
    IGDShowReport(gLastReport);
}
@end

// Find the like (heart) button in the visible Reels action column so the icon sits right above it.
static BOOL IGDFindLike(UIView *v, UIWindow *w, CGRect *out, int depth) {
    if (depth > 14 || v.hidden || v.alpha < 0.05) return NO;
    NSString *lab = [[NSString stringWithFormat:@"%@%@", v.accessibilityLabel ?: @"", v.accessibilityIdentifier ?: @""] lowercaseString];
    if (([lab containsString:@"like"] || [lab containsString:@"heart"] || [lab containsString:@"إعجاب"] || [lab containsString:@"اعجاب"]) && ![lab containsString:@"comment"]) {
        CGRect r = [v convertRect:v.bounds toView:w];
        if (r.size.width > 18 && r.size.width < 90 && r.size.height < 90 && CGRectGetMidX(r) > w.bounds.size.width * 0.7) { *out = r; return YES; }
    }
    for (UIView *sv in v.subviews) if (IGDFindLike(sv, w, out, depth + 1)) return YES;
    return NO;
}

static CGPoint IGDButtonSpot(UIWindow *w) {
    CGSize S = w.bounds.size;
    CGPoint fallback = CGPointMake(S.width * 0.927, S.height * 0.555);   // measured from the reference screenshot
    for (UIView *u in gUFIs.allObjects) {
        if (![u isKindOfClass:[UIView class]] || !u.window) continue;
        CGRect like;
        if (IGDFindLike(u, w, &like, 0)) return CGPointMake(CGRectGetMidX(like), CGRectGetMinY(like) - 36);
    }
    return fallback;
}

static void IGDEnsureButton(void) {
    IGDInstallHooks();
    if (!raOn(@"dl")) { gButton.hidden = YES; return; }
    gButton.hidden = NO;
    UIWindow *w = IGDKeyWindow();
    if (!w) return;
    if (!gButton) {
        gButton = [UIButton buttonWithType:UIButtonTypeCustom];
        gButton.bounds = CGRectMake(0, 0, 44, 44);
        gButton.tintColor = UIColor.whiteColor;
        gButton.layer.shadowColor = UIColor.blackColor.CGColor;     // keeps the bare icon readable on bright videos
        gButton.layer.shadowOpacity = 0.45;
        gButton.layer.shadowRadius = 2;
        gButton.layer.shadowOffset = CGSizeZero;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightSemibold];
        [gButton setImage:[UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:cfg] forState:UIControlStateNormal];
        [gButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { IGDTap(); }] forControlEvents:UIControlEventTouchUpInside];
        [gButton addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:[IGDHandler shared] action:@selector(hold:)]];
    }
    gButton.center = IGDButtonSpot(w);   // fixed, right above the like button
    if (gButton.superview != w) [w addSubview:gButton];
    else if (w.subviews.lastObject != gButton) [w bringSubviewToFront:gButton];
}

__attribute__((constructor)) static void IGDInit(void) {
    NSLog(@"[IGDownloader] %@ loaded", IGD_BUILD);
    raRegister(@"التحميل", @"dl", @"زر التحميل العائم", @"تحميل فيديوهات الريلز والستوري");
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { IGDEnsureButton(); }];
    });
}
