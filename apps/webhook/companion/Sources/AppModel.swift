//! Rows, their persistence, and what a tap does: run a Shortcut or POST to a webhook.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One watch row. `name` is the only thing sent to the watch; the action never leaves the phone.
struct Row: Identifiable, Codable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case shortcut
        case webhook

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shortcut: "Shortcut"
            case .webhook: "Webhook"
            }
        }
    }

    var id = UUID()
    var name: String = ""
    var action: Action = .shortcut
    /// A Shortcut's name, or the webhook URL.
    var target: String = ""

    /// What the watch shows: 23 bytes at most, never splitting a character (the watch reads it as `&str`).
    var watchName: String { String(decoding: H1.clip(name), as: UTF8.self) }

    var isRunnable: Bool { Runner.plan(self) != .nothing }
}

/// Runs an action. Separate from the UI so it can be exercised off-device, and so the network call is one place.
enum Runner {
    /// `shortcuts://run-shortcut?name=…`: the Shortcuts app opens and runs it.
    static func shortcutURL(name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// What a row does, decided before any I/O so the UI and the tests agree.
    enum Plan: Equatable {
        case shortcut(String)
        case webhook(URL)
        case nothing
    }

    static func plan(_ row: Row) -> Plan {
        let target = row.target.trimmingCharacters(in: .whitespacesAndNewlines)
        switch row.action {
        case .shortcut:
            return target.isEmpty ? .nothing : .shortcut(target)
        case .webhook:
            guard let url = URL(string: target), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http"
            else { return .nothing }
            return .webhook(url)
        }
    }

    /// POSTs `{"row": n, "source": "watch"}`; any 2xx counts as done, anything else throws.
    static func post(_ url: URL, row: Int, session: URLSession = .shared) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: ["row": row, "source": "watch"])
        let (_, response) = try await session.data(for: request)
        guard isSuccess(response) else { throw URLError(.badServerResponse) }
    }

    /// A webhook is done when the server said 2xx. Split out so the rule is testable without a server.
    static func isSuccess(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// `true` when the action ran. The watch gets that as the ack's status byte.
    @MainActor
    static func run(_ row: Row, index: Int, open: (URL) -> Void,
                    post: (URL, Int) async throws -> Void = { try await Runner.post($0, row: $1) }) async -> Bool {
        switch plan(row) {
        case .nothing:
            return false
        case .shortcut(let name):
            guard let url = shortcutURL(name: name) else { return false }
            open(url)
            return true
        case .webhook(let url):
            do {
                try await post(url, index)
                return true
            } catch {
                return false
            }
        }
    }
}
