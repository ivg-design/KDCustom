import CoreGraphics

/// A Flutter native editor can reuse one AX element while moving it between
/// numeric fields. Geometry complements app/window/focus/value checks.
enum NumericFocusGeometry {
    static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }
    static func sameField(_ first: CGRect, _ second: CGRect) -> Bool {
        valid(first) && valid(second) &&
            abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1 &&
            abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
    }
    static func distinctField(_ next: CGRect, original: CGRect, window: CGRect) -> Bool {
        valid(next) && valid(original) && valid(window) && window.contains(next) && window.contains(original) &&
            (abs(next.midX - original.midX) > 4 || abs(next.midY - original.midY) > 4)
    }
}
