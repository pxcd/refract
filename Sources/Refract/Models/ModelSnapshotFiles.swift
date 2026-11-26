import Darwin
import Foundation

enum ModelSnapshotFiles {
    /// HF cache snapshots often contain symlinks. Follow them once, then operate on the opened regular file.
    static func openRegular(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw ModelError("Expected a regular file: " + url.lastPathComponent)
        }
        return handle
    }

    /// Use copy-on-write on APFS. External and network volumes can require an ordinary copy.
    static func copyRegular(from source: URL, to destination: URL, size: Int64) throws {
        let input = try openRegular(source)
        defer { try? input.close() }
        var info = stat()
        guard fstat(input.fileDescriptor, &info) == 0, info.st_size == size, size >= 0 else {
            throw ModelError("The size of " + source.lastPathComponent + " differs from its recorded size.")
        }
        if fclonefileat(input.fileDescriptor, AT_FDCWD, destination.path, UInt32(CLONE_NOOWNERCOPY)) != 0 {
            let error = errno
            guard [EXDEV, ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL, EPERM, EACCES].contains(error) else {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            let fd = open(destination.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                var remaining = size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = Int(min(remaining, 4 * 1024 * 1024))
                    guard let data = try input.read(upToCount: count), !data.isEmpty else {
                        throw ModelError("The source changed while preparing " + source.lastPathComponent)
                    }
                    try output.write(contentsOf: data)
                    remaining -= Int64(data.count)
                }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
        }
        guard chmod(destination.path, 0o400) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
