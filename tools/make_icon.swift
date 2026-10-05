import AppKit

// 生成 GT 工具箱的 App 图标:macOS 圆角方块 + 白色扬声器,输出标准 iconset 与 icns。
// 用法:swiftc tools/make_icon.swift -o /tmp/make_icon -framework AppKit && /tmp/make_icon [输出目录]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets"
let size: CGFloat = 1024

func render(_ scale: CGFloat) -> NSImage {
    let px = size * scale
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocusFlipped(false)

    // Big Sur 风格圆角方块:1024 画布内 824 盒、圆角约 185
    let inset = px * 0.098
    let box = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let radius = box.width * 0.2245
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    // 背景渐变:左上亮蓝 → 右下深蓝紫
    NSGradient(starting: NSColor(calibratedRed: 0.28, green: 0.52, blue: 1.00, alpha: 1),
               ending: NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.82, alpha: 1))?
        .draw(in: squircle, angle: -60)

    // 顶部内高光(细描边)
    NSColor(white: 1.0, alpha: 0.18).setStroke()
    let highlight = NSBezierPath(roundedRect: box.insetBy(dx: px * 0.008, dy: px * 0.008),
                                 xRadius: radius * 0.98, yRadius: radius * 0.98)
    highlight.lineWidth = px * 0.004
    highlight.stroke()

    // 白色扬声器符号(SF Symbol 转模板后染色)
    let base = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!
    let config = NSImage.SymbolConfiguration(pointSize: px * 0.42, weight: .bold)
    let symbol = base.withSymbolConfiguration(config)!
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSColor.white.setFill()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn)
    tinted.unlockFocus()

    // 居中放置(扬声器字形偏左,视觉上右移一点)
    let target = box.width * 0.52
    let aspect = symbol.size.width / symbol.size.height
    let w = target * aspect, h = target
    let x = box.midX - w / 2 + box.width * 0.02
    let y = box.midY - h / 2
    tinted.draw(in: NSRect(x: x, y: y, width: w, height: h),
                from: .zero, operation: .sourceOver, fraction: 1)

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, sizePx: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sizePx, pixelsHigh: sizePx,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: sizePx, height: sizePx)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: sizePx, height: sizePx))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconset = "\(outDir)/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let master = render(1)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    writePNG(master, sizePx: px, to: "\(iconset)/\(name)")
}

let icns = "\(outDir)/AppIcon.icns"
try? fm.removeItem(atPath: icns)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset, "-o", icns]
try! proc.run(); proc.waitUntilExit()
print(proc.terminationStatus == 0
      ? "图标已生成:\(icns)"
      : "iconutil 失败(退出码 \(proc.terminationStatus))")
