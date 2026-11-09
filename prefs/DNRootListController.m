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

static NSString *const kDNBundleID = @"com.ning.switch";
static const char *const kDNNotify = "com.ning.switch/settingschanged";

static void DNLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = [[NSProcessInfo processInfo] processName] ?: @"unknown";
        path = [NSString stringWithFormat:@"/var/mobile/Library/switch-prefs-%@.log", name];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    });
    NSString *line = [msg stringByAppendingString:@"\n"];
    FILE *f = fopen(path.UTF8String, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

static NSString *DNPrefsFileName(void) { return @"com.ning.switch.plist"; }

static NSString *DNPrefsRealPath(void) {
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:DNPrefsFileName()];
}

/// 由设置 bundle 自身路径推导 jbroot 前缀
static NSString *DNPrefsJbRootPath(void) {
    NSString *bp = [[NSBundle bundleForClass:NSClassFromString(@"DNRootListController")] bundlePath] ?: @"";
    NSRange r = [bp rangeOfString:@"/Library/"];
    if (r.location == NSNotFound) return nil;
    NSString *jb = [bp substringToIndex:r.location];
    return [[jb stringByAppendingPathComponent:@"var/mobile/Library/Preferences"]
            stringByAppendingPathComponent:DNPrefsFileName()];
}

static NSDate *DNFileMTime2(NSString *path) {
    if (!path) return nil;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return a[NSFileModificationDate];
}

static NSDictionary *DNMergedPrefs2(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:DNPrefsRealPath()];
    return d ?: @{};
}

static void DNStorePref(NSString *key, id value) {
    // 两份都写：真实路径 + jbroot 路径（不同进程看到的是不同文件，必须同步）
    NSMutableDictionary *d = [DNMergedPrefs2() mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kDNBundleID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDNBundleID);
    BOOL okR = [d writeToFile:DNPrefsRealPath() atomically:YES];
    NSString *jb = DNPrefsJbRootPath();
    BOOL okJ = jb ? [d writeToFile:jb atomically:YES] : NO;
    BOOL exR = [[NSFileManager defaultManager] fileExistsAtPath:DNPrefsRealPath()];
    BOOL exJ = jb ? [[NSFileManager defaultManager] fileExistsAtPath:jb] : NO;
    DNLog(@"[写] %@=%@ okReal=%d(存在%d) okJb=%d(存在%d) jb=%@",
          key, value, okR, exR, okJ, exJ, jb ?: @"-");
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
        id v = DNMergedPrefs2()[key];
        if (v) return v;
    }
    return [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (key) {
        DNStorePref(key, value);
        notify_post(kDNNotify);
    }
    if ([[super class] instancesRespondToSelector:_cmd]) {
        [super setPreferenceValue:value specifier:spec];
    }
}

@end

// bundle 被加载的证据
__attribute__((constructor)) static void DNPrefsBundleLoaded(void) {
    DNLog(@"[加载] SwitchPrefs.bundle 已加载, DNRootListController=%@",
          NSClassFromString(@"DNRootListController") ? @"有" : @"无");
}