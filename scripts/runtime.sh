#!/bin/bash
# Provision a content-locked private runtime for macOS 27 arm64.
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."
root="$PWD"
runtime="$root/.runtime"
if [[ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]]; then
    echo 'The private runtime requires an Apple Silicon Mac.' >&2
    exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --rebuild ) ]]; then
    echo 'usage: runtime.sh [--rebuild]' >&2
    exit 2
fi
verify_runtime() { /usr/bin/python3 -I -B -S "$root/scripts/runtime-tree.py" "$1"; }
if [[ -d "$runtime" && $# -eq 0 ]]; then
    verify_runtime "$runtime"
    exit 0
fi

mkdir -p .runtime-build
stage="$(mktemp -d "$root/.runtime-build/install.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
wheels="$stage/wheels"
mkdir "$wheels"
# Astral python-build-standalone release 20261124, install-only stripped build.
archive=cpython-3.12.16+20261124-aarch64-apple-darwin-install_only_stripped.tar.gz
archive_hash=9d6d9d0d85feda3f9cb4eb3e048f0fed21ed280feda087927eaa4fbc7124826f
# An optional local artifact cache goes through the same pre-install digest checks.
if [[ -n "${REFRACT_RUNTIME_ARTIFACTS:-}" ]]; then
    cp "$REFRACT_RUNTIME_ARTIFACTS/$archive" "$stage/$archive"
else
    /usr/bin/curl -fsSL --retry 3 "https://github.com/astral-sh/python-build-standalone/releases/download/20261124/$archive" -o "$stage/$archive"
fi
(cd "$stage" && printf '%s  %s\n' "$archive_hash" "$archive" | /usr/bin/shasum -a 256 -c -)
COPYFILE_DISABLE=1 /usr/bin/tar -xzf "$stage/$archive" -C "$stage"
candidate="$stage/python"
python="$candidate/bin/python3.12"
# The release wheel digests follow runtime-requirements.txt order. pip enforces each
# digest during both resolution and installation, including for a local wheel cache.
paste scripts/runtime-requirements.txt scripts/runtime-macos27.sha256 | \
    awk '{ print $1, "--hash=sha256:" $2 }' > "$stage/locked.txt"
if [[ -n "${REFRACT_RUNTIME_ARTIFACTS:-}" ]]; then
    while read -r hash wheel; do cp "$REFRACT_RUNTIME_ARTIFACTS/$wheel" "$wheels/$wheel"; done < scripts/runtime-macos27.sha256
else
    "$python" -I -B -m pip --isolated --disable-pip-version-check download --no-cache-dir --no-deps --only-binary :all: \
        --index-url https://pypi.org/simple --platform macosx_27_0_arm64 --implementation cp --python-version 3.12 --abi cp312 \
        --dest "$wheels" --require-hashes --requirement "$stage/locked.txt"
fi
(cd "$wheels" && /usr/bin/shasum -a 256 -c "$root/scripts/runtime-macos27.sha256")
"$python" -I -B -m pip --isolated --disable-pip-version-check install --no-cache-dir --no-index --no-deps --no-compile \
    --only-binary :all: --break-system-packages --find-links "$wheels" --require-hashes --requirement "$stage/locked.txt"
"$python" -I -B -m pip --isolated --disable-pip-version-check check

# Drop console launchers, which contain the temporary interpreter path, and their RECORD entries.
find "$candidate/bin" -maxdepth 1 \( -type f -o -type l \) ! -name python3.12 ! -name python3 ! -name python -delete
find "$candidate" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$candidate" -type f -name '*.pyc' -delete
/usr/bin/python3 -I -B -S - "$candidate" <<'PY'
import csv
import sys
from pathlib import Path
site = Path(sys.argv[1]) / "lib/python3.12/site-packages"
for record in site.glob("*.dist-info/RECORD"):
    with record.open(newline="") as stream:
        kept = [row for row in csv.reader(stream) if not row[0].startswith("../../../bin/") and not row[0].endswith(".pyc")]
    with record.open("w", newline="") as stream:
        csv.writer(stream).writerows(kept)
PY
verify_runtime "$candidate"
"$python" -I -B scripts/runtime-audit.py "$candidate"
if [[ -e "$runtime" ]]; then mv "$runtime" "$stage/replaced"; fi
if ! mv "$candidate" "$runtime"; then
    if [[ -e "$stage/replaced" ]]; then mv "$stage/replaced" "$runtime"; fi
    exit 1
fi
