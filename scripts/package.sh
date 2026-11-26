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
# Package builds may run from a detached process without an inherited standard input.
"$app/Contents/Resources/runtime/bin/python3.12" -I -B -c 'from importlib.metadata import version; from pathlib import Path; import sys; Path(sys.argv[1]).write_text("\n".join(f"{p}=={version(p)}" for p in ("diffusers","torch","mlx","mlx-metal","mlx-gen","transformers","peft","safetensors","Pillow"))+"\n")' "$app/Contents/Resources/runtime-versions.txt" </dev/null
cat scripts/runtime-macos27.sha256 >> "$app/Contents/Resources/runtime-versions.txt"
(cd "$app/Contents/Resources" && find Worker -type f | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
done >> runtime-versions.txt)
"$runtime/bin/python3.12" -I -B scripts/runtime-audit.py "$app" </dev/null
/usr/bin/codesign --force --sign - --identifier studio.refract.mac "$app"
/usr/bin/codesign --verify --deep --strict "$app"
if [ -e build/Refract.app ]; then mv build/Refract.app "$stage/previous.app"; fi
if ! mv "$app" build/Refract.app; then
    if [ -d "$stage/previous.app" ]; then mv "$stage/previous.app" build/Refract.app; fi
    exit 1
fi
python3 scripts/receipt.py
echo "$root/build/Refract.app"
