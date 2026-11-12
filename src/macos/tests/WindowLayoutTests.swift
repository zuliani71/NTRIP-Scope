import AppKit
import SwiftUI

enum WindowLayoutChecks {
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let view = NSHostingView(rootView: Color.clear.frame(minWidth: 608, minHeight: 290)
            .background(InitialWindowWidth(width: 608)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let top = window.frame.maxY
        window.contentView = view
        for _ in 0..<20 {
            if abs(window.contentRect(forFrameRect: window.frame).width - 608) < 0.5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(abs(window.contentRect(forFrameRect: window.frame).width - 608) < 0.5)
        precondition(abs(window.frame.maxY - top) < 0.5)
        window.setContentSize(NSSize(width: 700, height: 400))
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        precondition(abs(window.contentRect(forFrameRect: window.frame).width - 700) < 0.5)
        window.contentView = nil
        let prefix = "NTRIPScope.Test." + UUID().uuidString
        let map = ScopeAuxiliaryWindows.make(title: "Map test", size: NSSize(width: 740, height: 700),
            minimum: NSSize(width: 560, height: 540), name: prefix + ".map", right: false)
        let live = ScopeAuxiliaryWindows.make(title: "Live test", size: NSSize(width: 760, height: 660),
            minimum: NSSize(width: 560, height: 470), name: prefix + ".live", right: true)
        precondition(!(map is NSPanel) && !(live is NSPanel))
        precondition(!map.hidesOnDeactivate && !live.hidesOnDeactivate)
        precondition(map.level == .normal && live.level == .normal)
        precondition(map !== live && map.tabbingMode == .disallowed && live.tabbingMode == .disallowed)
        map.orderFrontRegardless(); live.orderFrontRegardless()
        NSApp.deactivate()
        try await Task.sleep(for: .milliseconds(60))
        precondition(map.isVisible && live.isVisible)
        live.orderOut(nil)
        precondition(map.isVisible)
        live.makeKeyAndOrderFront(nil)
        precondition(map.isVisible && live.isVisible)
        map.close(); live.close()
        NSWindow.removeFrame(usingName: prefix + ".map")
        NSWindow.removeFrame(usingName: prefix + ".live")
        print("PASS: independent Map and Live windows remain visible on deactivation and can close/reopen independently")
        print("PASS: restored 760-point window shrinks to 608 on attachment; later manual resizing is preserved")
    }
}
