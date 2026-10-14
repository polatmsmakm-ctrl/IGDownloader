// IGNoAds: stop ads from being parsed / allowed in feed, stories and reels.
#import "igd_common.h"
#define BUILD @"a1"

static void returnNil(const char *cls, const char *sel) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != '@' || nargs != 1) return nil;
        return ^id(id self, id response) { return raOn(@"noads") ? nil : ((id (*)(id, SEL, id))orig)(self, s, response); };
    });
}
static void returnNO(const char *cls, const char *sel) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if ((ret != 'B' && ret != 'c') || nargs != 0) return nil;
        return ^BOOL(id self) { return raOn(@"noads") ? NO : ((BOOL (*)(id, SEL))orig)(self, s); };
    });
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"الإعلانات", @"noads", @"حظر الإعلانات", @"الفيد والستوري والريلز");
    igdRun(@"IGNoAds", BUILD, ^{
        returnNil("IGStoryAdsResponseParser", "parsedObjectFromResponse:");
        returnNil("IGSundialAdsResponseParser", "parsedObjectFromResponse:");
        returnNO("IGMainFeedViewModel", "surfaceSupportsAd");
        returnNO("IGStoryViewerViewController", "surfaceSupportsAd");
    });
}
