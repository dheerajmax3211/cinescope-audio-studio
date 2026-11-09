#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/CineScope.app"
CONTENTS="$APP/Contents"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
xcrun swiftc \
  -parse-as-library -O -target arm64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AVKit \
  -framework UniformTypeIdentifiers \
  -framework NaturalLanguage \
  -framework Security \
  "$ROOT/Sources/CineScope/App.swift" \
  -o "$CONTENTS/MacOS/CineScope"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/CineScopeLogo.png" "$CONTENTS/Resources/CineScopeLogo.png"
ICONSET="$ROOT/build/CineScope.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ROOT/Resources/CineScopeLogo.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
if [[ -d "$ROOT/Resources/StableAudio" ]]; then
  mkdir -p "$CONTENTS/Resources/StableAudio"
  cp -R "$ROOT/Resources/StableAudio/." "$CONTENTS/Resources/StableAudio/"
fi
codesign --force --deep --sign - "$APP"
echo "Built $APP"
