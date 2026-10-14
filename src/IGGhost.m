// IGGhost: stop broadcasting your activity — typing indicator and story "seen".
#import "igd_common.h"
#define BUILD @"g3"

// Make a method do nothing (void) or return NO (BOOL).
static void silence(const char *cls, const char *sel, NSString *key) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret == 'v') {
            if (nargs == 0) return ^(id self) { if (!raOn(key)) ((void (*)(id, SEL))orig)(self, s); };
            if (nargs == 1) return ^(id self, id a) { if (!raOn(key)) ((void (*)(id, SEL, id))orig)(self, s, a); };
            if (nargs == 2) return ^(id self, id a, id b) { if (!raOn(key)) ((void (*)(id, SEL, id, id))orig)(self, s, a, b); };
            return nil;
        }
        if (ret == 'B' || ret == 'c') {
            if (nargs == 0) return ^BOOL(id self) { return raOn(key) ? NO : ((BOOL (*)(id, SEL))orig)(self, s); };
            if (nargs == 1) return ^BOOL(id self, id a) { return raOn(key) ? NO : ((BOOL (*)(id, SEL, id))orig)(self, s, a); };
            return nil;
        }
        return nil;
    });
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"الخصوصية", @"gh.typing", @"إخفاء \"يكتب الآن\"", @"الطرف الثاني ما يشوف إنك تكتب");
    raRegister(@"الخصوصية", @"gh.story", @"إخفاء مشاهدة الستوري", @"تشوف الستوري بدون ما تظهر في قائمة المشاهدين");
    igdRun(@"IGGhost", BUILD, ^{
        // typing indicator: drop "I'm typing" updates, still pass "stopped typing"
        igdHook("IGDirectTypingStatusService", "updateOutgoingStatusIsActive:threadKey:threadMetadata:typingStatusType:",
                ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (ret != 'v' || nargs != 4) return nil;
            return ^(id self, BOOL active, id key, id meta, long type) {
                if (active && raOn(@"gh.typing")) return;
                ((void (*)(id, SEL, BOOL, id, id, long))orig)(self, s, active, key, meta, type);
            };
        });
        // (DM "seen" is handled by IGSeen, which adds a manual eye button)
        // story seen
        silence("IGStoryViewerViewController", "fullscreenSectionController:didMarkItemAsSeen:", @"gh.story");
    });
}
