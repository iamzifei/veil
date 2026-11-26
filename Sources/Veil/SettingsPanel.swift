// The settings panel window: a borderless, non-activating panel the full height of
// the screen, docked to its right edge (Control Center style). It fades in, and fades
// out on Esc, a click anywhere outside it, or the menu-bar icon.
//
// Non-activating: opening it does NOT take focus from the app you're working in, so
// the window Veil keeps sharp doesn't change while you adjust settings.

import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SettingsPanel: NSObject {
    static let shared = SettingsPanel()
    static let width: CGFloat = 350

    private var panel: KeyablePanel?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var frontTimer: Timer?
    /// Set while a child window (app picker, colour panel, alert) is up: outside clicks don't close.
    var childOpen = false
    var recordingShortcut = false
    private(set) var isOpen = false

    /// Built lazily by AppDelegate (needs its callbacks).
    var makeContent: (() -> AnyView)?

    func toggle() { isOpen ? close() : open() }

    /// The display the panel opens on: the one with the pointer (like Control Center).
    private var targetScreen: NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // Measured on the reference: the panel only fades — 0.25 s in, 0.18 s ease-in out — no slide.

    func open() {
        let sc = targetScreen
        let p = panel ?? build()
        let frame = NSRect(x: sc.frame.maxX - Self.width, y: sc.frame.minY, width: Self.width, height: sc.frame.height)
        if !isOpen || p.frame != frame {
            p.setFrame(frame, display: false)
            if !isOpen { p.alphaValue = 0 }
        }
        isOpen = true
        refreshFront()
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 1
        }
        installMonitors()
        // Keep the "Ignore <app>" pill current while the panel is up.
        frontTimer?.invalidate()
        frontTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshFront() }
    }

    func close() {
        guard let p = panel, isOpen else { return }
        isOpen = false
        // A shortcut being recorded must not outlive the panel (it suspends every hotkey).
        NotificationCenter.default.post(name: .veilCancelShortcutRecording, object: nil)
        removeMonitors()
        frontTimer?.invalidate(); frontTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isOpen else { return }
            p.orderOut(nil)
        })
    }

    /// Scroll the content back to the top (used by "Show Intro").
    func scrollToTop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let root = self?.panel?.contentView, let sv = Self.findScroll(root) else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: 0))
            }
        }
    }

    private static func findScroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for c in v.subviews { if let s = findScroll(c) { return s } }
        return nil
    }

    private func refreshFront() {
        let app = Engine.current?.focusedAppPublic
        if PanelState.shared.frontApp?.processIdentifier != app?.processIdentifier { PanelState.shared.frontApp = app }
    }

    private func build() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 800),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .mainMenu                        // menu-bar level, like Control Center
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        let root = makeContent?() ?? AnyView(EmptyView())
        let host = NSHostingView(rootView: root)
        host.frame = p.contentRect(forFrameRect: p.frame)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        return p
    }

    private func installMonitors() {
        removeMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let p = self.panel, !self.childOpen, NSApp.modalWindow == nil else { return }
            let loc = NSEvent.mouseLocation
            // Clicks in the colour panel (opened from the tint row) don't count as "outside".
            if NSColorPanel.shared.isVisible && NSColorPanel.shared.frame.contains(loc) { return }
            if !p.frame.contains(loc) { self.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53, !self.recordingShortcut, e.window === self.panel else { return e }
            self.close()
            return nil
        }
    }

    private func removeMonitors() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        outsideMonitor = nil; keyMonitor = nil
    }
}

extension Notification.Name {
    /// Posted when the settings panel closes, so an in-progress shortcut recording is cancelled.
    static let veilCancelShortcutRecording = Notification.Name("veil.cancelShortcutRecording")
}
