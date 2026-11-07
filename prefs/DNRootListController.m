//
//  DNRootListController.m — 设置入口（PreferenceLoader bundle）
//  不依赖私有头文件，手动声明用到的 PSListController / PSSpecifier 接口
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <notify.h>

// —— Preferences 私有框架的最小声明 ——
@interface PSSpecifier : NSObject
- (id)propertyForKey:(id)key;
- (void)setProperty:(id)value forKey:(id)key;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (id)readPreferenceValue:(PSSpecifier *)spec;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec;
- (void)reloadSpecifiers;
@end

static NSString *const kDNBundleID = @"com.ning.daynightswitch";
static const char *const kDNNotify = "com.ning.daynightswitch/settingschanged";

@interface DNRootListController : PSListController
@end

@implementation DNRootListController {
    NSArray *_dnSpecifiers;
}

- (NSArray *)specifiers {
    if (!_dnSpecifiers) {
        _dnSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _dnSpecifiers;
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
    [super setPreferenceValue:value specifier:spec];
}

@end