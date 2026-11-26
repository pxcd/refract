"""Verify native arm64 deployment targets, including Mach-Os inside wheels."""

import struct
import sys
from pathlib import Path


ARM64 = 0x0100000C
TARGET = (27, 0, 0)
THIN = {
    bytes.fromhex(magic): (endian, wide)
    for magic, endian, wide in (
        ("cffaedfe", "<", True), ("feedfacf", ">", True),
        ("cefaedfe", "<", False), ("feedface", ">", False),
    )
}
FAT = {
    bytes.fromhex(magic): (endian, fmt)
    for magic, endian, fmt in (
        ("cafebabe", ">", "IIIII"), ("bebafeca", "<", "IIIII"),
        ("cafebabf", ">", "IIQQII"), ("bfbafeca", "<", "IIQQII"),
    )
}


def read_fields(stream, fmt):
    return struct.unpack(fmt, stream.read(struct.calcsize(fmt)))


def minimum_version(stream):
    magic = stream.read(4)
    if magic in FAT:
        endian, arch_format = FAT[magic]
        count, = read_fields(stream, endian + "I")
        if count > 128:
            raise ValueError("invalid number of universal binary slices")
        slices = [read_fields(stream, endian + arch_format) for _ in range(count)]
        native = next((item for item in slices if item[0] == ARM64), None)
        if native is None:
            raise ValueError("missing arm64 slice")
        stream.seek(native[2])
        magic = stream.read(4)
    elif magic not in THIN:
        return None

    endian, wide = THIN[magic]
    cpu, _, _, commands, total_size, _ = read_fields(stream, endian + "6I")
    if cpu != ARM64:
        raise ValueError("missing arm64 architecture")
    if wide:
        stream.read(4)
    remaining = total_size
    for _ in range(commands):
        command, size = read_fields(stream, endian + "II")
        if size < 8 or size > remaining:
            raise ValueError("invalid load command size")
        remaining -= size
        if command == 0x32:  # LC_BUILD_VERSION
            platform, version = read_fields(stream, endian + "II")
            if platform != 1:
                raise ValueError(f"non-macOS platform {platform}")
            break
        if command == 0x24:  # LC_VERSION_MIN_MACOSX
            version, = read_fields(stream, endian + "I")
            break
        stream.seek(size - 8, 1)
    else:
        raise ValueError("missing deployment target")
    return version >> 16, (version >> 8) & 255, version & 255


def audit(root):
    maximum = (0, 0, 0)
    count = 0
    failures = []
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        try:
            with path.open("rb") as stream:
                version = minimum_version(stream)
            if version is None:
                continue
            count += 1
            maximum = max(maximum, version)
            if version > TARGET:
                raise ValueError(f"requires macOS {'.'.join(map(str, version))}")
        except (OSError, KeyError, ValueError, struct.error) as error:
            failures.append(f"{path.relative_to(root)}: {error}")
    if not count:
        failures.append("No Mach-Os found")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Verified {count} arm64 macOS Mach-Os. Highest deployment target {'.'.join(map(str, maximum))}.")


if __name__ == "__main__":
    audit(Path(sys.argv[1]))
