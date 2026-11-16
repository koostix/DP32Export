import Foundation

/// A plain-English reason why something was not done.
public struct Refusal: Error, CustomStringConvertible, Equatable, LocalizedError {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
    public var errorDescription: String? { reason }
}

/// A regular file opened for reading only. Symlinks are not followed.
public final class ReadOnlyFile {
    public let path: String
    public let size: UInt64
    private let fd: Int32

    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String) throws {
        let shortName = (path as NSString).lastPathComponent
        let handle = open(path, O_RDONLY | O_NOFOLLOW)
        guard handle >= 0 else { throw Refusal("\(shortName) could not be opened for reading") }
        var st = stat()
        guard fstat(handle, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else {
            close(handle)
            throw Refusal("\(shortName) is not a regular file")
        }
        self.path = path
        self.size = UInt64(st.st_size)
        self.fd = handle
    }

    deinit { close(fd) }

    /// Fills the whole buffer from the given offset, or throws.
    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        var done = 0
        while done < buffer.count {
            let got = pread(fd, base + done, buffer.count - done, off_t(offset) + off_t(done))
            if got < 0 {
                if errno == EINTR { continue }
                throw Refusal("\(name) could not be read")
            }
            if got == 0 { throw Refusal("\(name) ended before the audio the edit list asks for") }
            done += got
        }
    }

    public func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        try out.withUnsafeMutableBytes { try read(at: offset, into: $0) }
        return out
    }
}

/// A new file. Creation fails if anything already has that name.
public final class NewFile {
    public let path: String
    private var fd: Int32

    public init(path: String) throws {
        let handle = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard handle >= 0 else {
            throw Refusal("\((path as NSString).lastPathComponent) could not be created")
        }
        self.path = path
        self.fd = handle
    }

    deinit { if fd >= 0 { close(fd) } }

    public func append(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        var done = 0
        while done < buffer.count {
            let put = write(fd, base + done, buffer.count - done)
            if put < 0 {
                if errno == EINTR { continue }
                throw Refusal("writing \((path as NSString).lastPathComponent) failed (is the disk full?)")
            }
            done += put
        }
    }

    public func append(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try append($0) }
    }

    public func finish() throws {
        let handle = fd
        fd = -1
        if close(handle) != 0 {
            throw Refusal("closing \((path as NSString).lastPathComponent) failed")
        }
    }
}

public enum EntryKind { case file, directory, other }

/// What a path is, without following a symlink. Nil when nothing is there.
public func entryKind(_ path: String) -> EntryKind? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    switch st.st_mode & S_IFMT {
    case S_IFREG: return .file
    case S_IFDIR: return .directory
    default: return .other
    }
}

/// Names in a directory, sorted, without dot files.
public func visibleNames(in directory: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.filter { !$0.hasPrefix(".") }.sorted()
}

@inline(__always) func le16(_ b: [UInt8], _ o: Int) -> UInt16 {
    UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}

@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}

@inline(__always) func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
    UInt64(le32(b, o)) | (UInt64(le32(b, o + 4)) << 32)
}
