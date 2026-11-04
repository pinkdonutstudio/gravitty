// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Gravitty",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [.executableTarget(name: "Gravitty", dependencies: ["SwiftTerm", "Sparkle"])]
)
