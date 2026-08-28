// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "bsp-mux",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "bsp-mux", targets: ["bsp-mux"]),
    .executable(name: "fake-bsp-backend", targets: ["fake-bsp-backend"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-tools-protocols.git", exact: "0.0.10"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-clocks.git", from: "1.0.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "BSPMuxCore",
      dependencies: [
        .product(name: "BuildServerProtocol", package: "swift-tools-protocols"),
        .product(name: "LanguageServerProtocolTransport", package: "swift-tools-protocols"),
        .product(name: "SKLogging", package: "swift-tools-protocols"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "Clocks", package: "swift-clocks"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "bsp-mux",
      dependencies: ["BSPMuxCore"]
    ),
    .executableTarget(
      name: "fake-bsp-backend",
      dependencies: [
        .product(name: "BuildServerProtocol", package: "swift-tools-protocols"),
        .product(name: "LanguageServerProtocolTransport", package: "swift-tools-protocols"),
      ]
    ),
    .testTarget(
      name: "BSPMuxCoreTests",
      dependencies: [
        "BSPMuxCore",
        .product(name: "Clocks", package: "swift-clocks"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "BSPMuxIntegrationTests",
      dependencies: ["BSPMuxCore"]
    ),
  ]
)
