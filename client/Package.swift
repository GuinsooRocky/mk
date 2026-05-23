// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WE",
    platforms: [.macOS(.v26)],
    targets: [
        // sherpa-onnx C API 的 clang 模块包装（SwiftPM 无 bridging header）
        .target(
            name: "CSherpaOnnx",
            path: "CSherpaOnnx"
        ),
        .executableTarget(
            name: "MK",
            dependencies: ["CSherpaOnnx"],
            path: "Sources",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "Vendor/sherpa-onnx/lib",
                    "-lsherpa-onnx-c-api",
                    "-lonnxruntime",
                    // dev 裸二进制(.build/{debug,release}/MK)：相对 rpath 回指 Vendor，
                    // 不写死 /Users/<name>（可移植、不泄露用户名）。
                    // .app：dylib 拷到 MacOS/ 同级，靠 @executable_path 解析；不存在的 rpath dyld 静默跳过。
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Vendor/sherpa-onnx/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        )
    ]
)
