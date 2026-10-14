// IGGhost: stop broadcasting your activity — typing indicator and story "seen".
#import "igd_common.h"
#define BUILD @"g2"

// Make a method do nothing (void) or return NO (BOOL).
static void silence(const char *cls, const char *sel) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret == 'v') {
            if (nargs == 0) return ^(id self) {};
            if (nargs == 1) return ^(id self, id a) {};
            if (nargs == 2) return ^(id self, id a, id b) {};
            return nil;
        }
        if (ret == 'B' || ret == 'c') {
            if (nargs == 0) return ^BOOL(id self) { return NO; };
            if (nargs == 1) return ^BOOL(id self, id a) { return NO; };
            return nil;
        }
        return nil;
    });
}

__attribute__((constructor)) static void init(void) {
    igdRun(@"IGGhost", BUILD, ^{
        // typing indicator: drop "I'm typing" updates, still pass "stopped typing"
        igdHook("IGDirectTypingStatusService", "updateOutgoingStatusIsActive:threadKey:threadMetadata:typingStatusType:",
                ^id(IMP orig, SEL s, char ret, unsigned nargs) {
            if (ret != 'v' || nargs != 4) return nil;
            return ^(id self, BOOL active, id key, id meta, long type) {
                if (active) return;
                ((void (*)(id, SEL, BOOL, id, id, long))orig)(self, s, active, key, meta, type);
            };
        });
        // (DM "seen" is handled by IGSeen, which adds a manual eye button)
        // story seen
        silence("IGStoryViewerViewController", "fullscreenSectionController:didMarkItemAsSeen:");
    });
}
