#!/bin/sh
set -eu
native_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# App bundles must stay outside the File Provider-managed source checkout.
output=${WINDOW_FACTORY_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/window-factory/build}
. "$native_root/signing-config.sh"
build_number=${WINDOW_FACTORY_BUILD_NUMBER:-54}
case "$build_number" in ''|*[!0-9]*) echo "Build number must be numeric" >&2; exit 1;; esac
app="$output/Window Factory.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$output/ModuleCache"
cp "$native_root/Resources/adapters.json" "$app/Contents/Resources/adapters.json"
"$native_root/scripts/package-icon.sh" "$native_root/Resources/WindowFactory.icon" "$output/icon"
cp "$output/icon/WindowFactory.icns" "$app/Contents/Resources/WindowFactory.icns"
cp "$output/icon/Assets.car" "$app/Contents/Resources/Assets.car"
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -c "$native_root/Sources/Bridge.m" -o "$output/Bridge.o"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$output/ModuleCache" -import-objc-header "$native_root/Sources/Bridge.h" \
    "$native_root"/Sources/*.swift "$output/Bridge.o" \
    -framework Cocoa -framework ApplicationServices -framework Carbon -framework ScreenCaptureKit -o "$app/Contents/MacOS/WindowFactory"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.windowfactory.native</string>
<key>CFBundleName</key><string>Window Factory</string>
<key>CFBundleDisplayName</key><string>Window Factory</string>
<key>CFBundleExecutable</key><string>WindowFactory</string>
<key>CFBundleIconName</key><string>WindowFactory</string>
<key>CFBundleIconFile</key><string>WindowFactory</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>WindowFactoryCLIProtocolVersion</key><integer>1</integer>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppleEventsUsageDescription</key><string>Create missing application windows for layouts you choose to establish.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
signed=no
if [ "$signing_mode" = developer-id ]; then timestamp=--timestamp; else timestamp=--timestamp=none; fi
for attempt in 1 2 3; do
    for attribute in com.apple.FinderInfo com.apple.ResourceFork; do xattr -dr "$attribute" "$app" 2>/dev/null || :; done
    if codesign --force --sign "$signing_identity" --options runtime "$timestamp" \
        --entitlements "$native_root/Resources/entitlements.plist" "$app" \
        && codesign --verify --strict "$app" \
        && { [ "$signing_mode" = adhoc ] || codesign --verify -R "=identifier \"local.windowfactory.native\" and anchor apple generic and certificate leaf[subject.OU] = \"$signing_team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$app"; }; then signed=yes; break; fi
done
[ "$signed" = yes ]
printf 'Built %s\n' "$app"
