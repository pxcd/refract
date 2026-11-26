#!/bin/bash
# Resolve every wheel for the app's deployment target, independently of the build Mac's OS.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
version=3.12.16
runtime="$root/.runtime"
if [[ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]]; then
    echo 'The private runtime requires an Apple Silicon Mac.' >&2
    exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --rebuild ) ]]; then
    echo 'usage: runtime.sh [--rebuild]' >&2
    exit 2
fi
verify_runtime() {
    "$1/bin/python3.12" -I -B - "$version" "$root/scripts/runtime-requirements.txt" <<'PY'
from email.parser import Parser
from importlib.metadata import distribution
from pathlib import Path
from platform import machine, python_version
from packaging.tags import mac_platforms, parse_tag
import sys
assert python_version() == sys.argv[1] and machine() == 'arm64', 'Unexpected private interpreter'
platforms = {'any', *mac_platforms(version=(27, 0), arch='arm64')}
for requirement in Path(sys.argv[2]).read_text().splitlines():
    name, expected = requirement.split('==')
    dist = distribution(name)
    tags = Parser().parsestr(dist.read_text('WHEEL')).get_all('Tag', [])
    allowed = {'macosx_27_0_arm64'} if name in {'mlx', 'mlx-metal'} else platforms
    if dist.version != expected or not any(t.platform in allowed for label in tags for t in parse_tag(label)):
        raise SystemExit(f'{name} is incompatible with the locked macOS 27 runtime. Run scripts/runtime.sh --rebuild.')
print(f'Private ARM64 runtime validated at {sys.prefix}')
PY
    "$1/bin/python3.12" -I -B "$root/scripts/runtime-audit.py" "$1"
}
if [[ -d "$runtime" && $# -eq 0 ]]; then
    verify_runtime "$runtime"
    exit 0
fi
mkdir -p .runtime-build
stage="$(mktemp -d "$root/.runtime-build/install.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
uv python install --no-bin --no-cache --install-dir "$stage" "$version"
candidate="$stage/cpython-$version-macos-aarch64-none"
"$candidate/bin/python3.12" -I -B -m pip --isolated download --no-cache-dir --no-deps --only-binary :all: \
    --platform macosx_27_0_arm64 --implementation cp --python-version 3.12 --abi cp312 \
    --dest "$stage/wheels" --requirement "$root/scripts/runtime-requirements.txt"
(cd "$stage/wheels" && shasum -a 256 -c "$root/scripts/runtime-macos27.sha256")
uv pip install --no-cache --python "$candidate/bin/python3.12" --break-system-packages --no-index \
    --find-links "$stage/wheels" --only-binary :all: --no-deps --requirement "$root/scripts/runtime-requirements.txt"
uv pip check --no-cache --python "$candidate/bin/python3.12"
verify_runtime "$candidate"
# Only CPython is invoked by the application. Pip console scripts contain absolute build paths.
find "$candidate/bin" -maxdepth 1 \( -type f -o -type l \) ! -name python3.12 ! -name python3 ! -name python -delete
if [[ -e "$runtime" ]]; then mv "$runtime" "$stage/replaced"; fi
if ! mv "$candidate" "$runtime"; then
    if [[ -e "$stage/replaced" ]]; then mv "$stage/replaced" "$runtime"; fi
    exit 1
fi
