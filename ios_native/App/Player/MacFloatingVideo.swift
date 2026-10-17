#if os(macOS)
import AppKit
import AVFoundation
import SimpleLiveKit
import SwiftUI

/// Shared by live and replay. A native drag surface avoids NSHostingView swallowing
/// background drags; the explicit corner grip works with borderless panels.
@MainActor
final class MacFloatingVideoController: NSObject, NSWindowDelegate {
    private(set) var isActive = false
    private var panel: NSPanel?
    private weak var inlineLayer: CALayer?
    private var videoLayer: CALayer?
    var onStateChange: ((Bool) -> Void)?
    var onRestore: (() -> Void)?
    var onFinish: (() -> Void)?

    func start(layer: CALayer, size: CGSize?, settings: AppSettings,
               isPlaying: @escaping () -> Bool, togglePlayback: @escaping () -> Void,
               snapshot: @escaping () -> PiPDanmakuSnapshot) {
        guard !isActive, let parent = layer.superlayer else { return }
        inlineLayer = parent
        videoLayer = layer
        let area = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let aspect = FloatingVideoGeometry.aspect(for: size)
        let initial = FloatingVideoGeometry.initialSize(aspect: aspect, available: area.size)
        let created = NSPanel(contentRect: CGRect(x: area.maxX - initial.width - 24, y: area.minY + 24,
                                                 width: initial.width, height: initial.height),
                              styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        created.title = "SwiftPeek · 画中画"
        created.isReleasedWhenClosed = false
        created.level = settings.data.floatingWindowOnTop ? .floating : .normal
        created.hidesOnDeactivate = false
        created.isMovableByWindowBackground = false
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.hasShadow = true
        created.isOpaque = false
        created.backgroundColor = .clear
        created.contentAspectRatio = CGSize(width: aspect, height: 1)
        created.contentMinSize = CGSize(width: min(240, initial.width), height: min(240, initial.width) / aspect)
        created.delegate = self
        panel = created
        created.contentView = NSHostingView(rootView: FloatingPlayerView(
            layer: layer, settings: settings, isPlaying: isPlaying, snapshot: snapshot,
            togglePlayback: togglePlayback,
            setPinned: { [weak created] in created?.level = $0 ? .floating : .normal },
            restore: { [weak self] in self?.stop(); self?.onRestore?() },
            close: { [weak self] in self?.stop() }
        ))
        isActive = true
        onStateChange?(true)
        created.orderFrontRegardless()
    }

    func stop() { finish(closeWindow: true) }

    private func finish(closeWindow: Bool) {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let videoLayer {
            videoLayer.removeFromSuperlayer()
            if let inlineLayer {
                inlineLayer.addSublayer(videoLayer)
                videoLayer.frame = inlineLayer.bounds
            }
        }
        CATransaction.commit()
        if closeWindow { panel.close() }
        panel.contentView = nil
        videoLayer = nil
        inlineLayer = nil
        isActive = false
        onFinish?()
        onStateChange?(false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        finish(closeWindow: false)
    }
}

private struct FloatingPlayerView: View {
    let layer: CALayer
    @Bindable var settings: AppSettings
    let isPlaying: () -> Bool
    let snapshot: () -> PiPDanmakuSnapshot
    let togglePlayback: () -> Void
    let setPinned: (Bool) -> Void
    let restore: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        let danmaku = snapshot()
        ZStack {
            Color.black
            FloatingVideoSurface(videoLayer: layer).allowsHitTesting(false)
            DanmakuOverlay(messages: danmaku.messages, settings: danmaku.settings,
                           isVisible: danmaku.isVisible, clearToken: danmaku.clearToken, isPaused: danmaku.isPaused)
                .id(danmaku.sourceID).allowsHitTesting(false)
            FloatingPointerSurface(resize: false)
            if hovering || !isPlaying() {
                VStack {
                    HStack(spacing: 8) {
                        control("xmark", label: "关闭画中画", action: close)
                        Spacer(minLength: 0)
                        control(settings.data.pictureInPictureDanmaku ? "text.bubble.fill" : "text.bubble",
                                label: "小窗弹幕", active: settings.data.pictureInPictureDanmaku) {
                            settings.data.pictureInPictureDanmaku.toggle()
                        }
                        control(settings.data.floatingWindowOnTop ? "pin.fill" : "pin",
                                label: settings.data.floatingWindowOnTop ? "取消置顶" : "置顶",
                                active: settings.data.floatingWindowOnTop) {
                            settings.data.floatingWindowOnTop.toggle()
                        }
                        control("arrow.up.left.and.arrow.down.right", label: "返回播放窗口", action: restore)
                    }
                    Spacer()
                    control(isPlaying() ? "pause.fill" : "play.fill", label: "播放 / 暂停", action: togglePlayback)
                }.padding(12)
            }
        }
        .clipShape(.rect(cornerRadius: 16))
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Image(systemName: "line.3.horizontal.decrease").rotationEffect(.degrees(-45))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(hovering ? 0.8 : 0.35))
                    .allowsHitTesting(false)
                FloatingPointerSurface(resize: true)
            }.frame(width: 26, height: 26).padding(3)
                .help("拖动调整大小")
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.14), lineWidth: 1).allowsHitTesting(false) }
        .environment(\.colorScheme, .dark)
        .onHover { hovering = $0 }
        .onChange(of: settings.data.floatingWindowOnTop) { _, value in setPinned(value) }
    }

    private func control(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32).contentShape(.circle)
        }.buttonStyle(.plain).foregroundStyle(active ? .cyan : .white)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(label).accessibilityLabel(label)
            .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

private struct FloatingVideoSurface: NSViewRepresentable {
    let videoLayer: CALayer
    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.wantsLayer = true
        view.videoLayer = videoLayer
        view.layer?.addSublayer(videoLayer)
        return view
    }
    func updateNSView(_ view: Host, context: Context) {}
    final class Host: NSView {
        weak var videoLayer: CALayer?
        override func layout() {
            super.layout()
            guard let videoLayer, let layer else { return }
            VideoLayerLayout.resize(videoLayer, ownedBy: layer, bounds: bounds)
        }
    }
}

private struct FloatingPointerSurface: NSViewRepresentable {
    let resize: Bool
    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.resize = resize
        return view
    }
    func updateNSView(_ view: PointerView, context: Context) {}

    final class PointerView: NSView {
        var resize = false
        private var initialFrame = CGRect.zero
        private var initialPointer = CGPoint.zero
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if !resize { window.performDrag(with: event); return }
            initialFrame = window.frame
            initialPointer = NSEvent.mouseLocation
        }
        override func mouseDragged(with event: NSEvent) {
            guard resize, let window else { return }
            let frame = FloatingVideoGeometry.resizedFrame(initial: initialFrame,
                delta: CGSize(width: NSEvent.mouseLocation.x - initialPointer.x,
                              height: NSEvent.mouseLocation.y - initialPointer.y),
                minSize: window.contentMinSize, visible: window.screen?.visibleFrame)
            window.setFrame(frame, display: true)
        }
    }
}
#endif
