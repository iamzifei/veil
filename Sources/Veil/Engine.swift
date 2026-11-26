// Focus engine: decides which windows stay sharp and keeps each display's
// overlay ordered directly below its "anchor" window.
//
// Terms
//   anchor  – the window an overlay sits directly below (everything above it
//             is sharp, everything below is blurred).
//   holes   – other windows that must stay sharp even though they sit below the
//             overlay (App Groups, App-wide focus, Stage Manager strip). The
//             overlay's mask cuts them out.
//
// We poll CGWindowList (~10 Hz). It needs no permission for bounds / owner /
// layer, and it catches focus changes that no notification reports (e.g.
// switching between two windows of the same app).

import AppKit
import Combine

struct WinInfo {
    let id: Int
    let pid: pid_t
    let owner: String
    let layer: Int
    let frame: CGRect       // Cocoa global coordinates (y-up, origin = bottom-left of main display)
    let alpha: Double
}

final class Engine {
    static weak var current: Engine?
    private let s = Settings.shared
    private(set) var overlays: [OverlayWindow] = []
    private var shown: [CGDirectDisplayID: Bool] = [:]
    private var anchors: [CGDirectDisplayID: Int] = [:]
    private var timer: Timer?
    /// Bumped on every settings change so the tick signature notices it.
    private var settingsVersion = 0
    private var bag = Set<AnyCancellable>()

    // Temporary suppression reasons (each one hides the overlay while set).
    var peeking = false { didSet { if peeking != oldValue { lastSignature = nil; tick() } } }
    var dragging = false { didSet { if dragging != oldValue { lastSignature = nil; tick() } } }

    /// Fires when "is Veil currently visible anywhere" changes (used for auto-hiding bars).
    var onActiveChange: ((Bool) -> Void)?
    private(set) var active = false

    init() {
        Engine.current = self
        rebuild()
        let nc = NotificationCenter.default, wnc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(rebuild), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                  NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            wnc.addObserver(self, selector: #selector(rebuildSoon), name: n, object: nil)
        }
        wnc.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            wnc.addObserver(self, selector: #selector(appsChanged), name: n, object: nil)
        }
        // Pause polling while the screen is locked or the displays sleep.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        wnc.addObserver(self, selector: #selector(screenLocked), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screenUnlocked), name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Restyle overlays whenever a look-related setting changes.
        s.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.settingsVersion &+= 1
                self.overlays.forEach { $0.applyStyle() }
                self.tick()
            }
            .store(in: &bag)

        adjustPolling()
    }

    private var locked = false
    @objc private func screenLocked() { locked = true; adjustPolling() }
    @objc private func screenUnlocked() { locked = false; lastSignature = nil; adjustPolling(); tick() }

    /// Cheap fingerprint of everything tick() depends on; when it hasn't changed, there's nothing to do.
    private var lastSignature: [Int]?
    /// Consecutive polls with an unchanged signature (drives the adaptive poll rate).
    private var idleTicks = 0

    /// Something just happened that may change focus or window order (a click, an app switch):
    /// look now and again shortly after, and go back to the fast poll rate.
    func kick() {
        idleTicks = 0
        adjustPolling()
        tick()
        for d in [0.06, 0.18] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.tick() } }
    }

    @objc func rebuildSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.rebuild() } }

    @objc func rebuild() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0) }
        shown = [:]; anchors = [:]; lastSignature = nil
        tick()
    }

    /// Last frontmost app that isn't Veil. Opening Veil's settings or a veil://
    /// URL activates Veil itself; we keep focusing the app the user was in.
    private var lastExternal: NSRunningApplication? = NSWorkspace.shared.frontmostApplication

    @objc private func appChanged() {
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { lastExternal = f }
        kick()
    }

    var focusedAppPublic: NSRunningApplication? { focusedApp }

    private var focusedApp: NSRunningApplication? {
        let f = NSWorkspace.shared.frontmostApplication
        if let f, f.processIdentifier != getpid() { lastExternal = f; return f }
        return lastExternal
    }

    // MARK: Window list

    static func windows() -> [WinInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        return raw.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let x = b["X"] ?? 0, y = b["Y"] ?? 0, wd = b["Width"] ?? 0, h = b["Height"] ?? 0
            return WinInfo(id: id, pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "",
                           layer: w[kCGWindowLayer as String] as? Int ?? 0,
                           frame: CGRect(x: x, y: mainH - y - h, width: wd, height: h),
                           alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    static var stageManagerOn: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// macOS "Displays have separate Spaces" (true unless spans-displays is set).
    static var separateSpaces: Bool {
        !(UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false)
    }

    // MARK: Focus computation

    private func isNormal(_ w: WinInfo) -> Bool {
        w.layer == 0 && w.alpha > 0.05 && w.frame.width > 80 && w.frame.height > 80 && w.pid != getpid()
    }

    /// Bundle IDs that share focus with `bundle` (its App Group, or just itself).
    private func focusSet(for bundle: String) -> Set<String> {
        if let g = s.groups.first(where: { $0.bundleIDs.contains(bundle) }) { return Set(g.bundleIDs) }
        return [bundle]
    }

    /// bundle id → pids of running apps. Rebuilt only when an app launches or quits
    /// (`NSWorkspace.runningApplications` is far too slow to call 20 times a second).
    private var pidCache: [String: [pid_t]] = [:]
    private var pidCacheValid = false

    @objc private func appsChanged() {
        pidCacheValid = false
        lastSignature = nil          // an App Group peer may have windows on screen already
        kick()
    }

    private func pidsFor(_ bundles: Set<String>) -> Set<pid_t> {
        if !pidCacheValid {
            pidCache = Dictionary(grouping: NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != nil },
                                  by: { $0.bundleIdentifier! }).mapValues { $0.map(\.processIdentifier) }
            pidCacheValid = true
        }
        return Set(bundles.flatMap { pidCache[$0] ?? [] })
    }

    /// Corner radius used for holes — close to macOS 26 window corners.
    static let holeRadius: CGFloat = 14

    func tick() {
        let front = focusedApp
        let frontBundle = front?.bundleIdentifier ?? ""
        let suppressed = !s.enabled || peeking || dragging || front == nil || s.ignored.contains(frontBundle)
        adjustPolling()
        if suppressed {
            lastSignature = nil
            overlays.forEach { setShown($0, false) }
            updateActive()
            return
        }
        let all = Self.windows()
        let frontPID = front?.processIdentifier ?? -1
        // Skip the whole placement pass when no window moved, appeared or changed order
        // and the front app is the same (the common case: 20 polls a second of nothing).
        var sig = [Int(frontPID), settingsVersion]
        sig.reserveCapacity(all.count * 5 + 2)
        // Only app windows (and the Stage Manager strip) matter; menu-bar extras, the recording
        // indicator and other system windows come and go constantly and must not wake the pass.
        for w in all where w.layer == 0 || w.owner == "WindowManager" {
            sig += [w.id, Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height)]
        }
        if sig == lastSignature {
            idleTicks += 1
            if idleTicks == 20 { adjustPolling() }        // 1 s without changes → slow down
            return
        }
        lastSignature = sig
        if idleTicks >= 20 { idleTicks = 0; adjustPolling() } else { idleTicks = 0 }
        let normal = all.filter(isNormal)
        let focusWin = normal.first { $0.pid == frontPID }

        guard let focus = focusWin else {
            lastSignature = nil
            overlays.forEach { setShown($0, false) }
            updateActive()
            return
        }

        // Windows that must stay sharp: the focused one, plus its App Group / app-wide peers.
        let groupPIDs = pidsFor(focusSet(for: frontBundle)).union([frontPID])
        var sharp: [WinInfo] = []
        for pid in groupPIDs {
            let wins = normal.filter { $0.pid == pid }
            if s.appWide { sharp += wins } else if let top = wins.first { sharp.append(top) }
        }
        if !s.blurStageManager && Self.stageManagerOn {
            sharp += all.filter { $0.owner == "WindowManager" && $0.alpha > 0.05 && $0.frame.width > 20 }
        }
        let ids = all.map(\.id)

        for o in overlays {
            let onThis = { (w: WinInfo) in o.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }
            // The window this display is "about": the focused one, or (per-screen) this display's own front window.
            let anchor: WinInfo?
            if onThis(focus) || s.screenMode == .global && o.frame.intersects(focus.frame) {
                anchor = focus
            } else if s.screenMode == .perScreen {
                anchor = sharp.first(where: onThis) ?? normal.first(where: onThis)
            } else {
                anchor = nil   // global: this display has nothing sharp
            }
            if s.screenMode == .perScreen && anchor == nil { setShown(o, false); continue }

            // Directly below the anchor (global mode without one: below the focused window,
            // which is on another display, so everything here is veiled).
            let a = anchor ?? focus
            let previous = anchors[o.displayID]
            place(o, below: a.id, ids: ids)
            // Focus moved to another window while the veil was up: the old one blurs in gradually.
            if let prev = previous, prev != a.id, shown[o.displayID] == true,
               !sharp.contains(where: { $0.id == prev }),            // still sharp (group / app-wide): no blur-in
               let old = all.first(where: { $0.id == prev }) {
                o.blurIn(previous: old.frame.offsetBy(dx: -o.frame.minX, dy: -o.frame.minY), id: prev)
            }
            var keep = sharp.filter { $0.id != a.id }
            if s.screenMode == .global && anchor == nil { keep = [] }
            o.setHoles(holes(for: keep, on: o, all: all, ids: ids, below: a.id))
            setShown(o, true)
        }
        updateActive()
    }

    /// Hole shapes (window-local) for `wins` on overlay `o`. Each hole is the window's rounded
    /// rect minus any NON-sharp window stacked above it, so a blurred window that overlaps a
    /// sharp one stays blurred. `below`: only windows under this one in z-order get holes.
    private func holes(for wins: [WinInfo], on o: OverlayWindow, all: [WinInfo], ids: [Int], below: Int?) -> [CGPath] {
        // The anchor itself is sharp too, so it must never be treated as an occluder.
        let sharpIDs = Set(wins.map(\.id)).union(below.map { [$0] } ?? [])
        let floor = below.flatMap { ids.firstIndex(of: $0) }
        let local = { (r: CGRect) in r.intersection(o.frame).offsetBy(dx: -o.frame.minX, dy: -o.frame.minY) }
        return wins.compactMap { w -> CGPath? in
            guard let wi = ids.firstIndex(of: w.id) else { return nil }
            if let f = floor, wi <= f { return nil }
            let r = local(w.frame)
            guard !r.isNull, r.width > 1, r.height > 1 else { return nil }
            var p = CGPath(roundedRect: r, cornerWidth: Self.holeRadius, cornerHeight: Self.holeRadius, transform: nil)
            // Subtract normal windows above this one that aren't sharp themselves.
            let occluders = all[..<wi].filter { isNormal($0) && !sharpIDs.contains($0.id) && $0.frame.intersects(w.frame) }
            for c in occluders {
                let cr = local(c.frame)
                guard !cr.isNull else { continue }
                p = p.subtracting(CGPath(roundedRect: cr, cornerWidth: Self.holeRadius, cornerHeight: Self.holeRadius, transform: nil))
            }
            return p
        }
    }

    /// Poll the window list at 20 Hz (focus changes inside one app have no notification).
    private func adjustPolling() {
        // Off or locked: no timer at all (the settings sink and notifications call tick() when that changes).
        // 20 Hz while windows are changing; 4 Hz after a second of stillness (clicks and app
        // switches call kick(), so focus changes are still picked up at once).
        let want: TimeInterval? = (!s.enabled || locked) ? nil : (idleTicks >= 20 ? 0.25 : 1.0 / 20)
        guard timer?.isValid == true ? timer?.timeInterval != want : want != nil else { return }
        timer?.invalidate(); timer = nil
        guard let want else { return }
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = want * 0.2                       // let the system coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Order overlay `o` directly below window `id`, only if it isn't already there.
    private func place(_ o: OverlayWindow, below id: Int, ids: [Int]) {
        let ours = Set(overlays.map(\.windowNumber))
        if anchors[o.displayID] == id, let ai = ids.firstIndex(of: id), let oi = ids.firstIndex(of: o.windowNumber),
           oi > ai, ids[(ai + 1)..<oi].allSatisfy({ ours.contains($0) }) {
            return
        }
        o.order(.below, relativeTo: id)
        anchors[o.displayID] = id
    }

    private func setShown(_ o: OverlayWindow, _ v: Bool) {
        guard shown[o.displayID] != v else { return }
        let first = shown[o.displayID] == nil
        shown[o.displayID] = v
        if v { o.applyStyle(animated: false) }
        o.setShown(v, cursor: NSEvent.mouseLocation, animated: !(first && !v))
        if !v { anchors[o.displayID] = nil }
    }

    private func updateActive() {
        let now = shown.values.contains(true)
        if now != active { active = now; onActiveChange?(now) }
    }
}
