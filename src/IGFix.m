// IGFix: sideload fixes (written from scratch).
// A re-signed Instagram often has no App Group / keychain-group entitlement. On new iOS versions that makes
// containerURLForSecurityApplicationGroupIdentifier: return nil and SecItem* fail with errSecMissingEntitlement,
// so the DM inbox (which lives in the shared container + keychain) never loads and sessions get dropped.
#import "igd_common.h"
#import <Security/Security.h>
#define BUILD @"f1"
#define RA_MISSING_ENT (-34018)

static int gContainerFallbacks, gKeychainRetries;
static void note(NSString *s) { @synchronized (igdStatus()) { [igdStatus() addObject:s]; } }

static NSURL *fallbackDir(NSString *gid) {
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *p = [[lib stringByAppendingPathComponent:@"RaGroups"] stringByAppendingPathComponent:gid.length ? gid : @"default"];
    [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:p isDirectory:YES];
}

static CFDictionaryRef noGroup(CFDictionaryRef d) {       // copy without kSecAttrAccessGroup (NULL if it had none)
    if (!d || !CFDictionaryContainsKey(d, kSecAttrAccessGroup)) return NULL;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m;
}
static OSStatus ra_SecItemAdd(CFDictionaryRef a, CFTypeRef *r) {
    OSStatus s = SecItemAdd(a, r);
    if (s == RA_MISSING_ENT) { CFDictionaryRef m = noGroup(a); if (m) { s = SecItemAdd(m, r); CFRelease(m); if (++gKeychainRetries == 1) note(@"ℹ keychain: retried without access group"); } }
    return s;
}
static OSStatus ra_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
    OSStatus s = SecItemCopyMatching(q, r);
    if (s == RA_MISSING_ENT) { CFDictionaryRef m = noGroup(q); if (m) { s = SecItemCopyMatching(m, r); CFRelease(m); gKeychainRetries++; } }
    return s;
}
static OSStatus ra_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef u) {
    OSStatus s = SecItemUpdate(q, u);
    if (s == RA_MISSING_ENT) { CFDictionaryRef m = noGroup(q); CFDictionaryRef m2 = noGroup(u); if (m || m2) { s = SecItemUpdate(m ?: q, m2 ?: u); gKeychainRetries++; } if (m) CFRelease(m); if (m2) CFRelease(m2); }
    return s;
}
static OSStatus ra_SecItemDelete(CFDictionaryRef q) {
    OSStatus s = SecItemDelete(q);
    if (s == RA_MISSING_ENT) { CFDictionaryRef m = noGroup(q); if (m) { s = SecItemDelete(m); CFRelease(m); gKeychainRetries++; } }
    return s;
}
#define RA_INTERPOSE(_r, _o) __attribute__((used)) static struct { const void *r; const void *o; } _ra_i_##_o __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_r, (const void *)(unsigned long)&_o }
RA_INTERPOSE(ra_SecItemAdd, SecItemAdd);
RA_INTERPOSE(ra_SecItemCopyMatching, SecItemCopyMatching);
RA_INTERPOSE(ra_SecItemUpdate, SecItemUpdate);
RA_INTERPOSE(ra_SecItemDelete, SecItemDelete);

__attribute__((constructor)) static void init(void) {
    // must be in place before Instagram's own startup code asks for its group container
    SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method m = class_getInstanceMethod([NSFileManager class], sel);
    if (m) {
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^NSURL *(NSFileManager *self, NSString *gid) {
            NSURL *u = ((NSURL *(*)(id, SEL, id))orig)(self, sel, gid);
            if (u) return u;
            if (++gContainerFallbacks == 1) note([NSString stringWithFormat:@"ℹ app group has no entitlement: using local folder for %@", gid]);
            return fallbackDir(gid);
        }));
        note(@"✓ IGFix NSFileManager containerURLForSecurityApplicationGroupIdentifier:");
    } else note(@"✗ IGFix container hook (no method)");
    note(@"✓ IGFix keychain access-group fallback");
}
