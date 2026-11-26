import Darwin
import Foundation

/// One temporary session per running studio. macOS releases its file lock even after SIGKILL.
final class RuntimeScratch {
    private static let marker = ".refract-session-v1.lock"
    private let session: URL
    private let lease: FileHandle

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        let root = temporaryDirectory.appendingPathComponent("Refract Runtime Scratch", isDirectory: true)
        if mkdir(root.path, 0o700) < 0, errno != EEXIST { throw Self.posixError() }
        guard Self.isPrivateDirectory(root) else { throw StudioError("Cannot use the Refract temporary directory.") }
        Self.reapAbandoned(in: root)

        let session = root.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        guard mkdir(session.path, 0o700) == 0 else { throw Self.posixError() }
        do {
            let lease = try Self.lock(session, create: true)
            let files = session.appendingPathComponent("files", isDirectory: true)
            guard mkdir(files.path, 0o700) == 0 else { throw Self.posixError() }
            self.session = session
            self.lease = lease
        } catch {
            // This freshly created session has never been handed to a caller.
            try? FileManager.default.removeItem(at: session)
            throw error
        }
    }

    func makeDirectory() throws -> URL {
        let url = session.appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(url.path, 0o700) == 0 else { throw Self.posixError() }
        return url
    }

    deinit { Self.removeSession(session, holding: lease) }

    private static func reapAbandoned(in root: URL) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("run-"), UUID(uuidString: String(name.dropFirst(4))) != nil,
                  isPrivateDirectory(child), let lease = try? lock(child, create: false) else { continue }
            removeSession(child, holding: lease)
        }
    }

    private static func removeSession(_ session: URL, holding lease: FileHandle) {
        defer { withExtendedLifetime(lease) {} }
        let fm = FileManager.default
        guard isPrivateDirectory(session),
              let names = try? fm.contentsOfDirectory(atPath: session.path),
              names.contains(marker), Set(names).isSubset(of: [marker, "files"]) else { return }
        let markerURL = session.appendingPathComponent(marker)
        var held = stat(), named = stat()
        guard fstat(lease.fileDescriptor, &held) == 0, lstat(markerURL.path, &named) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { return }
        do {
            // Keep the marker until the heavy files are gone so another launch can finish interrupted cleanup.
            if names.contains("files") { try fm.removeItem(at: session.appendingPathComponent("files")) }
            guard unlink(markerURL.path) == 0 else { return }
            _ = rmdir(session.path)
        } catch { return }
    }

    private static func lock(_ session: URL, create: Bool) throws -> FileHandle {
        let url = session.appendingPathComponent(marker)
        // Acquire the lease atomically with open, including on first creation before any payload is written.
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK
        let fd = open(url.path, create ? flags | O_CREAT | O_EXCL : flags, 0o600)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size == 0 else { throw StudioError("Invalid Refract temporary session.") }
        return handle
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
