//
//  Tweak.m — DayNightSwitch（系统开关换肤）
//
//  原理：给每个 UISwitch 叠加一个自绘的日夜开关视图（DNToggleView），
//        由它接管触摸，再把状态写回 UISwitch 并发送 UIControlEventValueChanged。
//        不隐藏原生视图、不改私有结构，系统行为（VoiceOver / 触感 / 布局）不受影响。
//
//  设计：Dribbble Ramakrishna / Tsuriel   实现参考：Finn Gaida (MIT)   本插件：Ning
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DNToggleView.h"
#import "DNLiquidSwitchHost.h"

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static char kDNOverlayKey;

static void DNLogFirstAttach(void);

static void DNLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // 每进程一个小文件（首次调用时清空），便于精确读取
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = [[NSProcessInfo processInfo] processName] ?: @"unknown";
        path = [NSString stringWithFormat:@"/var/mobile/Library/switch-%@.log", name];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    });
    NSString *line = [[NSString alloc] initWithFormat:@"[%@] %@\n", [NSDate date], msg];
    FILE *f = fopen(path.UTF8String, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
    // 同时保留汇总日志（可选）
}

static void DNProbe(NSString *msg) { DNLog(@"%@", msg); }
static BOOL DNShouldApply(void);

// —— 偏好 ——
static BOOL gEnabled   = YES;
static BOOL gGlobal    = YES;   // YES: 所有 App；NO: 只在「设置」
static BOOL gExcludeSettings = NO;
static BOOL gLiquid = NO;   // 液态开关（航同款 LiquidGlassView）

static NSString *const kDNBundleID = @"com.ning.switch";
static NSString *const kDNNotify   = @"com.ning.switch/settingschanged";

// —— 偏好读取：多来源合并（roothide 下设置进程写 jbroot，App 读真实路径，两边会分裂）——
static NSString *DNPrefsFileName(void) { return @"com.ning.switch.plist"; }

static NSString *DNPrefsRealPath(void) {
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:DNPrefsFileName()];
}

/// 由插件 dylib 自身路径推导 jbroot 前缀 → jbroot 内的偏好文件
static NSString *DNPrefsJbRootPath(void) {
    NSString *exec = [[NSBundle bundleForClass:[DNToggleView class]] executablePath] ?: @"";
    NSRange r = [exec rangeOfString:@"/Library/"];
    if (r.location == NSNotFound) return nil;
    NSString *jb = [exec substringToIndex:r.location];
    return [[jb stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]
            stringByAppendingPathComponent:DNPrefsFileName()];
}

static NSDate *DNFileMTime(NSString *path) {
    if (!path) return nil;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return a[NSFileModificationDate];
}

#include <dlfcn.h>

static void DNDylibDirAnchor(void) {}

/// 本 dylib 所在目录（任何被注入的进程都能读这里）
static NSString *DNDylibDir(void) {
    Dl_info info;
    if (dladdr((const void *)&DNDylibDir, &info) == 0 || !info.dli_fname) return nil;
    NSString *p = [NSString stringWithUTF8String:info.dli_fname];
    return p.stringByDeletingLastPathComponent;
}

/// 与航一致：CFPreferences 优先，然后依次尝试多个文件路径（不同 App 沙盒能读到的不一样）
static NSArray *DNPrefsCandidates(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *dir = DNDylibDir();
    if (dir) [a addObject:[dir stringByAppendingPathComponent:@"SwitchPrefs.plist"]];
    [a addObject:@"/var/jb/var/mobile/Library/Preferences/com.ning.switch.plist"];
    NSString *derived = DNPrefsJbRootPath();
    if (derived) [a addObject:derived];
    [a addObject:DNPrefsRealPath()];
    return a;
}

static NSDictionary *DNPrefsDict(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    NSArray *keys = @[@"enabled", @"global", @"excludeSettings", @"liquid"];
    CFDictionaryRef got = CFPreferencesCopyMultiple((__bridge CFArrayRef)keys,
                                                    CFSTR("com.ning.switch"),
                                                    kCFPreferencesCurrentUser,
                                                    kCFPreferencesAnyHost);
    NSDictionary *cf = nil;
    if (got) {
        cf = (__bridge_transfer NSDictionary *)got;
        if (cf.count == 0) cf = nil;
    }

    NSMutableArray *hit = [NSMutableArray array];
    for (NSString *path in DNPrefsCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (d) {
            [hit addObject:path.lastPathComponent];
            [out addEntriesFromDictionary:d];
            break;   // 第一个能读到的为准
        }
    }
    if (cf) [out addEntriesFromDictionary:cf];   // cf 优先

    static int logged = 0;
    if (logged < 8) {
        logged++;
        DNLog(@"读取源: cf=%@ 文件=%@ 键数=%lu", cf ? @(cf.count) : @"nil",
              hit.count ? hit[0] : @"nil", (unsigned long)out.count);
    }
    return out;
}

static BOOL DNValueToBool(id v, BOOL fallback) {
    if (!v) return fallback;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return fallback;
}

/// 读取：只认文件里的值，没有就用默认值
static BOOL DNGetBool(NSString *key, BOOL fallback) {
    static NSDictionary *cached = nil;
    static NSDate *cachedAt = nil;
    if (!cached || !cachedAt || -[cachedAt timeIntervalSinceNow] > 0.3) {
        cached = DNPrefsDict();
        cachedAt = [NSDate date];
    }
    return DNValueToBool(cached[key], fallback);
}

static void DNLoadPrefs(void) {
    gEnabled         = DNGetBool(@"enabled", YES);
    gGlobal          = DNGetBool(@"global", YES);
    gExcludeSettings = DNGetBool(@"excludeSettings", NO);
    gLiquid          = DNGetBool(@"liquid", NO);
    static int lastE = -1, lastG = -1, lastX = -1;
    if (lastE != gEnabled || lastG != gGlobal || lastX != gExcludeSettings) {
        lastE = gEnabled; lastG = gGlobal; lastX = gExcludeSettings;
        DNLog(@"偏好 enabled=%d global=%d exclude=%d liquid=%d",
              gEnabled, gGlobal, gExcludeSettings, gLiquid);
    }
    DNProbe([NSString stringWithFormat:@"proc=%@ apply=%d E=%d G=%d X=%d",
             [[NSProcessInfo processInfo] processName],
             DNShouldApply() ? 1 : 0, gEnabled, gGlobal, gExcludeSettings]);
}

/// 当前进程是否需要 + 允许套用
static BOOL DNShouldApply(void) {
    // 总开关关 → 全部不套
    if (!gEnabled) return NO;
    if (!objc_getClass("UISwitch")) return NO;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    // 「设置」这一个 App：只由第三个开关单独决定（优先级最高）
    if ([bid isEqualToString:@"com.apple.Preferences"]) return !gExcludeSettings;
    // 其他 App：只看第二个「所有 App 生效」
    return gGlobal;
}

static DNToggleView *DNOverlay(UISwitch *sw) {
    return objc_getAssociatedObject(sw, &kDNOverlayKey);
}

// 用户操作回写 UISwitch 时，避免再次回灌 overlay 造成二次动画
static BOOL gInUserAction = NO;

static void DNDetach(UISwitch *sw);

// 尺寸闸门：只给「正常大小」的开关挂皮肤，异常尺寸（整屏/零尺寸）一律跳过
static BOOL DNSaneBounds(CGRect b) {
    if (b.size.width < 20 || b.size.width > 120) return NO;
    if (b.size.height < 12 || b.size.height > 70) return NO;
    return YES;
}

static void DNAttach(UISwitch *sw) {
    if (!DNShouldApply()) return;
    CGRect b = sw.bounds;
    if (!DNSaneBounds(b)) {
        // 异常尺寸：把已经挂上的摘掉，避免被放大成整屏
        DNDetach(sw);
        return;
    }

    // 液态模式：走独立实例宿主，不进 DNToggleView
    if (gLiquid) {
        DNDetach(sw);
        [DNLiquidSwitchHost applyToSwitch:sw];
        return;
    }
    [DNLiquidSwitchHost removeFromSwitch:sw];

    DNToggleView *v = DNOverlay(sw);
    if (!v) {
        v = [[DNToggleView alloc] initWithFrame:b];
        v.autoresizingMask = UIViewAutoresizingNone;   // 尺寸只由我们按开关 bounds 显式设置，绝不跟随缩放
        v.backgroundColor = [UIColor clearColor];
        __weak UISwitch *weakSw = sw;
        v.onChange = ^(BOOL on) {
            UISwitch *s = weakSw;
            if (!s) return;
            gInUserAction = YES;
            [s setOn:on animated:YES];
            gInUserAction = NO;
            [s sendActionsForControlEvents:UIControlEventValueChanged];
        };
        v.clipsToBounds = YES;
        v.layer.masksToBounds = YES;
        v.layer.cornerRadius = b.size.height / 2;
        if (@available(iOS 13.0, *)) {
            v.layer.cornerCurve = kCACornerCurveContinuous;
        }
        objc_setAssociatedObject(sw, &kDNOverlayKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sw addSubview:v];
        v.isAccessibilityElement = NO;
    }
    // 只在需要时调整层级，避免 layoutSubviews 里反复重排
    if (sw.subviews.lastObject != v) [sw bringSubviewToFront:v];
    if (!CGRectEqualToRect(v.frame, b)) v.frame = b;
    if (v.on != sw.isOn) [v setOn:sw.isOn animated:NO];
    DNLogFirstAttach();
}

static void DNDetach(UISwitch *sw) {
    [DNLiquidSwitchHost removeFromSwitch:sw];
    DNToggleView *v = DNOverlay(sw);
    if (!v) return;
    [v removeFromSuperview];
    objc_setAssociatedObject(sw, &kDNOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// —— 已挂载的开关（弱引用，用于偏好变化时整体开关）——
static NSHashTable *DNAllSwitches(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

// —— Hooks ——
static void (*orig_didMoveToSuperview)(id, SEL);
static void (*orig_layoutSubviews)(id, SEL);
static void (*orig_setOnAnimated)(id, SEL, BOOL, BOOL);
static void (*orig_setOn)(id, SEL, BOOL);

static void DN_didMoveToSuperview(UISwitch *self, SEL _cmd) {
    orig_didMoveToSuperview(self, _cmd);
    [DNAllSwitches() addObject:self];
    DNAttach(self);
}

static void DN_layoutSubviews(UISwitch *self, SEL _cmd) {
    orig_layoutSubviews(self, _cmd);
    if (!DNShouldApply()) { DNDetach(self); return; }
    if (gLiquid) {
        if ([DNLiquidSwitchHost isAttached:self]) [DNLiquidSwitchHost applyToSwitch:self];
        return;
    }
    DNToggleView *v = DNOverlay(self);
    if (!DNSaneBounds(self.bounds)) { DNDetach(self); return; }
    v.hidden = NO;
    if (!v) {
        DNAttach(self);
        return;
    }
    if (!CGRectEqualToRect(v.frame, self.bounds)) v.frame = self.bounds;
    if (self.subviews.lastObject != v) [self bringSubviewToFront:v];
}

static void DN_setOnAnimated(UISwitch *self, SEL _cmd, BOOL on, BOOL animated) {
    orig_setOnAnimated(self, _cmd, on, animated);
    if (gInUserAction) return;
    [DNOverlay(self) setOn:on animated:animated];
}

static void DN_setOn(UISwitch *self, SEL _cmd, BOOL on) {
    orig_setOn(self, _cmd, on);
    if (gInUserAction) return;
    [DNOverlay(self) setOn:on animated:NO];
}

/// 遍历视图树（航的做法：每次变更扫全窗口，而不是只查登记表）
static void DNVisitSwitchSubtree(UIView *v, BOOL apply, NSInteger *before, NSInteger *after) {
    if (!v) return;
    if ([v isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)v;
        if (DNOverlay(sw) || [DNLiquidSwitchHost isAttached:sw]) (*before)++;
        if (apply) DNAttach(sw); else DNDetach(sw);
        if (DNOverlay(sw) || [DNLiquidSwitchHost isAttached:sw]) (*after)++;
        [sw setNeedsLayout];
    }
    for (UIView *sub in v.subviews) DNVisitSwitchSubtree(sub, apply, before, after);
}

static void DNRefreshAll(void) {
    BOOL apply = DNShouldApply();
    NSInteger before = 0, after = 0;

    // 1) 遍历所有窗口的视图树（主要路径）
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        DNVisitSwitchSubtree(w, apply, &before, &after);
    }
    // 2) 登记表兜底（树里可能暂时不在这条链上）
    for (UISwitch *sw in DNAllSwitches().allObjects) {
        if (DNOverlay(sw) || [DNLiquidSwitchHost isAttached:sw]) before++;
        if (apply) DNAttach(sw); else DNDetach(sw);
        if (DNOverlay(sw) || [DNLiquidSwitchHost isAttached:sw]) after++;
    }
    DNLog(@"刷新: apply=%d 挂载前=%ld 挂载后=%ld", apply, (long)before, (long)after);
}

static void DNPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef info) {
    DNLoadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{ DNRefreshAll(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ DNRefreshAll(); });
}

__attribute__((constructor)) static void DNInit(void) {
    DNLoadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    DNPrefsChanged, (__bridge CFStringRef)kDNNotify, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class sw = objc_getClass("UISwitch");
    DNLog(@"ctor proc=%@ pid=%d UISwitch=%@",
          [[NSProcessInfo processInfo] processName],
          [[NSProcessInfo processInfo] processIdentifier],
          sw ? @"有" : @"无");
    if (!sw) return;
    MSHookMessageEx(sw, @selector(didMoveToSuperview), (IMP)&DN_didMoveToSuperview, (IMP *)&orig_didMoveToSuperview);
    MSHookMessageEx(sw, @selector(layoutSubviews),      (IMP)&DN_layoutSubviews,      (IMP *)&orig_layoutSubviews);
    MSHookMessageEx(sw, @selector(setOn:animated:),     (IMP)&DN_setOnAnimated,       (IMP *)&orig_setOnAnimated);
    MSHookMessageEx(sw, @selector(setOn:),              (IMP)&DN_setOn,               (IMP *)&orig_setOn);
    DNLog(@"hooks 安装完成 4/4  v1.0.5");
}

// 首次挂载记录
static void DNLogFirstAttach(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DNLog(@"首次挂载 overlay, proc=%@", [[NSProcessInfo processInfo] processName]);
    });
}
