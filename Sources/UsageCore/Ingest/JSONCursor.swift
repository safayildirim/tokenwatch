import Foundation

/// This cursor moves forward over one line of JSON held in memory.
///
/// Session logs contain very large values (tool output, file contents, model responses) next to the
/// handful of small fields this application needs. Decoding whole lines into Foundation objects
/// would allocate gigabytes during an initial import and would also copy conversation text into
/// memory for no reason. The cursor instead walks the structure, reads only the members the caller
/// asks for, and skips everything else without ever materializing it.
struct JSONCursor {
    let base: UnsafePointer<UInt8>
    let end: Int
    var i: Int

    init(_ buffer: UnsafeBufferPointer<UInt8>) {
        self.base = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
        self.end = buffer.count
        self.i = 0
    }

    // MARK: Character helpers

    @inline(__always) var atEnd: Bool { i >= end }
    @inline(__always) var peek: UInt8 { i < end ? base[i] : 0 }

    @inline(__always) mutating func skipWhitespace() {
        while i < end {
            let c = base[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
    }

    @inline(__always) mutating func consume(_ c: UInt8) -> Bool {
        skipWhitespace()
        if i < end && base[i] == c { i += 1; return true }
        return false
    }

    // MARK: Strings

    /// The raw bytes of a string literal, without the surrounding quotes and with escapes intact.
    struct RawString {
        let start: Int
        let end: Int
    }

    /// True if the string contains a backslash. Checked lazily because skipped strings (the vast
    /// majority) never need it.
    @inline(__always) func hasEscapes(_ s: RawString) -> Bool {
        s.end > s.start && memchr(base + s.start, 0x5C, s.end - s.start) != nil
    }

    /// Reads a string literal starting at the current position.
    mutating func readRawString() -> RawString? {
        skipWhitespace()
        guard i < end, base[i] == 0x22 else { return nil }
        i += 1
        let start = i
        while i < end {
            guard let hit = memchr(base + i, 0x22, end - i) else { return nil }
            let q = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            // Count the backslashes immediately before the quote: an odd count means it is escaped.
            var backslashes = 0
            var k = q - 1
            while k >= start && base[k] == 0x5C { backslashes += 1; k -= 1 }
            i = q + 1
            if backslashes % 2 == 0 { return RawString(start: start, end: q) }
        }
        return nil
    }

    /// Compares a raw string against an ASCII literal. Only valid for strings without escapes,
    /// which is always the case for the object keys this parser looks for.
    @inline(__always) func equals(_ s: RawString, _ literal: StaticString) -> Bool {
        let n = s.end - s.start
        guard n == literal.utf8CodeUnitCount, !hasEscapes(s) else { return false }
        return memcmp(base + s.start, literal.utf8Start, n) == 0
    }

    func string(_ s: RawString) -> String {
        let len = s.end - s.start
        if len == 0 { return "" }
        let buf = UnsafeBufferPointer(start: base + s.start, count: len)
        if !hasEscapes(s) { return String(decoding: buf, as: UTF8.self) }
        return JSONCursor.unescape(buf)
    }

    static func unescape(_ buf: UnsafeBufferPointer<UInt8>) -> String {
        var out = [UInt8]()
        out.reserveCapacity(buf.count)
        var k = 0
        while k < buf.count {
            let c = buf[k]
            if c != 0x5C { out.append(c); k += 1; continue }
            k += 1
            guard k < buf.count else { break }
            switch buf[k] {
            case 0x6E: out.append(0x0A)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x75:
                var code: UInt32 = 0
                var n = 0
                while n < 4, k + 1 < buf.count, let v = hexValue(buf[k + 1]) { code = code << 4 | v; k += 1; n += 1 }
                // Combine UTF-16 surrogate pairs.
                if code >= 0xD800, code < 0xDC00, k + 6 < buf.count, buf[k + 1] == 0x5C, buf[k + 2] == 0x75 {
                    var low: UInt32 = 0
                    var m = 0
                    var p = k + 2
                    while m < 4, p + 1 < buf.count, let v = hexValue(buf[p + 1]) { low = low << 4 | v; p += 1; m += 1 }
                    if low >= 0xDC00, low < 0xE000 {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        k = p
                    }
                }
                let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: out.append(buf[k])
            }
            k += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt32? {
        switch c {
        case 0x30...0x39: return UInt32(c - 0x30)
        case 0x41...0x46: return UInt32(c - 0x41 + 10)
        case 0x61...0x66: return UInt32(c - 0x61 + 10)
        default: return nil
        }
    }

    // MARK: Numbers, literals

    /// Reads a JSON number as a non-negative integer, accepting (and truncating) fractional values.
    mutating func readInt() -> Int64? {
        skipWhitespace()
        let start = i
        var negative = false
        if i < end, base[i] == 0x2D { negative = true; i += 1 }
        var value: Int64 = 0
        var digits = 0
        while i < end, base[i] >= 0x30, base[i] <= 0x39 {
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(base[i] - 0x30))
            if o1 || o2 { value = Int64.max } else { value = a }
            i += 1
            digits += 1
        }
        guard digits > 0 else { i = start; return nil }
        if i < end, base[i] == 0x2E || base[i] == 0x65 || base[i] == 0x45 {
            // Fractional or exponent form: fall back to a floating point parse.
            i = start
            guard let d = readDouble() else { return nil }
            if d.isNaN || d.isInfinite { return nil }
            return Int64(max(min(d, 9.0e18), -9.0e18))
        }
        return negative ? -value : value
    }

    mutating func readDouble() -> Double? {
        skipWhitespace()
        let start = i
        while i < end {
            let c = base[i]
            if (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45 { i += 1 } else { break }
        }
        guard i > start else { return nil }
        var tmp = [CChar](repeating: 0, count: min(i - start, 64) + 1)
        for k in 0..<(tmp.count - 1) { tmp[k] = CChar(bitPattern: base[start + k]) }
        return strtod(tmp, nil)
    }

    mutating func readBool() -> Bool? {
        skipWhitespace()
        if i + 4 <= end, memcmp(base + i, "true", 4) == 0 { i += 4; return true }
        if i + 5 <= end, memcmp(base + i, "false", 5) == 0 { i += 5; return false }
        return nil
    }

    // MARK: Skipping

    /// Advances past one complete value of any type. Returns false if the value is malformed or
    /// truncated, which is how partially written lines are detected.
    mutating func skipValue() -> Bool {
        skipWhitespace()
        guard i < end else { return false }
        switch base[i] {
        case 0x22:
            return readRawString() != nil
        case 0x7B, 0x5B:
            return skipContainer()
        case 0x74: // true
            guard i + 4 <= end else { return false }; i += 4; return true
        case 0x66: // false
            guard i + 5 <= end else { return false }; i += 5; return true
        case 0x6E: // null
            guard i + 4 <= end else { return false }; i += 4; return true
        default:
            let start = i
            while i < end {
                let c = base[i]
                if (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45 { i += 1 } else { break }
            }
            return i > start
        }
    }

    private mutating func skipContainer() -> Bool {
        var depth = 0
        while i < end {
            switch base[i] {
            case 0x22:
                guard readRawString() != nil else { return false }
                continue
            case 0x7B, 0x5B:
                depth += 1
            case 0x7D, 0x5D:
                depth -= 1
                if depth == 0 { i += 1; return true }
            default: break
            }
            i += 1
        }
        return false
    }

    // MARK: Objects

    /// Iterates the members of the object at the cursor. `body` receives the key and must either
    /// consume the value or return `false` to have the cursor skip it. Returns false when the
    /// object is malformed.
    mutating func forEachMember(_ body: (inout JSONCursor, RawString) -> Bool) -> Bool {
        guard consume(0x7B) else { return false }
        skipWhitespace()
        if peek == 0x7D { i += 1; return true }
        while true {
            guard let key = readRawString() else { return false }
            guard consume(0x3A) else { return false }
            skipWhitespace()
            let before = i
            let consumed = body(&self, key)
            if !consumed {
                i = before
                guard skipValue() else { return false }
            }
            skipWhitespace()
            if peek == 0x2C { i += 1; continue }
            if peek == 0x7D { i += 1; return true }
            return false
        }
    }
}

/// Parses the timestamps found in session logs without going through `DateFormatter`, which is far
/// too slow for hundreds of thousands of lines.
enum ISO8601Fast {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff]Z` (also with a numeric zone offset) to milliseconds since
    /// the Unix epoch.
    static func parse(_ s: String) -> Int64? {
        var result: Int64?
        var copy = s
        copy.withUTF8 { result = parse($0) }
        return result
    }

    static func parse(_ b: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard b.count >= 20 else { return nil }
        func d2(_ k: Int) -> Int? {
            let a = b[k], c = b[k + 1]
            guard a >= 0x30, a <= 0x39, c >= 0x30, c <= 0x39 else { return nil }
            return Int(a - 0x30) * 10 + Int(c - 0x30)
        }
        guard let c1 = d2(0), let c2 = d2(2), let mo = d2(5), let dd = d2(8),
              let hh = d2(11), let mi = d2(14), let ss = d2(17),
              b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20, b[13] == 0x3A, b[16] == 0x3A
        else { return nil }
        let year = c1 * 100 + c2
        var k = 19
        var millis = 0
        if k < b.count, b[k] == 0x2E {
            k += 1
            var scale = 100
            while k < b.count, b[k] >= 0x30, b[k] <= 0x39 {
                millis += Int(b[k] - 0x30) * scale
                scale /= 10
                k += 1
            }
        }
        var offsetSeconds = 0
        if k < b.count {
            if b[k] == 0x5A { /* Z */ }
            else if b[k] == 0x2B || b[k] == 0x2D {
                let sign = b[k] == 0x2D ? -1 : 1
                guard k + 2 < b.count, let oh = d2(k + 1) else { return nil }
                var om = 0
                if k + 4 < b.count {
                    let mk = b[k + 3] == 0x3A ? k + 4 : k + 3
                    if mk + 1 < b.count, let m = d2(mk) { om = m }
                }
                offsetSeconds = sign * (oh * 3600 + om * 60)
            } else { return nil }
        }
        let days = daysFromCivil(year: year, month: mo, day: dd)
        let seconds = Int64(days) * 86400 + Int64(hh * 3600 + mi * 60 + ss) - Int64(offsetSeconds)
        return seconds * 1000 + Int64(millis)
    }

    /// Returns the days since 1970-01-01 for a proleptic Gregorian date, using Howard Hinnant's algorithm.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
