"""Record the exact source and packaged app identity without recording user models."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
app = root / "build/Refract.app"

def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else streamed_digest(stream)

def streamed_digest(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(chunk)
    return value.hexdigest()

def git(*args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None

def tree_identity(base, paths):
    value = hashlib.sha256()
    for path in sorted(paths):
        relative = str(path.relative_to(base))
        if path.is_symlink():
            identity = "link:" + os.readlink(path)
        elif path.is_file():
            identity = digest(path)
        else:
            continue
        value.update((relative + "\0" + identity + "\n").encode())
    return value.hexdigest()

source = [root / "Package.swift", root / ".gitignore", root / "README.md"]
for name in (".github", "Resources", "Sources", "Tests", "Worker", "scripts"):
    source.extend(p for p in (root / name).rglob("*") if "__pycache__" not in p.parts)
data = {
    "checkout": str(root), "branch": git("branch", "--show-current"), "revision": git("rev-parse", "--verify", "HEAD"),
    "gitStatus": git("status", "--short"), "sourceSHA256": tree_identity(root, source),
    "command": "scripts/package.sh", "result": "success", "app": str(app),
    "appTreeSHA256": tree_identity(app, app.rglob("*")), "executableSHA256": digest(app / "Contents/MacOS/Refract"),
}
(root / "build/provenance.json").write_text(json.dumps(data, indent=2) + "\n")
