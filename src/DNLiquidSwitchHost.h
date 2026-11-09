//
//  DNLiquidSwitchHost.h — 液态开关宿主
//
#import <UIKit/UIKit.h>

@interface DNLiquidSwitchHost : NSObject
+ (void)applyToSwitch:(UISwitch *)sw;
+ (void)removeFromSwitch:(UISwitch *)sw;
+ (BOOL)isAttached:(UISwitch *)sw;
@end
