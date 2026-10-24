// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CapsFlow",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CapsFlow", targets: ["CapsFlow"]), .executable(name: "CoreChecks", targets: ["CoreChecks"]),
               .executable(name: "CapsFlowInputMethod", targets: ["CapsFlowInputMethod"])],
    targets: [
        .target(name: "InputCore", resources: [.process("Resources")]),
        .executableTarget(name: "CapsFlow", dependencies: ["InputCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "CapsFlowInputMethod", dependencies: ["InputCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "CoreChecks", dependencies: ["InputCore"], path: "Tests/InputCoreTests",
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
