// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MensurCore",
    products: [.library(name: "MensurCore", targets: ["MensurCore"])],
    targets: [
        .target(name: "MensurCore", path: "Mensur/Core"),
        .testTarget(name: "MensurCoreTests", dependencies: ["MensurCore"], path: "MensurTests")
    ]
)
