//
//  DNRootListController.m — 设置入口（PreferenceLoader bundle）
//  写法照抄本设备已验证可用的 SBXDesktop（Feature）实现：
//    - 用 PSListController 的真 ivar _specifiers
//    - plist 名字经方法给出，再调 loadSpecifiersFromPlistName:target:
//    - 全程写日志，用于定位「页面空白」
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <notify.h>

// —— Preferences 私有框架声明（含真 ivar）——
@class PSSpecifier;

@interface PSListController : UIViewController
{
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
- (id)readPreferenceValue:(PSSpecifier *)spec;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec;
@end

@interface PSSpecifier : NSObject
- (id)propertyForKey:(id)key;
- (void)setProperty:(id)value forKey:(id)key;
@end

static NSString *const kDNBundleID = @"com.ning.daynightswitch";
static const char *const kDNNotify = "com.ning.daynightswitch/settingschanged";

static void DNLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [msg stringByAppendingString:@"\n"];
    FILE *f = fopen("/var/mobile/Library/daynightswitch-prefs.log", "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

@interface DNRootListController : PSListController
@end

@implementation DNRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSBundle *b = [NSBundle bundleForClass:[self class]];
        NSString *path = [[b bundlePath] stringByAppendingPathComponent:@"Root.plist"];
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        DNLog(@"[主页] bundle=%@ Root存在=%@ count=%lu",
              [b bundlePath],
              [[NSFileManager defaultManager] fileExistsAtPath:path] ? @"YES" : @"NO",
              (unsigned long)[_specifiers count]);
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (key) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kDNBundleID);
        if (v) return (__bridge_transfer id)v;
    }
    return [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (key) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)kDNBundleID);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDNBundleID);
        notify_post(kDNNotify);
    }
    if ([[super class] instancesRespondToSelector:_cmd]) {
        [super setPreferenceValue:value specifier:spec];
    }
}

@end

// bundle 被加载的证据
__attribute__((constructor)) static void DNPrefsBundleLoaded(void) {
    DNLog(@"[加载] DayNightSwitchPrefs.bundle 已加载, DNRootListController=%@",
          NSClassFromString(@"DNRootListController") ? @"有" : @"无");
}