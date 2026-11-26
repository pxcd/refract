import Darwin
import Foundation

struct ManagedPackageIdentity: Codable {
    let volume: String?
    let device: dev_t
    let inode: ino_t

    func matches(_ other: Self) -> Bool {
        guard inode == other.inode else { return false }
        if let volume, let otherVolume = other.volume { return volume == otherVolume }
        return device == other.device
    }
}

/// Files used for writes, locks and cleanup are opened below a held directory descriptor.
final class ManagedModelDirectory {
    let url: URL
    private let handle: FileHandle
    private var fd: Int32 { handle.fileDescriptor }

    private init(handle: FileHandle, url: URL) {
        self.handle = handle
        self.url = url
    }

    private static func systemError(_ action: String) -> ModelError {
        ModelError("\(action): \(String(cString: strerror(errno)))")
    }

    /// Resolve the user's chosen root once. From there, reject ancestors that another user can replace.
    static func root(at location: URL, create: Bool = true) throws -> ManagedModelDirectory {
        var existing = location.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { throw systemError("Resolving model storage") }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError("Opening storage root") }
        var current = ManagedModelDirectory(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), url: URL(fileURLWithPath: "/", isDirectory: true))
        for name in canonical.pathComponents.dropFirst() {
            current = try current.child(name, create: false, ancestor: true)
        }
        for name in missing.reversed() {
            current = try current.child(name, create: create, ancestor: true)
        }
        return current
    }

    private static func checkPermissions(_ descriptor: Int32, ancestor: Bool, requirePrivate: Bool = false) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw systemError("Checking model storage permissions") }
        let sticky = ancestor && status.st_mode & S_ISVTX != 0
        guard status.st_uid == geteuid() || (ancestor && status.st_uid == 0),
              status.st_mode & 0o022 == 0 || sticky else {
            throw ModelError("Choose a model folder whose contents only your account can change.")
        }
        // Darwin ACLs may grant write access even when the POSIX permissions look private.
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if [0, ENOENT, ENOTSUP].contains(errno) { return }
            throw systemError("Checking model storage access controls")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writeRights = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        let mask = writeRights.reduce(UInt64(0)) { $0 | UInt64($1.rawValue) }
        var entry: acl_entry_t?
        var selector = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, Int32(selector), &entry) == 0, let item = entry {
            var tag = ACL_UNDEFINED_TAG
            var rights: acl_permset_mask_t = 0
            guard acl_get_tag_type(item, &tag) == 0, acl_get_permset_mask_np(item, &rights) == 0 else {
                throw systemError("Checking model storage access controls")
            }
            if tag == ACL_EXTENDED_ALLOW && (requirePrivate || rights & mask != 0) {
                throw ModelError("The model folder grants shared access. Choose private storage for managed downloads.")
            }
            selector = ACL_NEXT_ENTRY.rawValue
        }
    }

    private static func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ModelError("Invalid managed model filename.")
        }
    }

    func child(_ name: String, create: Bool = false, ancestor: Bool = false) throws -> ManagedModelDirectory {
        try Self.name(name)
        if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw Self.systemError("Creating \(name)") }
        let descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.systemError("Opening folder \(name)") }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try Self.checkPermissions(opened.fileDescriptor, ancestor: ancestor)
        return ManagedModelDirectory(handle: opened, url: url.appendingPathComponent(name, isDirectory: true))
    }

    func identity() throws -> ManagedPackageIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.systemError("Checking installed model location") }
        let volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return ManagedPackageIdentity(volume: volume, device: info.st_dev, inode: info.st_ino)
    }

    func makePrivate() throws {
        guard fchmod(fd, 0o700) == 0 else { throw Self.systemError("Securing model staging") }
        try Self.checkPermissions(fd, ancestor: false, requirePrivate: true)
    }

    func exists(_ name: String) throws -> Bool {
        try Self.name(name)
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw Self.systemError("Checking \(name)")
    }

    func file(_ name: String, writing: Bool = false, create: Bool = false, exclusive: Bool = false) throws -> FileHandle {
        try Self.name(name)
        var flags = (writing ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        if create { flags |= O_CREAT }
        if exclusive { flags |= O_EXCL }
        let descriptor = openat(fd, name, flags, 0o600)
        guard descriptor >= 0 else { throw Self.systemError("Opening \(name)") }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(opened.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ModelError("Expected a regular, singly linked model file at \(name).")
        }
        try Self.checkPermissions(opened.fileDescriptor, ancestor: false)
        return opened
    }

    func lock(_ name: String, wait: Bool = false) throws -> FileHandle {
        let handle = try file(name, writing: true, create: true)
        let flags = wait ? LOCK_EX : LOCK_EX | LOCK_NB
        while flock(handle.fileDescriptor, flags) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { throw ModelError("Another Refract instance is using this model. Try again when it finishes.") }
            throw Self.systemError("Locking model storage")
        }
        return handle
    }

    func parent(of relative: String, create: Bool = false) throws -> (directory: ManagedModelDirectory, name: String) {
        var parts = relative.components(separatedBy: "/")
        let leaf = parts.removeLast()
        try Self.name(leaf)
        var directory = self
        for name in parts { directory = try directory.child(name, create: create) }
        return (directory, leaf)
    }

    func remove(_ name: String, directory: Bool = false) throws {
        try Self.name(name)
        guard unlinkat(fd, name, directory ? AT_REMOVEDIR : 0) == 0 else { throw Self.systemError("Removing \(name)") }
    }

    func move(_ name: String, to destination: String) throws {
        try Self.name(name)
        try Self.name(destination)
        guard renameatx_np(fd, name, fd, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw Self.systemError("Moving model package")
        }
    }

    func names() throws -> [String] {
        // The directory and every ancestor were checked before handing a pathname to Foundation.
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
}
