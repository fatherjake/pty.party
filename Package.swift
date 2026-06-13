// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ptyparty",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "ptyparty",
            dependencies: ["SwiftTerm"]
        ),
    ]
)
