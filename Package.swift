// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMeter",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "AgentMeterPreview", targets: ["AgentMeterApp"]),
        .executable(name: "agent-meter", targets: ["AgentMeterCLI"]),
        .executable(name: "agent-meter-bridge", targets: ["AgentMeterBridge"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AgentMeterCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "AgentMeterCLI", dependencies: ["AgentMeterCore"]),
        .executableTarget(name: "AgentMeterApp", dependencies: ["AgentMeterCore"]),
        .executableTarget(name: "AgentMeterBridge", linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(name: "AgentMeterChecks", dependencies: ["AgentMeterCore"], path: "Tests/AgentMeterCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
