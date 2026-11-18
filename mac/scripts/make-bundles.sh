#!/bin/sh
# Wraps the release binary in two background-only app bundles for Options+ for Mac, which launches
# applications without arguments. The probe bundle names its one fixed command in Info.plist.
# Usage: make-bundles.sh BINARY OUTPUT_DIR VERSION
set -eu
binary=$1
out=$2
version=$3

make_bundle() {
    name=$1 identifier=$2 command=$3
    app="$out/$name.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$binary" "$app/Contents/MacOS/deskflip-mac"
    extra=""
    if [ -n "$command" ]; then
        extra="    <key>DeskflipCommand</key>
    <string>$command</string>"
    fi
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>deskflip-mac</string>
    <key>CFBundleIdentifier</key>
    <string>$identifier</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
$extra
</dict>
</plist>
EOF
    plutil -lint "$app/Contents/Info.plist"
    codesign --force --sign - --identifier "$identifier" "$app"
    codesign --verify --strict --verbose "$app"
}

make_bundle "Deskflip" "local.deskflip.helper" ""
make_bundle "Deskflip Probe" "local.deskflip.probe" "probe-trigger"
