#if os(macOS)
import AppKit
import AVFoundation
import SimpleLiveKit
import SwiftUI

/// Public AppKit floating window. Avoids AVKit's sample-buffer mirroring path:
/// the real display layer is moved, and only its current host may resize it.
@MainActor
final class PiPController: NSObject, NSWindowDelegate {
    static var isSupported: Bool { true }
    private(set) var isActive = false
    private weak var player: FLVLivePlayer?
    private weak var inlineLayer: CALayer?
    private var panel: NSPanel?
    var onRequestPlay: (() -> Void)?
    var onRequestPause: (() -> Void)?
    var onRequestRestore: (() -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var isPossible: Bool { player?.displayLayer.superlayer != nil }

    func attach(player: FLVLivePlayer, automatic: Bool) {
        if let current = self.player, current !== player { stop() }
        self.player = player
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    private func start() {
        guard let player, let parent = player.displayLayer.superlayer, !isActive else { return }
        inlineLayer = parent
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let aspect = FloatingVideoGeometry.aspect(for: player.videoSize)
        let size = FloatingVideoGeometry.initialSize(aspect: aspect, available: area.size)
        let created = NSPanel(contentRect: CGRect(origin: CGPoint(x: area.maxX - size.width - 24,
                                                                  y: area.minY + 24), size: size),
                              styleMask: [.borderless, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        created.title = "SwiftPeek · 画中画"
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.hidesOnDeactivate = false
        created.isMovableByWindowBackground = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.hasShadow = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.contentAspectRatio = CGSize(width: aspect, height: 1)
        created.contentMinSize = CGSize(width: 240, height: 240 / aspect)
        created.delegate = self
        panel = created
        player.isInFloatingWindow = true
        player.displayLayer.videoGravity = .resizeAspect
        created.contentView = NSHostingView(rootView: FloatingPlayerView(
            player: player,
            togglePlayback: { [weak self] in
                guard let self else { return }
                if self.player?.isActive == true { self.onRequestPause?() }
                else { self.onRequestPlay?() }
            },
            restore: { [weak self] in self?.restore() },
            close: { [weak self] in self?.stop() }
        ))
        isActive = true
        onStateChange?(true)
        created.orderFrontRegardless()
        LiveDiagnostics.record("pip.open", fields: ["player": player.diagnosticID, "backend": "AppKit", "aspect": String(Double(aspect))])
    }

    func stop() { finish(closeWindow: true) }

    private func restore() {
        stop()
        onRequestRestore?()
    }

    private func finish(closeWindow: Bool) {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        if let player {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            player.displayLayer.removeFromSuperlayer()
            if let inlineLayer {
                inlineLayer.addSublayer(player.displayLayer)
                player.displayLayer.frame = inlineLayer.bounds
            }
            player.displayLayer.videoGravity = player.videoGravity
            player.isInFloatingWindow = false
            CATransaction.commit()
            LiveDiagnostics.record("pip.close", fields: ["player": player.diagnosticID])
        }
        if closeWindow { panel.close() }
        panel.contentView = nil
        inlineLayer = nil
        isActive = false
        onStateChange?(false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        finish(closeWindow: false)
    }

    func detach() {
        stop()
        player = nil
        onRequestPlay = nil
        onRequestPause = nil
        onRequestRestore = nil
        onStateChange = nil
    }
}

private struct FloatingPlayerView: View {
    let player: FLVLivePlayer
    let togglePlayback: () -> Void
    let restore: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black
            FLVVideoLayerView(player: player, floating: true).allowsHitTesting(false)
            if hovering || !player.isActive {
                VStack {
                    HStack {
                        control("xmark", label: "关闭画中画", action: close)
                        Spacer()
                        control("arrow.up.left.and.arrow.down.right", label: "返回直播间", action: restore)
                    }
                    Spacer()
                    control(player.isActive ? "pause.fill" : "play.fill", label: "播放 / 停止", action: togglePlayback)
                }.padding(12)
            }
        }.clipShape(.rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.14), lineWidth: 1).allowsHitTesting(false) }
            .environment(\.colorScheme, .dark)
            .onHover { hovering = $0 }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32).contentShape(.circle)
        }.buttonStyle(.plain).foregroundStyle(.white)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(label).accessibilityLabel(label)
    }
}
#endif
