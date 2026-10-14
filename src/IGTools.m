// IGTools: chat tools opened by long-pressing the eye button in a chat.
//   • send the same message N times in a row (with a delay between sends)
#import "igd_common.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <PhotosUI/PhotosUI.h>
#define BUILD @"t3"

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


// =============================== video -> voice message ===============================
// 1) pick a video, 2) extract its audio and encode Ogg Opus (the format Instagram voice messages use),
// 3) the next voice message you record is swapped for that file the moment the recording stops.
static NSString *gPendingOgg;
static NSDate *gPendingAt;
static NSMutableString *gVoiceLog;
static void vlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void vlog(NSString *fmt, ...) {
    if (!gVoiceLog) gVoiceLog = [NSMutableString new];
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [gVoiceLog appendFormat:@"%@\n", m];
    NSLog(@"[IGTools voice] %@", m);
}

static void startPolling(void);

// ---- Ogg container -------------------------------------------------------------------
static uint32_t oggCRC(const uint8_t *d, size_t n) {
    static uint32_t T[256]; static dispatch_once_t o;
    dispatch_once(&o, ^{ for (uint32_t i = 0; i < 256; i++) { uint32_t r = i << 24; for (int k = 0; k < 8; k++) r = (r & 0x80000000) ? (r << 1) ^ 0x04C11DB7 : (r << 1); T[i] = r; } });
    uint32_t c = 0;
    for (size_t i = 0; i < n; i++) c = (c << 8) ^ T[((c >> 24) & 0xFF) ^ d[i]];
    return c;
}
static void oggPage(NSMutableData *out, uint8_t type, uint64_t granule, uint32_t serial, uint32_t seq, NSArray<NSData *> *packets) {
    NSMutableData *lace = [NSMutableData data], *body = [NSMutableData data];
    for (NSData *p in packets) {
        NSUInteger len = p.length;
        while (len >= 255) { uint8_t v = 255; [lace appendBytes:&v length:1]; len -= 255; }
        uint8_t v = (uint8_t)len; [lace appendBytes:&v length:1];
        [body appendData:p];
    }
    NSMutableData *pg = [NSMutableData data];
    uint8_t h[27] = {'O','g','g','S',0,type};
    memcpy(h + 6, &granule, 8);        // little endian on arm64
    memcpy(h + 14, &serial, 4);
    memcpy(h + 18, &seq, 4);
    h[26] = (uint8_t)lace.length;
    [pg appendBytes:h length:27];
    [pg appendData:lace]; [pg appendData:body];
    uint32_t crc = oggCRC(pg.bytes, pg.length);
    memcpy((uint8_t *)pg.mutableBytes + 22, &crc, 4);
    [out appendData:pg];
}

static NSData *oggFromOpusPackets(NSArray<NSData *> *pkts, uint32_t framesPerPacket, uint16_t preSkip) {
    NSMutableData *out = [NSMutableData data];
    uint32_t serial = arc4random();
    NSMutableData *head = [NSMutableData data];
    [head appendBytes:"OpusHead" length:8];
    uint8_t b = 1; [head appendBytes:&b length:1];         // version
    b = 1; [head appendBytes:&b length:1];                 // channels
    [head appendBytes:&preSkip length:2];
    uint32_t rate = 48000; [head appendBytes:&rate length:4];
    uint16_t gain = 0; [head appendBytes:&gain length:2];
    b = 0; [head appendBytes:&b length:1];                 // mapping family
    oggPage(out, 0x02, 0, serial, 0, @[head]);
    NSMutableData *tags = [NSMutableData data];
    [tags appendBytes:"OpusTags" length:8];
    const char *vendor = "RaTweak"; uint32_t vl = (uint32_t)strlen(vendor);
    [tags appendBytes:&vl length:4]; [tags appendBytes:vendor length:vl];
    uint32_t zero = 0; [tags appendBytes:&zero length:4];
    oggPage(out, 0x00, 0, serial, 1, @[tags]);
    uint32_t seq = 2; uint64_t gran = preSkip;
    NSUInteger i = 0, per = 20;
    while (i < pkts.count) {
        NSUInteger e = MIN(i + per, pkts.count);
        gran += (uint64_t)(e - i) * framesPerPacket;
        oggPage(out, e == pkts.count ? 0x04 : 0x00, gran, serial, seq++, [pkts subarrayWithRange:NSMakeRange(i, e - i)]);
        i = e;
    }
    return out;
}

// ---- video -> PCM -> Opus (CAF via AudioToolbox) -> Ogg ---------------------------------
static void convertVideoToOgg(NSURL *video, void (^done)(NSString *err)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        AVURLAsset *as = [AVURLAsset assetWithURL:video];
        AVAssetTrack *tr = [as tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (!tr) { done(@"الفيديو ما فيه صوت"); return; }
        AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:as error:&e];
        if (!rd) { done([NSString stringWithFormat:@"قراءة الفيديو: %@", e.localizedDescription]); return; }
        NSDictionary *pcm = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1,
                              AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO};
        AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr outputSettings:pcm];
        [rd addOutput:out];
        rd.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(180, 600));   // cap at 3 minutes
        if (![rd startReading]) { done(@"ما قدرت أقرأ الصوت"); return; }

        NSURL *caf = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ra-voice-%u.caf", arc4random()]]];
        AVAudioFormat *pf = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:48000 channels:1 interleaved:YES];
        AVAudioFile *af = [[AVAudioFile alloc] initForWriting:caf
            settings:@{AVFormatIDKey: @(kAudioFormatOpus), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1, AVEncoderBitRateKey: @32000}
            commonFormat:AVAudioPCMFormatInt16 interleaved:YES error:&e];
        if (!af) { done([NSString stringWithFormat:@"مشفّر Opus ما اشتغل: %@", e.localizedDescription]); return; }
        long long frames = 0;
        CMSampleBufferRef sb;
        while ((sb = [out copyNextSampleBuffer])) {
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            size_t len = 0; char *ptr = NULL;
            if (bb && CMBlockBufferGetDataPointer(bb, 0, NULL, &len, &ptr) == kCMBlockBufferNoErr && len >= 2) {
                AVAudioFrameCount n = (AVAudioFrameCount)(len / 2);
                AVAudioPCMBuffer *pb = [[AVAudioPCMBuffer alloc] initWithPCMFormat:pf frameCapacity:n];
                pb.frameLength = n;
                memcpy(pb.int16ChannelData[0], ptr, n * 2);
                if (![af writeFromBuffer:pb error:&e]) { CFRelease(sb); done([NSString stringWithFormat:@"كتابة Opus: %@", e.localizedDescription]); return; }
                frames += n;
            }
            CFRelease(sb);
        }
        af = nil;   // finalise the file
        if (!frames) { done(@"ما طلع صوت من الفيديو"); return; }

        AudioFileID fid = NULL;
        if (AudioFileOpenURL((__bridge CFURLRef)caf, kAudioFileReadPermission, kAudioFileCAFType, &fid) != noErr) { done(@"ما قدرت أفتح ملف Opus"); return; }
        AudioStreamBasicDescription asbd; UInt32 sz = sizeof asbd;
        AudioFileGetProperty(fid, kAudioFilePropertyDataFormat, &sz, &asbd);
        UInt64 npk = 0; sz = sizeof npk;
        AudioFileGetProperty(fid, kAudioFilePropertyAudioDataPacketCount, &sz, &npk);
        AudioFilePacketTableInfo pti = {0}; sz = sizeof pti;
        AudioFileGetProperty(fid, kAudioFilePropertyPacketTableInfo, &sz, &pti);
        UInt32 maxp = 0; sz = sizeof maxp;
        AudioFileGetProperty(fid, kAudioFilePropertyMaximumPacketSize, &sz, &maxp);
        uint32_t fpp = asbd.mFramesPerPacket ?: 960;
        vlog(@"opus: %llu packets, %u frames/packet, maxPacket %u, priming %d", npk, fpp, maxp, (int)pti.mPrimingFrames);

        NSMutableArray<NSData *> *pkts = [NSMutableArray new];
        UInt64 idx = 0;
        while (idx < npk) {
            UInt32 np = (UInt32)MIN((UInt64)64, npk - idx);
            UInt32 bytes = np * (maxp ?: 1500);
            NSMutableData *buf = [NSMutableData dataWithLength:bytes];
            AudioStreamPacketDescription *descs = calloc(np, sizeof *descs);
            OSStatus st = AudioFileReadPacketData(fid, false, &bytes, descs, idx, &np, buf.mutableBytes);
            if (st != noErr || !np) { free(descs); break; }
            for (UInt32 k = 0; k < np; k++) [pkts addObject:[buf subdataWithRange:NSMakeRange(descs[k].mStartOffset, descs[k].mDataByteSize)]];
            free(descs);
            idx += np;
        }
        AudioFileClose(fid);
        [[NSFileManager defaultManager] removeItemAtURL:caf error:nil];
        if (!pkts.count) { done(@"ما قدرت أقرأ حزم Opus"); return; }
        NSData *ogg = oggFromOpusPackets(pkts, fpp, pti.mPrimingFrames ? (uint16_t)pti.mPrimingFrames : 312);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ra-voice-%u.ogg", arc4random()]];
        [ogg writeToFile:path atomically:YES];
        vlog(@"ogg ready: %lu bytes, %.1f sec", (unsigned long)ogg.length, (double)frames / 48000.0);
        dispatch_async(dispatch_get_main_queue(), ^{ gPendingOgg = path; gPendingAt = [NSDate date]; startPolling(); done(nil); });
    });
}

// ---- swap the file Instagram just recorded -----------------------------------------------
static BOOL looksOgg(NSString *path) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *d = [h readDataOfLength:4]; [h closeFile];
    return d.length == 4 && memcmp(d.bytes, "OggS", 4) == 0;
}
static int swapInDir(NSString *dir, NSData *repl, int depth) {
    int n = 0;
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *it in items) {
        NSString *p = [dir stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&isDir]) continue;
        if (isDir) { if (depth < 3) n += swapInDir(p, repl, depth + 1); continue; }
        if ([p isEqualToString:gPendingOgg]) continue;
        NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
        if (-[at.fileModificationDate timeIntervalSinceNow] > 20 || at.fileSize == 0) continue;
        NSString *ext = p.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"ogg"] || [ext isEqualToString:@"opus"] || [ext isEqualToString:@"oga"] || looksOgg(p))) continue;
        BOOL ok = [repl writeToFile:p atomically:NO];     // same inode: Instagram may still hold it open
        vlog(@"swapped %@ (%llu bytes before) ok=%d", p.lastPathComponent, at.fileSize, ok);
        n++;
    }
    return n;
}
static void swapRecordedFile(void) {
    if (!gPendingOgg || -[gPendingAt timeIntervalSinceNow] > 600) return;
    NSData *repl = [NSData dataWithContentsOfFile:gPendingOgg];
    if (!repl.length) return;
    NSString *home = NSHomeDirectory();
    int n = 0;
    for (NSString *r in @[NSTemporaryDirectory(), [home stringByAppendingPathComponent:@"Library/Caches"], [home stringByAppendingPathComponent:@"Documents"], [home stringByAppendingPathComponent:@"Library"]])
        n += swapInDir(r, repl, 0);
    if (!n) vlog(@"stop() seen but no recent .ogg file found yet");
}


// ---- fallback: watch for the recording file instead of relying on stop() ---------------------
static NSTimer *gPoll;
static NSMutableDictionary<NSString *, NSDate *> *gSeenM;   // path -> last mtime we saw
static NSMutableSet<NSString *> *gLogged, *gSwappedKeys;

static void pollScan(NSString *dir, NSData *repl, int depth, int *logs) {
    for (NSString *it in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *p = [dir stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&isDir]) continue;
        if (isDir) { if (depth < 3) pollScan(p, repl, depth + 1, logs); continue; }
        if ([p isEqualToString:gPendingOgg]) continue;
        NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
        NSDate *mt = at.fileModificationDate;
        if (!mt || -[mt timeIntervalSinceNow] > 4 || at.fileSize == 0) continue;
        BOOL ogg = looksOgg(p) || [@[@"ogg", @"opus", @"oga"] containsObject:p.pathExtension.lowercaseString];
        if (![gLogged containsObject:p] && *logs < 3) {
            [gLogged addObject:p]; (*logs)++;
            vlog(@"new file: %@ (%llu bytes, ogg=%d)", [p stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"], at.fileSize, ogg);
        }
        if (!ogg) continue;
        NSDate *prev = gSeenM[p]; gSeenM[p] = mt;
        NSString *key = [NSString stringWithFormat:@"%@|%f", p, mt.timeIntervalSince1970];
        if (prev && [prev isEqualToDate:mt] && ![gSwappedKeys containsObject:key]) {   // unchanged for a tick = recording finished
            BOOL ok = [repl writeToFile:p atomically:NO];
            [gSwappedKeys addObject:key];
            vlog(@"poll: swapped %@ (%llu bytes) ok=%d", p.lastPathComponent, at.fileSize, ok);
            NSDictionary *at2 = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
            if (at2.fileModificationDate) [gSwappedKeys addObject:[NSString stringWithFormat:@"%@|%f", p, at2.fileModificationDate.timeIntervalSince1970]];
        }
    }
}
static void startPolling(void) {
    [gPoll invalidate];
    gSeenM = [NSMutableDictionary new]; gLogged = [NSMutableSet new]; gSwappedKeys = [NSMutableSet new];
    gPoll = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        if (!gPendingOgg || -[gPendingAt timeIntervalSinceNow] > 600) { [t invalidate]; gPoll = nil; return; }
        NSData *repl = [NSData dataWithContentsOfFile:gPendingOgg];
        if (!repl.length) return;
        NSString *home = NSHomeDirectory();
        int logs = 0;
        for (NSString *r in @[NSTemporaryDirectory(), [home stringByAppendingPathComponent:@"Library/Caches"], [home stringByAppendingPathComponent:@"Documents"], [home stringByAppendingPathComponent:@"Library/Application Support"]])
            pollScan(r, repl, 0, &logs);
    }];
}

static void hookRecorder(void) {
    igdHook("OggOpusVoiceMessageRecorder", "start", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^int(id self) { vlog(@"recorder start() pending=%d", gPendingOgg != nil); return ((int (*)(id, SEL))orig)(self, s); };
    });
    igdHook("OggOpusVoiceMessageRecorder", "stop", ^id(IMP orig, SEL s, char ret, unsigned nargs) {
        if (nargs != 0) return nil;
        return ^BOOL(id self) {
            BOOL r = ((BOOL (*)(id, SEL))orig)(self, s);
            vlog(@"recorder stop() pending=%d", gPendingOgg != nil);
            if (gPendingOgg) {
                vlog(@"recorder stop() -> swapping");
                swapRecordedFile();
                for (NSNumber *d in @[@0.15, @0.5, @1.2]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ swapRecordedFile(); });
            }
            return r;
        };
    });
}

@interface IGToolsPicker : NSObject <PHPickerViewControllerDelegate>
@end
@implementation IGToolsPicker
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *r = results.firstObject;
    if (!r) return;
    igdToast(@"أحوّل صوت الفيديو…");
    [r.itemProvider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) {
        if (!url) { igdToast(@"ما قدرت أقرأ الفيديو"); return; }
        NSURL *copy = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ra-src-%u.%@", arc4random(), url.pathExtension ?: @"mov"]]];
        [[NSFileManager defaultManager] copyItemAtURL:url toURL:copy error:nil];
        convertVideoToOgg(copy, ^(NSString *e) {
            [[NSFileManager defaultManager] removeItemAtURL:copy error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (e) { igdToast([NSString stringWithFormat:@"فشل: %@", e]); return; }
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"الصوت جاهز ✓"
                    message:@"الحين سجّل فويس عادي في المحادثة: اضغط مطوّلاً على المايك وأرسل (يفضّل تثبّت التسجيل لين تقارب مدة الصوت). أول فويس ترسله يتبدّل بصوت الفيديو."
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"تمام" style:UIAlertActionStyleDefault handler:nil]];
                [igdTopVC() presentViewController:a animated:YES completion:nil];
            });
        });
    }];
}
@end
static IGToolsPicker *gPicker;

static void pickVideoForVoice(void) {
    PHPickerConfiguration *c = [[PHPickerConfiguration alloc] init];
    c.filter = [PHPickerFilter videosFilter];
    c.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:c];
    gPicker = [IGToolsPicker new];
    p.delegate = gPicker;
    [igdTopVC() presentViewController:p animated:YES completion:nil];
}

static void showVoiceReport(void) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"تقرير الفويس"
        message:gVoiceLog.length ? gVoiceLog : @"(ما صار شي بعد)" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"مشاركة" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[gVoiceLog ?: @""] applicationActivities:nil];
        UIViewController *t = igdTopVC(); vc.popoverPresentationController.sourceView = t.view;
        [t presentViewController:vc animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"إغلاق" style:UIAlertActionStyleCancel handler:nil]];
    [igdTopVC() presentViewController:a animated:YES completion:nil];
}

static void openRepeat(UIViewController *thread);
static void openTools(UIViewController *thread) {
    UIAlertController *m = [UIAlertController alertControllerWithTitle:@"أدوات المحادثة" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [m addAction:[UIAlertAction actionWithTitle:@"إرسال رسالة متكررة" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (!raOn(@"tools.repeat")) { igdToast(@"مطفي من Ra Menu"); return; }
        openRepeat(thread);
    }]];
    [m addAction:[UIAlertAction actionWithTitle:(gPendingOgg ? @"فيديو ← فويس (يوجد صوت جاهز، اختر غيره)" : @"فيديو ← فويس") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (!raOn(@"tools.voice")) { igdToast(@"مطفي من Ra Menu"); return; }
        pickVideoForVoice();
    }]];
    if (gPendingOgg) [m addAction:[UIAlertAction actionWithTitle:@"إلغاء الصوت الجاهز" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { gPendingOgg = nil; igdToast(@"تم الإلغاء"); }]];
    [m addAction:[UIAlertAction actionWithTitle:@"تقرير الفويس" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { showVoiceReport(); }]];
    [m addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    m.popoverPresentationController.sourceView = thread.view;
    [igdTopVC() presentViewController:m animated:YES completion:nil];
}

static void openRepeat(UIViewController *thread) {
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
    raRegister(@"أدوات المحادثة", @"tools.voice", @"تحويل فيديو إلى فويس", @"تجريبي: يبدّل صوت الفويس اللي تسجّله بصوت الفيديو");
    dispatch_async(dispatch_get_main_queue(), ^{
        hookRecorder();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (!objc_getClass("OggOpusVoiceMessageRecorder")) vlog(@"OggOpusVoiceMessageRecorder class not found"); });
    });
    [NSNotificationCenter.defaultCenter addObserverForName:@"ra.chattools" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if ([n.object isKindOfClass:[UIViewController class]]) openTools(n.object);
    }];
    NSLog(@"[IGTools %@] loaded", BUILD);
}
