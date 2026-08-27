// swift make_icon.swift <输出.png>
// 生成 MacPulse 应用图标（1024×1024，macOS Big Sur 风格：圆角方块 + 心电脉冲线）
import Foundation
import CoreGraphics
import ImageIO

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let S = CGFloat(size)
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// 圆角方块（Big Sur 图标比例：内容约占 1024 的 80%，圆角 22.4%）
let inset = S * 0.10
let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = rect.width * 0.224
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(squircle)
ctx.clip()

// 背景渐变：深夜蓝 → 靛紫 → 品红（左上到右下）
let bgColors = [CGColor(srgbRed: 0.071, green: 0.078, blue: 0.173, alpha: 1),
                CGColor(srgbRed: 0.231, green: 0.157, blue: 0.518, alpha: 1),
                CGColor(srgbRed: 0.827, green: 0.184, blue: 0.502, alpha: 1)] as CFArray
let bg = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 0.58, 1])!
ctx.drawLinearGradient(bg,
                       start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY),
                       options: [])

// 左上柔光
let glow = CGGradient(colorsSpace: cs,
                      colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
                               CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                      locations: [0, 1])!
let glowCenter = CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22)
ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                       endCenter: glowCenter, endRadius: rect.width * 0.95, options: [])

// 细网格线（监护仪质感）
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))
ctx.setLineWidth(2)
let gridStep = rect.width / 8
for i in 1..<8 {
    let x = rect.minX + CGFloat(i) * gridStep
    ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
    let y = rect.minY + CGFloat(i) * gridStep
    ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
}
ctx.strokePath()

// 心电脉冲线（白，带品红辉光）
let midY = rect.midY - rect.height * 0.02
let left = rect.minX + rect.width * 0.12
let right = rect.maxX - rect.width * 0.12
let span = right - left
func X(_ t: CGFloat) -> CGFloat { left + span * t }
let pulse = CGMutablePath()
pulse.move(to: CGPoint(x: X(0), y: midY))
pulse.addLine(to: CGPoint(x: X(0.18), y: midY))
pulse.addLine(to: CGPoint(x: X(0.24), y: midY + rect.height * 0.06))   // P 波
pulse.addLine(to: CGPoint(x: X(0.30), y: midY))
pulse.addLine(to: CGPoint(x: X(0.36), y: midY - rect.height * 0.05))   // Q 谷
pulse.addLine(to: CGPoint(x: X(0.42), y: midY + rect.height * 0.26))   // R 尖峰
pulse.addLine(to: CGPoint(x: X(0.49), y: midY - rect.height * 0.16))   // S 谷
pulse.addLine(to: CGPoint(x: X(0.56), y: midY + rect.height * 0.08))   // T 波
pulse.addLine(to: CGPoint(x: X(0.63), y: midY))
pulse.addLine(to: CGPoint(x: X(1.0), y: midY))

// 辉光层
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46,
              color: CGColor(srgbRed: 1, green: 0.35, blue: 0.68, alpha: 0.9))
ctx.addPath(pulse)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.42, blue: 0.72, alpha: 1))
ctx.setLineWidth(30)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.restoreGState()

// 主线层
ctx.addPath(pulse)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(22)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.strokePath()

// 脉冲终点圆点（扫描光点）
let dot = CGPoint(x: X(1.0), y: midY)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: dot.x - 22, y: dot.y - 22, width: 44, height: 44))

// AI 星芒徽标（右上角四角星，白色带品红辉光）
let scx = rect.maxX - rect.width * 0.185
let scy = rect.minY + rect.height * 0.185
let sr = rect.width * 0.105
let sparkle = CGMutablePath()
let inner: CGFloat = 0.16
sparkle.move(to: CGPoint(x: scx, y: scy + sr))
sparkle.addQuadCurve(to: CGPoint(x: scx + sr, y: scy),
                     control: CGPoint(x: scx + sr * inner, y: scy + sr * inner))
sparkle.addQuadCurve(to: CGPoint(x: scx, y: scy - sr),
                     control: CGPoint(x: scx + sr * inner, y: scy - sr * inner))
sparkle.addQuadCurve(to: CGPoint(x: scx - sr, y: scy),
                     control: CGPoint(x: scx - sr * inner, y: scy - sr * inner))
sparkle.addQuadCurve(to: CGPoint(x: scx, y: scy + sr),
                     control: CGPoint(x: scx - sr * inner, y: scy + sr * inner))
sparkle.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30,
              color: CGColor(srgbRed: 1, green: 0.55, blue: 0.8, alpha: 0.9))
ctx.addPath(sparkle)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// 小星芒伴星
let bx = scx - sr * 1.35, by = scy - sr * 1.2, br = sr * 0.42
let spark2 = CGMutablePath()
spark2.move(to: CGPoint(x: bx, y: by + br))
spark2.addQuadCurve(to: CGPoint(x: bx + br, y: by),
                    control: CGPoint(x: bx + br * inner, y: by + br * inner))
spark2.addQuadCurve(to: CGPoint(x: bx, y: by - br),
                    control: CGPoint(x: bx + br * inner, y: by - br * inner))
spark2.addQuadCurve(to: CGPoint(x: bx - br, y: by),
                    control: CGPoint(x: bx - br * inner, y: by - br * inner))
spark2.addQuadCurve(to: CGPoint(x: bx, y: by + br),
                    control: CGPoint(x: bx - br * inner, y: by + br * inner))
spark2.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18,
              color: CGColor(srgbRed: 1, green: 0.55, blue: 0.8, alpha: 0.8))
ctx.addPath(spark2)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: output) as CFURL
let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("icon written: \(output)")
