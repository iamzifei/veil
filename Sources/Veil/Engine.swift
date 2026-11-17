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
    private var bag = Set<AnyCancellable>()

    // Temporary suppression reasons (each one hides the overlay while set).
    var peeking = false { didSet { if peeking != oldValue { tick() } } }
    var dragging = false { didSet { if dragging != oldValue { tick() } } }

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

        // Restyle overlays whenever a look-related setting changes.
        s.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.overlays.forEach { $0.applyStyle() }; self?.tick() }
            .store(in: &bag)

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc func rebuildSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.rebuild() } }

    @objc func rebuild() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0) }
        shown = [:]; anchors = [:]
        tick()
    }

    /// Last frontmost app that isn't Veil. Opening Veil's settings or a veil://
    /// URL activates Veil itself; we keep focusing the app the user was in.
    private var lastExternal: NSRunningApplication? = NSWorkspace.shared.frontmostApplication

    @objc private func appChanged() {
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { lastExternal = f }
        tick()
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

    private func pidsFor(_ bundles: Set<String>) -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter { bundles.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
    }

    func tick() {
        let front = focusedApp
        let frontBundle = front?.bundleIdentifier ?? ""
        let suppressed = !s.enabled || peeking || dragging || front == nil || s.ignored.contains(frontBundle)
        let all = Self.windows()
        let normal = all.filter(isNormal)
        let frontPID = front?.processIdentifier ?? -1
        let focusWin = normal.first { $0.pid == frontPID }

        guard !suppressed, let focus = focusWin else {
            overlays.forEach { setShown($0, false) }
            updateActive()
            return
        }

        // Windows that must stay sharp besides the anchor(s).
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
            // Pick the anchor for this display.
            let anchor: WinInfo?
            switch s.screenMode {
            case .global:
                anchor = focus
            case .perScreen:
                if o.frame.intersects(focus.frame) && o.frame.contains(CGPoint(x: focus.frame.midX, y: focus.frame.midY)) {
                    anchor = focus
                } else {
                    // Topmost sharp window on this display, else the topmost window on it.
                    anchor = sharp.first { o.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                        ?? normal.first { o.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                }
            }
            guard let a = anchor else {
                // Global mode on a display without the focused window: blur it all,
                // ordered under the focus window so nothing on this screen is sharp.
                if s.screenMode == .global { place(o, below: focus.id, ids: ids) } else { setShown(o, false); continue }
                setHoles(o, sharp: sharp, anchor: focus.id, ids: ids)
                setShown(o, true)
                continue
            }
            place(o, below: a.id, ids: ids)
            setHoles(o, sharp: sharp, anchor: a.id, ids: ids)
            setShown(o, true)
        }
        updateActive()
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

    /// Cut holes for sharp windows that sit below this overlay and overlap its display.
    private func setHoles(_ o: OverlayWindow, sharp: [WinInfo], anchor: Int, ids: [Int]) {
        guard let ai = ids.firstIndex(of: anchor) else { o.setHoles([]); return }
        let rects = sharp.compactMap { w -> CGRect? in
            guard w.id != anchor, let wi = ids.firstIndex(of: w.id), wi > ai else { return nil }
            let r = w.frame.intersection(o.frame)
            guard !r.isNull, r.width > 1 else { return nil }
            return r.offsetBy(dx: -o.frame.minX, dy: -o.frame.minY)
        }
        o.setHoles(rects)
    }

    private func setShown(_ o: OverlayWindow, _ v: Bool) {
        guard shown[o.displayID] != v else { return }
        let first = shown[o.displayID] == nil
        shown[o.displayID] = v
        if v { o.applyStyle() }
        o.setShown(v, transition: first && !v ? .none : s.transition, cursor: NSEvent.mouseLocation)
        if !v { anchors[o.displayID] = nil }
    }

    private func updateActive() {
        let now = shown.values.contains(true)
        if now != active { active = now; onActiveChange?(now) }
    }
}
