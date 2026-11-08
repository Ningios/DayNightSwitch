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
    NSString *line = [msg stringByAppendingString:@"\n"];
    FILE *f = fopen("/var/mobile/Library/daynightswitch-prefs.log", "a");
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
    NSString *real = DNPrefsRealPath();
    NSString *jb   = DNPrefsJbRootPath();
    NSDictionary *dR = [NSDictionary dictionaryWithContentsOfFile:real];
    NSDictionary *dJ = jb ? [NSDictionary dictionaryWithContentsOfFile:jb] : nil;
    NSDate *mR = DNFileMTime2(real), *mJ = DNFileMTime2(jb);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (dJ && dR) {
        BOOL realNewer = (!mJ || (mR && [mR compare:mJ] != NSOrderedAscending));
        NSDictionary *base = realNewer ? dJ : dR;
        NSDictionary *top  = realNewer ? dR : dJ;
        [out addEntriesFromDictionary:base];
        [out addEntriesFromDictionary:top];
    } else if (dR) [out addEntriesFromDictionary:dR];
    else if (dJ) [out addEntriesFromDictionary:dJ];
    return out;
}

/// 双写：cfprefsd + 真实路径 + jbroot 路径，保证两边一致
static void DNStorePref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kDNBundleID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDNBundleID);

    NSMutableDictionary *d = [DNMergedPrefs2() mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:DNPrefsRealPath() atomically:YES];
    NSString *jb = DNPrefsJbRootPath();
    if (jb) [d writeToFile:jb atomically:YES];
    DNLog(@"[写] %@=%@ real=%@ jb=%@", key, value, DNPrefsRealPath(), jb ?: @"-");
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
        CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                          (__bridge CFStringRef)kDNBundleID);
        if (cv) return (__bridge_transfer id)cv;
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