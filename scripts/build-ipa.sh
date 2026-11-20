#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
work="$root/.build"
output="$root/out"
payload="$work/package/Payload"
app="$payload/NethLocal.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]
unsigned="$output/NethLocal-v$version-unsigned.ipa"
impactor="$output/NethLocal-v$version-Impactor.ipa"

mkdir -p "$work" "$output"
source="$(python3 scripts/prepare-engine.py)"
framework="$source/build-ios-device/framework/llama.framework"
if [[ ! -f "$framework/llama" ]]; then
    (cd "$source" && bash build-xcframework.sh ios-device)
fi

rm -rf "$work/package"
mkdir -p "$app/Frameworks"
test -f "$framework/llama"
ditto "$framework" "$app/Frameworks/llama.framework"
cp App/Info.plist "$app/Info.plist"
cp NethLocal.entitlements "$app/NethLocal.entitlements"
cp NethLocal.entitlements "$output/NethLocal.entitlements"
cp ThirdParty/llama.cpp-LICENSE "$app/llama.cpp-LICENSE"

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
target="arm64-apple-ios18.0"

xcrun --sdk iphoneos clang++ -target "$target" -isysroot "$sdk" -std=c++17 -O2 \
    -I "$source/include" -I "$source/ggml/include" -I "$source/tools/mtmd" \
    -c App/NethRuntime.cpp -o "$work/NethRuntime.o"

xcrun --sdk iphoneos swiftc -target "$target" -sdk "$sdk" -swift-version 5 -O \
    -parse-as-library -module-name NethLocal -import-objc-header App/NethRuntime.h \
    -F "$app/Frameworks" -framework llama -lc++ -lsqlite3 \
    -Xlinker -rpath -Xlinker '@executable_path/Frameworks' \
    App/*.swift "$work/NethRuntime.o" -o "$app/NethLocal"

xcrun --sdk iphoneos actool App/Assets.xcassets --compile "$app" \
    --platform iphoneos --target-device ipad --minimum-deployment-target 18.0 \
    --app-icon AppIcon --output-partial-info-plist "$work/icons.plist"

python3 - "$app/Info.plist" "$work/icons.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as f:
    app = plistlib.load(f)
with open(sys.argv[2], "rb") as f:
    app.update(plistlib.load(f))
with open(sys.argv[1], "wb") as f:
    plistlib.dump(app, f)
PY

for binary in "$app/NethLocal" "$app/Frameworks/llama.framework/llama"; do
    if xcrun otool -l "$binary" | grep 'LC_CODE_SIGNATURE' >/dev/null; then
        codesign --remove-signature "$binary"
    fi
    if xcrun otool -l "$binary" | grep 'LC_CODE_SIGNATURE' >/dev/null; then
        echo "Unexpected code signature in $binary" >&2
        exit 1
    fi
    test "$(xcrun lipo -archs "$binary")" = arm64
    xcrun vtool -show-build "$binary"
done
find "$app" -type d -name _CodeSignature -prune -exec rm -rf {} +
xcrun otool -L "$app/NethLocal"

rm -f "$unsigned" "$impactor"
ditto -c -k --norsrc --keepParent "$payload" "$unsigned"
python3 scripts/verify-ipa.py "$unsigned"

# Impactor reads capability requests from the original main executable.
# It creates its own Apple ID signature and provisioning profile at install.
impactor_executable="$work/NethLocal-Impactor"
cp "$app/NethLocal" "$impactor_executable"
codesign --force --sign - --identifier com.neth.local --entitlements NethLocal.entitlements "$impactor_executable"
cp "$impactor_executable" "$app/NethLocal"
ditto -c -k --norsrc --keepParent "$payload" "$impactor"
python3 scripts/verify-ipa.py "$impactor" --impactor
