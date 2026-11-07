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

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static char kDNOverlayKey;

// —— 偏好 ——
static BOOL gEnabled   = YES;
static BOOL gGlobal    = YES;   // YES: 所有 App；NO: 只在「设置」
static BOOL gExcludeSettings = NO;

static NSString *const kDNBundleID = @"com.ning.daynightswitch";
static NSString *const kDNNotify   = @"com.ning.daynightswitch/settingschanged";

static BOOL DNGetBool(CFStringRef key, BOOL fallback) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, (__bridge CFStringRef)kDNBundleID);
    if (!v) return fallback;
    BOOL r = fallback;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue((CFBooleanRef)v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int i = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i); r = (i != 0);
    }
    CFRelease(v);
    return r;
}

static void DNLoadPrefs(void) {
    gEnabled = DNGetBool(CFSTR("enabled"), YES);
    gGlobal  = DNGetBool(CFSTR("global"), YES);
    gExcludeSettings = DNGetBool(CFSTR("excludeSettings"), NO);
}

/// 当前进程是否需要 + 允许套用
static BOOL DNShouldApply(void) {
    if (!gEnabled) return NO;
    if (!objc_getClass("UISwitch")) return NO;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (!gGlobal) {
        return [bid isEqualToString:@"com.apple.Preferences"];
    }
    if (gExcludeSettings && [bid isEqualToString:@"com.apple.Preferences"]) return NO;
    return YES;
}

static DNToggleView *DNOverlay(UISwitch *sw) {
    return objc_getAssociatedObject(sw, &kDNOverlayKey);
}

// 用户操作回写 UISwitch 时，避免再次回灌 overlay 造成二次动画
static BOOL gInUserAction = NO;

static void DNAttach(UISwitch *sw) {
    if (!DNShouldApply()) return;
    CGRect b = sw.bounds;
    if (b.size.width < 10 || b.size.height < 6) return;

    DNToggleView *v = DNOverlay(sw);
    if (!v) {
        v = [[DNToggleView alloc] initWithFrame:b];
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
        if (@available(iOS 13.0, *)) {
            v.layer.cornerCurve = kCACornerCurveContinuous;
        }
        objc_setAssociatedObject(sw, &kDNOverlayKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sw addSubview:v];
        v.isAccessibilityElement = NO;
    }
    [sw bringSubviewToFront:v];
    if (!CGRectEqualToRect(v.frame, b)) v.frame = b;
    if (v.on != sw.isOn) [v setOn:sw.isOn animated:NO];
}

static void DNDetach(UISwitch *sw) {
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
    if (!DNShouldApply()) return;
    DNToggleView *v = DNOverlay(self);
    if (!v) {
        DNAttach(self);
        return;
    }
    if (!CGRectEqualToRect(v.frame, self.bounds)) v.frame = self.bounds;
    [self bringSubviewToFront:v];
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

static void DNRefreshAll(void) {
    for (UISwitch *sw in DNAllSwitches().allObjects) {
        if (DNShouldApply()) DNAttach(sw);
        else DNDetach(sw);
    }
}

static void DNPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef info) {
    DNLoadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{ DNRefreshAll(); });
}

__attribute__((constructor)) static void DNInit(void) {
    DNLoadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    DNPrefsChanged, (__bridge CFStringRef)kDNNotify, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    Class sw = objc_getClass("UISwitch");
    if (!sw) return;
    MSHookMessageEx(sw, @selector(didMoveToSuperview), (IMP)&DN_didMoveToSuperview, (IMP *)&orig_didMoveToSuperview);
    MSHookMessageEx(sw, @selector(layoutSubviews),      (IMP)&DN_layoutSubviews,      (IMP *)&orig_layoutSubviews);
    MSHookMessageEx(sw, @selector(setOn:animated:),     (IMP)&DN_setOnAnimated,       (IMP *)&orig_setOnAnimated);
    MSHookMessageEx(sw, @selector(setOn:),              (IMP)&DN_setOn,               (IMP *)&orig_setOn);
}