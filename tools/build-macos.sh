#!/bin/bash
# DayNightSwitch —— macOS runner 构建（Xcode clang + Xcode ld64 → 真 arm64e）
# Linux 工具链的 ld64 只能写出 sub=0x2，不满足 ptrauth ABI，系统进程加载不了，故改用 macOS。
set -e
ROOT=$(pwd)
OUT="$ROOT/out"
V=$(awk '/^Version:/{print $2}' control)
DIST="$ROOT/dist"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$OUT" "$DIST"

echo "===== 0. 环境 ====="
xcodebuild -version | head -2
echo "SDK: $SDK"

echo "===== 0.5 生成 substrate 桩 dylib（只为产生 LC_LOAD_DYLIB）====="
cat > /tmp/substub.c <<'C'
typedef void (*IMP)(void);
void MSHookMessageEx(void *cls, void *sel, IMP imp, IMP *result) {}
void MSHookFunction(void *sym, void *hook, void **old) {}
C
xcrun --sdk iphoneos clang -target arm64e-apple-ios15.0 -dynamiclib \
  -install_name @loader_path/.jbroot/usr/lib/libsubstrate.dylib \
  -o /tmp/libsubstrate_stub.dylib /tmp/substub.c
ls -l /tmp/libsubstrate_stub.dylib

echo "===== 1. 编译 dylib（arm64e + arm64）====="
SRCS="src/Tweak.m src/DNToggleView.m src/DNLiquidSwitchHost.m \
src/liquidview/Runtime/LGLiquidGlassRuntime.m \
src/liquidview/Shared/LGSharedSupport.m \
src/liquidview/Shared/LGBackButtonSupport.m \
src/liquidview/Shared/LGMetalShaderSource.m \
src/liquidview/Shared/LGGlassRenderer.m \
src/liquidview/Shared/LGBannerCaptureSupport.m \
src/liquidview/Shared/LGHookSupport.m \
src/liquidview/Runtime/LGSnapshotCaptureSupport.m"
for ARCH in arm64e arm64; do
  xcrun --sdk iphoneos clang -fobjc-arc -O2 -isysroot "$SDK" \
    -target ${ARCH}-apple-ios15.0 -dynamiclib -Isrc -Isrc/liquidview -Isrc/liquidview/Shared \
    -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
    -framework Metal -framework MetalKit -framework CoreLocation -framework CoreVideo -framework CoreMedia \
    -Wl,-undefined,dynamic_lookup \
    -Wl,-install_name,@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/Switch.dylib \
    -o "$OUT/Switch-$ARCH.dylib" $SRCS /tmp/libsubstrate_stub.dylib
done
xcrun lipo -create -output "$OUT/Switch.dylib" \
  "$OUT/Switch-arm64e.dylib" "$OUT/Switch-arm64.dylib"
xcrun codesign --force --sign - "$OUT/Switch.dylib"
xcrun lipo -info "$OUT/Switch.dylib"

echo "===== 2. 编译设置 bundle 可执行文件 ====="
for ARCH in arm64e arm64; do
  xcrun --sdk iphoneos clang -fobjc-arc -O2 -isysroot "$SDK" \
    -target ${ARCH}-apple-ios15.0 -bundle \
    -framework Foundation -framework UIKit \
    -Wl,-undefined,dynamic_lookup \
    -o "$OUT/SwitchPrefs-$ARCH" prefs/DNRootListController.m
done
xcrun lipo -create -output "$OUT/SwitchPrefs" \
  "$OUT/SwitchPrefs-arm64e" "$OUT/SwitchPrefs-arm64"
xcrun codesign --force --sign - "$OUT/SwitchPrefs"
xcrun lipo -info "$OUT/SwitchPrefs"

echo "===== 3. 架构校验（arm64e slice 必须 sub=0x80000002）====="
python3 - <<'PY'
import struct, sys, os
bad = []
for p in ('out/Switch.dylib', 'out/SwitchPrefs'):
    d = open(p, 'rb').read()
    magic = struct.unpack('>I', d[:4])[0]
    print(f"{os.path.basename(p):24s} {len(d):8d} bytes magic={hex(magic)}")
    slices = []
    if magic in (0xcafebabe, 0xcafebabf):
        n = struct.unpack('>I', d[4:8])[0]; off = 8
        for _ in range(n):
            cpu, sub, fo, fs, al = struct.unpack('>iiIII', d[off:off+20]); off += 20
            slices.append((cpu & 0xffffffff, sub & 0xffffffff))
            print(f"    slice cpu={hex(cpu & 0xffffffff)} sub={hex(sub & 0xffffffff)} size={fs}")
    else:
        cpu, sub = struct.unpack('<ii', d[4:12])
        slices.append((cpu & 0xffffffff, sub & 0xffffffff))
        print(f"    cpu={hex(cpu & 0xffffffff)} sub={hex(sub & 0xffffffff)}")
    arm64e = [sub for cpu, sub in slices if cpu == 0x0100000c]
    if 0x80000002 in arm64e:
        print("    -> 真 arm64e OK")
    else:
        print("    !! 缺少真 arm64e（sub != 0x80000002）"); bad.append(p)
print("CHECK_FAILED" if bad else "CHECK_OK")
sys.exit(1 if bad else 0)
PY

echo "===== 4. 打包 ====="
STAGE=/tmp/dns-stage
rm -rf "$STAGE"
JB="$STAGE/var/jb"
mkdir -p "$STAGE/DEBIAN" "$JB/Library/MobileSubstrate/DynamicLibraries" \
         "$JB/Library/PreferenceBundles/SwitchPrefs.bundle" \
         "$JB/Library/PreferenceLoader/Preferences"
cp "$OUT/Switch.dylib" src/Switch.plist "$JB/Library/MobileSubstrate/DynamicLibraries/"
cp "$OUT/SwitchPrefs" "$JB/Library/PreferenceBundles/SwitchPrefs.bundle/"
cp prefs/Resources/Info.plist prefs/Resources/Root.plist "$JB/Library/PreferenceBundles/SwitchPrefs.bundle/"
cp prefs/Resources/icons/*.png "$JB/Library/PreferenceBundles/SwitchPrefs.bundle/"
cp prefs/Resources/icon.png prefs/Resources/icon@2x.png prefs/Resources/icon@3x.png \
   "$JB/Library/PreferenceBundles/SwitchPrefs.bundle/" 2>/dev/null || true
mkdir -p "$STAGE/usr/share/icons"
cp assets/pkgicon.png "$STAGE/usr/share/icons/com.ning.switch.png"
cp prefs/Resources/entry.plist "$JB/Library/PreferenceLoader/Preferences/Switch.plist"
cp control "$STAGE/DEBIAN/control"
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
# 只重启「设置」让入口立即出现，不做 respring
killall -9 Preferences 2>/dev/null || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"
find "$STAGE/var" -type d -exec chmod 755 {} \;
find "$STAGE/var" -type f -exec chmod 644 {} \;
chmod 755 "$JB/Library/MobileSubstrate/DynamicLibraries/Switch.dylib"
chmod 755 "$JB/Library/PreferenceBundles/SwitchPrefs.bundle/SwitchPrefs"

DEB="$DIST/com.ning.switch_${V}_iphoneos-arm64e.deb"
rm -f "$DEB"
python3 tools/mkdeb.py "$STAGE" "$DEB"
echo "== 产物 =="
ls -l "$DEB"
shasum -a 256 "$DEB" || sha256sum "$DEB"
echo "-- 包内文件 --"
python3 - <<'PY'
import tarfile, glob
p = glob.glob('dist/*.deb')[0]
data = open(p,'rb').read()
# 直接用 dpkg 不可用，改用 python 解析 ar
import struct
off = 8
while off + 60 <= len(data):
    hdr = data[off:off+60]; name = hdr[:16].decode().strip().rstrip('/')
    size = int(hdr[48:58].decode().strip())
    body = data[off+60:off+60+size]
    off += 60 + size + (size % 2)
    if name.startswith('data.tar'):
        open('/tmp/_data.tar.gz','wb').write(body)
import tarfile, io, gzip
with tarfile.open('/tmp/_data.tar.gz') as t:
    for m in t.getmembers()[:12]:
        print('  ', m.name, m.size)
PY
