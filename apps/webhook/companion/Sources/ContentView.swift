//! The phone's screen: link status, then one editable row per watch row.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RowStore
    @EnvironmentObject private var link: WatchLink
    @Environment(\.openURL) private var openURL
    @State private var lastRun: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusRow(state: link.state, name: link.watchName)
                    if case .failed(let message) = link.state {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let problem = link.lastProblem {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }
                    if link.state == .ready {
                        Button("Send the list again") {
                            link.answer()
                        }
                        Button("Read the pairing secret again", role: .destructive) {
                            link.forgetSecret()
                        }
                    }
                    if let lastRun {
                        Text(lastRun).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Rows on the watch") {
                    ForEach(store.rows.indices, id: \.self) { index in
                        RowEditor(row: $store.rows[index])
                            .opacity(store.rows[index].isRunnable ? 1 : 0.55)
                            .swipeActions {
                                Button("Clear") { store.clear(index) }
                            }
                    }
                }

                Section {
                    Text("A row runs on this phone: a Shortcut by name, or a POST to your webhook. "
                         + "Nothing but the row names goes to the watch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Shortcuts")
            .onChange(of: store.rows) {
                // The watch keeps a copy in NAND; send the new names now, not on its next ask.
                if link.state == .ready { link.answer() }
            }
            .task { await watch() }
        }
    }

    /// Runs for the life of the screen: the link is long-lived, so the handler is installed once.
    private func watch() async {
        link.onEvent = { event in
            switch event {
            case .linked, .asked:
                link.answer()
            case .run(let index):
                run(index)
            case .lost:
                break
            }
        }
        link.start()
    }

    /// Runs row `index`, then acks the watch either way.
    private func run(_ index: Int) {
        guard store.rows.indices.contains(index) else {
            link.send(H1.ack(index, ok: false))
            return
        }
        let row = store.rows[index]
        lastRun = "Running “\(row.watchName)”…"
        Task {
            let ok = await Runner.run(row, index: index) { openURL($0) }
            lastRun = ok ? "Ran “\(row.watchName)”" : "“\(row.watchName)” failed"
            link.send(H1.ack(index, ok: ok))
        }
    }
}

private struct StatusRow: View {
    let state: WatchLink.State
    let name: String?

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(colour).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let name, state == .ready || state == .connecting {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var title: String {
        switch state {
        case .off: "Not connected"
        case .scanning: "Looking for the watch…"
        case .connecting: "Connecting…"
        case .readingSecret: "Reading the pairing secret…"
        case .ready: "Connected"
        case .failed: "Problem"
        }
    }

    private var colour: Color {
        switch state {
        case .ready: .green
        case .failed: .red
        case .off: .secondary
        default: .orange
        }
    }
}

private struct RowEditor: View {
    @Binding var row: Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name on the watch", text: $row.name)
                .textInputAutocapitalization(.words)
                .onChange(of: row.name) {
                    // The watch shows 23 bytes, cut on a character boundary.
                    if row.name.utf8.count > 23 { row.name = row.watchName }
                }
            Picker("Action", selection: $row.action) {
                ForEach(Row.Action.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(
                row.action == .shortcut ? "Shortcut name, exactly as in Shortcuts" : "https://…",
                text: $row.target
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(row.action == .webhook ? .URL : .default)
            if !row.target.isEmpty && !row.isRunnable {
                Text(row.action == .shortcut ? "Needs a Shortcut name" : "Needs an http(s) URL")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
