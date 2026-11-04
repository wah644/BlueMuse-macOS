// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BlueMuseMac", platforms: [.macOS(.v13)], products: [.executable(name: "BlueMuseMac", targets: ["BlueMuseMac"])], targets: [.target(name: "BlueMuseCore"), .executableTarget(name: "BlueMuseMac", dependencies: ["BlueMuseCore"]), .testTarget(name: "BlueMuseCoreTests", dependencies: ["BlueMuseCore"], resources: [.copy("Fixtures")]), .testTarget(name: "BlueMuseMacTests", dependencies: ["BlueMuseMac", "BlueMuseCore"])])
