import Cocoa

/// Product-grade, non-activating, draggable floating status HUD capsule.
/// Renders a dark-obsidian frosted glass pill with soft ambient shadow,
/// live acoustic waveform bars, and smooth hover/drag without ever stealing focus.
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
    private let rootView: _HUDRootView
    private let shadowLayer = CALayer()
    private let pillContainer = NSView()
    private let effectView = NSVisualEffectView()
    private let tintLayer = CAGradientLayer()
    private let glossLayer = CAGradientLayer()
    private let borderLayer = CALayer()

    private let gripView = _DragGripView()
    private let beaconView = _StatusBeaconView()
    private let meterView = _WaveformView()
    private let progressView = _PillProgressView()
    private let label = NSTextField(labelWithString: "")

    private var presentation: Presentation = .hidden
    private var animationTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?
    private var targetLevel: CGFloat = 0
    private var smoothedLevel: CGFloat = 0
    private var phase: CGFloat = 0
    private var isDragging = false

    // Thread-safe hit rect in Quartz global display coordinates for GlobalHotkeyMonitor.
    private let hitRectLock = NSLock()
    private var quartzHitRect: CGRect?

    private let pillHeight: CGFloat = 32
    private let shadowInsetX: CGFloat = 18
    private let shadowInsetTop: CGFloat = 12
    private let shadowInsetBottom: CGFloat = 22
    private let minPillWidth: CGFloat = 136
    private let maxPillWidth: CGFloat = 310

    private static let savedCenterXKey = "macosAsr.hudCenterX"
    private static let savedCenterYKey = "macosAsr.hudCenterY"

    private init() {
        let initialPillSize = NSSize(width: 156, height: pillHeight)
        let initialPanelSize = NSSize(
            width: initialPillSize.width + shadowInsetX * 2,
            height: initialPillSize.height + shadowInsetTop + shadowInsetBottom
        )

        panel = _NonActivatingHUDPanel(
            contentRect: NSRect(origin: .zero, size: initialPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        rootView = _HUDRootView(frame: NSRect(origin: .zero, size: initialPanelSize))
        rootView.wantsLayer = true
        rootView.layer?.masksToBounds = false

        // Soft ambient floating shadow rendered cleanly on a dedicated backing layer.
        shadowLayer.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.92).cgColor
        shadowLayer.cornerRadius = pillHeight / 2.0
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.34
        shadowLayer.shadowRadius = 11
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        rootView.layer?.addSublayer(shadowLayer)

        pillContainer.wantsLayer = true
        pillContainer.layer?.cornerRadius = pillHeight / 2.0
        pillContainer.layer?.masksToBounds = true

        // Force dark-obsidian glass so the capsule stays crisp on both Light and Dark themes.
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = pillHeight / 2.0
        effectView.layer?.masksToBounds = true

        // Deep obsidian glass gradient tint + subtle top specular highlight.
        tintLayer.colors = [
            NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.86).cgColor,
            NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.92).cgColor,
        ]
        tintLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        tintLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        effectView.layer?.addSublayer(tintLayer)

        glossLayer.colors = [
            NSColor.white.withAlphaComponent(0.11).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor,
        ]
        glossLayer.locations = [0.0, 0.45, 1.0]
        glossLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        glossLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        effectView.layer?.addSublayer(glossLayer)

        borderLayer.cornerRadius = pillHeight / 2.0
        borderLayer.borderWidth = 0.75
        borderLayer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        borderLayer.backgroundColor = NSColor.clear.cgColor
        effectView.layer?.addSublayer(borderLayer)

        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.94)
        label.lineBreakMode = .byTruncatingTail

        pillContainer.addSubview(effectView)
        pillContainer.addSubview(gripView)
        pillContainer.addSubview(beaconView)
        pillContainer.addSubview(meterView)
        pillContainer.addSubview(progressView)
        pillContainer.addSubview(label)

        rootView.pillContainer = pillContainer
        rootView.addSubview(pillContainer)
        panel.contentView = rootView

        rootView.onHoverChanged = { [weak self] hovering in
            self?.applyHoverStyle(hovering)
        }
        rootView.onDragBegan = { [weak self] in
            self?.isDragging = true
            self?.applyHoverStyle(true)
        }
        rootView.onDragged = { [weak self] delta in
            self?.movePanel(by: delta)
        }
        rootView.onDragEnded = { [weak self] in
            self?.isDragging = false
            self?.persistCurrentPillCenter()
        }
        rootView.onDoubleClick = { [weak self] in
            self?.resetPositionToDefault(animated: true)
        }
    }

    /// Called synchronously from GlobalHotkeyMonitor's CGEventTap thread so dragging
    /// the HUD capsule during dictation never interrupts or discards the active utterance.
    func containsQuartzPoint(_ point: CGPoint) -> Bool {
        hitRectLock.lock()
        let rect = quartzHitRect
        hitRectLock.unlock()
        return rect?.contains(point) == true
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

    // MARK: - Rendering & Layout

    private func render(_ state: Presentation) {
        let showMeter: Bool
        let showProgress: Bool
        let accentColor: NSColor
        let text: String
        let steadyTextWidth: CGFloat?

        switch state {
        case .hidden:
            fadeOut()
            return
        case let .downloading(progress):
            showMeter = false
            showProgress = true
            accentColor = NSColor(calibratedRed: 0.24, green: 0.62, blue: 1.0, alpha: 1.0)
            let pct = Int(round(max(0, min(1, progress)) * 100))
            text = "Downloading \(pct)%"
            progressView.progress = CGFloat(progress)
            steadyTextWidth = nil
        case .starting:
            showMeter = false
            showProgress = false
            accentColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.22, alpha: 1.0)
            text = "Starting…"
            steadyTextWidth = nil
        case let .listening(speaking):
            showMeter = true
            showProgress = false
            accentColor = speaking
                ? NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.46, alpha: 1.0)
                : NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.44, alpha: 0.92)
            text = speaking ? "Speaking" : "Listening"
            meterView.setPalette(
                activeColor: NSColor(calibratedRed: 0.26, green: 0.88, blue: 0.52, alpha: 1.0),
                idleColor: NSColor.white.withAlphaComponent(0.42),
                active: speaking
            )
            steadyTextWidth = 55
        case .polishing:
            showMeter = true
            showProgress = false
            accentColor = NSColor(calibratedRed: 0.73, green: 0.48, blue: 1.0, alpha: 1.0)
            text = "Polishing…"
            meterView.setPalette(
                activeColor: NSColor(calibratedRed: 0.76, green: 0.54, blue: 1.0, alpha: 1.0),
                idleColor: NSColor(calibratedRed: 0.66, green: 0.46, blue: 0.96, alpha: 0.6),
                active: true
            )
            steadyTextWidth = 55
        case .finishing:
            showMeter = false
            showProgress = false
            accentColor = NSColor.white.withAlphaComponent(0.65)
            text = "Finishing…"
            steadyTextWidth = nil
        case .calibrating:
            showMeter = false
            showProgress = false
            accentColor = NSColor(calibratedRed: 1.0, green: 0.64, blue: 0.16, alpha: 1.0)
            text = "Calibrating noise… stay quiet"
            steadyTextWidth = nil
        case .calibrationDone:
            showMeter = false
            showProgress = false
            accentColor = NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.46, alpha: 1.0)
            text = "Noise calibrated"
            steadyTextWidth = nil
        case .calibrationFailed:
            showMeter = false
            showProgress = false
            accentColor = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.34, alpha: 1.0)
            text = "Calibration failed"
            steadyTextWidth = nil
        }

        beaconView.accentColor = accentColor
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.94),
                .kern: -0.1,
            ]
        )
        label.sizeToFit()
        meterView.isHidden = !showMeter
        progressView.isHidden = !showProgress

        layoutCapsule(showMeter: showMeter, showProgress: showProgress, steadyTextWidth: steadyTextWidth)
        fadeIn()

        if showMeter || state == .calibrating || state == .starting {
            startAnimationTimer()
        } else {
            stopAnimationTimer()
        }
    }

    private func layoutCapsule(showMeter: Bool, showProgress: Bool, steadyTextWidth: CGFloat?) {
        let paddingLeft: CGFloat = 12
        let paddingRight: CGFloat = 13
        let gripWidth: CGFloat = 6
        let beaconSize: CGFloat = 12
        let meterWidth: CGFloat = showMeter ? 29 : 0
        let progressWidth: CGFloat = showProgress ? 54 : 0
        let measuredTextWidth = ceil(label.frame.width)
        let textSlotWidth = max(measuredTextWidth, steadyTextWidth ?? 0)

        var pillWidth = paddingLeft + gripWidth + 6 + beaconSize + 7 + textSlotWidth + paddingRight
        if showMeter {
            pillWidth += meterWidth + 8
        }
        if showProgress {
            pillWidth += progressWidth + 10
        }
        pillWidth = max(minPillWidth, min(maxPillWidth, ceil(pillWidth)))

        let panelWidth = pillWidth + shadowInsetX * 2
        let panelHeight = pillHeight + shadowInsetTop + shadowInsetBottom

        let center = preferredPillCenter(forPillSize: NSSize(width: pillWidth, height: pillHeight))
        let panelOrigin = NSPoint(
            x: round(center.x - panelWidth / 2.0),
            y: round(center.y - pillHeight / 2.0 - shadowInsetBottom)
        )
        let clampedOrigin = clampPanelOrigin(panelOrigin, panelSize: NSSize(width: panelWidth, height: panelHeight))

        panel.setFrame(NSRect(origin: clampedOrigin, size: NSSize(width: panelWidth, height: panelHeight)), display: false)
        rootView.frame = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: panelHeight))

        let pillFrame = NSRect(x: shadowInsetX, y: shadowInsetBottom, width: pillWidth, height: pillHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = pillFrame
        shadowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: pillFrame.size),
            cornerWidth: pillHeight / 2.0,
            cornerHeight: pillHeight / 2.0,
            transform: nil
        )
        pillContainer.frame = pillFrame
        effectView.frame = pillContainer.bounds
        tintLayer.frame = effectView.bounds
        glossLayer.frame = effectView.bounds
        borderLayer.frame = effectView.bounds
        CATransaction.commit()

        var x = paddingLeft
        gripView.frame = NSRect(x: x, y: (pillHeight - 12) / 2.0, width: gripWidth, height: 12)
        x += gripWidth + 6

        beaconView.frame = NSRect(x: x, y: (pillHeight - beaconSize) / 2.0, width: beaconSize, height: beaconSize)
        x += beaconSize + 7

        if showMeter {
            meterView.frame = NSRect(x: x, y: (pillHeight - 16) / 2.0, width: meterWidth, height: 16)
            meterView.render(
                level: smoothedLevel,
                phase: phase * 1.3,
                mode: presentation == .polishing ? .shimmer : .live
            )
            x += meterWidth + 8
        }

        let labelHeight = ceil(label.frame.height)
        let availableTextWidth = max(40, pillWidth - x - paddingRight - (showProgress ? progressWidth + 10 : 0))
        label.frame = NSRect(
            x: x,
            y: round((pillHeight - labelHeight) / 2.0) + 0.5,
            width: min(measuredTextWidth, availableTextWidth),
            height: labelHeight
        )

        if showProgress {
            progressView.frame = NSRect(
                x: pillWidth - paddingRight - progressWidth,
                y: (pillHeight - 4) / 2.0,
                width: progressWidth,
                height: 4
            )
        }

        rootView.refreshTrackingArea()
        updateQuartzHitRect()
    }

    // MARK: - Positioning & Dragging

    private func preferredPillCenter(forPillSize pillSize: NSSize) -> NSPoint {
        if panel.isVisible && isDragging {
            return currentPillCenter()
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.savedCenterXKey) != nil,
           defaults.object(forKey: Self.savedCenterYKey) != nil
        {
            let saved = NSPoint(
                x: defaults.double(forKey: Self.savedCenterXKey),
                y: defaults.double(forKey: Self.savedCenterYKey)
            )
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(saved) }) {
                return saved
            }
        }
        return defaultPillCenter()
    }

    private func defaultPillCenter() -> NSPoint {
        let screen = targetScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX, y: visible.minY + 64.0)
    }

    private func currentPillCenter() -> NSPoint {
        let frame = panel.frame
        return NSPoint(
            x: frame.minX + shadowInsetX + pillContainer.frame.width / 2.0,
            y: frame.minY + shadowInsetBottom + pillHeight / 2.0
        )
    }

    private func movePanel(by delta: NSPoint) {
        let nextOrigin = NSPoint(x: panel.frame.origin.x + delta.x, y: panel.frame.origin.y + delta.y)
        let clamped = clampPanelOrigin(nextOrigin, panelSize: panel.frame.size)
        panel.setFrameOrigin(clamped)
        updateQuartzHitRect()
    }

    private func persistCurrentPillCenter() {
        let center = currentPillCenter()
        UserDefaults.standard.set(Double(center.x), forKey: Self.savedCenterXKey)
        UserDefaults.standard.set(Double(center.y), forKey: Self.savedCenterYKey)
    }

    private func resetPositionToDefault(animated: Bool) {
        UserDefaults.standard.removeObject(forKey: Self.savedCenterXKey)
        UserDefaults.standard.removeObject(forKey: Self.savedCenterYKey)
        let center = defaultPillCenter()
        let targetOrigin = clampPanelOrigin(
            NSPoint(
                x: round(center.x - panel.frame.width / 2.0),
                y: round(center.y - pillHeight / 2.0 - shadowInsetBottom)
            ),
            panelSize: panel.frame.size
        )
        let targetFrame = NSRect(origin: targetOrigin, size: panel.frame.size)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.updateQuartzHitRect()
            })
        } else {
            panel.setFrame(targetFrame, display: true)
            updateQuartzHitRect()
        }
    }

    private func clampPanelOrigin(_ origin: NSPoint, panelSize: NSSize) -> NSPoint {
        let pillCenter = NSPoint(
            x: origin.x + panelSize.width / 2.0,
            y: origin.y + shadowInsetBottom + pillHeight / 2.0
        )
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pillCenter) }) ?? targetScreen()
        guard let visible = screen?.visibleFrame else { return origin }

        let pillWidth = panelSize.width - shadowInsetX * 2
        let margin: CGFloat = 12
        let minPillX = visible.minX + margin
        let maxPillX = visible.maxX - pillWidth - margin
        let minPillY = visible.minY + margin
        let maxPillY = visible.maxY - pillHeight - margin

        let clampedPillX = min(max(origin.x + shadowInsetX, minPillX), max(minPillX, maxPillX))
        let clampedPillY = min(max(origin.y + shadowInsetBottom, minPillY), max(minPillY, maxPillY))
        return NSPoint(x: round(clampedPillX - shadowInsetX), y: round(clampedPillY - shadowInsetBottom))
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underMouse
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func updateQuartzHitRect() {
        guard panel.isVisible, presentation != .hidden else {
            clearQuartzHitRect()
            return
        }
        // Convert AppKit global pill frame (bottom-left primary origin) to Quartz top-left origin.
        let pillGlobal = NSRect(
            x: panel.frame.minX + shadowInsetX,
            y: panel.frame.minY + shadowInsetBottom,
            width: pillContainer.frame.width,
            height: pillContainer.frame.height
        )
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzRect = CGRect(
            x: pillGlobal.minX,
            y: primaryHeight - pillGlobal.maxY,
            width: pillGlobal.width,
            height: pillGlobal.height
        ).insetBy(dx: -4, dy: -4)

        hitRectLock.lock()
        quartzHitRect = quartzRect
        hitRectLock.unlock()
    }

    private func clearQuartzHitRect() {
        hitRectLock.lock()
        quartzHitRect = nil
        hitRectLock.unlock()
    }

    private func applyHoverStyle(_ hovering: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        borderLayer.borderColor = NSColor.white.withAlphaComponent(hovering ? 0.28 : 0.16).cgColor
        gripView.setHighlighted(hovering)
        CATransaction.commit()
    }

    // MARK: - Visibility & Animation

    private func fadeIn() {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        updateQuartzHitRect()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        stopAnimationTimer()
        targetLevel = 0
        smoothedLevel = 0
        clearQuartzHitRect()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.presentation == .hidden else { return }
            self.panel.orderOut(nil)
            self.clearQuartzHitRect()
        })
    }

    private func hideImmediately() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        stopAnimationTimer()
        targetLevel = 0
        smoothedLevel = 0
        clearQuartzHitRect()
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
        phase += 0.18
        let pulse = 0.5 + 0.5 * sin(phase * 0.9)
        beaconView.setPulse(pulse)

        if presentation == .polishing {
            meterView.render(level: 0.45, phase: phase * 1.4, mode: .shimmer)
            return
        }
        if case .listening = presentation {
            if targetLevel > smoothedLevel {
                smoothedLevel = smoothedLevel * 0.40 + targetLevel * 0.60
            } else {
                smoothedLevel = smoothedLevel * 0.82 + targetLevel * 0.18
            }
            targetLevel *= 0.88
            meterView.render(level: smoothedLevel, phase: phase * 1.3, mode: .live)
        }
    }
}

private final class _NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Root view that limits mouse interaction strictly to the pill area, supports
/// smooth non-activating dragging, hover cursor feedback, and double-click reset.
private final class _HUDRootView: NSView {
    weak var pillContainer: NSView?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastMouseLocation: NSPoint?
    private var draggedDuringPress = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pill = pillContainer, pill.frame.contains(point) else { return nil }
        return self
    }

    func refreshTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        guard let pill = pillContainer else { return }
        let area = NSTrackingArea(
            rect: pill.frame,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if lastMouseLocation != nil {
            NSCursor.closedHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        if lastMouseLocation == nil {
            onHoverChanged?(false)
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        lastMouseLocation = NSEvent.mouseLocation
        draggedDuringPress = false
        NSCursor.closedHand.push()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastMouseLocation else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - previous.x, y: current.y - previous.y)
        if abs(delta.x) > 0.2 || abs(delta.y) > 0.2 {
            draggedDuringPress = true
            onDragged?(delta)
        }
        lastMouseLocation = current
    }

    override func mouseUp(with event: NSEvent) {
        if lastMouseLocation != nil {
            NSCursor.pop()
            lastMouseLocation = nil
            if draggedDuringPress {
                onDragEnded?()
            }
        }
        let local = convert(event.locationInWindow, from: nil)
        let inside = pillContainer?.frame.contains(local) == true
        onHoverChanged?(inside)
        if inside {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// Subtle 2x3 micro drag-handle dots on the leading edge of the capsule.
private final class _DragGripView: NSView {
    private var dotLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0 ..< 6 {
            let dot = CALayer()
            dot.cornerRadius = 0.85
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            layer?.addSublayer(dot)
            dotLayers.append(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 1.7
        let colGap: CGFloat = 2.4
        let rowGap: CGFloat = 2.6
        for row in 0 ..< 3 {
            for col in 0 ..< 2 {
                let idx = row * 2 + col
                let x = CGFloat(col) * (size + colGap)
                let y = CGFloat(row) * (size + rowGap) + 0.5
                dotLayers[idx].frame = CGRect(x: x, y: y, width: size, height: size)
            }
        }
    }

    func setHighlighted(_ highlighted: Bool) {
        let color = NSColor.white.withAlphaComponent(highlighted ? 0.55 : 0.22).cgColor
        for dot in dotLayers {
            dot.backgroundColor = color
        }
    }
}

/// Glowing OLED-style status beacon with a soft feathered radial LED bloom.
private final class _StatusBeaconView: NSView {
    private let bloomLayer = CALayer()
    private let coreLayer = CALayer()

    var accentColor: NSColor = .systemGreen {
        didSet {
            let cg = accentColor.cgColor
            coreLayer.backgroundColor = cg
            coreLayer.shadowColor = cg
            bloomLayer.backgroundColor = cg
            bloomLayer.shadowColor = cg
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        bloomLayer.shadowOffset = .zero
        bloomLayer.shadowRadius = 6.5
        bloomLayer.shadowOpacity = 0.55

        coreLayer.shadowOffset = .zero
        coreLayer.shadowRadius = 2.5
        coreLayer.shadowOpacity = 0.85

        layer?.addSublayer(bloomLayer)
        layer?.addSublayer(coreLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let coreSize: CGFloat = 7
        let coreFrame = CGRect(
            x: (bounds.width - coreSize) / 2.0,
            y: (bounds.height - coreSize) / 2.0,
            width: coreSize,
            height: coreSize
        )
        let circlePath = CGPath(ellipseIn: CGRect(origin: .zero, size: coreFrame.size), transform: nil)
        bloomLayer.frame = coreFrame
        bloomLayer.cornerRadius = coreSize / 2.0
        bloomLayer.shadowPath = circlePath
        coreLayer.frame = coreFrame
        coreLayer.cornerRadius = coreSize / 2.0
        coreLayer.shadowPath = circlePath
        CATransaction.commit()
    }

    func setPulse(_ pulse: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bloomLayer.shadowOpacity = Float(0.32 + 0.42 * pulse)
        bloomLayer.shadowRadius = 5.0 + 2.5 * pulse
        CATransaction.commit()
    }
}

/// Symmetric 7-bar liquid acoustic waveform meter.
private final class _WaveformView: NSView {
    enum Mode {
        case live
        case shimmer
    }

    private let barCount = 7
    private var barLayers: [CALayer] = []
    private let weights: [CGFloat] = [0.38, 0.68, 0.92, 1.0, 0.90, 0.64, 0.36]
    private var activeColor: NSColor = .systemGreen
    private var idleColor: NSColor = NSColor.white.withAlphaComponent(0.42)
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0 ..< barCount {
            let bar = CALayer()
            bar.cornerRadius = 1.0
            bar.backgroundColor = idleColor.cgColor
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPalette(activeColor: NSColor, idleColor: NSColor, active: Bool) {
        self.activeColor = activeColor
        self.idleColor = idleColor
        self.isActive = active
        let color = (active ? activeColor : idleColor).cgColor
        for layer in barLayers {
            layer.backgroundColor = color
        }
    }

    func render(level: CGFloat, phase: CGFloat, mode: Mode) {
        let barWidth: CGFloat = 2.0
        let gap: CGFloat = 2.5
        let maxHeight = max(12, bounds.height)
        let minHeight: CGFloat = 3.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for idx in 0 ..< barCount {
            let x = CGFloat(idx) * (barWidth + gap)
            let normalized: CGFloat
            switch mode {
            case .shimmer:
                normalized = 0.22 + 0.56 * (0.5 + 0.5 * sin(phase + CGFloat(idx) * 0.75)) * weights[idx]
            case .live:
                if level > 0.05 {
                    let wave = 0.78 + 0.22 * sin(phase * 1.45 + CGFloat(idx) * 1.15)
                    normalized = min(1.0, max(0.14, level * weights[idx] * wave))
                } else {
                    // Subtle organic breathing idle ripple so the capsule feels alive.
                    let breath = 0.08 + 0.10 * (0.5 + 0.5 * sin(phase * 0.55 + CGFloat(idx) * 0.65))
                    normalized = breath * (0.65 + 0.35 * weights[idx])
                }
            }
            let h = minHeight + (maxHeight - minHeight) * max(0, min(1, normalized))
            let y = (maxHeight - h) / 2.0
            barLayers[idx].frame = CGRect(x: x, y: y, width: barWidth, height: h)
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
        trackLayer.cornerRadius = 2.0
        trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        fillLayer.cornerRadius = 2.0
        fillLayer.backgroundColor = NSColor(calibratedRed: 0.28, green: 0.66, blue: 1.0, alpha: 1.0).cgColor
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
