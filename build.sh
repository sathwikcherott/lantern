#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
LANTERN_OUTPUT="${1:-build}"
mkdir -p "$LANTERN_OUTPUT"
LANTERN_OUTPUT="${LANTERN_OUTPUT:A}"
LANTERN_STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/lantern-build.XXXXXX")"
trap 'rm -rf "$LANTERN_STAGE"' EXIT
LANTERN_BUNDLE="$LANTERN_STAGE/Foxfire.app"
LANTERN_MODULE_CACHE="${PWD}/build/module-cache"
mkdir -p "$LANTERN_BUNDLE/Contents/MacOS" "$LANTERN_BUNDLE/Contents/Resources"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$LANTERN_MODULE_CACHE" \
    Sources/*.swift -o "$LANTERN_BUNDLE/Contents/MacOS/Foxfire"
mkdir -p "$LANTERN_STAGE/classes"
javac --release 17 -d "$LANTERN_STAGE/classes" Telemetry/LanternMetrics.java
printf 'Premain-Class: LanternMetrics\n' > "$LANTERN_STAGE/metrics.mf"
jar cfm "$LANTERN_BUNDLE/Contents/Resources/LanternMetrics.jar" "$LANTERN_STAGE/metrics.mf" -C "$LANTERN_STAGE/classes" .
cp -R Resources/vendor "$LANTERN_BUNDLE/Contents/Resources/"
cp Resources/*.py "$LANTERN_BUNDLE/Contents/Resources/"
cp Info.plist "$LANTERN_BUNDLE/Contents/Info.plist"
if [[ -f Resources/Lantern.icns ]]; then
    cp Resources/Lantern.icns "$LANTERN_BUNDLE/Contents/Resources/Lantern.icns"
fi
xattr -cr "$LANTERN_BUNDLE"
codesign --force --sign - "$LANTERN_BUNDLE"
codesign --verify --deep --strict "$LANTERN_BUNDLE"
ditto -c -k --keepParent --norsrc --noextattr "$LANTERN_BUNDLE" "$LANTERN_OUTPUT/Foxfire.zip"
print "Built $LANTERN_OUTPUT/Foxfire.zip"
