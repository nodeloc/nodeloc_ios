// swift-tools-version: 6.2
//
// Compiles the app's Foundation-only core (nodeloc/Core/Kit, linked in as
// Sources/NodelocCore/Kit) as a package, so the API client, the adapter that
// shapes the new backend's JSON for the existing screens, and the realtime
// stream can be built and unit-tested without Xcode — including on Linux.
// The app target compiles the very same files; nothing here is shipped.

import PackageDescription

let appLikeSettings: [SwiftSetting] = [
    // Mirrors the app target's build settings, so a file means the same thing
    // in both places.
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "NodelocKit",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "NodelocCore", targets: ["NodelocCore"]),
    ],
    targets: [
        .target(name: "NodelocCore", swiftSettings: appLikeSettings),
        .testTarget(
            name: "NodelocCoreTests",
            dependencies: ["NodelocCore"],
            resources: [.copy("Fixtures")],
            // XCTestCase's initializers are nonisolated, so the test target
            // keeps the default isolation and marks main-actor tests itself.
            swiftSettings: Array(appLikeSettings.dropFirst())
        ),
    ],
    swiftLanguageModes: [.v5]
)
