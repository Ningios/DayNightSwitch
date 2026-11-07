#!/bin/bash
# DayNightSwitch —— Linux(ubuntu) 上用 sbingner arm64e 工具链编译，产出可安装 deb
# 参考 ThemeBoard 的已验证流程（clang 用系统 clang>=13，链接用工具链里的 ld64）
set -e
ROOT=$(pwd)
THEOS=${THEOS:-$HOME/theos}
OUT="$ROOT/out"
V=$(awk '/^Version:/{print $2}' control)
DIST="$ROOT/dist"

echo "===== 1. 工具链 ====="
mkdir -p "$THEOS/toolchain/linux" "$THEOS/sdks" "$OUT"
if [ ! -f "$THEOS/toolchain/linux/.ok" ]; then
  URL=https://github.com/sbingner/llvm-project/releases/download/v10.0.0-2/linux-ios-arm64e-clang-toolchain.tar.lzma
  curl -L -m 900 -o /tmp/tc.tar.lzma "$URL"
  cd "$THEOS/toolchain/linux"
  if ! tar -xJf /tmp/tc.tar.lzma 2>/tmp/tar.err; then
    xz -dc /tmp/tc.tar.lzma | tar -x 2>/tmp/tar2.err || cat /tmp/tar2.err | head -5
  fi
  cd "$ROOT"
  touch "$THEOS/toolchain/linux/.ok"
fi

TCBIN=$(find "$THEOS/toolchain" -maxdepth 4 -name 'bin' -type d 2>/dev/null | head -1)
LD_FOUND=""
for c in "$TCBIN/ld64" "$TCBIN/ld64.lld" "$TCBIN/ld"; do
  [ -x "$c" ] && LD_FOUND="$c" && break
done

SYS_CLANG=""
for c in /usr/lib/llvm-16/bin/clang /usr/lib/llvm-15/bin/clang /usr/lib/llvm-14/bin/clang /usr/bin/clang; do
  [ -x "$c" ] || continue
  maj=$("$c" --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9]+).*/\1/')
  if [ -n "$maj" ] && [ "$maj" -ge 13 ]; then SYS_CLANG="$c"; break; fi
done
[ -z "$SYS_CLANG" ] && SYS_CLANG=$(command -v clang)
echo "clang: $SYS_CLANG"
echo "ld64 : $LD_FOUND"

echo "===== 2. SDK ====="
if ! ls -d "$THEOS/sdks/"*.sdk >/dev/null 2>&1; then
  curl -L -m 900 -o /tmp/sdk.tar.gz "https://github.com/theos/sdks/archive/refs/heads/master.tar.gz"
  tar -xzf /tmp/sdk.tar.gz -C "$THEOS/sdks" --strip-components=1
fi
SDK=$(ls -d "$THEOS/sdks/iPhoneOS16.5.sdk" 2>/dev/null || ls -d "$THEOS/sdks/"*.sdk | head -1)
echo "SDK: $SDK"

echo "===== 3. ldid ====="
if ! command -v ldid >/dev/null 2>&1; then
  curl -L -m 300 -o /tmp/ldid "https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_x86_64"
  chmod +x /tmp/ldid; mkdir -p "$HOME/.local/bin"; cp /tmp/ldid "$HOME/.local/bin/ldid"
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "===== 4. 编译 dylib（arm64 + arm64e）====="
mkdir -p "$OUT"
for ARCH in arm64e arm64; do
  OBJ="$OUT/obj-$ARCH"; mkdir -p "$OBJ"
  for f in src/Tweak.m src/DNToggleView.m; do
    "$SYS_CLANG" -c -fobjc-arc -O2 -isysroot "$SDK" -target ${ARCH}-apple-ios15.0 \
      -Isrc -Wno-deprecated-declarations -Wno-unused-variable \
      -o "$OBJ/$(basename "$f" .m).o" "$f"
  done
  "$LD_FOUND" -dylib -arch $ARCH -platform_version ios 15.0 16.5 \
    -syslibroot "$SDK" -undefined dynamic_lookup -framework Foundation -framework UIKit \
    -framework QuartzCore -framework CoreGraphics \
    -o "$OUT/DayNightSwitch-$ARCH.dylib" "$OBJ"/*.o
done
lipo -create -output "$OUT/DayNightSwitch.dylib" "$OUT/DayNightSwitch-arm64e.dylib" "$OUT/DayNightSwitch-arm64.dylib" 2>/dev/null \
  || cp "$OUT/DayNightSwitch-arm64e.dylib" "$OUT/DayNightSwitch.dylib"
ldid -S "$OUT/DayNightSwitch.dylib" 2>/dev/null || echo "签名跳过"

echo "===== 5. 编译设置 bundle 可执行文件 ====="
for ARCH in arm64e arm64; do
  "$SYS_CLANG" -fobjc-arc -O2 -isysroot "$SDK" -target ${ARCH}-apple-ios15.0 -bundle \
    -framework Foundation -framework UIKit -Wl,-undefined,dynamic_lookup \
    -o "$OUT/DayNightSwitchPrefs-$ARCH" prefs/DNRootListController.m
done
lipo -create -output "$OUT/DayNightSwitchPrefs" "$OUT/DayNightSwitchPrefs-arm64e" "$OUT/DayNightSwitchPrefs-arm64" 2>/dev/null \
  || cp "$OUT/DayNightSwitchPrefs-arm64e" "$OUT/DayNightSwitchPrefs"
ldid -S "$OUT/DayNightSwitchPrefs" 2>/dev/null || echo "签名跳过"

echo "===== 6. 打包 deb ====="
STAGE=/tmp/dns-stage
rm -rf "$STAGE"
JB="$STAGE/var/jb"
mkdir -p "$STAGE/DEBIAN" "$JB/Library/MobileSubstrate/DynamicLibraries" \
         "$JB/Library/PreferenceBundles/DayNightSwitchPrefs.bundle" \
         "$JB/Library/PreferenceLoader/Preferences"
cp "$OUT/DayNightSwitch.dylib" src/DayNightSwitch.plist "$JB/Library/MobileSubstrate/DynamicLibraries/"
cp "$OUT/DayNightSwitchPrefs" "$JB/Library/PreferenceBundles/DayNightSwitchPrefs.bundle/"
cp prefs/Resources/Info.plist prefs/Resources/Root.plist "$JB/Library/PreferenceBundles/DayNightSwitchPrefs.bundle/"
cp prefs/Resources/entry.plist "$JB/Library/PreferenceLoader/Preferences/DayNightSwitch.plist"
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
chmod 755 "$JB/Library/MobileSubstrate/DynamicLibraries/DayNightSwitch.dylib"
chmod 755 "$JB/Library/PreferenceBundles/DayNightSwitchPrefs.bundle/DayNightSwitchPrefs"

mkdir -p "$DIST"
DEB="$DIST/com.ning.daynightswitch_${V}_iphoneos-arm64e.deb"
rm -f "$DEB"
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$DEB"
echo "== 产物 =="
ls -l "$DEB"
sha256sum "$DEB"
dpkg-deb -c "$DEB" | head -20
