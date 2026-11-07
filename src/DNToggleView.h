//
//  DNToggleView.h
//  DayNightSwitch for iOS (系统开关美化)
//
//  设计：Dribbble - Ramakrishna（原设计）/ Tsuriel（动效）
//  实现参考：Finn Gaida - DayNightSwitch (MIT)
//  本插件：Ning
//

#import <UIKit/UIKit.h>

@interface DNToggleView : UIView

/// 当前状态（不触发 onChange）
@property (nonatomic, assign, readonly) BOOL on;

/// 用户操作导致状态变化时回调（程序设置不会触发）
@property (nonatomic, copy) void (^onChange)(BOOL on);

/// 设置状态；animated 决定是否播放动画
- (void)setOn:(BOOL)on animated:(BOOL)animated;

@end
