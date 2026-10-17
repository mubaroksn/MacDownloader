import Darwin
import Foundation

/// Writes segments straight to their final offsets in one file with `pwrite(2)`.
///
/// - No part files and no merge step: half the disk I/O and no 2x free-space requirement.
/// - `pwrite` takes an explicit offset and doesn't move a shared file position, so all
///   workers can write concurrently through one descriptor without locking.
/// - Space is reserved up front with `F_PREALLOCATE` (macOS has no `posix_fallocate`) and the
///   logical size set with `ftruncate`, so a full disk fails at second zero, not at 97 %.
final class FileSink: @unchecked Sendable {
    let url: URL
    private let fd: Int32
    private var closed = false

    /// - Parameters:
    ///   - expectedSize: total size when known; enables preallocation.
    ///   - truncate: start from an empty file (fresh download) instead of resuming.
    init(url: URL, expectedSize: Int64?, truncate: Bool) throws {
        self.url = url
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | (truncate ? O_TRUNC : 0)
        let descriptor = open(url.path, flags, 0o644)
        guard descriptor >= 0 else { throw DownloadEngineError.io(operation: "open", code: errno) }
        fd = descriptor
        do {
            if let size = expectedSize, size > 0 { try preallocate(size) }
        } catch {
            Darwin.close(descriptor)
            closed = true
            throw error
        }
    }

    deinit { close() }

    private func preallocate(_ size: Int64) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DownloadEngineError.io(operation: "fstat", code: errno) }
        if info.st_size >= size { return } // resuming into an already sized file

        try Self.ensureFreeSpace(size - info.st_size, at: url.deletingLastPathComponent())

        var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL),
                             fst_posmode: Int32(F_PEOFPOSMODE),
                             fst_offset: 0,
                             fst_length: off_t(size - info.st_size),
                             fst_bytesalloc: 0)
        if fcntl(fd, F_PREALLOCATE, &store) == -1 {
            // Contiguous space unavailable: accept any extents.
            store.fst_flags = UInt32(F_ALLOCATEALL)
            if fcntl(fd, F_PREALLOCATE, &store) == -1 {
                let code = errno
                if code == ENOSPC { throw DownloadEngineError.insufficientSpace(needed: size, available: -1) }
                // ENOTSUP/EINVAL (SMB, exFAT, …): fall through to a sparse file.
            }
        }
        guard ftruncate(fd, off_t(size)) == 0 else {
            let code = errno
            throw code == ENOSPC
                ? DownloadEngineError.insufficientSpace(needed: size, available: -1)
                : DownloadEngineError.io(operation: "ftruncate", code: code)
        }
    }

    static func ensureFreeSpace(_ needed: Int64, at directory: URL) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < needed {
            throw DownloadEngineError.insufficientSpace(needed: needed, available: available)
        }
    }

    /// Writes the first `count` bytes of `data` at `offset`, handling short writes and EINTR.
    func write(_ data: Data, count: Int, at offset: Int64) throws {
        precondition(count <= data.count)
        guard count > 0 else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = count
            var position = off_t(offset)
            while remaining > 0 {
                let written = pwrite(fd, pointer, remaining, position)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == ENOSPC { throw DownloadEngineError.insufficientSpace(needed: Int64(remaining), available: 0) }
                    throw DownloadEngineError.io(operation: "pwrite", code: code)
                }
                remaining -= written
                position += off_t(written)
                pointer = pointer.advanced(by: written)
            }
        }
    }

    func truncate(to size: Int64) throws {
        guard ftruncate(fd, off_t(size)) == 0 else { throw DownloadEngineError.io(operation: "ftruncate", code: errno) }
    }

    /// Flushes to stable storage before the file is renamed into place.
    func synchronize() throws {
        guard fsync(fd) == 0 else { throw DownloadEngineError.io(operation: "fsync", code: errno) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
