#!/bin/bash
set -euo pipefail
project=$(cd -- "$(dirname -- "$0")" && pwd)
app=${1:-"$project/build/RouteSentry.app"}
artifacts=$(mktemp -d)
trap 'rm -rf -- "$artifacts"' EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$artifacts/AppIcon.iconset"
for arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc -O -target "$arch-apple-macos14.0" -parse-as-library \
    "$project"/Sources/*.swift -o "$artifacts/$arch"
done
/usr/bin/lipo -create "$artifacts/arm64" "$artifacts/x86_64" -output "$app/Contents/MacOS/RouteSentry"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$project/Assets/AppIcon.png" --out "$artifacts/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z "$((size*2))" "$((size*2))" "$project/Assets/AppIcon.png" --out "$artifacts/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$artifacts/AppIcon.iconset" --output "$app/Contents/Resources/AppIcon.icns"
/usr/bin/install -m 0644 "$project/Info.plist" "$app/Contents/Info.plist"
/usr/bin/install -m 0644 "$project/sota-policy.py" "$app/Contents/Resources/sota-policy.py"
/usr/bin/install -m 0644 "$project/Design/assets/protection-ring.png" "$app/Contents/Resources/protection-ring.png"
/usr/bin/install -d "$app/Contents/Resources/Glyphs"
/usr/bin/install -m 0644 "$project"/Assets/Glyphs/*.png "$app/Contents/Resources/Glyphs"
/usr/bin/codesign --force --sign "${ROUTESENTRY_SIGN_IDENTITY:--}" "$app"
/usr/bin/codesign --verify --strict "$app"
