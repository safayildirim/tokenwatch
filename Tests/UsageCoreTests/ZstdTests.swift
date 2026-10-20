import XCTest
import CryptoKit
@testable import UsageCore

final class ZstdReaderTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    private func expected(_ name: String) throws -> (bytes: Int, sha256: String, lines: Int) {
        let data = try Data(contentsOf: fixture("expected.json"))
        let all = try JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
        let e = all[name]!
        return (e["bytes"] as! Int, e["sha256"] as! String, e["lines"] as! Int)
    }

    /// Decodes a whole file using a deliberately small output buffer, so that many reads are needed.
    private func decode(_ url: URL, chunk: Int = 4096) throws -> Data {
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let reader = try ZstdFileReader(fd: fd)
        var out = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        while true {
            let n = try reader.read(into: buffer, capacity: chunk)
            if n == 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }

    func testDecodesExactlyWhatTheReferenceToolCompressed() throws {
        for name in ["sample.jsonl.zst", "multiframe.jsonl.zst", "big.jsonl.zst"] {
            let e = try expected(name)
            let data = try decode(fixture(name))
            XCTAssertEqual(data.count, e.bytes, name)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), e.sha256, name)
            XCTAssertEqual(data.filter { $0 == 0x0A }.count, e.lines, name)
        }
    }

    func testOutputBufferSizeDoesNotChangeTheResult() throws {
        let e = try expected("big.jsonl.zst")
        for chunk in [1, 7, 1000, 65_536, 1 << 20] {
            let data = try decode(fixture("big.jsonl.zst"), chunk: chunk == 1 ? 1 : chunk)
            if chunk == 1 { XCTAssertEqual(data.count, e.bytes) } else { XCTAssertEqual(data.count, e.bytes, "chunk \(chunk)") }
        }
    }

    func testTruncatedFileIsReportedNotReturnedShort() throws {
        XCTAssertThrowsError(try decode(fixture("truncated.jsonl.zst"))) { error in
            XCTAssertTrue("\(error)".contains("truncated"), "\(error)")
        }
    }

    func testCorruptDataIsReported() throws {
        XCTAssertThrowsError(try decode(fixture("corrupt.jsonl.zst")))
    }

    func testEmptyAndNonZstdInput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.zst")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertEqual(try decode(empty).count, 0, "an empty file has no data and is not an error")
        let text = dir.appendingPathComponent("plain.zst")
        try "this is not compressed data at all".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try decode(text))
    }
}
