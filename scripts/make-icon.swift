import AppKit

// Renders the app icon (a sparkle on a warm rounded square) at every size macOS needs and writes
// an .iconset folder, which `iconutil` turns into an .icns file.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.45, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.80, green: 0.31, blue: 0.17, alpha: 1)])!
        .draw(in: path, angle: -90)
    if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)) {
        let tinted = symbol.copy() as! NSImage
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
