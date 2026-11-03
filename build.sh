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
codesign --force --deep --sign - "$APP"
echo "Built $APP"
