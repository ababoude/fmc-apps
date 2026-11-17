//! What a row does when the watch taps it: no network, no watch, just the decision and the Shortcut URL.

import Foundation
import XCTest

@testable import ShortcutsWatchCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RunnerTests: XCTestCase {
    func testShortcutPlanUsesTheTrimmedName() {
        let row = Row(name: "Garage", action: .shortcut, target: "  Open the garage ")
        XCTAssertEqual(Runner.plan(row), .shortcut("Open the garage"))
    }

    func testEmptyTargetsDoNothing() {
        XCTAssertEqual(Runner.plan(Row(name: "A", action: .shortcut, target: "   ")), .nothing)
        XCTAssertEqual(Runner.plan(Row(name: "A", action: .webhook, target: "")), .nothing)
    }

    func testOnlyHttpWebhooksAreAccepted() {
        XCTAssertEqual(
            Runner.plan(Row(name: "A", action: .webhook, target: "https://example.com/hook")),
            .webhook(URL(string: "https://example.com/hook")!)
        )
        XCTAssertEqual(
            Runner.plan(Row(name: "A", action: .webhook, target: "http://192.168.1.4:8080/go")),
            .webhook(URL(string: "http://192.168.1.4:8080/go")!)
        )
        for bad in ["ftp://example.com", "file:///etc/passwd", "example.com/hook", "javascript:alert(1)"] {
            XCTAssertEqual(Runner.plan(Row(name: "A", action: .webhook, target: bad)), .nothing, bad)
        }
    }

    func testShortcutURLRunsByName() throws {
        let url = try XCTUnwrap(Runner.shortcutURL(name: "Open the garage"))
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "run-shortcut")
        // The name must be percent-encoded, not spliced in raw.
        XCTAssertEqual(url.absoluteString, "shortcuts://run-shortcut?name=Open%20the%20garage")
    }

    func testRunShortcutOpensTheURLAndSucceeds() async {
        let row = Row(name: "Garage", action: .shortcut, target: "Open the garage")
        var opened: URL?
        let ok = await Runner.run(row, index: 0) { opened = $0 }
        XCTAssertTrue(ok)
        XCTAssertEqual(opened?.absoluteString, "shortcuts://run-shortcut?name=Open%20the%20garage")
    }

    func testRunWebhookReportsFailure() async {
        let row = Row(name: "Hook", action: .webhook, target: "https://example.com/hook")
        let failing = await Runner.run(row, index: 2, open: { _ in }) { _, _ in
            throw URLError(.timedOut)
        }
        XCTAssertFalse(failing)

        var sentRow: Int?
        let ok = await Runner.run(row, index: 2, open: { _ in }) { _, index in sentRow = index }
        XCTAssertTrue(ok)
        XCTAssertEqual(sentRow, 2)
    }

    /// The name the watch shows is the clipped one, and a tap is still runnable.
    func testLongNamesAreStillRunnable() {
        let row = Row(name: String(repeating: "A", count: 40), action: .shortcut, target: "x")
        XCTAssertEqual(row.watchName.count, 23)
        XCTAssertTrue(row.isRunnable)
    }

    /// The ack the watch gets is `ok`, so a 4xx must not be reported as a sent webhook (and a 2xx must).
    func testWebhookStatusRule() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/hook"))
        for code in [200, 201, 204] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                                        headerFields: nil))
            XCTAssertTrue(Runner.isSuccess(response), "\(code)")
        }
        for code in [301, 400, 404, 500] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                                        headerFields: nil))
            XCTAssertFalse(Runner.isSuccess(response), "\(code)")
        }
        XCTAssertFalse(Runner.isSuccess(nil))
        XCTAssertFalse(Runner.isSuccess(URLResponse(url: url, mimeType: nil,
                                                   expectedContentLength: 0, textEncodingName: nil)))
    }
}
