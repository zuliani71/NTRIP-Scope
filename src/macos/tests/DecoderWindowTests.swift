import AppKit
import SwiftUI

@main struct DecoderWindowChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let radio = Radio()
        radio.fixtureReceive(Fixture.msmPacket(code: 100, cnr: 643))
        let window = ScopeAuxiliaryWindows.make(title: "Decoder layout test", size: NSSize(width: 760, height: 660),
            minimum: NSSize(width: 560, height: 470), name: "NTRIPScope.LayoutTest", right: true)
        let host = NSHostingView(rootView: fixtureDecoder(radio).frame(maxWidth: .infinity, maxHeight: .infinity).padding(16).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<15 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        func splitViews(_ view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews)
        }
        let split = splitViews(host).first!
        precondition(split.arrangedSubviews.count == 2)
        precondition(split.arrangedSubviews[0].frame.height >= 139 && split.arrangedSubviews[1].frame.height >= 229,
                     "Both decoder panes must have their full initial height")
        if let path = ProcessInfo.processInfo.environment["NTRIP_LAYOUT_PNG"],
           let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        window.setContentSize(NSSize(width: 850, height: 820))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        precondition(split.arrangedSubviews[0].frame.height >= 140 && split.arrangedSubviews[1].frame.height >= 230)
        window.close()
        NSWindow.removeFrame(usingName: "NTRIPScope.LayoutTest")
        print("PASS: decoder details and both full split panes appear on first opening without selecting a type; resize preserves both panes")
    }
}
