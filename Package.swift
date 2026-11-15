// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimbiaCaptions",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "SimbiaCaptions", targets: ["SimbiaCaptions"]),
        .executable(name: "simbia", targets: ["simbia"]),
    ],
    targets: [
        // Project file, composition and the caption/title renderer — shared by the app and the CLI,
        // so a frame Claude renders headlessly is the frame the app shows.
        .target(name: "SimbiaCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SimbiaCaptions", dependencies: ["SimbiaCore"]),
        .executableTarget(name: "simbia", dependencies: ["SimbiaCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
