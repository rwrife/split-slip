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
    ],
    targets: [
        .target(name: "ReceiptDomain"),
        .target(name: "ReceiptStore", dependencies: ["ReceiptDomain"]),
        .testTarget(name: "ReceiptDomainTests", dependencies: ["ReceiptDomain", "ReceiptStore"]),
    ]
)
