import AppKit
import Foundation

private enum WispryGeneratedIcon {
    static let ink = NSColor(calibratedRed: 16 / 255, green: 21 / 255, blue: 16 / 255, alpha: 1)
    static let paper = NSColor(calibratedRed: 246 / 255, green: 241 / 255, blue: 229 / 255, alpha: 1)

    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        ink.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.03, dy: size * 0.03)).fill()

        paper.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.07, dy: size * 0.07))
        border.lineWidth = max(0.7, size * 0.035)
        border.stroke()

        drawBars(in: rect.insetBy(dx: size * 0.09, dy: size * 0.09))
        image.unlockFocus()
        return image
    }

    private static func drawBars(in rect: NSRect) {
        paper.setFill()

        let heights: [CGFloat] = [0.34, 0.64, 0.46]
        let barWidth = rect.width * 0.09
        let spacing = rect.width * 0.12
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
        let startX = rect.midX - totalWidth / 2

        for (index, heightRatio) in heights.enumerated() {
            let height = rect.height * heightRatio
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = rect.midY - height / 2
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
    }
}

private func writePNG(image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url, options: .atomic)
}

private let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icns")
let fileManager = FileManager.default
let temporaryDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("WispryAppIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconFiles: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in iconFiles {
    try writePNG(
        image: WispryGeneratedIcon.image(size: size),
        to: iconsetURL.appendingPathComponent(name)
    )
}

try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

try? fileManager.removeItem(at: temporaryDirectory)

if process.terminationStatus != 0 {
    throw CocoaError(.fileWriteUnknown)
}
