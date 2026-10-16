import SimpleLiveKit
import SwiftUI

/// 录像进度条：底部是播放 / 缓冲进度，上方浮着一条弹幕热度曲线，
/// 章节位置用细缝标出。拖动时预览目标时间与所在章节，松手才真正跳转。
struct ReplayScrubber: View {
    let time: TimeInterval
    let duration: TimeInterval
    let buffered: TimeInterval
    var heat: [Double] = []
    var chapters: [DouyuReplayChapter] = []
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    @State private var hoverFraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heatHeight: CGFloat = 16
    private var active: Bool { dragFraction != nil || hoverFraction != nil }
    private var trackHeight: CGFloat { active ? 6 : 4 }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = dragFraction ?? progress(time)
            let trackY = geometry.size.height - 9
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawHeat(in: &context, size: size, trackY: trackY, played: fraction)
                    drawTrack(in: &context, width: size.width, trackY: trackY, played: fraction)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .frame(width: active ? 14 : 10, height: active ? 14 : 10)
                    .position(x: width * fraction, y: trackY)
                if let preview = dragFraction ?? hoverFraction {
                    previewLabel(for: preview)
                        .fixedSize()
                        .position(x: min(max(width * preview, 60), width - 60), y: -16)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragFraction = clamp(value.location.x / width) }
                    .onEnded { value in
                        let target = clamp(value.location.x / width)
                        dragFraction = nil
                        if duration > 0 { onSeek(target * duration) }
                    }
            )
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverFraction = clamp(location.x / width)
                case .ended: hoverFraction = nil
                }
            }
            #endif
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: active)
        }
        .frame(height: heatHeight + 18)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(ReplayPlayer.format(time))，共 \(ReplayPlayer.format(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, time + 15))
            case .decrement: onSeek(max(0, time - 15))
            @unknown default: break
            }
        }
    }

    private func progress(_ value: TimeInterval) -> Double {
        duration > 0 ? clamp(value / duration) : 0
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private func drawHeat(in context: inout GraphicsContext, size: CGSize, trackY: CGFloat, played: Double) {
        guard heat.count > 1 else { return }
        let base = trackY - 5
        var path = Path()
        path.move(to: CGPoint(x: 0, y: base))
        let step = size.width / CGFloat(heat.count - 1)
        var previous = CGPoint(x: 0, y: base - CGFloat(heat[0]) * heatHeight)
        path.addLine(to: previous)
        for index in 1..<heat.count {
            let point = CGPoint(x: CGFloat(index) * step, y: base - CGFloat(heat[index]) * heatHeight)
            let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
            previous = point
        }
        path.addLine(to: previous)
        path.addLine(to: CGPoint(x: size.width, y: base))
        path.closeSubpath()

        let opacity = active ? 1.0 : 0.7
        context.fill(path, with: .color(.white.opacity(0.16 * opacity)))
        var playedContext = context
        playedContext.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * played, height: size.height)))
        playedContext.fill(path, with: .linearGradient(
            Gradient(colors: [Theme.accent.opacity(0.75 * opacity), Theme.accent.opacity(0.18 * opacity)]),
            startPoint: CGPoint(x: 0, y: base - heatHeight), endPoint: CGPoint(x: 0, y: base)
        ))
    }

    private func drawTrack(in context: inout GraphicsContext, width: CGFloat, trackY: CGFloat, played: Double) {
        let rect = CGRect(x: 0, y: trackY - trackHeight / 2, width: width, height: trackHeight)
        let radius = trackHeight / 2
        context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(.white.opacity(0.2)))
        let bufferedWidth = width * progress(buffered)
        if bufferedWidth > 0 {
            context.fill(Path(roundedRect: CGRect(x: 0, y: rect.minY, width: bufferedWidth, height: trackHeight),
                              cornerRadius: radius), with: .color(.white.opacity(0.22)))
        }
        context.fill(Path(roundedRect: CGRect(x: 0, y: rect.minY, width: width * played, height: trackHeight),
                          cornerRadius: radius), with: .color(Theme.accent))
        // 章节分隔：在轨道上切出细缝
        guard duration > 0 else { return }
        for chapter in chapters where chapter.start > 1 {
            let x = width * progress(chapter.start)
            context.fill(Path(CGRect(x: x - 1, y: rect.minY, width: 2, height: trackHeight)),
                         with: .color(.black.opacity(0.55)))
        }
    }

    private func previewLabel(for fraction: Double) -> some View {
        let target = fraction * duration
        let chapter = chapters.last { $0.start <= target }
        return VStack(spacing: 2) {
            if let chapter {
                Text(chapter.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: 220)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(ReplayPlayer.format(target))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.72), in: .rect(cornerRadius: 9))
    }
}
