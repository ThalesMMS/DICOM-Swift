// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DICOMSwift",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.0"),
        .visionOS("26.0"),
        .macOS("26.0")
    ],
    products: [
        .library(name: "HL7v3CDA", targets: ["HL7v3CDA"]),
        .library(name: "HL7v3Transport", targets: ["HL7v3Transport"]),
        .library(name: "FHIR", targets: ["FHIR"]),
        .library(name: "ClinicalMapping", targets: ["ClinicalMapping"]),
        .library(name: "HL7MLLP", targets: ["HL7MLLP"]),
        .library(name: "HL7v2", targets: ["HL7v2"]),
        .library(name: "DicomCodecs", targets: ["DicomCodecs"]),
        .library(name: "DicomObjects", targets: ["DicomObjects"]),
        .library(name: "DicomNetwork", targets: ["DicomNetwork"]),
        .library(name: "DicomData", targets: ["DicomData"]),
        .library(name: "DicomCore", targets: ["DicomCore"]),
        .library(name: "DicomWebClient", targets: ["DicomWebClient"]),
        .library(name: "DicomWebOIDC", targets: ["DicomWebOIDC"]),
        .library(name: "DicomWebHTTP", targets: ["DicomWebHTTP"]),
        .library(name: "DicomDocumentContent", targets: ["DicomDocumentContent"]),
        .library(name: "DicomAppleMedia", targets: ["DicomAppleMedia"]),
        .executable(name: "hl7tool", targets: ["hl7tool"]),
        .executable(name: "dicomtool", targets: ["dicomtool"]),
        .library(name: "DicomSwiftUI", targets: ["DicomSwiftUI"]),
        .executable(name: "DicomSwiftUIExample", targets: ["DicomSwiftUIExample"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(name: "HL7v3CDA", dependencies: ["HL7v2", "DicomCore", "DicomDocumentContent"], path: "Sources/HL7v3CDA", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "HL7v3CDATests", dependencies: ["HL7v3CDA"], path: "Tests/HL7v3CDATests", resources: [.copy("Fixtures")]),
        .target(name: "HL7v3Transport", dependencies: ["HL7v3CDA", "DicomCore"], path: "Sources/HL7v3Transport", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "HL7v3TransportTests", dependencies: ["HL7v3Transport", "DicomWebHTTP"], path: "Tests/HL7v3TransportTests"),
        .target(name: "FHIR", dependencies: ["HL7v3CDA", "HL7v3Transport", "DicomCore", "DicomWebHTTP"], path: "Sources/FHIR", resources: [.copy("Resources/FHIRElements.json")], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "FHIRTests", dependencies: ["FHIR", "DicomWebHTTP", "DicomTestSupport"], path: "Tests/FHIRTests", resources: [.copy("Fixtures")]),
        .target(name: "ClinicalMapping", dependencies: ["FHIR", "HL7v2", "HL7v3CDA", "DicomCore"], path: "Sources/ClinicalMapping", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ClinicalMappingTests", dependencies: ["ClinicalMapping", "DicomTestSupport", "DicomWebHTTP"], path: "Tests/ClinicalMappingTests", resources: [.copy("Fixtures")]),
        .executableTarget(name: "hl7tool", dependencies: ["HL7v2", "HL7MLLP", "HL7v3CDA", "FHIR", "ClinicalMapping",
            .product(name: "ArgumentParser", package: "swift-argument-parser")], path: "Sources/hl7tool"),
        .testTarget(name: "hl7toolTests", dependencies: ["hl7tool", "HL7v2", "HL7MLLP", "FHIR", "ClinicalMapping", "DicomTestSupport",
            .product(name: "ArgumentParser", package: "swift-argument-parser")], path: "Tests/hl7toolTests"),
        .target(name: "HL7MLLP", dependencies: ["HL7v2", "DicomCore"], path: "Sources/HL7MLLP", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "HL7MLLPTests", dependencies: ["HL7MLLP", "HL7v2"], path: "Tests/HL7MLLPTests", resources: [.copy("Fixtures")]),
        .target(name: "HL7v2", path: "Sources/HL7v2", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "HL7v2Tests", dependencies: ["HL7v2"], path: "Tests/HL7v2Tests", resources: [.copy("Fixtures")]),
        .target(name: "DicomWebClient", dependencies: ["DicomData"]),
        // OpenID Connect sign-in and token renewal for DicomWebClient, without UI or a token store of its own.
        .target(name: "DicomWebOIDC", dependencies: ["DicomWebClient"]),
        .testTarget(name: "DicomWebOIDCTests", dependencies: ["DicomWebOIDC", "DicomWebClient"]),
        .target(name: "DicomTestUtilities", path: "Tests/DicomTestUtilities"),
        .testTarget(name: "DicomWebClientTests", dependencies: ["DicomWebClient", "DicomData", "DicomTestUtilities"],
                    resources: [.process("Resources")],
                    swiftSettings: [.define("DEBUG", .when(configuration: .debug))]),
        .target(name: "DicomWebHTTP", dependencies: ["DicomCore"]),
        .testTarget(name: "DicomWebHTTPTests", dependencies: ["DicomWebHTTP", "DicomCore", "DicomTestSupport"]),
        .testTarget(name: "DicomDataTests", dependencies: ["DicomData"]),
        .testTarget(name: "DicomCodecsTests", dependencies: ["DicomCodecs"]),
        .testTarget(name: "DicomObjectsTests", dependencies: ["DicomObjects"]),
        .testTarget(name: "DicomNetworkTests", dependencies: ["DicomNetwork"]),

        .target(name: "DicomDocumentContent", dependencies: ["DicomCore"]),
        .testTarget(name: "DicomDocumentContentTests", dependencies: ["DicomDocumentContent"]),
        .target(name: "DicomCodecs"),
        // Vendored JPEG (SOF0/SOF1/SOF2/SOF3) codec: Raster-Lab/JLISwift 0.5.0 (Apache-2.0), see ThirdPartyNotices.txt.
        .target(name: "DicomJPEG", path: "Sources/DicomJPEG"),
        // Vendored JPEG-LS codec: Raster-Lab/JLSwift 0.9.1 (Apache-2.0), see ThirdPartyNotices.txt.
        .target(name: "DicomJPEGLS", path: "Sources/DicomJPEGLS"),
        // Vendored JPEG XL codec: Raster-Lab/JXLSwift 1.4.0 (MIT), see ThirdPartyNotices.txt. Issue #2332.
        .target(name: "DicomJPEGXL", path: "Sources/DicomJPEGXL", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        // Vendored JPEG 2000 Part 1/15 CPU codec: Raster-Lab/J2KSwift 11.0.2 J2KCore+J2KCodec without GPU/NEON/MJ2 (MIT; BSD-2-Clause), plus later upstream fixes listed in ThirdPartyNotices.txt.
        .target(name: "DicomJPEG2000", dependencies: ["DicomJPEG2000NEON"], path: "Sources/DicomJPEG2000"),
        // HT tier-1 block coder hot path of the same J2KSwift core (plain C, no unsafe flags).
        .target(name: "DicomJPEG2000NEON", path: "Sources/DicomJPEG2000NEON", publicHeadersPath: "include"),
        .target(name: "DicomObjects", dependencies: ["DicomData"]),
        .target(name: "DicomNetwork", dependencies: ["DicomData"]),
        .target(
            name: "DicomData",
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "DicomCore",
            dependencies: [
                "DicomData",
                "DicomWebClient",
                "DicomCodecs",
                "DicomJPEG",
                "DicomObjects",
                "DicomNetwork",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "DicomJPEG2000",
                "DicomJPEGLS",
                "DicomJPEGXL"
            ],
            path: "Sources/DicomCore",
            exclude: [
                "JPEGLossless_ALGORITHM.md"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Metal", .when(platforms: [.iOS, .visionOS, .macOS])),
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "DicomAppleMedia",
            dependencies: ["DicomCore"],
            path: "Sources/DicomAppleMedia",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .executableTarget(
            name: "dicomtool",
            dependencies: [
                "DicomWebHTTP",
                "DicomCore",
                "DicomDocumentContent",
                .target(name: "DicomAppleMedia", condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS])),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/dicomtool"
        ),
        .target(
            name: "DicomSwiftUI",
            dependencies: ["DicomCore"],
            path: "Sources/DicomSwiftUI"
        ),
        .executableTarget(
            name: "DicomSwiftUIExample",
            dependencies: ["DicomSwiftUI", "DicomCore"],
            path: "Examples/DicomSwiftUIExample",
            exclude: [
                "Info.plist",
                "README.md"
            ],
            resources: [
                .process("Assets.xcassets"),
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "DicomTestSupport",
            dependencies: ["DicomCore", "DicomTestUtilities"],
            // Shared test support target that owns MockDicomDecoder for all test targets.
            path: "Tests/DicomTestSupport"
        ),
        .testTarget(
            name: "DicomCoreTests",
            dependencies: [
                "DicomCore",
                "DicomWebHTTP",
                "DicomJPEG",
                "DicomTestSupport",
                "DicomTestUtilities",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "DicomJPEG2000",
                "DicomJPEGLS",
                "DicomJPEGXL"
            ],
            path: "Tests/DicomCoreTests",
            exclude: [
                "Fixtures"
            ],
            resources: [
                .process("PerformanceBenchmarks/Baselines"),
                .process("Resources")
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "DicomAppleMediaTests",
            dependencies: ["DicomAppleMedia", "DicomCore"],
            path: "Tests/DicomAppleMediaTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DicomSwiftUITests",
            dependencies: ["DicomSwiftUI", "DicomCore", "DicomTestSupport"],
            path: "Tests/DicomSwiftUITests"
        ),
        .testTarget(
            name: "dicomtoolTests",
            dependencies: [
                "DicomWebHTTP",
                "dicomtool",
                "DicomCore",
                "DicomTestSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Tests/dicomtoolTests"
        ),
        .testTarget(
            name: "dicomtoolIntegrationTests",
            dependencies: [
                "dicomtool",
                "DicomCore",
                "DicomTestSupport"
            ],
            path: "Tests/dicomtoolIntegrationTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
