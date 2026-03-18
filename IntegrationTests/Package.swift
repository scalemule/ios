// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScaleMuleIntegrationTests",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "IntegrationTests",
            dependencies: [
                .product(name: "ScaleMule", package: "ios"),
            ],
            path: "Sources"
        ),
    ]
)
