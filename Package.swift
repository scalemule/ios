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
        .library(name: "ScaleMuleSocial", targets: ["ScaleMuleSocial"]),
        .library(name: "ScaleMulePhotos", targets: ["ScaleMulePhotos"]),
        .library(name: "ScaleMuleSafety", targets: ["ScaleMuleSafety"]),
        .library(name: "ScaleMuleStorage", targets: ["ScaleMuleStorage"]),
        .library(name: "ScaleMule", targets: ["ScaleMule"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ScaleMuleCore", path: "Sources/ScaleMuleCore"),
        .target(name: "ScaleMuleAuth", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMuleAuth"),
        .target(name: "ScaleMulePermissions", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMulePermissions"),
        .target(name: "ScaleMuleWorkspaces", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMuleWorkspaces"),
        .target(name: "ScaleMuleSocial", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMuleSocial"),
        .target(name: "ScaleMuleStorage", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMuleStorage"),
        .target(name: "ScaleMulePhotos", dependencies: ["ScaleMuleCore", "ScaleMuleStorage"], path: "Sources/ScaleMulePhotos"),
        .target(name: "ScaleMuleSafety", dependencies: ["ScaleMuleCore"], path: "Sources/ScaleMuleSafety"),
        .target(name: "ScaleMule", dependencies: ["ScaleMuleCore", "ScaleMuleAuth", "ScaleMulePermissions", "ScaleMuleWorkspaces", "ScaleMuleSocial", "ScaleMuleStorage", "ScaleMulePhotos", "ScaleMuleSafety"], path: "Sources/ScaleMule"),
        .target(name: "ScaleMuleTestHelpers", dependencies: ["ScaleMuleCore"], path: "Tests/Helpers"),
        .testTarget(name: "ScaleMuleCoreTests", dependencies: ["ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleCoreTests"),
        .testTarget(name: "ScaleMuleAuthTests", dependencies: ["ScaleMuleAuth", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleAuthTests"),
        .testTarget(name: "ScaleMulePermissionsTests", dependencies: ["ScaleMulePermissions", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMulePermissionsTests"),
        .testTarget(name: "ScaleMuleSocialTests", dependencies: ["ScaleMuleSocial", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleSocialTests"),
        .testTarget(name: "ScaleMuleSafetyTests", dependencies: ["ScaleMuleSafety", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleSafetyTests"),
        .testTarget(name: "ScaleMuleStorageTests", dependencies: ["ScaleMuleStorage", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleStorageTests"),
        .testTarget(name: "ScaleMulePhotosTests", dependencies: ["ScaleMulePhotos", "ScaleMuleStorage", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMulePhotosTests"),
        .testTarget(name: "ScaleMuleWorkspacesTests", dependencies: ["ScaleMuleWorkspaces", "ScaleMuleCore", "ScaleMuleTestHelpers"], path: "Tests/ScaleMuleWorkspacesTests"),
    ]
)
