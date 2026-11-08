//
//  DNToggleView.m
//  DayNightSwitch for iOS —— 纯代码绘制（不依赖任何图片素材）
//
//  几何全部按高度等比，与原作者实现一致：
//    宽 = 高 × 1.75（实用中直接铺满 UISwitch 的 51×31）
//    圆角 = 高/2，可见描边 = 高/14，滑块 = 高 − 2×(高/10)，滑块内圆边距 = 滑块/12
//    关闭态 7 颗星，直径 = 高×0.05×(0.6~1.4)
//    开启态云：宽 = 宽/3、高 = 宽×0.23，位于 (宽/3, 高×0.40)，绘制在滑块之上
//

#import "DNToggleView.h"

// —— 配色（取自原作者 DayNightSwitch.m 宏定义）——
#define kOffColor      [UIColor colorWithRed:0.235 green:0.255 blue:0.271 alpha:1]  // #3C4145
#define kOffBorder     [UIColor colorWithRed:0.110 green:0.110 blue:0.110 alpha:1]  // #1C1C1C
#define kOffKnob       [UIColor colorWithRed:0.894 green:0.902 blue:0.788 alpha:1]  // #E4E6C9 月亮
#define kOffInner      [UIColor whiteColor]
#define kOnColor       [UIColor colorWithRed:0.627 green:0.894 blue:0.980 alpha:1]  // #A0E4FA
#define kOnBorder      [UIColor colorWithRed:0.533 green:0.769 blue:0.843 alpha:1]  // #88C4D7
#define kOnKnob        [UIColor colorWithRed:0.882 green:0.765 blue:0.325 alpha:1]  // #E1C353 太阳
#define kOnInner       [UIColor colorWithRed:0.992 green:0.875 blue:0.459 alpha:1]  // #FDE075
#define kCloudFill     [UIColor whiteColor]
#define kCloudStroke   [UIColor colorWithRed:0.827 green:0.827 blue:0.827 alpha:1]  // #D3D3D3

static CGFloat DNScale(CGFloat v) { return v; }

#pragma mark - 云朵

/// 扁平云：白填充 + 浅灰描边（两层 shape 叠加，避免路径内部出现描边线）
@interface DNCloudView : UIView
@end

@implementation DNCloudView {
    CAShapeLayer *_outline;
    CAShapeLayer *_fill;
}

+ (Class)layerClass { return [CAShapeLayer class]; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        _outline = [CAShapeLayer layer];
        _outline.fillColor = kCloudStroke.CGColor;
        _outline.strokeColor = [UIColor clearColor].CGColor;
        [self.layer addSublayer:_outline];

        _fill = [CAShapeLayer layer];
        _fill.fillColor = kCloudFill.CGColor;
        _fill.strokeColor = [UIColor clearColor].CGColor;
        [self.layer addSublayer:_fill];
    }
    return self;
}

/// 构造云的并集路径；expand 为描边外扩量
- (CGPathRef)cloudPathExpandedBy:(CGFloat)expand {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat bx = w * 0.06 - expand, by = h * 0.48 - expand;
    CGFloat bw = w * 0.88 + expand * 2, bh = h * 0.44 + expand * 2;
    [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(bx, by, bw, bh)
                                             cornerRadius:bh / 2]];
    CGFloat bumps[3][3] = {
        { w * 0.30, h * 0.42, w * 0.19 },
        { w * 0.52, h * 0.28, w * 0.25 },
        { w * 0.74, h * 0.43, w * 0.17 },
    };
    for (int i = 0; i < 3; i++) {
        CGFloat cx = bumps[i][0], cy = bumps[i][1], r = bumps[i][2] + expand;
        [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - r, cy - r, r * 2, r * 2)]];
    }
    return p.CGPath;
}

- (void)layoutSubviews {
    // 兜底：尺寸异常（被父视图放大/整屏）时整块隐藏，绝不整屏渲染
    if (self.bounds.size.width > 200 || self.bounds.size.height > 200) { self.hidden = YES; return; }
    self.hidden = NO;
    [super layoutSubviews];
    CGFloat lw = MAX(0.5, self.bounds.size.width * 0.045);
    _outline.frame  = self.bounds;
    _fill.frame     = self.bounds;
    _outline.path   = [self cloudPathExpandedBy:lw];
    _fill.path      = [self cloudPathExpandedBy:0];
}

@end

#pragma mark - 开关本体

@implementation DNToggleView {
    UIView *_bg;
    UIView *_border;
    UIView *_stars;        // 用 CAShapeLayer 画 7 颗星
    UIView *_knob;
    UIView *_knobInner;
    CAShapeLayer *_craters;
    DNCloudView *_cloud;

    BOOL _dragging;
    BOOL _moved;
}

#pragma mark 初始化

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = NO;

        _bg = [[UIView alloc] initWithFrame:self.bounds];
        _bg.userInteractionEnabled = NO;
        [self addSubview:_bg];

        _border = [[UIView alloc] initWithFrame:self.bounds];
        _border.userInteractionEnabled = NO;
        _border.backgroundColor = [UIColor clearColor];
        [self addSubview:_border];

        _stars = [[UIView alloc] initWithFrame:self.bounds];
        _stars.userInteractionEnabled = NO;
        _stars.layer.mask = [CAShapeLayer layer];   // 用 mask 画星星形状（白色填充）
        _stars.backgroundColor = [UIColor whiteColor];
        [self addSubview:_stars];

        _knob = [[UIView alloc] initWithFrame:CGRectZero];
        _knob.userInteractionEnabled = NO;
        [self addSubview:_knob];

        _knobInner = [[UIView alloc] initWithFrame:CGRectZero];
        _knobInner.userInteractionEnabled = NO;
        _knobInner.clipsToBounds = YES;
        [_knob addSubview:_knobInner];

        _craters = [CAShapeLayer layer];
        [_knobInner.layer addSublayer:_craters];

        self.isAccessibilityElement = NO;

        _cloud = [[DNCloudView alloc] initWithFrame:CGRectZero];
        _cloud.alpha = 0;
        [self addSubview:_cloud];

        _on = NO;
        [self applyStateAnimated:NO];
    }
    return self;
}

#pragma mark 几何

- (CGFloat)knobMargin  { return self.bounds.size.height / 10; }
- (CGFloat)knobSize    { return self.bounds.size.height - [self knobMargin] * 2; }
- (CGFloat)borderWidth { return self.bounds.size.height / 14; }

- (CGRect)knobFrameForOn:(BOOL)on expanded:(BOOL)expanded {
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    CGFloat m = [self knobMargin], s = [self knobSize];
    CGFloat kw = expanded ? s * 1.25 : s;
    CGFloat x = on ? (w - m - kw) : m;
    return CGRectMake(x, m, kw, h - m * 2);
}

- (CGPathRef)starPath {
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    CGFloat base = h * 0.05;
    CGFloat pts[7][3] = {
        { 0.50, 0.16, 1.0 }, { 0.62, 0.33, 0.6 }, { 0.70, 0.15, 1.0 }, { 0.83, 0.39, 1.4 },
        { 0.70, 0.54, 0.8 }, { 0.52, 0.73, 1.3 }, { 0.82, 0.66, 1.1 },
    };
    UIBezierPath *p = [UIBezierPath bezierPath];
    for (int i = 0; i < 7; i++) {
        CGFloat r = base * pts[i][2] / 2;
        CGFloat cx = w * pts[i][0], cy = h * pts[i][1];
        [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - r, cy - r, r * 2, r * 2)]];
    }
    return p.CGPath;
}

- (CGPathRef)craterPathInsideKnobSize:(CGFloat)ks {
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat items[3][3] = {
        { 0.10, 0.24, 0.28 }, { 0.50, 0.14, 0.30 }, { 0.36, 0.56, 0.26 },
    };
    for (int i = 0; i < 3; i++) {
        CGFloat r = ks * items[i][2] / 2;
        CGFloat cx = ks * items[i][0], cy = ks * items[i][1];
        [p appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - r, cy - r, r * 2, r * 2)]];
    }
    return p.CGPath;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    CGFloat bw = [self borderWidth];
    CGFloat m  = [self knobMargin];
    CGFloat ks = [self knobSize];
    CGFloat innerMargin = ks / 12;

    _bg.frame = self.bounds;
    _bg.layer.cornerRadius = h / 2;
    _bg.layer.cornerCurve = kCACornerCurveContinuous;

    _border.frame = CGRectInset(self.bounds, bw / 2, bw / 2);
    _border.layer.cornerRadius = (h - bw) / 2;
    _border.layer.cornerCurve = kCACornerCurveContinuous;
    _border.layer.borderWidth = bw;

    _stars.frame = self.bounds;
    CAShapeLayer *mask = (CAShapeLayer *)_stars.layer.mask;
    mask.frame = _stars.bounds;
    mask.path = [self starPath];

    _knob.frame = [self knobFrameForOn:_on expanded:_dragging];
    _knob.layer.cornerRadius = _knob.bounds.size.height / 2;
    _knob.layer.cornerCurve = kCACornerCurveContinuous;

    _knobInner.frame = CGRectInset(_knob.bounds, innerMargin, innerMargin);
    _knobInner.layer.cornerRadius = _knobInner.bounds.size.height / 2;
    _knobInner.layer.cornerCurve = kCACornerCurveContinuous;

    _craters.frame = _knobInner.bounds;
    _craters.path = [self craterPathInsideKnobSize:ks];
    _craters.lineWidth = MAX(0.5, innerMargin * 0.85);

    // 云：比原实现略靠左、略小，保证在 51×31 的真实尺寸下也露得出来
    CGFloat cw = w * 0.26, ch = w * 0.19;
    _cloud.frame = CGRectMake(w * 0.26, h * 0.36, cw, ch);
    [_cloud setNeedsLayout];
}

#pragma mark 状态

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    [self applyStateAnimated:animated];
}

- (void)applyStateAnimated:(BOOL)animated {
    __weak typeof(self) weakSelf = self;
    void (^anim)(void) = ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        BOOL on = s->_on;
        s->_bg.backgroundColor            = on ? kOnColor  : kOffColor;
        s->_border.layer.borderColor      = (on ? kOnBorder : kOffBorder).CGColor;
        s->_stars.alpha                   = on ? 0.0 : 1.0;
        s->_knob.backgroundColor          = on ? kOnKnob : kOffKnob;
        s->_knobInner.backgroundColor     = on ? kOnInner : kOffInner;
        s->_knob.frame                    = [s knobFrameForOn:on expanded:NO];
        s->_craters.fillColor             = (on ? kOnInner : kOffInner).CGColor;
        s->_craters.strokeColor           = (on ? kOnKnob : kOffKnob).CGColor;
        s->_craters.opacity               = on ? 0.0 : 1.0;
        s->_knobInner.transform           = CGAffineTransformMakeRotation(M_PI * (on ? 0.2 : -0.2));
        s->_cloud.alpha                   = on ? 1.0 : 0.0;
        s->_cloud.transform               = on ? CGAffineTransformIdentity
                                              : CGAffineTransformMakeScale(0.01, 0.01);
    };

    if (!animated) {
        [UIView performWithoutAnimation:anim];
        [self setNeedsLayout];
        [self layoutIfNeeded];
        return;
    }
    // 颜色 0.8s / 几何 0.4s（与原实现一致）
    __weak typeof(self) w2 = self;
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(self) s = w2;
        if (!s) return;
        BOOL on = s->_on;
        s->_knob.frame          = [s knobFrameForOn:on expanded:NO];
        s->_knobInner.transform = CGAffineTransformMakeRotation(M_PI * (on ? 0.2 : -0.2));
        s->_cloud.alpha         = on ? 1.0 : 0.0;
        s->_cloud.transform     = on ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.01, 0.01);
        s->_stars.alpha         = on ? 0.0 : 1.0;
    } completion:nil];

    [UIView animateWithDuration:0.8 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(self) s = w2;
        if (!s) return;
        BOOL on = s->_on;
        s->_bg.backgroundColor        = on ? kOnColor  : kOffColor;
        s->_border.layer.borderColor  = (on ? kOnBorder : kOffBorder).CGColor;
        s->_knob.backgroundColor      = on ? kOnKnob : kOffKnob;
        s->_knobInner.backgroundColor = on ? kOnInner : kOffInner;
        s->_craters.fillColor         = (on ? kOnInner : kOffInner).CGColor;
        s->_craters.strokeColor       = (on ? kOnKnob : kOffKnob).CGColor;
        s->_craters.opacity           = on ? 0.0 : 1.0;
    } completion:nil];
}

#pragma mark 触摸

/// 把触摸的 x 换算成滑块的目标中心
- (void)moveKnobToTouch:(UITouch *)touch {
    CGFloat w = self.bounds.size.width, m = [self knobMargin], ks = [self knobSize];
    CGFloat kw = _dragging ? ks * 1.25 : ks;
    CGFloat x = [touch locationInView:self].x - kw / 2;
    x = MAX(m, MIN(w - m - kw, x));
    CGRect f = _knob.frame;
    f.origin.x = x;
    _knob.frame = f;
}

/// 以当前滑块位置判断该切到哪一态
- (BOOL)targetStateForTouch:(UITouch *)touch {
    CGFloat w = self.bounds.size.width;
    return [touch locationInView:self].x > w / 2;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragging = YES;
    _moved = NO;
    [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self->_knob.frame = [self knobFrameForOn:self->_on expanded:YES];
        self->_knob.layer.cornerRadius = self->_knob.bounds.size.height / 2;
    } completion:nil];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _moved = YES;
    [self moveKnobToTouch:touches.anyObject];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    BOOL target = _moved ? [self targetStateForTouch:t] : !_on;
    BOOL changed = (target != _on);
    _dragging = NO;
    [self setOn:target animated:YES];
    if (changed && self.onChange) self.onChange(target);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragging = NO;
    [self setOn:_on animated:YES];
}

@end
