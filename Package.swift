// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ApertureCue",
    platforms: [.macOS(.v13)],
    products: [.library(name: "MappingCore", targets: ["MappingCore"]),
               .executable(name: "ApertureCue", targets: ["ApertureCue"])],
    targets: [
        .target(name: "MappingCore"),
        .executableTarget(name: "ApertureCue", dependencies: ["MappingCore"]),
        .testTarget(name: "MappingCoreTests", dependencies: ["MappingCore"])
    ]
)
