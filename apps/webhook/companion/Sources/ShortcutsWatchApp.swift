//! The app's entry point and the objects the views share.

import SwiftUI

@main
struct ShortcutsWatchApp: App {
    @StateObject private var store: RowStore
    @StateObject private var link: WatchLink

    init() {
        let store = RowStore()
        let link = WatchLink()
        link.names = { [weak store] in store?.watchNames ?? [] }
        _store = StateObject(wrappedValue: store)
        _link = StateObject(wrappedValue: link)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(link)
        }
    }
}
