#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
engine_tag=b12549
engine_sha=8c87f76161bb1666e39686702744bb46f3945ce43b49d4be00d75b7001122f42
work="$root/.build"
output="$root/out"
engine_dir="$work/$engine_tag"
payload="$work/package/Payload"
app="$payload/NethLocal.app"

mkdir -p "$work" "$output"
archive="$work/llama-$engine_tag-xcframework.zip"
if [[ ! -f "$archive" ]] || ! printf '%s  %s\n' "$engine_sha" "$archive" | shasum -a 256 -c --status; then
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 \
        --output "$archive.partial" \
        "https://github.com/ggml-org/llama.cpp/releases/download/$engine_tag/llama-$engine_tag-xcframework.zip"
    printf '%s  %s\n' "$engine_sha" "$archive.partial" | shasum -a 256 -c
    mv "$archive.partial" "$archive"
fi

rm -rf "$engine_dir" "$work/package"
mkdir -p "$engine_dir" "$app/Frameworks"
unzip -q "$archive" -d "$engine_dir"
framework="$(find "$engine_dir" -type d -name llama.framework | awk '/\/ios-arm64\/llama\.framework$/')"
test -d "$framework"
ditto "$framework" "$app/Frameworks/llama.framework"
cp App/Info.plist "$app/Info.plist"
cp NethLocal.entitlements "$app/NethLocal.entitlements"
cp NethLocal.entitlements "$output/NethLocal.entitlements"
cp ThirdParty/llama.cpp-LICENSE "$app/llama.cpp-LICENSE"

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
target="arm64-apple-ios18.0"

xcrun --sdk iphoneos clang++ -target "$target" -isysroot "$sdk" -std=c++17 -O2 \
    -F "$app/Frameworks" -c App/NethRuntime.cpp -o "$work/NethRuntime.o"

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

rm -f "$output/NethLocal-unsigned.ipa" "$output/NethLocal-Impactor.ipa"
ditto -c -k --norsrc --keepParent "$payload" "$output/NethLocal-unsigned.ipa"
python3 scripts/verify-ipa.py "$output/NethLocal-unsigned.ipa"

# Impactor reads capability requests from the original main executable.
# It creates its own Apple ID signature and provisioning profile at install.
codesign --force --sign - --identifier com.neth.local --entitlements NethLocal.entitlements "$app/NethLocal"
ditto -c -k --norsrc --keepParent "$payload" "$output/NethLocal-Impactor.ipa"
python3 scripts/verify-ipa.py "$output/NethLocal-Impactor.ipa" --impactor
