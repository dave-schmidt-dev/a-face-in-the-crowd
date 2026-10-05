import SwiftUI
import UIKit

/// Photo that fills its container and zooms with pinch or a double tap, then pans while zoomed.
/// The zoom level is the accessibility value ("100 percent"), so VoiceOver and UI tests can read
/// it, and Zoom in / Zoom out / Reset zoom are offered as accessibility actions.
struct ZoomableImage: View {
    let image: UIImage
    /// Called with true while the photo is zoomed in, so a parent can hold its own scrolling.
    var onZoomed: (Bool) -> Void = { _ in }
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    private static let limits: ClosedRange<CGFloat> = 1...6

    private func clamped(_ value: CGFloat) -> CGFloat { min(max(value, Self.limits.lowerBound), Self.limits.upperBound) }

    private func bounded(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let x = size.width * (scale - 1) / 2, y = size.height * (scale - 1) / 2
        return CGSize(width: min(max(proposed.width, -x), x), height: min(max(proposed.height, -y), y))
    }

    private func set(_ value: CGFloat) {
        scale = clamped(value)
        if scale <= 1 { offset = .zero }
        onZoomed(scale > 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let live = clamped(scale * pinch)
            let position = bounded(CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                                   scale: live, in: geometry.size)
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(live).offset(position)
                .contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { set(scale * $0.magnification) })
                .gesture(DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset = bounded(CGSize(width: offset.width + value.translation.width,
                                                height: offset.height + value.translation.height),
                                         scale: scale, in: geometry.size)
                    }, including: scale > 1 ? .all : .subviews)
                .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { set(scale > 1 ? 1 : 2.5) } }
                .accessibilityLabel("Photo view")
                .accessibilityValue("\(Int((scale * 100).rounded())) percent")
                .accessibilityAction(named: "Zoom in") { set(scale * 1.5) }
                .accessibilityAction(named: "Zoom out") { set(scale / 1.5) }
                .accessibilityAction(named: "Reset zoom") { set(1) }
        }
        .clipped()
    }
}
