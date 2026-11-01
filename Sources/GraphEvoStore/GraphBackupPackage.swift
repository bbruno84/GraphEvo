import zlib
import CryptoKit
import Darwin
import Foundation

/// GEB container v1: a bounded plaintext manifest followed by one raw DEFLATE stream.
/// The manifest inventory defines file boundaries; archive-controlled paths/links are never extracted.
enum GraphBackupPackage {
    static let fileExtension = "geb"
    static let headerBytes = 64
    private static let magic = Data("GEBACKUP".utf8)
    private static let bufferBytes = 256 * 1024

    struct Header: Sendable {
        let manifest: GraphBackupManifest
        let manifestBytes: Int
        let payloadBytes: UInt64
    }

    static func header(at url: URL, limits: GraphBackupLimits) throws -> Header {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size <= limits.maximumPackageBytes, size >= UInt64(headerBytes) else { throw GraphBackupError.invalidBackup }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let prefix = try read(file, count: headerBytes)
        guard prefix.prefix(8) == magic, integer(prefix, 8, 4) == 1,
              integer(prefix, 12, 4) == 1 else { throw GraphBackupError.invalidBackup }
        let length = integer(prefix, 16, 8), packed = integer(prefix, 24, 8)
        guard length > 0, length <= 4 * 1024 * 1024,
              length <= size - UInt64(headerBytes), packed == size - UInt64(headerBytes) - length else { throw GraphBackupError.invalidBackup }
        let json = try read(file, count: Int(length))
        guard Data(SHA256.hash(data: json)) == prefix.suffix(32) else { throw GraphBackupError.invalidBackup }
        let manifest = try JSONDecoder().decode(GraphBackupManifest.self, from: json)
        try validateInventory(manifest, limits: limits)
        return Header(manifest: manifest, manifestBytes: Int(length), payloadBytes: packed)
    }

    static func pack(_ directory: URL, manifest: GraphBackupManifest, to destination: URL,
                     limits: GraphBackupLimits) throws {
        try validateInventory(manifest, limits: limits)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(manifest)
        guard json.count <= 4 * 1024 * 1024,
              UInt64(headerBytes + json.count) <= limits.maximumPackageBytes else { throw GraphBackupError.limitExceeded }
        let output = try exclusiveFile(destination); defer { try? output.close() }
        try output.write(contentsOf: prefix(json, packed: 0)); try output.write(contentsOf: json)
        var index = 0, input: FileHandle?
        defer { try? input?.close() }
        try transform(encoding: true, read: {
            while index < manifest.files.count {
                if input == nil { input = try FileHandle(forReadingFrom: directory.appendingPathComponent(manifest.files[index].path)) }
                let data = try input!.read(upToCount: bufferBytes) ?? Data()
                if !data.isEmpty { return data }
                try input!.close(); input = nil; index += 1
            }
            return nil
        }, write: { data in
            guard try output.offset() <= limits.maximumPackageBytes,
                  UInt64(data.count) <= limits.maximumPackageBytes - (try output.offset()) else { throw GraphBackupError.limitExceeded }
            try output.write(contentsOf: data)
        })
        let size = try output.offset()
        try output.seek(toOffset: 0)
        try output.write(contentsOf: prefix(json, packed: size - UInt64(headerBytes + json.count)))
        try output.close()
    }

    /// Destination is an owned fresh stage, never an application or existing backup directory.
    static func unpack(_ url: URL, to directory: URL, limits: GraphBackupLimits) throws -> GraphBackupManifest {
        let value = try header(at: url, limits: limits), manifest = value.manifest
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        try input.seek(toOffset: UInt64(headerBytes + value.manifestBytes))
        var remaining = value.payloadBytes, index = 0, offset: UInt64 = 0
        var output: FileHandle?
        defer { try? output?.close() }
        func advance() throws {
            while index < manifest.files.count && output == nil {
                let target = directory.appendingPathComponent(manifest.files[index].path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                output = try exclusiveFile(target); offset = 0
                if manifest.files[index].bytes != 0 { return }
                try output!.close(); output = nil; index += 1
            }
        }
        try advance()
        try transform(encoding: false, read: {
            if remaining == 0 { return nil }
            let data = try read(input, count: Int(min(remaining, UInt64(bufferBytes))))
            remaining -= UInt64(data.count); return data
        }, write: { data in
            var consumed = 0
            while consumed < data.count {
                guard index < manifest.files.count, let file = output else { throw GraphBackupError.limitExceeded }
                let count = Int(min(UInt64(data.count - consumed), manifest.files[index].bytes - offset))
                try file.write(contentsOf: data.subdata(in: consumed..<(consumed + count)))
                consumed += count; offset += UInt64(count)
                if offset == manifest.files[index].bytes {
                    try file.close(); output = nil; index += 1; try advance()
                }
            }
        })
        guard index == manifest.files.count, remaining == 0 else { throw GraphBackupError.invalidBackup }
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        return manifest
    }

    private static func validateInventory(_ manifest: GraphBackupManifest, limits: GraphBackupLimits) throws {
        guard manifest.files.count <= limits.maximumFiles,
              manifest.files.map(\.path) == manifest.files.map(\.path).sorted(),
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw GraphBackupError.invalidBackup }
        var total: UInt64 = 0, entries = Set<String>()
        for file in manifest.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count > 1, parts.count <= 64, ["payload", "artifacts"].contains(String(parts[0])),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") && $0.utf8.count <= 255 }),
                  file.bytes <= limits.maximumBytes - min(total, limits.maximumBytes),
                  file.sha256.count == 64 else { throw GraphBackupError.invalidBackup }
            total += file.bytes
            for depth in 1...parts.count {
                entries.insert(parts.prefix(depth).joined(separator: "/"))
                guard entries.count <= limits.maximumFiles else { throw GraphBackupError.limitExceeded }
            }
        }
    }

    private static func prefix(_ json: Data, packed: UInt64) -> Data {
        var result = magic
        for (value, width) in [(UInt64(1), 4), (UInt64(1), 4), (UInt64(json.count), 8), (packed, 8)] {
            for byte in (0..<width).reversed() { result.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        result.append(Data(SHA256.hash(data: json))); return result
    }
    private static func integer(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
        data[start..<(start + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: count - result.count), !chunk.isEmpty else { throw GraphBackupError.invalidBackup }
            result.append(chunk)
        }
        return result
    }
    private static func exclusiveFile(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GraphBackupError.invalidDestination }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func copy(_ source: URL, to destination: URL, maximumBytes: UInt64) throws {
        let input = try FileHandle(forReadingFrom: source), output = try exclusiveFile(destination)
        defer { try? input.close(); try? output.close() }
        var bytes: UInt64 = 0
        while let data = try input.read(upToCount: bufferBytes), !data.isEmpty {
            try Task.checkCancellation()
            guard UInt64(data.count) <= maximumBytes - min(bytes, maximumBytes) else { throw GraphBackupError.limitExceeded }
            bytes += UInt64(data.count); try output.write(contentsOf: data)
        }
        try output.close()
    }

    /// All buffers are bounded independently of archive size. End markers and unused input
    /// are checked explicitly: neither truncation nor concatenated/trailing streams are accepted.
    private static func transform(encoding: Bool,
                                  read: () throws -> Data?, write: (Data) throws -> Void) throws {
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferBytes)
        defer { output.deallocate() }
        var stream = z_stream()
        let initialized = encoding
            ? deflateInit2_(&stream, 5, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw GraphBackupError.invalidBackup }
        defer { if encoding { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        var chunk = try read()
        while true {
            try Task.checkCancellation()
            let next = chunk == nil ? nil : try read(), final = next == nil
            let data = chunk ?? Data()
            let ended = try data.withUnsafeBytes { raw -> Bool in
                stream.next_in = UnsafeMutablePointer(mutating: raw.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(output))
                stream.avail_in = uInt(raw.count)
                repeat {
                    try Task.checkCancellation()
                    stream.next_out = output; stream.avail_out = uInt(bufferBytes)
                    let before = stream.avail_in
                    let status = encoding ? deflate(&stream, final ? Z_FINISH : Z_NO_FLUSH) : inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END else { throw GraphBackupError.invalidBackup }
                    let count = bufferBytes - Int(stream.avail_out)
                    if count > 0 { try write(Data(bytes: output, count: count)) }
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw GraphBackupError.invalidBackup }
                        return true
                    }
                    if !final, stream.avail_in == 0, stream.avail_out > 0 { return false }
                    guard count > 0 || stream.avail_in < before else { throw GraphBackupError.invalidBackup }
                } while true
            }
            if ended {
                guard next == nil else { throw GraphBackupError.invalidBackup }
                return
            }
            guard !final else { throw GraphBackupError.invalidBackup }
            chunk = next
        }
    }

    static func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached { try body() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
