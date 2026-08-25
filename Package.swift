// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Spinosis",
  platforms: [
    .iOS(.v15),
  ],
  products: [
    .library(name: "Spinosis", targets: ["Spinosis"]),
  ],
  targets: [
    .target(name: "Spinosis"),
  ]
)
