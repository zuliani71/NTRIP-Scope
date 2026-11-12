import AppKit
import SwiftUI

/// Apply the compact width to an existing/restored window, not only to newly
/// created SwiftUI windows. Later manual resizing remains available.
struct InitialWindowWidth: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> WidthView { WidthView(targetWidth: width) }
    func updateNSView(_ nsView: WidthView, context: Context) {}

    final class WidthView: NSView {
        let targetWidth: CGFloat
        private weak var sizedWindow: NSWindow?

        init(targetWidth: CGFloat) {
            self.targetWidth = targetWidth
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, sizedWindow !== window else { return }
            sizedWindow = window
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.contentView?.layoutSubtreeIfNeeded()
                let top = window.frame.maxY
                let x = window.frame.minX
                let content = window.contentRect(forFrameRect: window.frame).size
                let width = max(self.targetWidth, window.contentMinSize.width)
                let height = max(content.height, window.contentMinSize.height)
                window.setContentSize(NSSize(width: width, height: height))
                window.setFrameOrigin(NSPoint(x: x, y: top - window.frame.height))
            }
        }
    }
}

/// Regular document windows remain visible when another application becomes active.
@MainActor
enum ScopeAuxiliaryWindows {
    static func make(title: String, size: NSSize, minimum: NSSize, name: String, right: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.tabbingMode = .disallowed
        window.contentMinSize = minimum
        let restored = window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
        if !restored {
            if let screen = NSApp.mainWindow?.screen ?? NSScreen.main {
                let area = screen.visibleFrame
                let x = right ? area.maxX - window.frame.width - 24 : area.minX + 24
                let y = area.maxY - window.frame.height - (right ? 64 : 24)
                let desired = NSRect(origin: NSPoint(x: x, y: y), size: window.frame.size)
                window.setFrame(window.constrainFrameRect(desired, to: screen), display: false)
            } else { window.center() }
        }
        return window
    }
}

struct RTCMDetailTabs: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach([("fields", tr("Campi")), ("measurements", tr("Misure")), ("chart", tr("Grafico C/N₀"))], id: \.0) { key, label in
                Button { selection = key } label: {
                    Text(label).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selection == key ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selection == key ? Color.accentColor : Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == key ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A two-axis SwiftUI ScrollView otherwise centres short content horizontally.
struct LeadingDecoderScroll<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        GeometryReader { viewport in
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                content
                    .frame(minWidth: max(0, viewport.size.width - 16),
                           minHeight: max(0, viewport.size.height - 16), alignment: .topLeading)
                    .padding(8)
            }
        }
    }
}
