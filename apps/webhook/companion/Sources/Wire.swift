//! The watch's BLE channel, from the phone's side: framing, AES-CBC with the pairing secret, CRC32, and the `h1`
//! messages. No CoreBluetooth here, so this file builds and runs on a Mac or on Linux (`swift test`).

import Foundation

/// Frame layout from the SDK's `docs/abi-1.4.md`: `F5 ‖ len:u16be ‖ c1 ‖ 00 01 ‖ 00 01 ‖ c2 ‖ body`.
enum Frame {
    static let head: UInt8 = 0xF5
    static let headerSize = 11
    static let system: UInt16 = 0xFFFF
    static let iv: [UInt8] = [0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
                              0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x5A]

    static func build(c1: UInt16, c2: UInt16, payload: [UInt8], key: [UInt8]) -> [UInt8] {
        let body = seal(payload, key: key)
        var out: [UInt8] = [head]
        append(&out, UInt16(body.count))
        append(&out, c1)
        append(&out, 1)
        append(&out, 1)
        append(&out, c2)
        out += body
        return out
    }

    private static func append(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }
}

/// `AES-128-CBC(K, IV, PKCS7(plain ‖ crc32le(plain)))`.
func seal(_ plain: [UInt8], key: [UInt8]) -> [UInt8] {
    var body = plain
    let crc = CRC32.checksum(plain)
    body += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 24) & 0xFF)]
    let pad = 16 - body.count % 16
    body += [UInt8](repeating: UInt8(pad), count: pad)
    return AES.encryptCBC(body, key: key, iv: Frame.iv)
}

/// The reverse of `seal`. `nil` for bad padding or a bad CRC: on a shared link that is another host's frame.
func open(_ sealed: [UInt8], key: [UInt8]) -> [UInt8]? {
    guard !sealed.isEmpty, sealed.count % 16 == 0 else { return nil }
    guard let padded = AES.decryptCBC(sealed, key: key, iv: Frame.iv) else { return nil }
    guard let pad = padded.last, pad >= 1, Int(pad) <= 16, Int(pad) <= padded.count else { return nil }
    let body = Array(padded[..<(padded.count - Int(pad))])
    guard body.count >= 4 else { return nil }
    let plain = Array(body[..<(body.count - 4)])
    let tail = body[(body.count - 4)...]
    let crc = UInt32(tail[tail.startIndex])
        | UInt32(tail[tail.startIndex + 1]) << 8
        | UInt32(tail[tail.startIndex + 2]) << 16
        | UInt32(tail[tail.startIndex + 3]) << 24
    guard crc == CRC32.checksum(plain) else { return nil }
    return plain
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    /// The zlib CRC the watch uses, not CRC-32/MPEG-2.
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A reply the stub sends in the clear (`0x0048`), where the header's length counts a CRC the body does not carry.
func isClearReply(c1: UInt16, c2: UInt16) -> Bool { c1 == Frame.system && c2 == 0x0048 }

/// Reassembles frames spread over several notifications. `F5` can appear inside a body, so only the header's length
/// decides where a frame ends.
struct FrameParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ data: [UInt8]) -> [(c1: UInt16, c2: UInt16, body: [UInt8])] {
        buffer += data
        var out: [(UInt16, UInt16, [UInt8])] = []
        while true {
            guard let start = buffer.firstIndex(of: Frame.head) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= Frame.headerSize else { break }
            let length = Int(buffer[1]) << 8 | Int(buffer[2])
            let c1 = UInt16(buffer[3]) << 8 | UInt16(buffer[4])
            let c2 = UInt16(buffer[9]) << 8 | UInt16(buffer[10])
            // A watch → phone `0x0048` in the clear declares a length that includes a CRC it does not send.
            let size = isClearReply(c1: c1, c2: c2) ? length - 4 : length
            guard size >= 0, buffer.count >= Frame.headerSize + size else { break }
            let body = Array(buffer[Frame.headerSize..<(Frame.headerSize + size)])
            out.append((c1, c2, body))
            buffer.removeFirst(Frame.headerSize + size)
        }
        return out
    }
}

/// What the watch asks of the phone, and what the phone answers. `../src/model.rs` is the other half.
enum H1 {
    static let ask: [UInt8] = Array("h1R".utf8)

    static func run(_ message: [UInt8]) -> Int? {
        guard message.count == 4, message[0...2].elementsEqual(Array("h1N".utf8)) else { return nil }
        return Int(message[3])
    }

    static func begin(_ count: Int) -> [UInt8] { Array("h1L".utf8) + [UInt8(count & 0xFF)] }

    /// A name longer than 23 bytes is cut on a char boundary, as the watch's own `Slot::set` does.
    static func slot(_ index: Int, name: String) -> [UInt8] {
        Array("h1S".utf8) + [UInt8(index & 0xFF)] + clip(name)
    }

    static func end(_ count: Int) -> [UInt8] { Array("h1E".utf8) + [UInt8(count & 0xFF)] }

    static func ack(_ row: Int, ok: Bool) -> [UInt8] { Array("h1A".utf8) + [UInt8(row & 0xFF), ok ? 0 : 1] }

    /// 23 bytes, cut on a UTF-8 boundary so the watch's `&str` read stays valid.
    static func clip(_ name: String, max: Int = 23) -> [UInt8] {
        let bytes = Array(name.utf8)
        guard bytes.count > max else { return bytes }
        // Shorten until the prefix is a whole number of characters, so the watch's `&str` read stays valid.
        var keep = max
        while keep > 0, String(bytes: bytes.prefix(keep), encoding: .utf8) == nil { keep -= 1 }
        return Array(bytes.prefix(keep))
    }
}

/// One message at a time, because the watch's inbox holds four (`fw/wp2-core/src/chan.rs`, `DEPTH`).
/// The phone writes a message and waits for the watch's reply before the next, so a seven-message list cannot
/// overflow the inbox, and a reply that never comes is retried instead of stalling the queue.
struct Outbox {
    /// What the watch's reply means for the queue.
    enum Outcome: Equatable {
        /// The message went through; the next one may be written.
        case accepted
        /// "Not now" (busy, full, a popup covers the app): write the same message again shortly.
        case retry
        /// The watch refused it outright; the queue was dropped.
        case refused(UInt8)
        /// Too many refusals or silence; the queue was dropped.
        case gaveUp
    }

    /// Status bytes that mean "not now": the same message goes again.
    private static let transient: Set<UInt8> = [5, 8, 9]
    static let maxAttempts = 9

    private var queue: [[UInt8]] = []
    private(set) var inflight: [UInt8]?
    private(set) var attempts = 0

    var isEmpty: Bool { queue.isEmpty && inflight == nil }

    /// Replaces the queue (a new list) or appends to it (a single ack).
    mutating func push(_ messages: [[UInt8]], replacing: Bool) {
        guard replacing else {
            queue.append(contentsOf: messages)
            return
        }
        queue.removeAll()
        // The attempt count belongs to the messages just dropped: a new list must not inherit a nearly-exhausted
        // budget and be abandoned on its first retry. Any message already on the wire is left alone, so its ack
        // still matches what was sent.
        attempts = 0
        queue.append(contentsOf: messages)
    }

    /// The next message to write, or `nil` when the queue is empty or one is already in flight.
    /// `attempts` deliberately survives a requeue: it counts tries for this message, not for this call.
    mutating func next() -> [UInt8]? {
        guard inflight == nil, !queue.isEmpty else { return nil }
        let message = queue.removeFirst()
        inflight = message
        return message
    }

    /// The watch replied.
    mutating func settle(status: UInt8?) -> Outcome {
        guard let status else { return .retry }
        if status == 0 {
            inflight = nil
            attempts = 0
            return .accepted
        }
        if Self.transient.contains(status) {
            guard let inflight else { return .accepted }
            attempts += 1
            if attempts >= Self.maxAttempts {
                self.inflight = nil
                queue.removeAll()
                return .gaveUp
            }
            queue.insert(inflight, at: 0)
            self.inflight = nil
            return .retry
        }
        inflight = nil
        queue.removeAll()
        return .refused(status)
    }

    /// No reply arrived: the message goes back to the front, up to `maxAttempts` times.
    mutating func timedOut() -> Outcome {
        guard let inflight else { return .accepted }
        attempts += 1
        if attempts >= Self.maxAttempts {
            self.inflight = nil
            queue.removeAll()
            return .gaveUp
        }
        queue.insert(inflight, at: 0)
        self.inflight = nil
        return .retry
    }

    mutating func clear() {
        queue.removeAll()
        inflight = nil
        attempts = 0
    }
}
