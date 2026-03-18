// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScaleMule",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ScaleMuleCore", targets: ["ScaleMuleCore"]),
        .library(name: "ScaleMuleAuth", targets: ["ScaleMuleAuth"]),
        .library(name: "ScaleMulePermissions", targets: ["ScaleMulePermissions"]),
        .library(name: "ScaleMuleWorkspaces", targets: ["ScaleMuleWorkspaces"]),
        .library(name: "ScaleMule", targets: ["ScaleMule"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ScaleMuleCore", path: "Sources/ScaleMuleCore"),
        .target(name: "ScaleMuleAuth", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMuleAuth"),
        .target(name: "ScaleMulePermissions", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMulePermissions"),
        .target(name: "ScaleMuleWorkspaces", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMuleWorkspaces"),
        .target(name: "ScaleMule", dependencies: ["ScaleMuleCore", "ScaleMuleAuth", "ScaleMulePermissions", "ScaleMuleWorkspaces"], path: "Sources/ScaleMule"),
        .target(name: "ScaleMuleTestHelpers", dependencies: ["ScaleMuleCore"], path: "Tests/Helpers"),
        .testTarget(name: "ScaleMuleCoreTests", dependencies: ["ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleCoreTests"),
        .testTarget(name: "ScaleMuleAuthTests", dependencies: ["ScaleMuleAuth", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleAuthTests"),
        .testTarget(name: "ScaleMulePermissionsTests", dependencies: ["ScaleMulePermissions", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMulePermissionsTests"),
        .testTarget(name: "ScaleMuleWorkspacesTests", dependencies: ["ScaleMuleWorkspaces", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleWorkspacesTests"),
    ]
)
