// swift-tools-version: 6.0
// xtool builds this into the iOS app (`xtool dev build --ipa`). The sources are the parent package's, reached
// through `Sources` below: one copy of the code, two manifests, because `swift test` on Linux must leave out
// CoreBluetooth and SwiftUI.

import PackageDescription

let package = Package(
    name: "ShortcutsWatch",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ShortcutsWatch", targets: ["ShortcutsWatch"]),
    ],
    targets: [
        // Swift 5 language mode, like the Xcode target: the CoreBluetooth delegates in `WatchLink.swift` pass
        // non-Sendable CB objects across actors, which Swift 6 mode rejects.
        .target(
            name: "ShortcutsWatch",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
