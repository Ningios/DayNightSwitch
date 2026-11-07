#!/usr/bin/env python3
"""预览：真实 UISwitch 尺寸 51×31 下的效果（另放大 6 倍供查看）"""
import os
from PIL import Image, ImageDraw

SS = 6
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'preview')
os.makedirs(OUT, exist_ok=True)

OFF, OFF_B = (60, 65, 69), (28, 28, 28)
ON, ON_B = (160, 228, 250), (136, 196, 215)
MOON, SUN, SUN_IN = (228, 230, 201), (225, 195, 83), (253, 224, 117)


def render(on, w_pt=51, h_pt=31, ss=SS):
    W, H = int(w_pt * ss), int(h_pt * ss)
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=H / 2, fill=(ON if on else OFF) + (255,))
    t = H / 14
    d.rounded_rectangle([t / 2, t / 2, W - 1 - t / 2, H - 1 - t / 2], radius=(H - t) / 2,
                        outline=(ON_B if on else OFF_B) + (255,), width=max(1, int(t)))
    # 星星（关态）
    if not on:
        base = H * 0.05
        for px, py, k in ((0.50, 0.16, 1.0), (0.62, 0.33, 0.6), (0.70, 0.15, 1.0), (0.83, 0.39, 1.4),
                          (0.70, 0.54, 0.8), (0.52, 0.73, 1.3), (0.82, 0.66, 1.1)):
            r = base * k / 2
            d.ellipse([W * px - r, H * py - r, W * px + r, H * py + r], fill=(255, 255, 255, 255))
    # 云（开态，画在滑块之下不遮挡的部分）
    if on:
        cw, ch = W * 0.26, W * 0.19
        cx, cy = W * 0.26, H * 0.36
        lw = max(1, cw * 0.05)
        base = (cx + cw * 0.06, cy + ch * 0.48, cx + cw * 0.94, cy + ch * 0.92)
        rad = (base[3] - base[1]) / 2
        bumps = [(cx + cw * 0.30, cy + ch * 0.42, cw * 0.19),
                 (cx + cw * 0.52, cy + ch * 0.28, cw * 0.25),
                 (cx + cw * 0.74, cy + ch * 0.43, cw * 0.17)]
        for extra, color in ((lw, (211, 211, 211)), (0, (255, 255, 255))):
            d.rounded_rectangle([base[0]-extra, base[1]-extra, base[2]+extra, base[3]+extra],
                                radius=rad + extra, fill=color + (255,))
            for bx, by, br in bumps:
                d.ellipse([bx-br-extra, by-br-extra, bx+br+extra, by+br+extra], fill=color + (255,))
    # 滑块
    m = H / 10
    ks = H - m * 2
    kx = (W - m - ks) if on else m
    d.ellipse([kx, m, kx + ks, m + ks], fill=(SUN if on else MOON) + (255,))
    inset = ks / 12
    d.ellipse([kx + inset, m + inset, kx + ks - inset, m + ks - inset],
              fill=((SUN_IN if on else (255, 255, 255))) + (255,))
    if not on:
        for cxp, cyp, r in ((0.10, 0.24, 0.28), (0.50, 0.14, 0.30), (0.36, 0.56, 0.26)):
            rr = ks * r
            px, py = kx + ks * cxp, m + ks * cyp
            d.ellipse([px, py, px + rr, py + rr], fill=(255, 255, 255, 255),
                      outline=MOON + (255,), width=max(1, int(ks * 0.02)))
    return im.resize((int(w_pt), int(h_pt)), Image.LANCZOS)


real_n, real_d = render(False), render(True)
big_n, big_d = render(False, ss=24), render(True, ss=24)
real_n.save(os.path.join(OUT, 'real_night_51x31.png'))
real_d.save(os.path.join(OUT, 'real_day_51x31.png'))
big_n.save(os.path.join(OUT, 'zoom6x_night.png'))
big_d.save(os.path.join(OUT, 'zoom6x_day.png'))

sheet = Image.new('RGB', (860, 420), (244, 245, 247))
sheet.paste(big_n, (40, 40), big_n)
sheet.paste(big_d, (330, 40), big_d)
# 真实尺寸（放大 4 倍显示，便于肉眼判断）
sheet.paste(real_n.resize((204, 124), Image.NEAREST), (40, 250))
sheet.paste(real_d.resize((204, 124), Image.NEAREST), (330, 250))
sheet.paste(real_n.resize((204, 124), Image.LANCZOS), (620, 40))
sheet.paste(real_d.resize((204, 124), Image.LANCZOS), (620, 250))
sheet.save(os.path.join(OUT, 'compare.png'))
print('-> preview/compare.png，以及 real_/zoom6x_ 单图')
