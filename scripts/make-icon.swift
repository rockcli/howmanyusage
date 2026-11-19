// Generate the app icon (bar-chart badge) into build/HowManyUsage.icns
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// rounded gradient background
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.34, blue: 0.92, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.62, alpha: 1),
])!.draw(in: path, angle: -70)

// three bars
let bars: [(CGFloat, CGFloat)] = [
    (0.20, 0.52), // x, height fraction
    (0.435, 0.78),
    (0.67, 0.38),
]
let barW: CGFloat = 0.17
let baseY: CGFloat = 0.20
for (x, h) in bars {
    let bar = NSRect(x: size * x, y: size * baseY, width: size * barW, height: size * h)
    let p = NSBezierPath(roundedRect: bar, xRadius: size * 0.055, yRadius: size * 0.055)
    NSColor.white.withAlphaComponent(0.95).setFill()
    p.fill()
}
img.unlockFocus()

// export iconset
let outDir = "build/HowManyUsage.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let resized = NSImage(size: NSSize(width: px, height: px))
    resized.lockFocus()
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    resized.unlockFocus()
    guard
        let tiff = resized.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", outDir, "-o", "build/HowManyUsage.icns"]
try? p.run()
p.waitUntilExit()
print("Icon generated: build/HowManyUsage.icns")
