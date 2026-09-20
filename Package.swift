// swift-tools-version: 6.2
import PackageDescription

var radioDependencies: [Target.Dependency] = []
#if os(Linux)
radioDependencies = [.target(name: "Switch2KitDBus")]
#elseif os(Windows)
radioDependencies = [.target(name: "Switch2KitWinRT")]
#endif
var products: [Product] = [.library(name: "Switch2Kit", targets: ["Switch2Kit"])]
#if os(Windows)
// PE exports are generated for product targets, not merely their transitive
// dependencies. Keep the shared engine's Swift symbols in this same DLL.
products.append(.library(name: "Switch2KitC", type: .dynamic, targets: ["Switch2KitC", "Switch2Kit"]))
#else
products.append(.library(name: "Switch2KitC", type: .dynamic, targets: ["Switch2KitC"]))
#endif
var targets: [Target] = [
    .target(name: "Switch2KitCABI"),
    .target(name: "Switch2KitC", dependencies: ["Switch2Kit", "Switch2KitCABI"],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "Switch2KitCTests", dependencies: ["Switch2Kit", "Switch2KitC", "Switch2KitCABI"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
    // Compile the actual native SDL fixture during swift test, not just its separate CMake build.
    .testTarget(name: "Switch2KitSDLFixtureTests", dependencies: ["Switch2Kit", "Switch2KitC", "Switch2KitCABI"],
                path: "tests/sdl-inprocess",
                exclude: ["CMakeLists.txt", "Clock.cpp", "Clock.hpp", "main.cpp", "motion.cpp", "verify.sh", "run.sh", "version_test.py"],
                sources: ["Fixture.swift", "FixtureTests.swift"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "Switch2Kit", dependencies: radioDependencies, path: "Sources/Switch2Kit", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "Switch2KitTests", dependencies: [.target(name: "Switch2Kit")] + radioDependencies, path: "Tests/Switch2KitTests",
                swiftSettings: [.swiftLanguageMode(.v6)])
]
#if os(Linux)
targets.append(.target(name: "Switch2KitDBus", linkerSettings: [.linkedLibrary("dl")]))
#endif
#if os(Windows)
targets.append(.target(name: "Switch2KitWinRT", cxxSettings: [.define("NOMINMAX"), .define("WIN32_LEAN_AND_MEAN")],
                       linkerSettings: [.linkedLibrary("windowsapp")]))
#endif
#if os(macOS)
products += [
    .executable(name: "Switch2KitApp", targets: ["Switch2KitApp"]),
    .executable(name: "Switch2KitDemo", targets: ["Switch2KitDemo"])
]
targets += [
    .executableTarget(name: "Switch2KitApp", dependencies: ["Switch2Kit"],
                      path: "Sources/Switch2KitApp", swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "Switch2KitDemo", dependencies: ["Switch2Kit"], path: "Examples/Switch2KitDemo",
                      swiftSettings: [.swiftLanguageMode(.v6)])
]
#endif
let package = Package(name: "Switch2Kit", platforms: [.iOS(.v18), .macOS(.v15)], products: products, targets: targets, cxxLanguageStandard: .cxx20)
