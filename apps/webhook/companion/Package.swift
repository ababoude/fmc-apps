// swift-tools-version: 6.0
// The phone-side protocol as a package, so its tests run on Linux with `swift test`. The iOS app target pulls the
// same `Sources/` in through Xcode (`project.yml`), which is why this package holds only the CoreBLE-free files.

import PackageDescription

let package = Package(
    name: "ShortcutsWatchCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShortcutsWatchCore", targets: ["ShortcutsWatchCore"]),
    ],
    targets: [
        .target(
            name: "ShortcutsWatchCore",
            path: "Sources",
            // UI and CoreBluetooth need iOS; the protocol and the action plan run on Linux too.
            exclude: ["WatchLink.swift", "RowStore.swift", "ContentView.swift", "ShortcutsWatchApp.swift"]
        ),
        .testTarget(name: "ShortcutsWatchCoreTests", dependencies: ["ShortcutsWatchCore"], path: "Tests"),
    ]
)
