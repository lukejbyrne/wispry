import AppKit

enum BubbleState {
    case idle
    case listening
    case processing
    case success
    case error
}

protocol BubbleViewDelegate: AnyObject {
    func bubbleDidRequestToggle()
    func bubbleDidRequestCommit()
    func bubbleDidRequestCancel()
    func bubbleDidMove(to frame: NSRect)
}

final class BubbleWindow: NSPanel {
    let bubbleView: BubbleView

    init(frame: NSRect) {
        bubbleView = BubbleView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = bubbleView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BubbleView: NSView {
    weak var delegate: BubbleViewDelegate?

    var state: BubbleState = .idle {
        didSet {
            wantsAnimationTimer = state == .listening
            needsDisplay = true
        }
    }

    var partialTranscript: String = "" {
        didSet {}
    }

    var showCopyButton: Bool = false {
        didSet {}
    }

    private var mouseDownScreenPoint = NSPoint.zero
    private var mouseDownWindowOrigin = NSPoint.zero
    private var hasDragged = false
    private var hover = false
    private var phase: CGFloat = 0
    private var animationTimer: Timer?
    private var tracking: NSTrackingArea?

    private var wantsAnimationTimer: Bool = false {
        didSet {
            if wantsAnimationTimer {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPoint = NSEvent.mouseLocation
        mouseDownWindowOrigin = window?.frame.origin ?? .zero
        hasDragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let deltaX = current.x - mouseDownScreenPoint.x
        let deltaY = current.y - mouseDownScreenPoint.y

        if abs(deltaX) > 2 || abs(deltaY) > 2 {
            hasDragged = true
        }

        let origin = NSPoint(
            x: mouseDownWindowOrigin.x + deltaX,
            y: mouseDownWindowOrigin.y + deltaY
        )
        window.setFrameOrigin(clamped(origin, for: window.frame.size))
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }

        if hasDragged {
            delegate?.bubbleDidMove(to: window.frame)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if state == .listening && cancelButtonRect.contains(point) {
            delegate?.bubbleDidRequestCancel()
        } else if state == .listening && commitButtonRect.contains(point) {
            delegate?.bubbleDidRequestCommit()
        } else {
            delegate?.bubbleDidRequestToggle()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bubbleRect = centerBubbleRect
        drawGlow(around: bubbleRect)
        drawBubble(in: bubbleRect)

        switch state {
        case .idle:
            drawStaticSoundIcon(in: bubbleRect)
        case .listening:
            drawWaveform(in: bubbleRect)
        case .processing:
            drawProcessingIcon(in: bubbleRect)
        case .success:
            drawSuccessIcon(in: bubbleRect)
        case .error:
            drawErrorIcon(in: bubbleRect)
        }

        if state == .listening {
            drawSideButton(in: cancelButtonRect, symbol: .cancel)
            drawSideButton(in: commitButtonRect, symbol: .commit)
        }
    }

    private var centerBubbleRect: NSRect {
        let diameter = min(bounds.height - 8, 38)
        return NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private var cancelButtonRect: NSRect {
        NSRect(x: 6, y: bounds.midY - 11, width: 22, height: 22)
    }

    private var commitButtonRect: NSRect {
        NSRect(x: bounds.maxX - 28, y: bounds.midY - 11, width: 22, height: 22)
    }

    private func drawGlow(around rect: NSRect) {
        let color: NSColor
        switch state {
        case .idle:
            color = hover ? NSColor(calibratedWhite: 0.02, alpha: 0.30) : NSColor(calibratedWhite: 0.02, alpha: 0.18)
        case .listening:
            color = NSColor(calibratedWhite: 0.0, alpha: 0.42)
        case .processing:
            color = NSColor(calibratedWhite: 0.0, alpha: 0.34)
        case .success:
            color = NSColor(calibratedWhite: 0.0, alpha: 0.32)
        case .error:
            color = NSColor(calibratedRed: 0.9, green: 0.12, blue: 0.12, alpha: 0.26)
        }

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = hover || state != .idle ? 12 : 8
        shadow.shadowOffset = .zero
        shadow.shadowColor = color
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawBubble(in rect: NSRect) {
        let path = NSBezierPath(ovalIn: rect)
        let fill: NSColor
        switch state {
        case .idle:
            fill = NSColor(calibratedWhite: 0.03, alpha: hover ? 0.72 : 0.48)
        case .listening:
            fill = NSColor(calibratedWhite: 0.015, alpha: 0.92)
        case .processing:
            fill = NSColor(calibratedWhite: 0.04, alpha: 0.84)
        case .success:
            fill = NSColor(calibratedWhite: 0.015, alpha: 0.90)
        case .error:
            fill = NSColor(calibratedRed: 0.18, green: 0.03, blue: 0.03, alpha: 0.90)
        }
        fill.setFill()
        path.fill()

        NSColor(calibratedWhite: 1.0, alpha: state == .idle ? 0.14 : 0.26).setStroke()
        path.lineWidth = 0.8
        path.stroke()

    }

    private func drawStaticSoundIcon(in rect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: hover ? 0.90 : 0.68).setFill()

        let bars: [CGFloat] = [7, 13, 9]
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 4
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        let startX = rect.midX - totalWidth / 2

        for (index, height) in bars.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = rect.midY - height / 2
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                xRadius: 1.5,
                yRadius: 1.5
            ).fill()
        }
    }

    private func drawMicrophoneIcon(in rect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: hover ? 0.92 : 0.72).setStroke()
        let centerX = rect.midX
        let top = rect.minY + 13
        let body = NSBezierPath(roundedRect: NSRect(x: centerX - 5.5, y: top, width: 11, height: 17), xRadius: 5.5, yRadius: 5.5)
        body.lineWidth = 1.8
        body.stroke()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: centerX, y: top + 25))
        stem.line(to: NSPoint(x: centerX, y: top + 29))
        stem.lineWidth = 1.8
        stem.stroke()

        let base = NSBezierPath()
        base.move(to: NSPoint(x: centerX - 7, y: top + 29))
        base.line(to: NSPoint(x: centerX + 7, y: top + 29))
        base.lineWidth = 1.8
        base.stroke()
    }

    private func drawWaveform(in rect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.90).setFill()

        let clip = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()

        let bars = 4
        let spacing: CGFloat = 3.2
        let barWidth: CGFloat = 3
        let totalWidth = CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing
        let startX = rect.midX - totalWidth / 2

        for index in 0..<bars {
            let offset = CGFloat(index) * 0.75
            let amplitude = (sin(phase + offset) + 1) / 2
            let height = 6 + amplitude * 12
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = rect.midY - height / 2
            let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: height), xRadius: 2, yRadius: 2)
            bar.fill()
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private enum SideButtonSymbol {
        case cancel
        case commit
    }

    private func drawSideButton(in rect: NSRect, symbol: SideButtonSymbol) {
        let background = NSBezierPath(ovalIn: rect)
        NSColor(calibratedWhite: 0.02, alpha: 0.78).setFill()
        background.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
        background.lineWidth = 0.8
        background.stroke()

        NSColor(calibratedWhite: 1.0, alpha: 0.88).setStroke()
        let glyph = NSBezierPath()
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        glyph.lineWidth = 1.8

        switch symbol {
        case .cancel:
            glyph.move(to: NSPoint(x: rect.midX - 4.5, y: rect.midY - 4.5))
            glyph.line(to: NSPoint(x: rect.midX + 4.5, y: rect.midY + 4.5))
            glyph.move(to: NSPoint(x: rect.midX + 4.5, y: rect.midY - 4.5))
            glyph.line(to: NSPoint(x: rect.midX - 4.5, y: rect.midY + 4.5))
        case .commit:
            glyph.move(to: NSPoint(x: rect.midX - 5, y: rect.midY + 1))
            glyph.line(to: NSPoint(x: rect.midX - 1, y: rect.midY + 5))
            glyph.line(to: NSPoint(x: rect.midX + 6, y: rect.midY - 5))
        }

        glyph.stroke()
    }

    private func drawProcessingIcon(in rect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.82).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.2
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 11, startAngle: 20, endAngle: 300)
        path.stroke()
    }

    private func drawSuccessIcon(in rect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.92).setStroke()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 2.6
        path.move(to: NSPoint(x: rect.midX - 8, y: rect.midY + 1))
        path.line(to: NSPoint(x: rect.midX - 2, y: rect.midY + 7))
        path.line(to: NSPoint(x: rect.midX + 9, y: rect.midY - 7))
        path.stroke()
    }

    private func drawErrorIcon(in rect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.90).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.8
        path.move(to: NSPoint(x: rect.midX - 8, y: rect.midY - 8))
        path.line(to: NSPoint(x: rect.midX + 8, y: rect.midY + 8))
        path.move(to: NSPoint(x: rect.midX + 8, y: rect.midY - 8))
        path.line(to: NSPoint(x: rect.midX - 8, y: rect.midY + 8))
        path.stroke()
    }

    private func clamped(_ origin: NSPoint, for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return origin
        }

        let frame = screen.visibleFrame
        return NSPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.42
            self.needsDisplay = true
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}
