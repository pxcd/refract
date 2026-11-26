#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
runtime="${REFRACT_RUNTIME:-$root/.runtime}"
test -x "$runtime/bin/python3.12" || { echo 'Prepare the bundled Python runtime first.' >&2; exit 1; }
swift build -c release --arch arm64 --disable-sandbox
products="$(swift build -c release --arch arm64 --show-bin-path --disable-sandbox)"
mkdir -p build
stage="$(mktemp -d "$root/build/.package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Refract.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Refract.icns "$app/Contents/Resources/Refract.icns"
cp "$products/Refract" "$app/Contents/MacOS/Refract"
/usr/bin/rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' Worker/ "$app/Contents/Resources/Worker/"
/usr/bin/rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' "$runtime/" "$app/Contents/Resources/runtime/"
bundled="$app/Contents/Resources/runtime"
identity="$app/Contents/Resources/runtime-versions.txt"
# Check the copied tree and its native deployment targets without executing the candidate runtime.
/usr/bin/python3 -I -B -S scripts/runtime-tree.py "$bundled" > "$identity"
cat scripts/runtime-requirements.txt >> "$identity"
cat scripts/runtime-macos27.sha256 >> "$identity"
(cd "$app/Contents/Resources" && find Worker -type f | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
done >> runtime-versions.txt)
/usr/bin/python3 -I -B -S scripts/runtime-audit.py "$app"
/usr/bin/codesign --force --sign - --identifier studio.refract.mac "$app"
/usr/bin/codesign --verify --deep --strict "$app"
if [ -e build/Refract.app ]; then mv build/Refract.app "$stage/previous.app"; fi
if ! mv "$app" build/Refract.app; then
    if [ -d "$stage/previous.app" ]; then mv "$stage/previous.app" build/Refract.app; fi
    exit 1
fi
python3 scripts/receipt.py
echo "$root/build/Refract.app"
