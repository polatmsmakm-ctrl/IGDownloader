// IGTools: chat tools opened by long-pressing the eye button in a chat.
//   • send the same message N times in a row (with a delay between sends)
#import "igd_common.h"
#define BUILD @"t1"

static BOOL gRunning, gStop;

static UIViewController *findVC(UIViewController *vc, NSString *needle, int depth) {
    if (!vc || depth > 6) return nil;
    if ([NSStringFromClass(vc.class) containsString:needle]) return vc;
    for (UIViewController *c in vc.childViewControllers) { UIViewController *r = findVC(c, needle, depth + 1); if (r) return r; }
    return nil;
}

// The lowest text view on screen = the message composer.
static UITextView *findComposerTextView(UIView *v, UITextView *best, UIWindow *w) {
    if ([v isKindOfClass:[UITextView class]] && !v.hidden && v.window) {
        CGFloat y = CGRectGetMaxY([v convertRect:v.bounds toView:w]);
        if (!best || y > CGRectGetMaxY([best convertRect:best.bounds toView:w])) best = (UITextView *)v;
    }
    for (UIView *s in v.subviews) best = findComposerTextView(s, best, w);
    return best;
}

// Search an object graph (ivars) for an instance whose class name contains `needle`.
static id findObject(id o, NSString *needle, int depth, NSMutableSet *seen) {
    if (!o || depth < 0) return nil;
    NSValue *k = [NSValue valueWithPointer:(__bridge void *)o];
    if ([seen containsObject:k]) return nil;
    [seen addObject:k];
    if ([NSStringFromClass(object_getClass(o)) containsString:needle]) return o;
    for (Class c = object_getClass(o); c && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned n = 0; Ivar *l = class_copyIvarList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(l[i]);
            if (!t || t[0] != '@') continue;
            NSString *cn = [NSString stringWithUTF8String:t];
            if ([cn containsString:@"NSString"] || [cn containsString:@"UIImage"] || [cn containsString:@"NSData"]) continue;
            id v = object_getIvar(o, l[i]);
            id r = findObject(v, needle, depth - 1, seen);
            if (r) { free(l); return r; }
        }
        free(l);
    }
    return nil;
}

static UIButton *findSendButton(UIView *v) {
    if ([v isKindOfClass:[UIButton class]] && !v.hidden) {
        NSString *l = [[NSString stringWithFormat:@"%@%@", v.accessibilityLabel ?: @"", v.accessibilityIdentifier ?: @""] lowercaseString];
        if ([l containsString:@"send"] || [l containsString:@"إرسال"] || [l containsString:@"ارسال"]) return (UIButton *)v;
    }
    for (UIView *s in v.subviews) { UIButton *b = findSendButton(s); if (b) return b; }
    return nil;
}

static BOOL sendOnce(UIViewController *thread, NSString *text) {
    UIWindow *w = igdKeyWindow();
    UITextView *tv = findComposerTextView(thread.view, nil, w);
    if (!tv) return NO;
    tv.text = text;
    if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) [tv.delegate textViewDidChange:tv];
    [NSNotificationCenter.defaultCenter postNotificationName:UITextViewTextDidChangeNotification object:tv];

    UIViewController *comp = findVC(thread, @"IGDirectComposerViewController", 0);
    id ctl = comp ? findObject(comp, @"IGDirectComposerSendController", 4, [NSMutableSet new]) : nil;
    SEL tap = sel_registerName("didTapSend");
    if (ctl && [ctl respondsToSelector:tap]) { ((void (*)(id, SEL))objc_msgSend)(ctl, tap); return YES; }
    UIButton *b = findSendButton(thread.view);
    if (b) { [b sendActionsForControlEvents:UIControlEventTouchUpInside]; return YES; }
    return NO;
}

static void runRepeat(__weak UIViewController *thread, NSString *text, NSInteger count, double delay) {
    gRunning = YES; gStop = NO;
    __block NSInteger i = 0;
    __block void (^step)(void);
    step = ^{
        UIViewController *t = thread;
        if (gStop || !t || i >= count) {
            gRunning = NO;
            igdToast(gStop ? [NSString stringWithFormat:@"توقّف الإرسال بعد %ld رسالة", (long)i] : [NSString stringWithFormat:@"تم إرسال %ld رسالة ✓", (long)i]);
            step = nil; return;
        }
        if (!sendOnce(t, text)) { gRunning = NO; igdToast(@"ما قدرت أرسل (ما لقيت خانة الكتابة أو زر الإرسال)"); step = nil; return; }
        i++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    };
    step();
}

static void openTools(UIViewController *thread) {
    if (!raOn(@"tools.repeat")) { igdToast(@"أدوات المحادثة مطفية من Ra Menu"); return; }
    UIViewController *top = igdTopVC();
    if (gRunning) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"الإرسال شغّال" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"إيقاف" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { gStop = YES; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"كمّل" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
        return;
    }
    UITextView *tv = findComposerTextView(thread.view, nil, igdKeyWindow());
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"إرسال رسالة متكررة"
                                                               message:@"اكتب الرسالة وعدد المرات (الحد 50). بين كل رسالة وثانية فيه فاصل عشان ما ينحظر الحساب."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"الرسالة"; f.text = tv.text; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"العدد"; f.text = @"20"; f.keyboardType = UIKeyboardTypeNumberPad; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"الفاصل بالثواني"; f.text = @"1"; f.keyboardType = UIKeyboardTypeDecimalPad; }];
    __weak UIViewController *wt = thread;
    [a addAction:[UIAlertAction actionWithTitle:@"ابدأ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *msg = a.textFields[0].text;
        NSInteger n = MIN(MAX(a.textFields[1].text.integerValue, 1), 50);
        double d = MAX(a.textFields[2].text.doubleValue, 0.6);
        if (!msg.length) { igdToast(@"اكتب الرسالة أول"); return; }
        runRepeat(wt, msg, n, d);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void init(void) {
    raRegister(@"أدوات المحادثة", @"tools.repeat", @"إرسال رسالة متكررة", @"اضغط مطوّلاً على زر العين داخل المحادثة");
    [NSNotificationCenter.defaultCenter addObserverForName:@"ra.chattools" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if ([n.object isKindOfClass:[UIViewController class]]) openTools(n.object);
    }];
    NSLog(@"[IGTools %@] loaded", BUILD);
}
