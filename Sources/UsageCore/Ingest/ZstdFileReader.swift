import Foundation
import CZstd

/// Reads a Zstandard-compressed file sequentially and returns the decompressed bytes.
///
/// Codex compresses its older session files in place (`rollout-….jsonl.zst`), and they are immutable once
/// written. The reader decodes with a fixed-size window, so memory use does not depend on the file size.
/// Files made of several concatenated frames are handled, and a file that ends in the middle of a frame is
/// reported as truncated instead of silently yielding a short result.
final class ZstdFileReader {
    struct DecodeError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private let fd: Int32
    private let stream: OpaquePointer
    private var input: UnsafeMutableRawPointer
    private let inputCapacity: Int
    private var inputSize = 0
    private var inputPos = 0
    private var reachedEndOfFile = false
    /// The decoder's last return value: 0 means a frame has just completed, anything else means more input is needed.
    private var frameHint = 0
    private var sawAnyData = false

    init(fd: Int32) throws {
        self.fd = fd
        guard let s = ZSTD_createDStream() else { throw DecodeError(message: "could not create the zstd decoder") }
        stream = s
        inputCapacity = ZSTD_DStreamInSize()
        input = UnsafeMutableRawPointer.allocate(byteCount: inputCapacity, alignment: 16)
        let rc = ZSTD_initDStream(s)
        if ZSTD_isError(rc) != 0 {
            ZSTD_freeDStream(s)
            input.deallocate()
            throw DecodeError(message: String(cString: ZSTD_getErrorName(rc)))
        }
    }

    deinit {
        ZSTD_freeDStream(stream)
        input.deallocate()
    }

    /// Decodes up to `capacity` bytes into `buffer`. Returns 0 at the end of the data.
    func read(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> Int {
        var output = ZSTD_outBuffer(dst: UnsafeMutableRawPointer(buffer), size: capacity, pos: 0)
        while output.pos == 0 {
            if inputPos >= inputSize {
                if reachedEndOfFile {
                    // The file ended. That is only valid between frames.
                    if sawAnyData && frameHint != 0 { throw DecodeError(message: "the compressed file is truncated") }
                    return 0
                }
                let n = readRetrying()
                if n < 0 { throw DecodeError(message: String(cString: strerror(errno))) }
                if n == 0 { reachedEndOfFile = true; continue }
                inputSize = n
                inputPos = 0
                sawAnyData = true
            }
            var inBuf = ZSTD_inBuffer(src: UnsafeRawPointer(input), size: inputSize, pos: inputPos)
            let hint = ZSTD_decompressStream(stream, &output, &inBuf)
            if ZSTD_isError(hint) != 0 { throw DecodeError(message: "the compressed data is damaged: \(String(cString: ZSTD_getErrorName(hint)))") }
            inputPos = inBuf.pos
            frameHint = hint
            // A completed frame resets the decoder so that a following frame can be decoded as well.
            if hint == 0 && inputPos >= inputSize && reachedEndOfFile { break }
        }
        return output.pos
    }

    private func readRetrying() -> Int {
        while true {
            let n = Foundation.read(fd, input, inputCapacity)
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }
}
