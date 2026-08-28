// swift-tools-version: 6.0
import PackageDescription

// Invoices Retriever deliberately ships without third-party dependencies.
// The app holds every credential the user owns and runs community-authored
// content; each dependency we add is another way for that to go wrong (M6).
// SQLite, WebKit, PDFKit, Vision, Security and CryptoKit all come from the SDK.
let package = Package(
    name: "InvoicesRetriever",
    // FR and EN at v1, as the specification's internationalisation requirement
    // asks. English is the source language and its strings are the keys.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IRCore", targets: ["IRCore"]),
        .library(name: "IRBrowser", targets: ["IRBrowser"]),
        .executable(name: "InvoicesRetriever", targets: ["InvoicesRetrieverApp"]),
        .executable(name: "irctl", targets: ["irctl"]),
        .executable(name: "irtest", targets: ["irtest"]),
    ],
    targets: [
        .target(
            name: "IRCore",
            // Two rules on purpose: `copy` keeps bundled-plugins/ a directory,
            // which the catalogue loader walks, while `process` is what places
            // the .lproj folders where NSBundle looks for them.
            resources: [.copy("Resources"), .process("Localization")]
        ),
        .target(
            name: "IRBrowser",
            dependencies: ["IRCore"]
        ),
        .executableTarget(
            name: "InvoicesRetrieverApp",
            dependencies: ["IRCore", "IRBrowser"],
            path: "Sources/InvoicesRetriever",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "irctl",
            dependencies: ["IRCore", "IRBrowser"]
        ),
        // The test suite is an executable rather than a testTarget: Apple's
        // Command Line Tools ship neither XCTest nor swift-testing, so a
        // contributor without the full Xcode could not otherwise run it.
        .executableTarget(
            name: "irtest",
            dependencies: ["IRCore"]
        ),
    ]
)
