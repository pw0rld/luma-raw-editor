// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LumaRAW", platforms: [.macOS(.v13)], products: [
    .executable(name: "LumaRAW", targets: ["LumaRAW"]),
    .library(name: "LumaCore", targets: ["LumaCore"])
], targets: [
    .target(name: "LumaCore"),
    .executableTarget(name: "LumaRAW", dependencies: ["LumaCore"]),
    .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"])
], swiftLanguageModes: [.v5])
