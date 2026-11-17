//! Host tests for the phone-side protocol. They run on Linux with `swift test`: no CoreBluetooth, no simulator.

import XCTest

@testable import ShortcutsWatchCore

private func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        let end = hex.index(start, offsetBy: 2)
        return UInt8(hex[start..<end], radix: 16)!
    }
}

extension Array where Element == UInt8 {
    fileprivate init(bytes_hex hex: String) { self = bytes(hex) }
}

final class AESTests: XCTestCase {
    /// FIPS-197 appendix C.1.
    func testEncryptMatchesFips197() {
        let key = bytes("000102030405060708090a0b0c0d0e0f")
        let plain = bytes("00112233445566778899aabbccddeeff")
        let cipher = bytes("69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertEqual(AES.encryptBlock(plain, key: key), cipher)
        XCTAssertEqual(AES.decryptBlock(cipher, key: key), plain)
    }

    /// SP 800-38A F.2.1, CBC.
    func testCBCMatchesNist() {
        let key = bytes("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = bytes("000102030405060708090a0b0c0d0e0f")
        let plain = bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let sealed = AES.encryptCBC(plain, key: key, iv: iv)
        XCTAssertEqual(sealed, bytes("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"))
        XCTAssertEqual(AES.decryptCBC(sealed, key: key, iv: iv), plain)
    }
}

final class WireTests: XCTestCase {
    private let key: [UInt8] = stride(from: 0, to: 32, by: 2).map { UInt8($0 / 2) }

    /// The zlib CRC the watch uses, not CRC-32/MPEG-2.
    func testCRC32MatchesZlib() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum([]), 0)
    }

    func testSealOpensWithTheSameKey() {
        for plain in [Array("h1R".utf8), Array("h1N".utf8) + [3], [UInt8](repeating: 0x41, count: 128)] {
            let sealed = seal(plain, key: key)
            XCTAssertEqual(sealed.count % 16, 0)
            XCTAssertEqual(open(sealed, key: key), plain)
        }
    }

    /// Another host's frame on a shared link must not open.
    func testForeignFramesDoNotOpen() {
        let sealed = seal(Array("h1R".utf8), key: key)
        XCTAssertNil(open(sealed, key: [UInt8](repeating: 0x99, count: 16)))
        XCTAssertNil(open([], key: key))
        XCTAssertNil(open([0x00, 0x01, 0x02], key: key))
        var flipped = sealed
        flipped[0] ^= 0xFF
        XCTAssertNil(open(flipped, key: key))
    }

    func testFrameLayout() {
        let frame = Frame.build(c1: 0xFFFF, c2: 0x90A5, payload: [0xFF, 0x41, 0x42, 0x43], key: key)
        XCTAssertEqual(frame[0], 0xF5)
        // 4 B payload + 4 B CRC + 8 B padding fills one block exactly.
        XCTAssertEqual(frame[1], 0x00)
        XCTAssertEqual(frame[2], 0x10)
        XCTAssertEqual(Array(frame[3...6]), [0xFF, 0xFF, 0x00, 0x01])
        XCTAssertEqual(Array(frame[7...10]), [0x00, 0x01, 0x90, 0xA5])
        XCTAssertEqual(open(Array(frame[11...]), key: key), [0xFF, 0x41, 0x42, 0x43])
    }

    /// A `F5` inside a body must not be taken for the next frame's start.
    func testParserKeepsABodyTogether() {
        let payload: [UInt8] = [0xF5, 0xF5, 0xF5, 0x41]
        let frame = Frame.build(c1: 0xFFFF, c2: 0x90A5, payload: payload, key: key)
        var parser = FrameParser()
        var frames: [(c1: UInt16, c2: UInt16, body: [UInt8])] = []
        for byte in frame { frames += parser.feed([byte]) }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.c1, 0xFFFF)
        XCTAssertEqual(frames.first?.c2, 0x90A5)
        XCTAssertEqual(open(frames[0].body, key: key), payload)
    }

    func testParserSkipsGarbageAndJoinsNotifications() {
        let frame = Frame.build(c1: 0xFFFF, c2: 0xB0A6, payload: [1, 0, 0x68], key: key)
        var parser = FrameParser()
        var got = parser.feed([0x00, 0x11] + Array(frame.prefix(5)))
        XCTAssertTrue(got.isEmpty)
        got += parser.feed(Array(frame.dropFirst(5)))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.c2, 0xB0A6)
    }

    /// Golden bytes produced by the SDK's own Python host (`wp2apps/link.py`) with key `00…0f`.
    /// If this fails, the phone and the watch no longer understand each other.
    func testSealMatchesTheSdkPythonHost() {
        let key = Array(UInt8(0)..<UInt8(16))
        let cases: [(String, String)] = [
            ("h1R", "c5dcc2644c65b878b7ef767c90df4185"),
            ("h1N\u{02}", "424518540be877a65adc0142bb24681b"),
            ("h1L\u{06}", "db5632199a8243b97873dbf9fd38696f"),
            ("h1S\u{02}Garage", "52e79b2794368561cf141c14cbded578"),
            ("h1E\u{06}", "1426466b861bfe3e52d40382ccbfabb0"),
            ("h1A\u{02}\u{00}", "c47dc107cc560f9b0b88450994c01f7a"),
        ]
        for (plain, expected) in cases {
            let bytes = Array(plain.utf8)
            XCTAssertEqual(seal(bytes, key: key), [UInt8](bytes_hex: expected), plain)
            // And the phone must read the watch's own frames back.
            XCTAssertEqual(open([UInt8](bytes_hex: expected), key: key), bytes, plain)
        }
    }

    /// A full watch → phone event, as the stub sends it: `seq ‖ slot ‖ "h1N\u{02}"`.
    func testWatchEventDecodesToATap() {
        let key = Array(UInt8(0)..<UInt8(16))
        let event = Array("h1N".utf8) + [2]
        let plain: [UInt8] = [7, 0xFF] + event
        let frame = Frame.build(c1: Frame.system, c2: 0xB0A6, payload: plain, key: key)
        var parser = FrameParser()
        let frames = parser.feed(frame)
        XCTAssertEqual(frames.count, 1)
        let opened = open(frames[0].body, key: key)
        XCTAssertEqual(opened.map { Array($0.dropFirst(2)) }, event)
        XCTAssertEqual(H1.run(Array(opened!.dropFirst(2))), 2)
    }

    /// The shell's `0x0048` reply is not encrypted and its length counts a CRC that is not sent.
    func testClearReplyFrameIsRead() {
        var frame: [UInt8] = [0xF5, 0x00, 0x08] // 4 B body + 4 B of CRC the body lacks
        frame += [0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01, 0x00, 0x48]
        frame += Array("OK\r\n".utf8)
        var parser = FrameParser()
        let frames = parser.feed(frame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.c2, 0x0048)
        XCTAssertEqual(frames.first.map { String(decoding: $0.body, as: UTF8.self) }, "OK\r\n")
    }

    func testH1Messages() {
        XCTAssertEqual(H1.begin(6), Array("h1L".utf8) + [6])
        XCTAssertEqual(H1.slot(2, name: "Garage"), Array("h1S".utf8) + [2] + Array("Garage".utf8))
        XCTAssertEqual(H1.end(6), Array("h1E".utf8) + [6])
        XCTAssertEqual(H1.ack(2, ok: true), Array("h1A".utf8) + [2, 0])
        XCTAssertEqual(H1.ack(2, ok: false), Array("h1A".utf8) + [2, 1])
        XCTAssertEqual(H1.run(Array("h1N".utf8) + [2]), 2)
        XCTAssertNil(H1.run(Array("h1R".utf8)))
        XCTAssertNil(H1.run(Array("h1N".utf8)))
        XCTAssertNil(H1.run(Array("x1N".utf8) + [2]))
    }

    /// The watch reads names as `&str`: never split a multi-byte character.
    func testNamesAreClippedOnACharBoundary() {
        let clipped = H1.clip(String(repeating: "é", count: 20))
        XCTAssertEqual(clipped.count, 22)
        XCTAssertEqual(String(decoding: clipped, as: UTF8.self).count, 11)
        XCTAssertEqual(H1.clip("Garage"), Array("Garage".utf8))
    }

    /// The whole answer to `h1R`, as the phone builds it: every message inside the watch's 128 B.
    func testListBatchFitsTheWatch() {
        let names = ["Garage", "Salon", "Café", "Porte", "Musique", "Nuit"]
        var messages = [H1.begin(names.count)]
        messages += names.enumerated().map { H1.slot($0.offset, name: $0.element) }
        messages.append(H1.end(names.count))
        for message in messages {
            XCTAssertLessThanOrEqual(message.count, 128)
        }
        // `h1S` is 3 B, then the row index, then the name.
        XCTAssertEqual(String(decoding: messages[3].dropFirst(4), as: UTF8.self), "Café")
    }
}

final class OutboxTests: XCTestCase {
    /// The watch's inbox holds four (`chan.rs` `DEPTH`); a 6-row list is eight messages. Writing them all at once
    /// is what a naive client does and what makes rows go missing, so only one may be in flight.
    func testOnlyOneMessageIsWrittenAtATime() {
        var box = Outbox()
        let list = (0..<8).map { Array("h1S".utf8) + [UInt8($0)] }
        box.push(list, replacing: true)

        var written: [[UInt8]] = []
        while let message = box.next() {
            written.append(message)
            XCTAssertNil(box.next(), "a second message was written before the first was acknowledged")
            box.settle(status: 0)
        }
        XCTAssertEqual(written, list)
    }

    /// A refusal that means "not now" must repeat the same message, in order, not skip it.
    func testTransientStatusRepeatsTheSameMessage() {
        var box = Outbox()
        let first: [UInt8] = Array("h1L".utf8) + [2]
        let second: [UInt8] = Array("h1S".utf8) + [0] + Array("A".utf8)
        box.push([first, second], replacing: true)

        XCTAssertEqual(box.next(), first)
        XCTAssertEqual(box.settle(status: 8), .retry)   // inbox full
        XCTAssertEqual(box.next(), first, "the full inbox must not lose the message")
        XCTAssertEqual(box.settle(status: 5), .retry)   // busy
        XCTAssertEqual(box.next(), first)
        XCTAssertEqual(box.settle(status: 0), .accepted)
        XCTAssertEqual(box.next(), second)
    }

    /// A hard refusal (no app running) drops the rest: retrying would only repeat the same error.
    func testHardRefusalDropsTheQueue() {
        var box = Outbox()
        box.push([[1], [2], [3]], replacing: true)
        XCTAssertEqual(box.next(), [1])
        XCTAssertEqual(box.settle(status: 7), .refused(7))
        XCTAssertTrue(box.isEmpty)
        XCTAssertNil(box.next())
    }

    /// Silence must not wedge the queue: it is retried, then abandoned so the UI can say so.
    func testSilenceIsRetriedThenAbandoned() {
        var box = Outbox()
        box.push([[1]], replacing: true)
        XCTAssertEqual(box.next(), [1])
        var outcomes: [Outbox.Outcome] = []
        for _ in 0..<Outbox.maxAttempts {
            outcomes.append(box.timedOut())
            if outcomes.last == .retry { XCTAssertEqual(box.next(), [1]) }
        }
        XCTAssertEqual(outcomes.last, .gaveUp)
        XCTAssertTrue(box.isEmpty)
    }

    /// A new list replaces the old one: a half-sent stale list must not follow the new names.
    func testNewListReplacesTheQueue() {
        var box = Outbox()
        box.push([[1], [2], [3]], replacing: true)
        XCTAssertEqual(box.next(), [1])
        box.push([[9]], replacing: true)
        XCTAssertEqual(box.settle(status: 0), .accepted)
        XCTAssertEqual(box.next(), [9])
        XCTAssertNil(box.next())
    }

    /// An ack is appended, not replacing: it must not cancel a list that is still being pushed.
    func testAckIsAppendedToTheQueue() {
        var box = Outbox()
        box.push([[1]], replacing: true)
        XCTAssertEqual(box.next(), [1])
        box.push([[7]], replacing: false)
        XCTAssertEqual(box.settle(status: 0), .accepted)
        XCTAssertEqual(box.next(), [7])
    }

    /// A fresh list gets a fresh retry budget: a stale list that was nearly abandoned must not poison it.
    func testNewListGetsAFreshRetryBudget() {
        var box = Outbox()
        box.push([[1]], replacing: true)
        // Spend almost the whole budget on the old list, leaving it queued but not in flight.
        for _ in 0..<(Outbox.maxAttempts - 1) {
            XCTAssertEqual(box.next(), [1])
            XCTAssertEqual(box.settle(status: 8), .retry)
        }
        box.push([[2]], replacing: true)
        XCTAssertEqual(box.next(), [2], "the new list must still be written")
        XCTAssertEqual(box.settle(status: 8), .retry, "and must not be abandoned on its first refusal")
    }

    /// A message already on the wire is left in flight when a new list arrives, so its late ack still matches it
    /// instead of being applied to the wrong message.
    func testReplaceKeepsTheMessageOnTheWire() {
        var box = Outbox()
        box.push([[1]], replacing: true)
        XCTAssertEqual(box.next(), [1])
        box.push([[2]], replacing: true)
        XCTAssertNil(box.next(), "one message at a time: the old one is still awaiting its ack")
        XCTAssertEqual(box.settle(status: 0), .accepted)
        XCTAssertEqual(box.next(), [2])
    }
}
