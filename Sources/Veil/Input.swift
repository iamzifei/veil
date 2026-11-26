// Input: shake gestures, corner peek, drag detection, global hotkeys, and
// auto-hiding the menu bar & Dock.

import AppKit
import Carbon

// MARK: - Shake detector

/// Counts fast left/right direction reversals of the pointer.
final class ShakeDetector {
    private var lastX: CGFloat?
    private var lastDir = 0
    private var stroke: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var cooldownUntil: TimeInterval = 0

    /// Feed a pointer x position; returns true once when a shake completes.
    func feed(x: CGFloat, time t: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lx = lastX, t > cooldownUntil else { return false }
        let dx = x - lx
        if abs(dx) < 1 { return false }
        let sens = Settings.shared.sensitivity            // 0 = low … 1 = high
        let minStroke = 70 - 45 * sens                    // shorter strokes count when sensitive
        let needed = sens > 0.66 ? 3 : (sens > 0.33 ? 4 : 5)
        let dir = dx > 0 ? 1 : -1
        if dir == lastDir {
            stroke += abs(dx)
        } else {
            if stroke > minStroke { reversals.append(t) }
            stroke = abs(dx)
            lastDir = dir
        }
        reversals.removeAll { t - $0 > 0.7 }
        if reversals.count >= needed {
            reversals.removeAll()
            cooldownUntil = t + 0.8
            return true
        }
        return false
    }
}

/// Wires mouse gestures to the engine.
final class Gestures {
    private let shake = ShakeDetector()
    private let s = Settings.shared
    private weak var engine: Engine?
    private let onToggle: () -> Void
    private var peekStarted: TimeInterval = 0
    private var peekModifier: NSEvent.ModifierFlags = []
    private var cornerPeeking = false
    private var dragChange = 0
    private var mouseIsDown = false

    init(engine: Engine, onToggle: @escaping () -> Void) {
        self.engine = engine
        self.onToggle = onToggle
        let move: (NSEvent) -> Void = { [weak self] e in self?.moved(e) }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: move)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { move($0); return $0 }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e) }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.mouseIsDown = true
            self?.dragChange = NSPasteboard(name: .drag).changeCount
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.mouseIsDown = false
            self?.engine?.dragging = false
        }
    }

    private func moved(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        let mods = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])

        // Hide while dragging files: the drag pasteboard changes when a drag session starts.
        if s.hideWhileDragging, mouseIsDown, e.type == .leftMouseDragged,
           NSPasteboard(name: .drag).changeCount != dragChange {
            engine?.dragging = true
        }

        // Corner peek: park the pointer in any screen corner.
        if s.cornerPeek {
            let inCorner = NSScreen.screens.contains { sc in
                let f = sc.frame
                return (abs(p.x - f.minX) < 3 || abs(p.x - f.maxX + 1) < 3) && (abs(p.y - f.minY) < 3 || abs(p.y - f.maxY + 1) < 3)
            }
            if inCorner != cornerPeeking {
                cornerPeeking = inCorner
                if inCorner { engine?.peeking = true } else if peekModifier.isEmpty { engine?.peeking = false }
            }
        }

        guard s.shakeEnabled, shake.feed(x: p.x, time: ProcessInfo.processInfo.systemUptime) else { return }
        // Peek takes precedence when its modifier is held.
        if s.shakePeek != .off, !s.shakePeek.flags.isEmpty, mods == s.shakePeek.flags {
            startPeek(modifier: s.shakePeek.flags)
        } else if s.shakeToggle != .off, mods == s.shakeToggle.flags {
            onToggle()
        } else if s.shakePeek == .none, mods.isEmpty {
            startPeek(modifier: [])
        }
    }

    /// Peek lasts at least 2 s and extends while the modifier stays held.
    private func startPeek(modifier: NSEvent.ModifierFlags) {
        peekStarted = ProcessInfo.processInfo.systemUptime
        peekModifier = modifier
        engine?.peeking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.maybeEndPeek() }
    }

    private func maybeEndPeek() {
        guard engine?.peeking == true, !cornerPeeking else { return }
        if !peekModifier.isEmpty && NSEvent.modifierFlags.contains(peekModifier) { return } // still held
        peekModifier = []
        engine?.peeking = false
    }

    /// Modifier released: end the peek once the 2-second minimum has passed.
    private func flags(_ e: NSEvent) {
        guard !peekModifier.isEmpty, !e.modifierFlags.contains(peekModifier) else { return }
        peekModifier = []
        let remain = max(0, 2 - (ProcessInfo.processInfo.systemUptime - peekStarted))
        DispatchQueue.main.asyncAfter(deadline: .now() + remain) { [weak self] in self?.maybeEndPeek() }
    }
}

// MARK: - Global hotkeys (Carbon, no Accessibility permission required)

enum HotKeys {
    static var handlers: [UInt32: () -> Void] = [:]
    static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeys.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Re-register all shortcuts from Settings.
    static func reload(_ actions: [Action: () -> Void]) {
        install()
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []; handlers = [:]
        for (i, a) in Action.allCases.enumerated() {
            guard let sc = Settings.shared.shortcut(a), let h = actions[a] else { continue }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(sc.keyCode, sc.modifiers, EventHotKeyID(signature: 0x5645_494C, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let r = ref { refs.append(r); handlers[id] = h }
        }
    }

    /// Temporarily disable while recording a new shortcut, so the old one doesn't fire.
    static func suspend() { refs.forEach { UnregisterEventHotKey($0) }; refs = [] }
}

// MARK: - Auto-hide menu bar & Dock

/// Flips the system "automatically hide" settings through System Events while
/// Veil is active, restoring the user's originals afterwards. First use asks
/// for Automation permission (Veil → System Events).
final class BarHider {
    private var original: (dock: Bool, menu: Bool)?
    private var applied = false
    private let queue = DispatchQueue(label: "veil.barhider")

    private func run(_ src: String) -> String? {
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { NSLog("Veil BarHider: \(err)") }
        return out?.stringValue
    }

    /// What is currently forced hidden (nil = nothing).
    private var appliedMode: AutoHide = .off

    func set(active: Bool) {
        let mode = active ? Settings.shared.autoHide : .off
        guard mode != appliedMode else { return }
        appliedMode = mode
        applied = mode != .off
        queue.async { [self] in
            if mode != .off {
                if original == nil {
                    let d = run("tell application \"System Events\" to get autohide of dock preferences") == "true"
                    let m = run("tell application \"System Events\" to get autohide menu bar of dock preferences") == "true"
                    original = (d, m)
                }
                let o = original!
                // Hide what this mode asks for; leave the other bar as the user had it.
                let dock = mode.hidesDock || o.dock, menu = mode.hidesMenuBar || o.menu
                _ = run("tell application \"System Events\" to tell dock preferences to set {autohide, autohide menu bar} to {\(dock), \(menu)}")
            } else if let o = original {
                _ = run("tell application \"System Events\" to tell dock preferences to set {autohide, autohide menu bar} to {\(o.dock), \(o.menu)}")
                original = nil
            }
        }
    }

    /// Synchronous restore for app termination.
    func restoreNow() {
        guard applied, let o = original else { return }
        queue.sync {
            _ = run("tell application \"System Events\" to tell dock preferences to set {autohide, autohide menu bar} to {\(o.dock), \(o.menu)}")
        }
        applied = false
        appliedMode = .off
    }
}
