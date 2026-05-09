#!/usr/bin/env swift
// 生成 MK app 图标：橙色线条麦克风 + 橙色 MK 字 + 透明背景（加粗版）
import Cocoa

let size = NSSize(width: 1024, height: 1024)

func render() -> Data? {
    let img = NSImage(size: size)
    img.lockFocus()

    // 透明背景
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    // 麦克风路径（线条 / stroke）
    let mic = NSBezierPath()
    let cx: CGFloat = 512
    let headTop: CGFloat = 880
    let headBottom: CGFloat = 290
    let headWidth: CGFloat = 480

    // 头部（胶囊）
    mic.appendRoundedRect(
        NSRect(x: cx - headWidth / 2, y: headBottom, width: headWidth, height: headTop - headBottom),
        xRadius: headWidth / 2,
        yRadius: headWidth / 2
    )

    // 支架弧
    let bracketRadius: CGFloat = 320
    let bracketCenterY: CGFloat = 410
    mic.move(to: NSPoint(x: cx - bracketRadius, y: bracketCenterY))
    mic.appendArc(
        withCenter: NSPoint(x: cx, y: bracketCenterY),
        radius: bracketRadius,
        startAngle: 180,
        endAngle: 360,
        clockwise: false
    )

    // 短支柱
    mic.move(to: NSPoint(x: cx, y: bracketCenterY - bracketRadius))
    mic.line(to: NSPoint(x: cx, y: 60))

    // 底座（稍微加长）
    mic.move(to: NSPoint(x: cx - 200, y: 60))
    mic.line(to: NSPoint(x: cx + 200, y: 60))

    // 加粗 stroke：32 → 48（粗 50%）
    NSColor.systemOrange.setStroke()
    mic.lineWidth = 48
    mic.lineCapStyle = .round
    mic.lineJoinStyle = .round
    mic.stroke()

    // MK 文字（橙色，加粗匹配粗描边）
    let textCenterY: CGFloat = (headTop + headBottom) / 2
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 240),
        .foregroundColor: NSColor.systemOrange
    ]
    let text = "MK" as NSString
    let textSize = text.size(withAttributes: attrs)
    let textRect = NSRect(
        x: cx - textSize.width / 2,
        y: textCenterY - textSize.height / 2,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attrs)

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    return png
}

guard let data = render() else {
    fputs("render failed\n", stderr)
    exit(1)
}

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/mk_icon.png"
try? data.write(to: URL(fileURLWithPath: path))
print("Saved \(path)")
