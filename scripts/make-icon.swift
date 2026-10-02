// Renders Resources/AppIcon.icns: a dark tile with a notch and a heatmap grid.
// Usage: swift scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))!.draw(in: bg, angle: -90)
    bg.addClip()

    // Notch
    let nw = tile.width * 0.44, nh = tile.height * 0.12
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: tile.midX - nw / 2, y: tile.maxY - nh, width: nw, height: nh * 2),
                 xRadius: nh * 0.7, yRadius: nh * 0.7).fill()

    // Heatmap grid
    let levels = [[0, 1, 2, 1, 3], [1, 3, 4, 2, 1], [2, 4, 4, 3, 0], [1, 2, 3, 4, 2]]
    let alphas: [CGFloat] = [0.10, 0.30, 0.52, 0.76, 1.0]
    let cols = 5, rows = 4
    let gridW = tile.width * 0.64
    let gap = gridW * 0.06
    let cell = (gridW - gap * CGFloat(cols - 1)) / CGFloat(cols)
    let gridH = cell * CGFloat(rows) + gap * CGFloat(rows - 1)
    let originX = tile.midX - gridW / 2
    let originY = tile.minY + (tile.height - nh - gridH) / 2 - tile.height * 0.02
    for r in 0..<rows {
        for c in 0..<cols {
            let l = levels[r][c]
            let color = l == 0 ? NSColor(white: 1, alpha: alphas[0])
                               : NSColor(red: 0.16, green: 0.76, blue: 0.43, alpha: alphas[l])
            color.setFill()
            let rect = NSRect(x: originX + CGFloat(c) * (cell + gap),
                              y: originY + CGFloat(rows - 1 - r) * (cell + gap), width: cell, height: cell)
            NSBezierPath(roundedRect: rect, xRadius: cell * 0.22, yRadius: cell * 0.22).fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(dir.path)")
