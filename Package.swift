// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Joryio",
    // iOS only. macOS 10.15 used to be declared here while every target
    // imports UIKit, so the declaration promised a platform the package has
    // never compiled for - `swift build` on a Mac failed on the first import.
    platforms: [
        .iOS(.v14)
    ],
    // Three products, one package - the common shape of mobile messaging
    // SDKs (a core module and a UI module). An app links `Joryio` for tracking, identity and
    // push, and adds `JoryioUI` only if it wants the SDK to DRAW in-app
    // messages. Leaving JoryioUI out means no WebKit and no message views are
    // linked at all, which is a procurement question for some security teams
    // rather than a size preference.
    //
    // `JoryioNotificationServiceExtension` is for the Notification Service
    // Extension TARGET only. It depends on nothing - no SQLite, no UIKit, no
    // `UIApplication.shared` - because an app extension may only link
    // extension-safe code, and the main `Joryio` product is not (it drives
    // UIApplication for push registration, badges and background flushes).
    products: [
        .library(
            name: "Joryio",
            targets: ["Joryio"]
        ),
        .library(
            name: "JoryioUI",
            targets: ["JoryioUI"]
        ),
        .library(
            name: "JoryioNotificationServiceExtension",
            targets: ["JoryioNotificationServiceExtension"]
        ),
    ],
    dependencies: [
        // SQLite for the offline event queue.
        //
        // Capped below 0.17.0: SQLite.swift 0.17.0 raised its own minimum to
        // iOS 15, and SwiftPM refuses a library whose platform minimum is lower
        // than a dependency's ("the library 'Joryio' requires ios 14.0, but
        // depends on the product 'SQLite' which requires ios 15.0"). Our own
        // Package.resolved pins 0.15.4, so this package's tests never saw it -
        // but an APP resolves the newest allowed version, and every app, the
        // React Native bridge and the Unity build (which all take this package
        // since CocoaPods trunk went read-only, D199) would fail. Lift the cap
        // together with raising `platforms` to iOS 15.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", "0.15.0"..<"0.17.0"),
    ],
    targets: [
        .target(
            name: "Joryio",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Sources/Joryio",
            // Apple's privacy manifest: the required-reason API the SDK uses
            // (UserDefaults, CA92.1) and the data it collects. JoryioUI and the
            // notification extension use no required-reason API.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "JoryioUI",
            dependencies: ["Joryio"],
            path: "Sources/JoryioUI"
        ),
        .target(
            name: "JoryioNotificationServiceExtension",
            dependencies: [],
            path: "Sources/JoryioNotificationServiceExtension"
        ),
        .testTarget(
            name: "JoryioUITests",
            dependencies: ["Joryio", "JoryioUI", "JoryioNotificationServiceExtension"],
            path: "Tests/JoryioUITests"
        ),
    ]
)
