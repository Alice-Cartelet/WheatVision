// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WheatVisionCore", platforms: [.macOS(.v13)], products: [.library(name: "LeafCore", targets: ["LeafCore"])], targets: [
    .target(name: "LeafCore", path: "WPD", exclude: ["ContentView.swift", "WPDApp.swift", "Imaging.swift", "Records.swift", "PhotoAnalysisView.swift", "YOLOLeafAnalyzer.swift", "WheatLeaf.mlpackage", "Assets.xcassets", "Preview Content"], sources: ["LeafAnalysis.swift"]),
    .testTarget(name: "LeafCoreTests", dependencies: ["LeafCore"], path: "WPDTests", exclude: ["YOLODemoFixture.png"])
])
