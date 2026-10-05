import SwiftUI

/// Wraps a few equal-width tiles into rows. Unlike `LazyVGrid` every tile is always created, so
/// each stays in the accessibility tree and reachable by scrolling at any text size. For small,
/// bounded sets only (a review card's faces); long collections stay lazy.
struct TileLayout: Layout {
    var minimumWidth: CGFloat = 150
    var maximumWidth: CGFloat = 220
    var spacing: CGFloat = DesignTokens.Spacing.m
    /// 1 stacks every tile in one column (accessibility text sizes).
    var maximumColumns = 4

    private func columns(for width: CGFloat, count: Int) -> Int {
        let fit = max(1, Int((width + spacing) / (minimumWidth + spacing)))
        return max(1, min(fit, maximumColumns, max(count, 1)))
    }

    private func tileWidth(for width: CGFloat, columns: Int) -> CGFloat {
        min(maximumWidth, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minimumWidth
        let count = columns(for: width, count: subviews.count)
        let tile = tileWidth(for: width, columns: count)
        var height: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            if index > 0, index % count == 0 { height += rowHeight + spacing; rowHeight = 0 }
            rowHeight = max(rowHeight, view.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height)
        }
        return CGSize(width: width, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = columns(for: bounds.width, count: subviews.count)
        let tile = tileWidth(for: bounds.width, columns: count)
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            if index > 0, index % count == 0 { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            let size = view.sizeThatFits(ProposedViewSize(width: tile, height: nil))
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: tile, height: size.height))
            x += tile + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
