// 用 Vision 的前景实例分割，把 art/hero-*.jpg 的神兽从暗底上抠出来，
// 输出带 alpha 的 Sources/MacPulse/Resources/char-*.png 供亮色影棚背景使用。
// 原画放在 art/（不进 .app），只有抠好的 PNG 随包发布。
// 用法：swift scripts/cutout.swift [名字...]   （省略则处理全部六界）
import AppKit
import CoreImage
import Foundation
import Vision

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceDir = root.appendingPathComponent("art")
let outputDir = root.appendingPathComponent("Sources/MacPulse/Resources")

let names: [String] = {
    let args = Array(CommandLine.arguments.dropFirst())
    return args.isEmpty ? ["fire", "metal", "wood", "earth", "water", "gate"] : args
}()

let ciContext = CIContext(options: [.useSoftwareRenderer: false])

/// 把裁好的前景放进正方形画布并留边，避免立绘贴边被 SwiftUI 裁掉。
func padded(_ image: CIImage, margin: CGFloat = 0.06) -> CIImage {
    let e = image.extent
    let side = max(e.width, e.height) * (1 + margin * 2)
    let dx = (side - e.width) / 2 - e.origin.x
    let dy = (side - e.height) / 2 - e.origin.y
    let moved = image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    return moved.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
}

for name in names {
    let input = sourceDir.appendingPathComponent("hero-\(name).jpg")
    let output = outputDir.appendingPathComponent("char-\(name).png")
    guard let source = CIImage(contentsOf: input) else {
        FileHandle.standardError.write(Data("skip \(name): unreadable\n".utf8))
        continue
    }

    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(ciImage: source, options: [:])
    do {
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            FileHandle.standardError.write(Data("skip \(name): no subject found\n".utf8))
            continue
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances,
                                                    from: handler,
                                                    croppedToInstancesExtent: true)
        let cut = padded(CIImage(cvPixelBuffer: buffer))
        try ciContext.writePNGRepresentation(
            of: cut,
            to: output,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        print("cut \(name) -> \(output.lastPathComponent) \(Int(cut.extent.width))x\(Int(cut.extent.height))")
    } catch {
        FileHandle.standardError.write(Data("fail \(name): \(error)\n".utf8))
    }
}
