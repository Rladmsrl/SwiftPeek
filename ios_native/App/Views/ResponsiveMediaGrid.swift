import SwiftUI

/// Measures the grid's container, including the space left by vertical system bars.
/// On a book fold, an even number of columns leaves a gutter at the actual hinge.
struct ResponsiveMediaGrid<Content: View>: View {
    var minimumWidth: CGFloat
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 18
    @ViewBuilder var content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var metrics = Metrics()

    private struct Metrics: Equatable {
        var width: CGFloat = 0
        var foldStart: CGFloat?
        var foldEnd: CGFloat?
    }

    private var leadingInset: CGFloat {
        metrics.foldStart == 0 ? (metrics.foldEnd ?? 0) : 0
    }

    private var trailingInset: CGFloat {
        metrics.foldEnd == metrics.width ? max(0, metrics.width - (metrics.foldStart ?? metrics.width)) : 0
    }

    private var columns: [GridItem] {
        let minimum = minimumWidth * (dynamicTypeSize.isAccessibilitySize ? 1.6 : 1)
        guard metrics.width > 0 else { return [GridItem(.flexible(minimum: 0))] }
        if let start = metrics.foldStart, let end = metrics.foldEnd,
           start > 0, end < metrics.width {
            let leftWidth = start
            let rightWidth = metrics.width - end
            let count = max(1, Int((min(leftWidth, rightWidth) + spacing) / (minimum + spacing)))
            let left = max(0, (leftWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
            let right = max(0, (rightWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
            return (0..<count).map { index in
                GridItem(.fixed(left), spacing: index == count - 1 ? end - start : spacing)
            } + Array(repeating: GridItem(.fixed(right), spacing: spacing), count: count)
        }
        let availableWidth = max(0, metrics.width - leadingInset - trailingInset)
        let count = max(1, Int((availableWidth + spacing) / (minimum + spacing)))
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: rowSpacing) {
            ForEach(subviews: content()) { card in
                card.modifier(HorizontalFoldAvoidance())
            }
        }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: Metrics.self) { geometry in
                var value = Metrics(width: geometry.size.width)
                if #available(iOS 27.1, *) {
                    if let fold = geometry.reservedRegions(kind: .division).first(where: {
                        $0.isActive && $0.frame.height > $0.frame.width
                    }) {
                        value.foldStart = max(0, fold.frame.minX)
                        value.foldEnd = min(value.width, fold.frame.maxX)
                    }
                }
                return value
            } action: { metrics = $0 }
    }
}

/// Move an entire card below a horizontal fold, including its title and tap area.
/// Measure the unpadded content separately so adding the gap cannot feed back
/// into the intersection test and repeatedly grow/shrink the same row.
private struct HorizontalFoldAvoidance: ViewModifier {
    @State private var contentHeight: CGFloat = 0
    @State private var fold: CGRect?

    private var topInset: CGFloat {
        guard let fold, fold.maxY > 0, fold.minY < contentHeight else { return 0 }
        return fold.maxY
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .padding(.top, topInset)
            .onGeometryChange(for: CGRect?.self) { geometry in
                if #available(iOS 27.1, *) {
                    return geometry.reservedRegions(kind: .division).first(where: {
                        $0.isActive && $0.frame.width > $0.frame.height
                    })?.frame
                }
                return nil
            } action: { fold = $0 }
    }
}
