#!/bin/zsh
# Build MuxShots and assemble a signed MuxShots.app under .build/.
set -euo pipefail

configuration=${1:-debug}
root=${0:A:h:h}
identity=${MUXSHOTS_SIGN_IDENTITY:-MuxShots Development}
app="$root/.build/MuxShots.app"

swift build --package-path "$root" -c "$configuration" --product MuxShots
bin_path=$(swift build --package-path "$root" -c "$configuration" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$bin_path/MuxShots" "$app/Contents/MacOS/MuxShots"

if security find-identity -p codesigning | grep -q "\"$identity\""; then
    codesign --force --options runtime --sign "$identity" "$app"
else
    echo "warning: signing identity \"$identity\" not found, signing ad hoc;" \
        "Accessibility access will be lost on every rebuild (run scripts/create-dev-certificate.sh)" >&2
    codesign --force --options runtime --sign - "$app"
fi

echo "$app"
