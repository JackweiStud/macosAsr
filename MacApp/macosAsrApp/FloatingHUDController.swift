import Cocoa

/// Minimal, non-activating, click-through floating status HUD capsule.
/// Never steals focus or blocks mouse/keyboard events from the target editor.
final class FloatingHUDController {
    static let shared = FloatingHUDController()

    enum Presentation: Equatable {
        case hidden
        case downloading(progress: Double)
        case starting
        case listening(speaking: Bool)
        case polishing
        case finishing
        case calibrating
        case calibrationDone
        case calibrationFailed(String)
    }

    private let panel: _NonActivatingHUDPanel
    private let effectView: NSVisualEffectView
    private let dotView = NSView()
    private let meterView = _LevelMeterView()
    private let progressView = _PillProgressView()
    private let label = NSTextField(labelWithString: "")

    private var presentation: Presentation = .hidden
    private var animationTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?
    private var targetLevel: CGFloat = 0
    private var smoothedLevel: CGFloat = 0
    private var phase: CGFloat = 0

    private let panelHeight: CGFloat = 34
    private let minWidth: CGFloat = 164
    private let maxWidth: CGFloat = 300

    private init() {
        panel = _NonActivatingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 176, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 176, height: 34))
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 17
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4.5

        label.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        effectView.addSubview(dotView)
        effectView.addSubview(meterView)
        effectView.addSubview(progressView)
        effectView.addSubview(label)
        panel.contentView = effectView
    }

    func setEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        if !enabled {
            hideImmediately()
        } else if presentation != .hidden {
            render(presentation)
        }
    }

    func update(_ next: Presentation, autoHideAfter delay: TimeInterval? = nil) {
        precondition(Thread.isMainThread)
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        presentation = next
        guard ConfigManager.shared.hudEnabled else {
            hideImmediately()
            return
        }

        if next == .hidden {
            fadeOut()
            return
        }

        render(next)
        if let delay {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.presentation == next else { return }
                self.presentation = .hidden
                self.fadeOut()
            }
            autoHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func updateAudioLevel(_ level: Double, speaking: Bool) {
        precondition(Thread.isMainThread)
        targetLevel = CGFloat(max(0.0, min(1.0, level)))
        if case let .listening(prevSpeaking) = presentation, prevSpeaking != speaking {
            presentation = .listening(speaking: speaking)
            if ConfigManager.shared.hudEnabled {
                render(presentation)
            }
        }
    }

    // MARK: - Rendering

    private func render(_ state: Presentation) {
        let showMeter: Bool
        let showProgress: Bool
        let dotColor: NSColor
        let text: String

        switch state {
        case .hidden:
            fadeOut()
            return
        case let .downloading(progress):
            showMeter = false
            showProgress = true
            dotColor = .systemBlue
            let pct = Int(round(max(0, min(1, progress)) * 100))
            text = "Downloading model \(pct)%"
            progressView.progress = CGFloat(progress)
        case .starting:
            showMeter = false
            showProgress = false
            dotColor = .systemYellow
            text = "Starting…"
        case let .listening(speaking):
            showMeter = true
            showProgress = false
            dotColor = .systemGreen
            text = speaking ? "Speaking" : "Listening"
            meterView.barColor = speaking ? .systemGreen : NSColor.secondaryLabelColor.withAlphaComponent(0.75)
        case .polishing:
            showMeter = true
            showProgress = false
            dotColor = .systemPurple
            text = "Polishing…"
            meterView.barColor = .systemPurple
        case .finishing:
            showMeter = false
            showProgress = false
            dotColor = .secondaryLabelColor
            text = "Finishing…"
        case .calibrating:
            showMeter = false
            showProgress = false
            dotColor = .systemOrange
            text = "Calibrating noise… stay quiet"
        case .calibrationDone:
            showMeter = false
            showProgress = false
            dotColor = .systemGreen
            text = "Noise calibrated"
        case .calibrationFailed:
            showMeter = false
            showProgress = false
            dotColor = .systemRed
            text = "Calibration failed"
        }

        dotView.layer?.backgroundColor = dotColor.cgColor
        label.stringValue = text
        label.sizeToFit()
        meterView.isHidden = !showMeter
        progressView.isHidden = !showProgress

        layoutCapsule(showMeter: showMeter, showProgress: showProgress)
        fadeIn()

        if showMeter {
            startAnimationTimer()
        } else {
            stopAnimationTimer()
        }
    }

    private func layoutCapsule(showMeter: Bool, showProgress: Bool) {
        let paddingX: CGFloat = 14
        let dotSize: CGFloat = 9
        let gap: CGFloat = 8
        let meterWidth: CGFloat = showMeter ? 28 : 0
        let progressWidth: CGFloat = showProgress ? 54 : 0
        let labelWidth = ceil(label.frame.width)

        var contentWidth = paddingX + dotSize + gap + labelWidth + paddingX
        if showMeter {
            contentWidth += meterWidth + gap
        }
        if showProgress {
            contentWidth += progressWidth + gap
        }
        let width = max(minWidth, min(maxWidth, contentWidth))

        let screen = targetScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = round(visible.midX - width / 2.0)
        let originY = round(visible.minY + 72.0)

        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: panelHeight), display: false)
        effectView.frame = NSRect(x: 0, y: 0, width: width, height: panelHeight)
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        var x = paddingX
        dotView.frame = NSRect(x: x, y: (panelHeight - dotSize) / 2.0, width: dotSize, height: dotSize)
        x += dotSize + gap

        if showMeter {
            meterView.frame = NSRect(x: x, y: (panelHeight - 16) / 2.0, width: meterWidth, height: 16)
            x += meterWidth + gap
        }

        let labelHeight = ceil(label.frame.height)
        let availableLabelWidth = max(40, width - x - paddingX - (showProgress ? progressWidth + gap : 0))
        label.frame = NSRect(
            x: x,
            y: round((panelHeight - labelHeight) / 2.0),
            width: min(labelWidth, availableLabelWidth),
            height: labelHeight
        )
        x += label.frame.width + gap

        if showProgress {
            progressView.frame = NSRect(x: width - paddingX - progressWidth, y: (panelHeight - 5) / 2.0, width: progressWidth, height: 5)
        }
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func fadeIn() {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        stopAnimationTimer()
        targetLevel = 0
        smoothedLevel = 0
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.presentation == .hidden else { return }
            self.panel.orderOut(nil)
        })
    }

    private func hideImmediately() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        stopAnimationTimer()
        targetLevel = 0
        smoothedLevel = 0
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tickAnimation() {
        phase += 0.28
        if presentation == .polishing {
            meterView.render(level: 0.42, phase: phase, shimmer: true)
            return
        }
        // Fast attack, smooth decay for crisp visual mic feedback.
        if targetLevel > smoothedLevel {
            smoothedLevel = smoothedLevel * 0.45 + targetLevel * 0.55
        } else {
            smoothedLevel = smoothedLevel * 0.80 + targetLevel * 0.20
        }
        targetLevel *= 0.90
        meterView.render(level: smoothedLevel, phase: phase, shimmer: false)
    }
}

private final class _NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class _LevelMeterView: NSView {
    private let barCount = 5
    private var barLayers: [CALayer] = []
    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.82, 0.58]

    var barColor: NSColor = .systemGreen {
        didSet {
            for layer in barLayers {
                layer.backgroundColor = barColor.cgColor
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0 ..< barCount {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            bar.backgroundColor = barColor.cgColor
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(level: CGFloat, phase: CGFloat, shimmer: Bool) {
        let width: CGFloat = 3
        let gap: CGFloat = 3
        let maxHeight = max(10, bounds.height)
        let minHeight: CGFloat = 3.5

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for idx in 0 ..< barCount {
            let x = CGFloat(idx) * (width + gap)
            let wave: CGFloat
            if shimmer {
                wave = 0.28 + 0.52 * (0.5 + 0.5 * sin(phase + CGFloat(idx) * 0.85))
            } else {
                let jitter = level > 0.06 ? (0.82 + 0.18 * sin(phase * 1.4 + CGFloat(idx) * 1.3)) : 1.0
                wave = min(1.0, level * weights[idx] * jitter)
            }
            let h = minHeight + (maxHeight - minHeight) * max(0, min(1, wave))
            let y = (maxHeight - h) / 2.0
            barLayers[idx].frame = CGRect(x: x, y: y, width: width, height: h)
        }
        CATransaction.commit()
    }
}

private final class _PillProgressView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    var progress: CGFloat = 0 {
        didSet {
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        trackLayer.cornerRadius = 2.5
        trackLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fillLayer.cornerRadius = 2.5
        fillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        let clamped = max(0, min(1, progress))
        fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        CATransaction.commit()
    }
}
