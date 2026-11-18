#!/bin/zsh
# Build Rookery and assemble a signed Rookery.app under .build/.
set -euo pipefail

configuration=${1:-debug}
root=${0:A:h:h}
identity=${ROOKERY_SIGN_IDENTITY:-Rookery Development}
# The identity made while the app was called MuxShots signs just as well, until a new one is made.
legacy_identity="MuxShots Development"
app="$root/.build/Rookery.app"

swift build --package-path "$root" -c "$configuration" --product Rookery
swift build --package-path "$root" -c "$configuration" --product rookery-chrome-host
swift build --package-path "$root" -c "$configuration" --product rookery-mail
bin_path=$(swift build --package-path "$root" -c "$configuration" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
rm -rf "$app/Contents/Resources/Fonts"
cp -R "$root/Resources/Fonts" "$app/Contents/Resources/Fonts"
rm -rf "$app/Contents/Resources/Icons"
cp -R "$root/Resources/Icons" "$app/Contents/Resources/Icons"
rm -rf "$app/Contents/Resources/Raven"
cp -R "$root/Resources/Raven" "$app/Contents/Resources/Raven"
cp "$root/rook/bin/rook-client" "$app/Contents/Resources/Raven/rook-client"
cp "$bin_path/Rookery" "$app/Contents/MacOS/Rookery"
cp "$bin_path/rookery-chrome-host" "$app/Contents/MacOS/rookery-chrome-host"
cp "$bin_path/rookery-mail" "$app/Contents/MacOS/rookery-mail"

if ! security find-identity -p codesigning | grep -q "\"$identity\"" \
    && security find-identity -p codesigning | grep -q "\"$legacy_identity\""; then
    identity=$legacy_identity
fi

if security find-identity -p codesigning | grep -q "\"$identity\""; then
    codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/rookery-chrome-host"
    codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/rookery-mail"
    codesign --force --options runtime --entitlements "$root/Resources/Rookery.entitlements" --sign "$identity" "$app"
else
    echo "warning: signing identity \"$identity\" not found, signing ad hoc;" \
        "Accessibility access will be lost on every rebuild (run scripts/create-dev-certificate.sh)" >&2
    codesign --force --options runtime --sign - "$app/Contents/MacOS/rookery-chrome-host"
    codesign --force --options runtime --sign - "$app/Contents/MacOS/rookery-mail"
    codesign --force --options runtime --entitlements "$root/Resources/Rookery.entitlements" --sign - "$app"
fi

echo "$app"
