// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReceiptDomain",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ReceiptDomain", targets: ["ReceiptDomain"]),
        .library(name: "ReceiptStore", targets: ["ReceiptStore"]),
        .library(name: "SplitSlipCore", targets: ["SplitSlipCore"]),
    ],
    targets: [
        .target(name: "ReceiptDomain"),
        .target(name: "ReceiptStore", dependencies: ["ReceiptDomain"]),
        .target(name: "SplitSlipCore", dependencies: ["ReceiptDomain"]),
        .testTarget(name: "ReceiptDomainTests", dependencies: ["ReceiptDomain", "ReceiptStore"]),
        .testTarget(name: "SplitSlipCoreTests", dependencies: ["SplitSlipCore"]),
    ]
)
