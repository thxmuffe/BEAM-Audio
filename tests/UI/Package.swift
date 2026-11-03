// swift-tools-version: 5.9
import PackageDescription
import Foundation
let product = ProcessInfo.processInfo.environment["OPENSOUND_ROOT"].map { $0 + "/src/Apps/Shared/ParviKit" } ?? "../../../OpenSound/src/Apps/Shared/ParviKit"
let package = Package(name: "OpenSoundUIChecks", platforms: [.macOS(.v14)],
    dependencies: [.package(path: product)],
    targets: [.testTarget(name: "ParviKitTests", dependencies: [.product(name: "ParviKit", package: "ParviKit")])])
