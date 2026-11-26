"""Verify every packaged runtime path against the independently provisioned reference."""

import hashlib
import os
import stat
import sys
from pathlib import Path


def tree_digest(root):
    digest = hashlib.sha256()
    # Record paths/types/modes as well as bytes. Never execute the candidate interpreter.
    for directory, dirs, files in os.walk(root):
        dirs.sort()
        files.sort()
        for name in sorted(dirs + files):
            node = Path(directory, name)
            mode = node.lstat().st_mode
            path = os.fsencode(node.relative_to(root))
            digest.update(path + b"\0" + format(mode, "o").encode() + b"\0")
            if stat.S_ISLNK(mode):
                digest.update(os.fsencode(os.readlink(node)) + b"\0")
            elif stat.S_ISREG(mode):
                contents = hashlib.sha256()
                with node.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        contents.update(block)
                digest.update(contents.digest())
            elif not stat.S_ISDIR(mode):
                raise ValueError(f"Unexpected runtime file type: {path!r}")
    return digest.hexdigest()


if __name__ == "__main__":
    root = Path(sys.argv[1])
    expected = Path(__file__).with_name("runtime-tree.sha256").read_text().strip()
    observed = tree_digest(root)
    if expected != observed:
        sys.exit(f"Unverified runtime at {root}: expected {expected}, found {observed}. "
                 "Run scripts/runtime.sh --rebuild.")
    print(f"runtime-tree-sha256 {observed}")
