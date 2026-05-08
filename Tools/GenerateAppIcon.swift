import AppKit
import Foundation

private enum WispryGeneratedIcon {
    static let ink = NSColor(calibratedRed: 16 / 255, green: 21 / 255, blue: 16 / 255, alpha: 1)
    static let paper = NSColor(calibratedRed: 246 / 255, green: 241 / 255, blue: 229 / 255, alpha: 1)
    static let accent = NSColor(calibratedRed: 171 / 255, green: 213 / 255, blue: 107 / 255, alpha: 1)

    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        ink.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: size * 14 / 64,
            yRadius: size * 14 / 64
        ).fill()

        drawWave(in: rect.insetBy(dx: size * 0.03, dy: size * 0.03), lineWidth: max(2, size * 5 / 64))
        image.unlockFocus()
        return image
    }

    private static func drawWave(in rect: NSRect, lineWidth: CGFloat) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(
                x: rect.minX + x / 64 * rect.width,
                y: rect.maxY - y / 64 * rect.height
            )
        }

        let wave = NSBezierPath()
        wave.move(to: point(12, 35))
        wave.line(to: point(17, 35))
        wave.line(to: point(20, 23))
        wave.line(to: point(26, 48))
        wave.line(to: point(32, 16))
        wave.line(to: point(38, 35))
        wave.line(to: point(52, 35))
        wave.lineWidth = lineWidth
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        accent.setStroke()
        wave.stroke()

        let cursor = NSBezierPath()
        cursor.move(to: point(44, 18))
        cursor.line(to: point(44, 46))
        cursor.lineWidth = lineWidth
        cursor.lineCapStyle = .round
        paper.setStroke()
        cursor.stroke()

        paper.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: point(44, 13).x - lineWidth * 0.6,
                y: point(44, 13).y - lineWidth * 0.6,
                width: lineWidth * 1.2,
                height: lineWidth * 1.2
            )
        ).fill()
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
