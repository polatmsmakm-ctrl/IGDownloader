// IGConfirm: asks "are you sure?" before accidental taps (calls, follow, repost).
#import "igd_common.h"
#define BUILD @"c1"

static void igdConfirm(NSString *msg, void (^go)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"تأكيد" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"نعم" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { go(); }]];
        [igdTopVC() presentViewController:a animated:YES completion:nil];
    });
}

static void confirmHook(const char *cls, const char *sel, NSString *key, NSString *msg) {
    igdHook(cls, sel, ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (ret != 'v') return nil;
        if (nargs == 0) return ^(id self) { if (!raOn(key)) { ((void (*)(id, SEL))orig)(self, s); return; } igdConfirm(msg, ^{ ((void (*)(id, SEL))orig)(self, s); }); };
        if (nargs == 1) return ^(id self, id a) { if (!raOn(key)) { ((void (*)(id, SEL, id))orig)(self, s, a); return; } igdConfirm(msg, ^{ ((void (*)(id, SEL, id))orig)(self, s, a); }); };
        return nil;
    });
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"تأكيد قبل التنفيذ", @"cf.call", @"تأكيد الاتصال", @"سؤال قبل المكالمة الصوتية أو الفيديو");
    raRegister(@"تأكيد قبل التنفيذ", @"cf.follow", @"تأكيد المتابعة", @"سؤال قبل متابعة حساب");
    raRegister(@"تأكيد قبل التنفيذ", @"cf.repost", @"تأكيد إعادة النشر", @"سؤال قبل الريبوست");
    igdRun(@"IGConfirm", BUILD, ^{
        confirmHook("IGDirectThreadCallButtonsCoordinator", "_didTapAudioButton:", @"cf.call", @"تبي تتصل صوتي؟");
        confirmHook("IGDirectThreadCallButtonsCoordinator", "_didTapVideoButton:", @"cf.call", @"تبي تتصل فيديو؟");
        confirmHook("IGFollowController", "_didPressFollowButton", @"cf.follow", @"تبي تتابع هذا الحساب؟");
        confirmHook("IGSundialViewerVerticalUFI", "_didTapRepostButton", @"cf.repost", @"تبي تعيد نشر الريل؟");
        confirmHook("IGUFIInteractionCountsView", "_onRepostButtonPressed:", @"cf.repost", @"تبي تعيد نشر المنشور؟");
    });
}
