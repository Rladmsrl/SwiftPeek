import SwiftUI
import SimpleLiveKit

/// Both children retain their identity across resizing, folding and fullscreen.
/// In particular the UIKit video host is never replaced by a second host.
struct AdaptivePlaybackContainer<Video: View, Companion: View>: View {
    let fullscreen: Bool
    @ViewBuilder var video: () -> Video
    @ViewBuilder var companion: () -> Companion

    var body: some View {
        GeometryReader { geometry in
            let layout = layout(in: geometry)
            PlaybackPaneLayout(size: geometry.size, layout: layout) {
                video()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(.rect)
                    // A collapsed UIKit scroll/list pane can retain its old hit
                    // region. Keep player controls above it without replacing the host.
                    .zIndex(1)

                companion()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(.rect)
                    .opacity(layout.companion.isEmpty ? 0 : 1)
                    .allowsHitTesting(!layout.companion.isEmpty)
                    .accessibilityHidden(layout.companion.isEmpty)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            #if DEBUG
            .onChange(of: layout, initial: true) { _, value in
                var fields = [
                    "container": String(describing: geometry.size),
                    "video": String(describing: value.video),
                    "companion": String(describing: value.companion),
                    "fullscreen": String(fullscreen)
                ]
                if #available(iOS 27.1, *) {
                    fields["divisions"] = String(describing: geometry.reservedRegions(kind: .division).filter(\.isActive).map(\.frame))
                }
                LiveDiagnostics.record("ui.playbackLayout", fields: fields)
            }
            #endif
        }
        // 只在内容区内铺分隔色（视频与面板之间的 1pt 缝），不延伸到导航栏和标签栏后面
        .background(fullscreen ? Color.black : Color(uiColor: .separator), ignoresSafeAreaEdges: [])
        .background {
            if fullscreen { Color.black.ignoresSafeArea() }
        }
    }

    private func layout(in geometry: GeometryProxy) -> PlaybackLayout {
        if #available(iOS 27.1, *) {
            // GeometryReader already respects the safe area. Reserved-region
            // frames use these same local coordinates; don't subtract insets again.
            func frames(_ kind: ReservedRegion.Kind) -> [CGRect] {
                // frame already includes the margins for interactive content.
                geometry.reservedRegions(kind: kind).filter(\.isActive).map(\.frame)
            }
            return PlaybackLayout(size: geometry.size, fullscreen: fullscreen,
                                  divisions: frames(.division), occlusions: frames(.occlusion))
        }
        return PlaybackLayout(size: geometry.size, fullscreen: fullscreen)
    }
}

/// Place children through the layout system so visual and touch coordinates
/// share the same bounds when system bars disappear or change axis.
private struct PlaybackPaneLayout: Layout {
    let size: CGSize
    let layout: PlaybackLayout

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, [layout.video, layout.companion]) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// Keep metadata readable at large text sizes without starving the list below it.
struct PlaybackCompanion<Info: View, Content: View>: View {
    @ViewBuilder var info: () -> Info
    @ViewBuilder var content: () -> Content
    @State private var infoHeight: CGFloat = 96

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    info()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { infoHeight = $0 }
                }
                    .frame(height: min(infoHeight, geometry.size.height * 0.4))
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // 浅色为白，深色为次级灰：深色模式下面板与纯黑视频区分得开
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
