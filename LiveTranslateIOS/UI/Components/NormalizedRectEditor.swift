import SwiftUI
import UIKit

/// Interactive normalized-rect editor over an image — the shared engine
/// behind both the visual-ask region selector (圈选区域) and the
/// attachment crop sheet.
///
/// Two modes (zoom and rect editing never fight over gestures):
/// - browse: pinch to zoom (1…4×), drag to pan while zoomed;
/// - select: drag on empty image area to draw a rect, drag inside to
///   move it, drag a corner handle to resize. The rect is NORMALIZED
///   in the upright image space (0…1) — never screen pixels; geometry
///   survives rotation, export and sync.
struct NormalizedRectEditor: View {
    let uiImage: UIImage
    @Binding var rect: NormalizedRect
    var isSelecting: Bool
    /// Smallest selectable rect (normalized long-edge fraction).
    var minNormalizedSize: CGFloat = 0.06

    @State private var dragKind: DragKind = .none
    @State private var dragStartRect: NormalizedRect = .full
    @State private var dragStartPoint: CGPoint = .zero
    @State private var zoomScale: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    private enum DragKind: Equatable {
        case none
        case move
        case resizeCorner(Int)
        case drawNew
    }

    private let handleRadius: CGFloat = 13
    private let handleHitRadius: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let display = Self.fittedSize(imageSize: uiImage.size, in: proxy.size)
            let frame = CGRect(
                x: (proxy.size.width - display.width) / 2,
                y: (proxy.size.height - display.height) / 2,
                width: display.width,
                height: display.height
            )
            ZStack {
                Image(uiImage: uiImage)
                    .resizable()
                    .frame(width: display.width, height: display.height)
                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                    .scaleEffect(isSelecting ? 1 : zoomScale, anchor: .center)
                    .offset(isSelecting ? .zero : zoomOffset)

                if isSelecting {
                    selectionUI(in: frame)
                }
            }
            .contentShape(Rectangle())
            .gesture(isSelecting ? selectDrag(in: frame) : panDrag(in: frame))
            .simultaneousGesture(
                isSelecting ? nil : MagnificationGesture()
                    .onChanged { value in
                        zoomScale = min(max(steadyZoom * value, 1), 4)
                    }
                    .onEnded { _ in
                        steadyZoom = zoomScale
                        if zoomScale <= 1.01 { zoomOffset = .zero; steadyOffset = .zero }
                    }
            )
            .clipped()
        }
    }

    // MARK: - Select mode

    /// Dimmed surround + the selection window border + corner handles,
    /// all positioned in the FITTED image frame (correctly aligned with
    /// the image regardless of container aspect).
    @ViewBuilder
    private func selectionUI(in frame: CGRect) -> some View {
        let window = displayRect(of: rect.cgRect, in: frame)
        WindowSurround(window: window)
            .fill(Color.black.opacity(0.45))
            .allowsHitTesting(false)

        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(LTColors.accentGreen, lineWidth: 1.5)
            .frame(width: window.width, height: window.height)
            .position(x: window.midX, y: window.midY)
            .allowsHitTesting(false)

        ForEach(0..<4, id: \.self) { corner in
            Circle()
                .fill(LTColors.accentGreen)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .frame(width: handleRadius * 2, height: handleRadius * 2)
                .position(handlePoint(corner, window: window))
                .allowsHitTesting(false)
        }
    }

    private func selectDrag(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = value.startLocation
                if dragKind == .none {
                    dragStartRect = rect
                    dragStartPoint = start
                    dragKind = hitTest(start, in: frame)
                }
                let current = normalized(value.location, in: frame)
                let origin = normalized(dragStartPoint, in: frame)
                switch dragKind {
                case .move:
                    let dx = current.x - origin.x
                    let dy = current.y - origin.y
                    let startRect = dragStartRect
                    let x = min(max(0, startRect.x + dx), 1 - startRect.width)
                    let y = min(max(0, startRect.y + dy), 1 - startRect.height)
                    rect = NormalizedRect(x: x, y: y, width: startRect.width, height: startRect.height)
                case .resizeCorner(let corner):
                    rect = resized(from: dragStartRect, corner: corner, to: current)
                case .drawNew:
                    rect = NormalizedRect(
                        x: min(origin.x, current.x),
                        y: min(origin.y, current.y),
                        width: abs(current.x - origin.x),
                        height: abs(current.y - origin.y)
                    )
                case .none:
                    break
                }
            }
            .onEnded { _ in
                // Snap degenerate rects back to the previous selection.
                if rect.width < minNormalizedSize || rect.height < minNormalizedSize {
                    if dragKind == .drawNew {
                        rect = dragStartRect
                    }
                }
                rect = rect.clamped()
                dragKind = .none
            }
    }

    private func hitTest(_ point: CGPoint, in frame: CGRect) -> DragKind {
        let window = displayRect(of: rect.cgRect, in: frame)
        for corner in 0..<4 {
            let handle = handlePoint(corner, window: window)
            if hypot(point.x - handle.x, point.y - handle.y) <= handleHitRadius {
                return .resizeCorner(corner)
            }
        }
        if window.insetBy(dx: -handleHitRadius * 0.4, dy: -handleHitRadius * 0.4).contains(point) {
            return .move
        }
        // Only drags starting ON the image draw a new rect.
        if frame.contains(point) {
            return .drawNew
        }
        return .none
    }

    /// Corner 0 = top-left, 1 = top-right, 2 = bottom-right, 3 = bottom-left.
    private func handlePoint(_ corner: Int, window: CGRect) -> CGPoint {
        switch corner {
        case 0: return CGPoint(x: window.minX, y: window.minY)
        case 1: return CGPoint(x: window.maxX, y: window.minY)
        case 2: return CGPoint(x: window.maxX, y: window.maxY)
        default: return CGPoint(x: window.minX, y: window.maxY)
        }
    }

    /// Resizes one corner of the start rect to the dragged point; the
    /// opposite edge stays anchored and everything clamps to 0…1.
    private func resized(from start: NormalizedRect, corner: Int, to point: CGPoint) -> NormalizedRect {
        let minX = start.x, minY = start.y, maxX = start.x + start.width, maxY = start.y + start.height
        var newMinX = minX, newMinY = minY, newMaxX = maxX, newMaxY = maxY
        switch corner {
        case 0: newMinX = point.x; newMinY = point.y
        case 1: newMaxX = point.x; newMinY = point.y
        case 2: newMaxX = point.x; newMaxY = point.y
        default: newMinX = point.x; newMaxY = point.y
        }
        let loX = min(max(0, min(newMinX, newMaxX)), 1)
        let hiX = min(max(0, max(newMinX, newMaxX)), 1)
        let loY = min(max(0, min(newMinY, newMaxY)), 1)
        let hiY = min(max(0, max(newMinY, newMaxY)), 1)
        return NormalizedRect(
            x: loX, y: loY,
            width: max(hiX - loX, 0), height: max(hiY - loY, 0)
        )
    }

    // MARK: - Browse mode

    private func panDrag(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard zoomScale > 1.01 else { return }
                // Accumulate from the gesture start's steady offset so
                // consecutive pans don't snap back.
                zoomOffset = CGSize(
                    width: steadyOffset.width + value.translation.width,
                    height: steadyOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                steadyOffset = zoomOffset
            }
    }

    // MARK: - Geometry

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - frame.minX) / max(frame.width, 1), 0), 1),
            y: min(max((point.y - frame.minY) / max(frame.height, 1), 0), 1)
        )
    }

    private func displayRect(of rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX * frame.width,
            y: frame.minY + rect.minY * frame.height,
            width: rect.width * frame.width,
            height: rect.height * frame.height
        )
    }

    static func fittedSize(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let aspect = imageSize.width / imageSize.height
        var width = container.width
        var height = width / aspect
        if height > container.height {
            height = container.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }
}

/// The area around a window (top/bottom/left/right strips) — fills the
/// whole frame except the window.
private struct WindowSurround: Shape {
    let window: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(
            x: rect.minX, y: rect.minY,
            width: rect.width, height: max(window.minY - rect.minY, 0)
        ))
        path.addRect(CGRect(
            x: rect.minX, y: window.maxY,
            width: rect.width, height: max(rect.maxY - window.maxY, 0)
        ))
        path.addRect(CGRect(
            x: rect.minX, y: window.minY,
            width: max(window.minX - rect.minX, 0), height: window.height
        ))
        path.addRect(CGRect(
            x: window.maxX, y: window.minY,
            width: max(rect.maxX - window.maxX, 0), height: window.height
        ))
        return path
    }
}
