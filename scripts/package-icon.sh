#!/bin/sh
# Let Apple's compiler apply the modern outer mask and generate legacy fallback.
set -eu
source=${1:?Expected Icon Composer document}
output=${2:?Expected output directory}
mkdir -p "$output"
xcrun actool "$source" --compile "$output" --app-icon WindowFactory \
    --platform macosx --minimum-deployment-target 14.0 --target-device mac \
    --development-region en --output-partial-info-plist "$output/icon-info.plist"
for key in CFBundleIconName CFBundleIconFile; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$output/icon-info.plist")
    [ "$value" = WindowFactory ] || { echo "Unexpected compiled icon identity" >&2; exit 1; }
done
[ -s "$output/Assets.car" ] && [ -s "$output/WindowFactory.icns" ]
