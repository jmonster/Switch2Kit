// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [.library(name: "Switch2Kit", targets: ["Switch2Kit"])]
var targets: [Target] = [
    .target(name: "Switch2Kit", swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "Switch2KitNavigationExample", dependencies: ["Switch2Kit"],
            path: "Examples/NavigationSupport", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "Switch2KitTests", dependencies: ["Switch2Kit", "Switch2KitNavigationExample"],
                path: "Tests/Switch2KitTests", swiftSettings: [.swiftLanguageMode(.v6)])
]
#if os(macOS)
products += [
    .executable(name: "Switch2KitApp", targets: ["Switch2KitApp"]),
    .executable(name: "Switch2KitDemo", targets: ["Switch2KitDemo"])
]
targets += [
    .executableTarget(name: "Switch2KitApp", dependencies: ["Switch2Kit"],
                      swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "Switch2KitDemo", dependencies: ["Switch2Kit", "Switch2KitNavigationExample"],
                      path: "Examples/Switch2KitDemo", swiftSettings: [.swiftLanguageMode(.v6)])
]
#endif
let package = Package(name: "Switch2Kit", platforms: [.macOS(.v15)], products: products, targets: targets)
