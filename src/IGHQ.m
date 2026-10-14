// IGHQ: send photos/videos at original quality (best effort, based on symbol names).
#import "igd_common.h"
#include <dlfcn.h>
#define BUILD @"q1"

static void hookStrategy(void) {
    Class c = objc_getClass("IGVideoDynamicConfigurationStrategy");
    if (!c) { [igdStatus() addObject:@"✗ IGVideoDynamicConfigurationStrategy (no class)"]; return; }
    Class meta = object_getClass(c);
    SEL sel = sel_registerName("serverDerivedWithAllowPassthrough:highQuality:enableKeyframeDataExtraction:");
    Method m = class_getInstanceMethod(meta, sel);
    if (!m || method_getNumberOfArguments(m) != 5) { [igdStatus() addObject:@"✗ +serverDerivedWithAllowPassthrough:highQuality:… (no method)"]; return; }
    static BOOL done; if (done) return; done = YES;
    IMP orig = method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^id(id self, BOOL pass, BOOL hq, BOOL key) {
        if (raOn(@"hq.send")) { pass = YES; hq = YES; }
        return ((id (*)(id, SEL, BOOL, BOOL, BOOL))orig)(self, sel, pass, hq, key);
    });
    method_setImplementation(m, imp);
    [igdStatus() addObject:@"✓ +IGVideoDynamicConfigurationStrategy serverDerived…highQuality"];
}

static void forceFlag(void) {
    if (!raOn(@"hq.send")) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray *keys = [@[@"_IGUploadHighQuality", @"IGUploadHighQuality"] mutableCopy];
    // "IGUploadHighQuality" is an exported string constant in the app: use its real value as the key too
    void **sym = (void **)dlsym(RTLD_DEFAULT, "IGUploadHighQuality");
    id val = sym ? (__bridge id)(*sym) : nil;
    if ([val isKindOfClass:[NSString class]]) [keys addObject:val];
    for (NSString *k in keys) {
        if (![d boolForKey:k]) [d setBool:YES forKey:k];
    }
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"الرسائل", @"hq.send", @"إرسال الصور والفيديو بجودة أصلية", @"يفعّل خيار الجودة العالية للرفع ويمنع الضغط (يعمل بعد إعادة فتح التطبيق)");
    forceFlag();
    igdRun(@"IGHQ", BUILD, ^{
        hookStrategy();
        forceFlag();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ forceFlag(); });
    });
}
