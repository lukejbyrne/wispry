import AppKit

enum WispryIcon {
    private static let ink = NSColor(calibratedRed: 16 / 255, green: 21 / 255, blue: 16 / 255, alpha: 1)
    private static let paper = NSColor(calibratedRed: 246 / 255, green: 241 / 255, blue: 229 / 255, alpha: 1)
    private static let accent = NSColor(calibratedRed: 171 / 255, green: 213 / 255, blue: 107 / 255, alpha: 1)
    private static let red = NSColor(calibratedRed: 201 / 255, green: 69 / 255, blue: 54 / 255, alpha: 1)

    static func appMark(size: CGFloat) -> NSImage {
        draw(size: size, state: nil)
    }

    static func statusImage(for state: BubbleState) -> NSImage {
        let image = statusSoundImage(size: 18, state: state)
        image.isTemplate = false
        return image
    }

    private static func statusSoundImage(size: CGFloat, state: BubbleState) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        switch state {
        case .success:
            drawStatusCheck(size: size)
        case .error:
            drawStatusError(size: size)
        default:
            drawStatusBars(size: size, state: state)
        }

        image.unlockFocus()
        return image
    }

    private static func drawStatusBars(size: CGFloat, state: BubbleState) {
        NSColor(calibratedWhite: 1, alpha: state == .idle ? 0.82 : 0.94).setFill()

        let heights: [CGFloat] = state == .listening
            ? [7, 13, 9, 15]
            : [7, 13, 9]
        let barWidth: CGFloat = 2.4
        let spacing: CGFloat = 2.4
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
        let startX = (size - totalWidth) / 2

        for (index, height) in heights.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = (size - height) / 2
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
    }

    private static func drawStatusCheck(size: CGFloat) {
        NSColor(calibratedWhite: 1, alpha: 0.94).setStroke()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 2.3
        path.move(to: NSPoint(x: size * 0.23, y: size * 0.53))
        path.line(to: NSPoint(x: size * 0.43, y: size * 0.72))
        path.line(to: NSPoint(x: size * 0.78, y: size * 0.28))
        path.stroke()
    }

    private static func drawStatusError(size: CGFloat) {
        red.setStroke()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = 2.2
        path.move(to: NSPoint(x: size * 0.28, y: size * 0.28))
        path.line(to: NSPoint(x: size * 0.72, y: size * 0.72))
        path.move(to: NSPoint(x: size * 0.72, y: size * 0.28))
        path.line(to: NSPoint(x: size * 0.28, y: size * 0.72))
        path.stroke()
    }

    private static func draw(size: CGFloat, state: BubbleState?) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let backgroundAlpha: CGFloat
        switch state {
        case .listening:
            backgroundAlpha = 0.96
        case .processing, .success, .error:
            backgroundAlpha = 0.92
        default:
            backgroundAlpha = 1
        }

        ink.withAlphaComponent(backgroundAlpha).setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: size * 0.03, dy: size * 0.03),
            xRadius: size * 14 / 64,
            yRadius: size * 14 / 64
        ).fill()

        paper.withAlphaComponent(0.20).setStroke()
        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: size * 0.07, dy: size * 0.07),
            xRadius: size * 12 / 64,
            yRadius: size * 12 / 64
        )
        border.lineWidth = max(0.7, size * 0.04)
        border.stroke()

        drawMark(
            in: rect.insetBy(dx: size * 0.03, dy: size * 0.03),
            accentColor: accentColor(for: state),
            lineWidth: max(1.2, size * 5 / 64)
        )

        image.unlockFocus()
        return image
    }

    private static func accentColor(for state: BubbleState?) -> NSColor {
        switch state {
        case .error:
            red
        case .processing:
            paper.withAlphaComponent(0.86)
        default:
            accent
        }
    }

    private static func drawMark(in rect: NSRect, accentColor: NSColor, lineWidth: CGFloat) {
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
        accentColor.setStroke()
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
                x: point(44, 13).x - lineWidth * 0.58,
                y: point(44, 13).y - lineWidth * 0.58,
                width: lineWidth * 1.16,
                height: lineWidth * 1.16
            )
        ).fill()
    }
}
