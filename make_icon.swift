// 生成应用图标：蓝紫渐变圆角方板 + 白色拉链头 + 向下箭头（解压意象）
// 用法: swift make_icon.swift <输出 iconset 目录>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func drawIcon(_ ctx: CGContext, side: CGFloat) {
    let s = side / canvas
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    defer { ctx.restoreGState() }

    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // ── 背板（macOS 大苏尔风格圆角方板，约占 80%）──
    let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let plate = CGPath(roundedRect: bgRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(plate)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.36, green: 0.60, blue: 0.99, alpha: 1),
            CGColor(red: 0.16, green: 0.33, blue: 0.88, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // 顶部轻微提亮
    let sheen = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(gray: 1, alpha: 0.18),
            CGColor(gray: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 420), options: [])

    let white = CGColor(gray: 1, alpha: 1)
    ctx.setFillColor(white)

    // ── 拉链齿：左右两列交错咬合，中间留缝 ──
    for i in 0..<4 {
        let y = 640 + CGFloat(i) * 56
        ctx.fill(CGRect(x: 446, y: y, width: 54, height: 44))
        ctx.fill(CGRect(x: 524, y: y + 28, width: 54, height: 44))
    }

    // ── 拉链头（滑块）──
    let slider = CGPath(roundedRect: CGRect(x: 437, y: 452, width: 150, height: 160),
                        cornerWidth: 40, cornerHeight: 40, transform: nil)
    ctx.addPath(slider)
    ctx.fillPath()
    // 滑块上的深色拉片孔
    let slot = CGPath(roundedRect: CGRect(x: 494, y: 500, width: 36, height: 96),
                      cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.24, blue: 0.66, alpha: 1))
    ctx.addPath(slot)
    ctx.fillPath()
    ctx.setFillColor(white)

    // ── 向下箭头（解压出来）──
    ctx.fill(CGRect(x: 467, y: 260, width: 90, height: 150))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 397, y: 270))
    ctx.addLine(to: CGPoint(x: 627, y: 270))
    ctx.addLine(to: CGPoint(x: 512, y: 128))
    ctx.closePath()
    ctx.fillPath()
}

func render(_ px: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    drawIcon(ctx, side: CGFloat(px))
    guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write failed: \(url)") }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: make_icon.swift <iconset目录>")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    render(px, to: outDir.appendingPathComponent(name))
}
print("图标已生成 → \(outDir.path)")
