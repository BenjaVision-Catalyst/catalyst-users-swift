// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CatalystUsersSwift", platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "CatalystUsers", targets: ["CatalystUsers"])],
    dependencies: [
        .package(url: "https://github.com/BenjaVisionPro/CatalystConnectSwift.git", revision: "867b1779e2685470ff3941814efe2b7651ba3eec"),
        .package(url: "https://github.com/BenjaVision-Catalyst/magritte-swift.git", revision: "420abc5ae5ef2140f3c62102dfabad5a7a30cac2")
    ],
    targets: [.target(name: "CatalystUsers", dependencies: [
        .product(name: "CatalystConnect", package: "CatalystConnectSwift"),
        .product(name: "CatalystConnectObjects", package: "CatalystConnectSwift"),
        .product(name: "Magritte", package: "magritte-swift")]),
        .testTarget(name: "CatalystUsersTests", dependencies: ["CatalystUsers", .product(name: "CatalystConnect", package: "CatalystConnectSwift"), .product(name: "CatalystConnectObjects", package: "CatalystConnectSwift"), .product(name: "Magritte", package: "magritte-swift")])]
)
