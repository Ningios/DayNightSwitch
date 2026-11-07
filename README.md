# DayNightSwitch（iOS 系统开关美化插件）

把系统里的 `UISwitch` 换成「日夜」样式的胶囊开关：**关 = 夜空 + 月亮（带陨石坑）**，**开 = 蓝天 + 太阳 + 白云**。
尺寸按系统原生开关（**51 × 31 pt**）铺满，不做放大。

- 设计：Dribbble — Ramakrishna（原设计）/ Tsuriel（动效）
- 实现参考：Finn Gaida《DayNightSwitch》(MIT) —— 含他本人的插件骨架 `Tweak/`
- 插件：Ning `com.ning.daynightswitch`

## 目录

```
src/DNToggleView.h/.m     自绘开关视图（纯代码绘制，不依赖任何图片素材）
src/Tweak.m               注入与 Hook（UISwitch）
src/DayNightSwitch.plist  注入过滤（空 = 所有进程）
prefs/DNRootListController.m  设置入口控制器
prefs/Resources/*.plist   Info.plist / Root.plist（设置项）/ entry.plist（PreferenceLoader）
tools/build-linux.sh      CI 构建脚本（Linux + sbingner arm64e 工具链 + theos SDK + ldid + dpkg-deb）
tools/preview_51.py       真实尺寸渲染预览（51×31）
preview/                  预览图
.github/workflows/build.yml   GitHub Actions（ubuntu-22.04）
```

## 实现要点

1. **不隐藏、不改私有结构**：把自绘视图叠加在 `UISwitch` 上（`frame = bounds`），它接管触摸，
   再把状态写回 `setOn:animated:` 并 `sendActionsForControlEvents:UIControlEventValueChanged`。
   系统行为（VoiceOver、触感、表格布局、target-action）全部保留。
2. Hook 四个方法：`-didMoveToSuperview`（挂载）、`-layoutSubviews`（跟随尺寸 / 重新挂载）、
   `-setOn:animated:` 和 `-setOn:`（外部改状态时同步视图）。
3. 用 `gInUserAction` 标志避免「用户点 → 写回 UISwitch → 又回灌视图」造成的二次动画。
4. 已挂载的开关用 `NSHashTable`（弱引用）记录，偏好变化时整体挂载 / 卸载。

## 几何（与原作者实现一致，全部按高度等比）

| 项 | 公式 | 51×31 时 |
|---|---|---|
| 圆角 | 高 / 2 | 15.5 |
| 可见描边 | 高 / 14 | 2.2 |
| 滑块直径 | 高 − 2 × (高/10) | 24.8 |
| 滑块内圆边距 | 滑块 / 12 | 2.07 |
| 星星 | 7 颗，直径 = 高 × 0.05 × (0.6 ~ 1.4) | — |
| 云 | 宽 × 0.26，位于 (宽 × 0.26, 高 × 0.36) | 13 × 9.7 |

> 云的位置比原实现（`w/3`）略靠左、略小 —— 原位置在 51×31 下会被太阳挡住看不见。

## 动画

- 颜色过渡 0.8s spring，几何变化 0.4s（与原实现一致）
- 太阳 / 月亮内圆旋转 ±0.2 rad
- 按压拖拽时滑块横向拉伸 1.25×，松开回弹
- 点按切换；拖动超过中线才切换
- 开启时云朵从 scale 0 弹出、星星淡出

## 设置项（设置 → DayNightSwitch）

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | 开 | 总开关 |
| `global` | 开 | 开＝所有 App；关＝只在「设置」里生效 |
| `excludeSettings` | 关 | 「设置」App 内保留系统原样式 |

写入域 `com.ning.daynightswitch`，改完 `notify_post("com.ning.daynightswitch/settingschanged")`，插件即时响应，不需要 respring。

## 安装包内容

```
/var/jb/Library/MobileSubstrate/DynamicLibraries/DayNightSwitch.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/DayNightSwitch.plist
/var/jb/Library/PreferenceBundles/DayNightSwitchPrefs.bundle/{DayNightSwitchPrefs, Info.plist, Root.plist}
/var/jb/Library/PreferenceLoader/Preferences/DayNightSwitch.plist
```

`postinst` 只重启「设置」App（`killall -9 Preferences`），**不 respring、不重启 SpringBoard**。

## 构建

```bash
bash tools/build-linux.sh     # 产出 dist/com.ning.daynightswitch_1.0.0_iphoneos-arm64e.deb
```

暂存 `out/`（arm64 + arm64e 的 dylib 与 prefs bundle），工具链/SDK 缓存到 `$HOME/theos`。

## 待办

- [ ] 首次构建与真机验证（roothide 17.2.1）
- [ ] 插件图标（Sileo 包图标 + 设置入口图标，按惯例先出 3~5 个方案预览）
- [ ] 若要上架自建源：补 depiction / sileo-featured / Packages 索引

## 许可

- 原始实现 Finn Gaida，MIT；设计来自 Dribbble，商业用途请先联系原作者。
- 本插件部分：Ning。
