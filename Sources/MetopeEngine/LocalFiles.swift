import Foundation
import Darwin
import MetopeCore

/// All destination traversal is relative to an open directory. No symlink component is followed.
final class LocalDirectory {
    private let descriptor: Int32
    init(path: String) throws {
        descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure(path) }
    }
    deinit { Darwin.close(descriptor) }
    private static func failure(_ path: String) -> MTPError {
        MTPError(detail: "Couldn’t access “\(path)”: \(String(cString: strerror(errno)))")
    }
    private func parent(_ relative: String, create: Bool) throws -> (Int32, String) {
        try TransferSafety.validateRemotePath("/" + relative)
        var components = relative.split(separator: "/").map(String.init)
        let name = components.removeLast()
        var fd = dup(descriptor)
        guard fd >= 0 else { throw Self.failure(relative) }
        do {
            for component in components {
                if create && mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { throw Self.failure(relative) }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure(relative) }
                Darwin.close(fd); fd = next
            }
            return (fd, name)
        } catch { Darwin.close(fd); throw error }
    }
    func directory(_ relative: String) throws {
        let (fd, name) = try parent(relative, create: true); defer { Darwin.close(fd) }
        if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw Self.failure(relative) }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw Self.failure(relative) }; Darwin.close(child)
    }
    func create(_ relative: String) throws -> FileHandle {
        let (fd, name) = try parent(relative, create: true); defer { Darwin.close(fd) }
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.failure(relative) }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }
    func read(_ relative: String, expected: Int64) throws -> FileHandle {
        let (fd, name) = try parent(relative, create: false); defer { Darwin.close(fd) }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure(relative) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == expected else {
            Darwin.close(file); throw MTPError(detail: "The source file changed after transfer preparation: \(relative)")
        }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }
    static func modificationDate(_ handle: FileHandle) throws -> Date {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw failure("file metadata") }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
    static func setModificationDate(_ date: Date?, on handle: FileHandle) throws {
        guard let date else { return }
        var times = [timeval(tv_sec: Int(Date().timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
        guard futimes(handle.fileDescriptor, &times) == 0 else { throw failure("file modification date") }
    }

}
