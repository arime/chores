// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChoresCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChoresCore", targets: ["ChoresCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "ChoresCore",
            dependencies: [.product(name: "Supabase", package: "supabase-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChoresCoreTests",
            dependencies: ["ChoresCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
