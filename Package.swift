// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Refract",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "Refract", targets: ["Refract"])],
    targets: [
        .executableTarget(name: "Refract"),
        .testTarget(name: "RefractTests", dependencies: ["Refract"])
    ],
    swiftLanguageModes: [.v5]
)
