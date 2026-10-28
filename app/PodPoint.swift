// PodPoint: control the Mac cursor with AirPods head tracking.
// Single stem press = left click, double press = right click, triple press = recentre.
// Smoothing uses the One Euro filter (Casiez, Roussel and Vogel, CHI 2012).

import Cocoa
import CoreMotion
import MediaPlayer
import AVFoundation
import ApplicationServices
import QuartzCore

// MARK: - One Euro filter

final class OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double
    private var xPrev: Double?
    private var dxPrev: Double = 0
    private var tPrev: Double = 0

    init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    func reset() {
        xPrev = nil
        dxPrev = 0
    }

    func filter(_ x: Double, t: Double) -> Double {
        guard let xp = xPrev else {
            xPrev = x
            tPrev = t
            return x
        }
        let dt = max(t - tPrev, 0.001)
        let dx = (x - xp) / dt
        let aD = alpha(dCutoff, dt)
        let dxHat = aD * dx + (1.0 - aD) * dxPrev
        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff, dt)
        let xHat = a * x + (1.0 - a) * xp
        xPrev = xHat
        dxPrev = dxHat
        tPrev = t
        return xHat
    }
}

// MARK: - Head angle to screen mapping (affine, fitted by least squares)

struct Affine: Codable {
    var ax: Double, bx: Double, cx: Double
    var ay: Double, by: Double, cy: Double

    func map(_ yaw: Double, _ pitch: Double) -> CGPoint {
        CGPoint(x: ax * yaw + bx * pitch + cx, y: ay * yaw + by * pitch + cy)
    }

    func linear(_ dYaw: Double, _ dPitch: Double) -> CGPoint {
        CGPoint(x: ax * dYaw + bx * dPitch, y: ay * dYaw + by * dPitch)
    }

    static func fit(_ samples: [(Double, Double, Double, Double)]) -> Affine? {
        var a = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var bxv = [0.0, 0.0, 0.0]
        var byv = [0.0, 0.0, 0.0]
        for s in samples {
            let f = [s.0, s.1, 1.0]
            for i in 0..<3 {
                for j in 0..<3 { a[i][j] += f[i] * f[j] }
                bxv[i] += f[i] * s.2
                byv[i] += f[i] * s.3
            }
        }
        guard let sx = solve3(a, bxv), let sy = solve3(a, byv) else { return nil }
        return Affine(ax: sx[0], bx: sx[1], cx: sx[2], ay: sy[0], by: sy[1], cy: sy[2])
    }

    private static func solve3(_ input: [[Double]], _ rhs: [Double]) -> [Double]? {
        var m = input
        var v = rhs
        for i in 0..<3 {
            var p = i
            for r in i..<3 where abs(m[r][i]) > abs(m[p][i]) { p = r }
            if abs(m[p][i]) < 1e-12 { return nil }
            m.swapAt(i, p)
            v.swapAt(i, p)
            for r in 0..<3 where r != i {
                let f = m[r][i] / m[i][i]
                for c in i..<3 { m[r][c] -= f * m[i][c] }
                v[r] -= f * v[i]
            }
        }
        return [v[0] / m[0][0], v[1] / m[1][1], v[2] / m[2][2]]
    }
}

// MARK: - Settings

enum Mode: String { case absolute, joystick }

final class Settings {
    private let d = UserDefaults.standard

    var mode: Mode {
        get { Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .absolute }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }
    var speed: Double {
        get { d.object(forKey: "speed") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "speed") }
    }
    var smoothing: Int {   // 0 low, 1 normal, 2 high
        get { d.object(forKey: "smoothing") as? Int ?? 1 }
        set { d.set(newValue, forKey: "smoothing") }
    }
    var invertX: Bool {
        get { d.bool(forKey: "invertX") }
        set { d.set(newValue, forKey: "invertX") }
    }
    var invertY: Bool {
        get { d.bool(forKey: "invertY") }
        set { d.set(newValue, forKey: "invertY") }
    }
    var clickLookback: Double {   // seconds: click where the cursor was this long before the press arrived
        get { d.object(forKey: "clickLookback") as? Double ?? 0.30 }
        set { d.set(newValue, forKey: "clickLookback") }
    }
    var model: Affine? {
        get {
            guard let data = d.data(forKey: "model") else { return nil }
            return try? JSONDecoder().decode(Affine.self, from: data)
        }
        set {
            if let m = newValue, let data = try? JSONEncoder().encode(m) {
                d.set(data, forKey: "model")
            } else {
                d.removeObject(forKey: "model")
            }
        }
    }
}

// MARK: - Calibration overlay

final class CalibrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CalibrationView: NSView {
    var targetPoint: CGPoint = .zero
    var message: String = ""
    var onKey: ((UInt16) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKey?(event.keyCode)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.0, alpha: 0.6).setFill()
        bounds.fill()

        let c = targetPoint
        NSColor.systemGreen.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 30, y: c.y - 30, width: 60, height: 60)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: message, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.5 + 70))
    }
}

final class Calibrator {
    private let fractions: [(Double, Double)] = [(0.5, 0.5), (0.08, 0.08), (0.92, 0.08), (0.92, 0.92), (0.08, 0.92)]
    private let names = ["the middle", "the top left", "the top right", "the bottom right", "the bottom left"]
    private var step = 0
    private var captured: [(Double, Double, Double, Double)] = []
    private let window: CalibrationWindow
    private let view: CalibrationView
    private let displayRect: CGRect   // CG coordinates of the main display
    private let headNow: () -> (Double, Double)?
    private let finish: (Affine?) -> Void

    init(headNow: @escaping () -> (Double, Double)?, finish: @escaping (Affine?) -> Void) {
        self.headNow = headNow
        self.finish = finish
        displayRect = CGDisplayBounds(CGMainDisplayID())
        let frame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = CalibrationWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        view = CalibrationView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        view.onKey = { [weak self] code in self?.key(code) }
    }

    func start() {
        step = 0
        captured = []
        update()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func update() {
        let f = fractions[step]
        view.targetPoint = CGPoint(x: f.0 * view.bounds.width, y: (1.0 - f.1) * view.bounds.height)
        view.message = "Look at the dot in \(names[step]), then press an AirPod stem or Space  (\(step + 1) of \(fractions.count))   Esc to cancel"
        view.needsDisplay = true
    }

    private func key(_ code: UInt16) {
        switch code {
        case 49, 36: capture()        // Space, Return
        case 53: close(nil)           // Escape
        default: break
        }
    }

    func capture() {
        guard let head = headNow() else {
            view.message = "No head tracking. Check your AirPods are in, then try again."
            view.needsDisplay = true
            return
        }
        let f = fractions[step]
        let x = displayRect.origin.x + f.0 * displayRect.width
        let y = displayRect.origin.y + f.1 * displayRect.height
        captured.append((head.0, head.1, x, y))
        step += 1
        if step < fractions.count {
            update()
            return
        }
        let yaws = captured.map { $0.0 }
        let pitches = captured.map { $0.1 }
        let yawSpread = (yaws.max() ?? 0) - (yaws.min() ?? 0)
        let pitchSpread = (pitches.max() ?? 0) - (pitches.min() ?? 0)
        if yawSpread < 0.05 || pitchSpread < 0.03 {
            step = 0
            captured = []
            update()
            view.message = "Your head barely moved. Turn your head (not just your eyes) to each dot. Starting again."
            view.needsDisplay = true
            return
        }
        close(Affine.fit(captured))
    }

    private func close(_ result: Affine?) {
        window.orderOut(nil)
        finish(result)
    }
}

// MARK: - App

final class PodPoint: NSObject, NSApplicationDelegate, NSMenuDelegate, CMHeadphoneMotionManagerDelegate {
    private let settings = Settings()
    private let motion = CMHeadphoneMotionManager()
    private var fYaw = OneEuroFilter(minCutoff: 0.8, beta: 4.0)
    private var fPitch = OneEuroFilter(minCutoff: 0.8, beta: 4.0)

    private var refYaw: Double?
    private var headYaw = 0.0          // filtered, relative to refYaw (radians)
    private var headPitch = 0.0
    private var rawSamples: [(Double, Double, Double)] = []   // t, yaw, pitch (unfiltered, relative)
    private var lastMotion = 0.0
    private var haveSample = false

    private var enabled = true
    private var bias = CGPoint.zero
    private var cursor = CGPoint.zero
    private var history: [(Double, CGPoint)] = []
    private var freezeUntil = 0.0
    private var needsRebias = false
    private var pauseUntil = 0.0
    private var lastTick = CACurrentMediaTime()
    private var bounds = CGRect.null

    private var joyTarget = CGPoint.zero
    private var joyCentre = (0.0, 0.0)

    private var precisionActive = false
    private var precisionAnchorCursor = CGPoint.zero
    private var precisionAnchorHead = (0.0, 0.0)

    private var lastSingle = 0.0
    private var lastLeftClick = (0.0, CGPoint.zero)

    private var calibrator: Calibrator?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let engine = AVAudioEngine()
    private var timer: Timer?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        applySmoothing()
        refreshBounds()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.refreshBounds() }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        setupHotkeys()
        setupRemoteCommands()
        startKeepAliveAudio()
        startMotion()

        timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    // MARK: Head tracking

    private func startMotion() {
        motion.delegate = self
        guard motion.isDeviceMotionAvailable else { return }
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            self.onMotion(m)
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        resetTracking()
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        resetTracking()
    }

    private func resetTracking() {
        refYaw = nil
        haveSample = false
        fYaw.reset()
        fPitch.reset()
        rawSamples.removeAll()
    }

    private func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

    private func onMotion(_ m: CMDeviceMotion) {
        let t = CACurrentMediaTime()
        if refYaw == nil { refYaw = m.attitude.yaw }
        let ry = wrap(m.attitude.yaw - (refYaw ?? 0))
        let rp = m.attitude.pitch
        headYaw = fYaw.filter(ry, t: t)
        headPitch = fPitch.filter(rp, t: t)
        lastMotion = t
        rawSamples.append((t, ry, rp))
        rawSamples.removeAll { t - $0.0 > 1.0 }
        if !haveSample {
            haveSample = true
            rebias()
        }
    }

    private var tracking: Bool { haveSample && CACurrentMediaTime() - lastMotion < 0.5 }

    private var adjYaw: Double { headYaw * (settings.invertX ? -1 : 1) }
    private var adjPitch: Double { headPitch * (settings.invertY ? -1 : 1) }

    private func averagedHead() -> (Double, Double)? {
        guard tracking else { return nil }
        let now = CACurrentMediaTime()
        let recent = rawSamples.filter { now - $0.0 < 0.5 }
        guard !recent.isEmpty else { return nil }
        let n = Double(recent.count)
        return (recent.map { $0.1 }.reduce(0, +) / n, recent.map { $0.2 }.reduce(0, +) / n)
    }

    // MARK: Mapping

    private func currentModel() -> Affine {
        if let m = settings.model { return m }
        let r = CGDisplayBounds(CGMainDisplayID())
        return Affine(ax: -r.width / 0.70, bx: 0, cx: r.midX, ay: 0, by: -r.height / 0.42, cy: r.midY)
    }

    private func mapNoBias() -> CGPoint {
        let s = settings.speed
        return currentModel().map(adjYaw * s, adjPitch * s)
    }

    private func headTarget() -> CGPoint {
        let p = mapNoBias()
        return CGPoint(x: p.x + bias.x, y: p.y + bias.y)
    }

    private func currentMouse() -> CGPoint {
        CGEvent(source: nil)?.location ?? cursor
    }

    private func refreshBounds() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        bounds = ids.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        guard !bounds.isNull else { return p }
        return CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(p.y, bounds.minY), bounds.maxY - 1))
    }

    /// Re-anchor so the head's current direction maps to wherever the cursor is now (no jump).
    private func rebias() {
        cursor = currentMouse()
        let raw = mapNoBias()
        bias = CGPoint(x: cursor.x - raw.x, y: cursor.y - raw.y)
        joyTarget = cursor
        joyCentre = (adjYaw, adjPitch)
        precisionActive = false
        history.removeAll()
    }

    /// Face the middle of the main screen: cursor goes to the middle and tracking re-anchors there.
    private func recentre() {
        let r = CGDisplayBounds(CGMainDisplayID())
        let mid = CGPoint(x: r.midX, y: r.midY)
        postMouse(.mouseMoved, mid, .left)
        cursor = mid
        let raw = mapNoBias()
        bias = CGPoint(x: mid.x - raw.x, y: mid.y - raw.y)
        joyTarget = mid
        joyCentre = (adjYaw, adjPitch)
        precisionActive = false
        history.removeAll()
    }

    // MARK: Cursor loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        guard enabled, calibrator == nil, tracking else { return }

        if now < freezeUntil { return }
        if needsRebias {
            needsRebias = false
            rebias()
            return
        }

        // If the real mouse or trackpad moved the pointer, follow it instead of fighting it.
        let actual = currentMouse()
        if hypot(actual.x - cursor.x, actual.y - cursor.y) > 4 {
            pauseUntil = now + 0.5
            rebias()
            return
        }
        if now < pauseUntil {
            rebias()
            return
        }

        let precision = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
        var target: CGPoint

        switch settings.mode {
        case .absolute:
            if precision {
                if !precisionActive {
                    precisionActive = true
                    precisionAnchorCursor = cursor
                    precisionAnchorHead = (adjYaw, adjPitch)
                }
                let s = settings.speed * 0.25
                let d = currentModel().linear((adjYaw - precisionAnchorHead.0) * s, (adjPitch - precisionAnchorHead.1) * s)
                target = CGPoint(x: precisionAnchorCursor.x + d.x, y: precisionAnchorCursor.y + d.y)
            } else {
                if precisionActive {
                    precisionActive = false
                    let raw = mapNoBias()
                    bias = CGPoint(x: cursor.x - raw.x, y: cursor.y - raw.y)
                }
                target = headTarget()
            }
        case .joystick:
            func deadZone(_ v: Double, _ dz: Double) -> Double {
                abs(v) < dz ? 0 : v - (v > 0 ? dz : -dz)
            }
            let gain = 1800.0 * settings.speed * (precision ? 0.3 : 1.0)
            let vx = -deadZone(adjYaw - joyCentre.0, 0.035) * gain
            let vy = -deadZone(adjPitch - joyCentre.1, 0.03) * gain
            joyTarget = clamp(CGPoint(x: joyTarget.x + vx * dt, y: joyTarget.y + vy * dt))
            target = joyTarget
        }

        // Ease towards the target at 120 Hz so 25 Hz head data still looks smooth.
        let k = 1.0 - exp(-dt / 0.035)
        var next = CGPoint(x: cursor.x + (target.x - cursor.x) * k, y: cursor.y + (target.y - cursor.y) * k)
        next = clamp(next)
        if hypot(next.x - cursor.x, next.y - cursor.y) < 0.5 { return }
        postMouse(.mouseMoved, next, .left)
        cursor = next
        history.append((now, next))
        history.removeAll { now - $0.0 > 1.5 }
    }

    private func postMouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clickState: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickState)
        e.post(tap: .cghidEventTap)
    }

    private func position(secondsAgo s: Double) -> CGPoint {
        let t = CACurrentMediaTime() - s
        for h in history.reversed() where h.0 <= t { return h.1 }
        return history.first?.1 ?? cursor
    }

    // MARK: Clicks from AirPod stems

    private enum Press { case single, double, triple }

    private func stemPress(_ p: Press) {
        if let calibrator {
            if p == .single { calibrator.capture() }
            return
        }
        guard enabled else { return }
        let now = CACurrentMediaTime()
        switch p {
        case .single:
            if now - lastSingle < 0.25 { return }   // play and pause can both arrive for one press
            lastSingle = now
            click(right: false)
        case .double:
            click(right: true)
        case .triple:
            recentre()
        }
    }

    private func click(right: Bool) {
        let now = CACurrentMediaTime()
        // Pressing a stem nudges your head, and the press arrives a moment late,
        // so click where the cursor was just before the press.
        let at = clamp(position(secondsAgo: settings.clickLookback))
        freezeUntil = now + 0.35
        needsRebias = true
        postMouse(.mouseMoved, at, .left)
        cursor = at
        if right {
            postMouse(.rightMouseDown, at, .right)
            postMouse(.rightMouseUp, at, .right)
        } else {
            // Two single presses close together count as a double click.
            let isDouble = now - lastLeftClick.0 < 1.2 && hypot(at.x - lastLeftClick.1.x, at.y - lastLeftClick.1.y) < 12
            let state: Int64 = isDouble ? 2 : 1
            postMouse(.leftMouseDown, at, .left, clickState: state)
            postMouse(.leftMouseUp, at, .left, clickState: state)
            lastLeftClick = (isDouble ? 0 : now, at)
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        let singles: [MPRemoteCommand] = [c.togglePlayPauseCommand, c.playCommand, c.pauseCommand]
        for cmd in singles {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.stemPress(.single) }
                return .success
            }
        }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.stemPress(.double) }
            return .success
        }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.stemPress(.triple) }
            return .success
        }
        claimNowPlaying()
    }

    /// Become the "Now Playing" app so stem presses come to PodPoint.
    private func claimNowPlaying() {
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "PodPoint",
                               MPNowPlayingInfoPropertyPlaybackRate: 1.0]
        info.playbackState = .playing
    }

    private func releaseNowPlaying() {
        let info = MPNowPlayingInfoCenter.default()
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
    }

    /// Silent audio keeps the AirPods awake (head tracking stops when nothing is playing)
    /// and keeps PodPoint as the Now Playing app.
    private func startKeepAliveAudio() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else { return }
        let source = AVAudioSourceNode { _, _, _, bufferList -> OSStatus in
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    // MARK: Hotkeys (Control + Option + key)

    private func setupHotkeys() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.hotkey(e) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if self?.hotkey(e) == true { return nil }
            return e
        }
    }

    @discardableResult
    private func hotkey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] else { return false }
        switch e.keyCode {
        case 15: recentre(); return true        // R
        case 35: toggleEnabled(); return true   // P
        case 8: startCalibration(); return true // C
        default: return false
        }
    }

    // MARK: Calibration

    @objc private func startCalibration() {
        guard calibrator == nil else { return }
        let cal = Calibrator(headNow: { [weak self] in
            guard let self, let h = self.averagedHead() else { return nil }
            return (h.0 * (self.settings.invertX ? -1 : 1), h.1 * (self.settings.invertY ? -1 : 1))
        }, finish: { [weak self] model in
            guard let self else { return }
            self.calibrator = nil
            if let model {
                self.settings.model = model
                self.settings.speed = 1.0
                self.bias = .zero
                self.cursor = self.currentMouse()
                self.history.removeAll()
            }
        })
        calibrator = cal
        cal.start()
    }

    // MARK: Menu

    private func updateIcon() {
        let name = enabled ? "airpodspro" : "pause.circle"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "PodPoint") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = enabled ? "PP" : "PP off"
        }
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled {
            claimNowPlaying()
            rebias()
        } else {
            releaseNowPlaying()
        }
        updateIcon()
    }

    @objc private func doRecentre() { recentre() }
    @objc private func setAbsolute() { settings.mode = .absolute; rebias() }
    @objc private func setJoystick() { settings.mode = .joystick; rebias() }
    @objc private func setSpeed(_ sender: NSMenuItem) { settings.speed = Double(sender.tag) / 100.0; rebias() }
    @objc private func setSmoothing(_ sender: NSMenuItem) { settings.smoothing = sender.tag; applySmoothing() }
    @objc private func setLookback(_ sender: NSMenuItem) { settings.clickLookback = Double(sender.tag) / 1000.0 }
    @objc private func toggleInvertX() { settings.invertX.toggle(); rebias() }
    @objc private func toggleInvertY() { settings.invertY.toggle(); rebias() }
    @objc private func clearCalibration() { settings.model = nil; rebias() }
    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func applySmoothing() {
        let presets: [(Double, Double)] = [(1.5, 8.0), (0.8, 4.0), (0.4, 2.0)]
        let p = presets[min(max(settings.smoothing, 0), 2)]
        fYaw.minCutoff = p.0
        fYaw.beta = p.1
        fPitch.minCutoff = p.0
        fPitch.beta = p.1
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", tag: Int = 0, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.tag = tag
        i.state = on ? .on : .off
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if !motion.isDeviceMotionAvailable {
            status = "Head tracking not available on this Mac"
        } else if tracking {
            status = "AirPods tracking: on"
        } else {
            status = "AirPods tracking: waiting (put AirPods in)"
        }
        let statusItemRow = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItemRow.isEnabled = false
        menu.addItem(statusItemRow)
        let ax = NSMenuItem(title: AXIsProcessTrusted() ? "Accessibility: allowed" : "Accessibility: needed (click to open)",
                            action: AXIsProcessTrusted() ? nil : #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        menu.addItem(.separator())

        menu.addItem(item(enabled ? "Pause PodPoint   (⌃⌥P)" : "Resume PodPoint   (⌃⌥P)", #selector(toggleEnabled)))
        menu.addItem(item("Recentre: face the middle of your screen   (⌃⌥R)", #selector(doRecentre)))
        menu.addItem(item(settings.model == nil ? "Calibrate (recommended)…   (⌃⌥C)" : "Calibrate again…   (⌃⌥C)", #selector(startCalibration)))
        menu.addItem(.separator())

        menu.addItem(submenu("Mode", [
            item("Point (cursor goes where you look)", #selector(setAbsolute), on: settings.mode == .absolute),
            item("Joystick (tilt to move, centre to stop)", #selector(setJoystick), on: settings.mode == .joystick)
        ]))
        menu.addItem(submenu("Speed", [
            item("Slow", #selector(setSpeed(_:)), tag: 60, on: abs(settings.speed - 0.6) < 0.01),
            item("Normal", #selector(setSpeed(_:)), tag: 100, on: abs(settings.speed - 1.0) < 0.01),
            item("Fast", #selector(setSpeed(_:)), tag: 150, on: abs(settings.speed - 1.5) < 0.01)
        ]))
        menu.addItem(submenu("Smoothing", [
            item("Low (faster, a bit jittery)", #selector(setSmoothing(_:)), tag: 0, on: settings.smoothing == 0),
            item("Normal", #selector(setSmoothing(_:)), tag: 1, on: settings.smoothing == 1),
            item("High (steadier, a bit slower)", #selector(setSmoothing(_:)), tag: 2, on: settings.smoothing == 2)
        ]))
        menu.addItem(submenu("Click timing fix", [
            item("Off", #selector(setLookback(_:)), tag: 0, on: settings.clickLookback < 0.01),
            item("Small (0.2 s)", #selector(setLookback(_:)), tag: 200, on: abs(settings.clickLookback - 0.2) < 0.01),
            item("Normal (0.3 s)", #selector(setLookback(_:)), tag: 300, on: abs(settings.clickLookback - 0.3) < 0.01),
            item("Large (0.5 s)", #selector(setLookback(_:)), tag: 500, on: abs(settings.clickLookback - 0.5) < 0.01)
        ]))
        menu.addItem(submenu("Direction", [
            item("Flip left and right", #selector(toggleInvertX), on: settings.invertX),
            item("Flip up and down", #selector(toggleInvertY), on: settings.invertY),
            item("Clear calibration", #selector(clearCalibration))
        ]))
        menu.addItem(.separator())

        for line in ["Single press: left click", "Two single presses: double click",
                     "Double press: right click", "Triple press: recentre", "Hold ⌥ Option: fine control"] {
            let i = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit PodPoint", #selector(quit), key: "q"))
    }
}

// MARK: - Main

let app = NSApplication.shared
let podPoint = PodPoint()
app.delegate = podPoint
app.setActivationPolicy(.accessory)
app.run()
