// swift-tools-version: 5.9
import PackageDescription
import Foundation
let product = ProcessInfo.processInfo.environment["OPENSOUND_ROOT"].map { $0 + "/src/Apps/Shared/OpenSoundKit" } ?? "../../../OpenSound/src/Apps/Shared/OpenSoundKit"
let package = Package(name: "OpenSoundUIChecks", platforms: [.macOS(.v14)],
    dependencies: [.package(path: product)],
    targets: [.testTarget(name: "OpenSoundKitTests", dependencies: [.product(name: "OpenSoundKit", package: "OpenSoundKit")])])
