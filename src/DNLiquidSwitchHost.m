//
//  DNLiquidSwitchHost.m — 液态开关宿主（航同款 LiquidGlassView，独立实例）
//
//  绝不 object_setClass（会踩堆崩溃）。做法：
//  · 引擎视图作为「开关的兄弟视图」挂在父视图上
//  · 原生开关 alpha=0 隐藏
//  · 透明触摸层盖在最上，点击 → 写回原开关 + 发事件
//  · 背景用父视图快照喂给引擎（限流 0.4s）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LiquidGlass.h"
#import "DNLiquidSwitchHost.h"

@class DNLiquidTapBox;
@interface DNLiquidTapBox : NSObject
+ (instancetype)shared;
- (void)tapFired:(UIControl *)sender;
@end

static char kDNLiquidHostKey;
static char kDNLiquidTapKey;
static char kDNLiquidAlphaKey;
static char kDNLiquidStampKey;

@implementation DNLiquidSwitchHost

+ (CGSize)designSize { return CGSizeMake(63, 28); }

+ (CGRect)frameForSwitch:(UISwitch *)sw {
    CGSize d = [self designSize];
    CGRect r = sw.frame;
    return CGRectMake(CGRectGetMidX(r) - d.width / 2,
                      CGRectGetMidY(r) - d.height / 2,
                      d.width, d.height);
}

+ (void)applyToSwitch:(UISwitch *)sw {
    if (!sw.superview) return;
    UIView *host = sw.superview;
    CGRect f = [self frameForSwitch:sw];

    LiquidGlassView *glass = objc_getAssociatedObject(sw, &kDNLiquidHostKey);
    if (!glass) {
        UIImage *bg = [self snapshotBehind:sw rect:f];
        glass = [[LiquidGlassView alloc] initWithFrame:f wallpaper:bg wallpaperOrigin:CGPointZero];
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        glass.cornerRadius = f.size.height / 2;
        glass.bezelWidth = f.size.height * 0.16;
        glass.glassThickness = f.size.height * 1.6;
        glass.refractionScale = 1.2;
        glass.refractiveIndex = 1.0;
        glass.specularOpacity = 0.8;
        glass.blur = 6;
        objc_setAssociatedObject(sw, &kDNLiquidHostKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIControl *tap = [[UIControl alloc] initWithFrame:f];
        tap.backgroundColor = [UIColor clearColor];
        [tap addTarget:[DNLiquidTapBox shared]
                action:@selector(tapFired:)
      forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(sw, &kDNLiquidTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        objc_setAssociatedObject(sw, &kDNLiquidAlphaKey, @(sw.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sw.alpha = 0.0;

        [host addSubview:glass];
        [host addSubview:tap];
    }

    glass.frame = f;
    glass.cornerRadius = f.size.height / 2;
    UIControl *tap = objc_getAssociatedObject(sw, &kDNLiquidTapKey);
    tap.frame = f;
    [host bringSubviewToFront:glass];
    [host bringSubviewToFront:tap];

    NSDate *stamp = objc_getAssociatedObject(sw, &kDNLiquidStampKey);
    if (!stamp || -[stamp timeIntervalSinceNow] > 0.4) {
        objc_setAssociatedObject(sw, &kDNLiquidStampKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIImage *bg = [self snapshotBehind:sw rect:f];
        if (bg) glass.wallpaperImage = bg;
    }
}

+ (void)removeFromSwitch:(UISwitch *)sw {
    LiquidGlassView *glass = objc_getAssociatedObject(sw, &kDNLiquidHostKey);
    UIControl *tap = objc_getAssociatedObject(sw, &kDNLiquidTapKey);
    if (glass) {
        [glass removeFromSuperview];
        objc_setAssociatedObject(sw, &kDNLiquidHostKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (tap) {
        [tap removeFromSuperview];
        objc_setAssociatedObject(sw, &kDNLiquidTapKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *a = objc_getAssociatedObject(sw, &kDNLiquidAlphaKey);
    if (a) {
        sw.alpha = a.doubleValue;
        objc_setAssociatedObject(sw, &kDNLiquidAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(sw, &kDNLiquidStampKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)isAttached:(UISwitch *)sw {
    return objc_getAssociatedObject(sw, &kDNLiquidHostKey) != nil;
}

/// 采样开关背后的背景（临时隐藏我们自己的层与原生开关）
+ (UIImage *)snapshotBehind:(UISwitch *)sw rect:(CGRect)rect {
    UIView *host = sw.superview;
    if (!host) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat oldA = sw.alpha;
    LiquidGlassView *glass = objc_getAssociatedObject(sw, &kDNLiquidHostKey);
    UIControl *tap = objc_getAssociatedObject(sw, &kDNLiquidTapKey);
    sw.alpha = 0; glass.hidden = YES; tap.hidden = YES;

    UIGraphicsBeginImageContextWithOptions(rect.size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, -rect.origin.x, -rect.origin.y);
    [host.layer renderInContext:ctx];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    sw.alpha = oldA; glass.hidden = NO; tap.hidden = NO;
    return img;
}

@end

#pragma mark - 触摸层

@implementation DNLiquidTapBox

+ (instancetype)shared {
    static DNLiquidTapBox *box;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ box = [DNLiquidTapBox new]; });
    return box;
}

- (void)tapFired:(UIControl *)sender {
    UIView *parent = sender.superview;
    UISwitch *sw = nil;
    for (UIView *v in parent.subviews) {
        if ([v isKindOfClass:[UISwitch class]]) {
            UIControl *t = objc_getAssociatedObject(v, &kDNLiquidTapKey);
            if (t == sender) { sw = (UISwitch *)v; break; }
        }
    }
    if (!sw) return;
    [sw setOn:!sw.isOn animated:YES];
    [sw sendActionsForControlEvents:UIControlEventValueChanged];
    [DNLiquidSwitchHost applyToSwitch:sw];
}

@end