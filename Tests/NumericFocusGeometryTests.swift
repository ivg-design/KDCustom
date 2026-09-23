import CoreGraphics

@main enum NumericFocusGeometryTests {
    static func main() {
        let window = CGRect(x: 0, y: 20, width: 1000, height: 800)
        let x = CGRect(x: 800, y: 100, width: 40, height: 18)
        let y = CGRect(x: 850, y: 100, width: 40, height: 18)
        precondition(NumericFocusGeometry.sameField(x, x))
        precondition(NumericFocusGeometry.sameField(x, x.offsetBy(dx: 0.5, dy: 0)))
        precondition(!NumericFocusGeometry.sameField(x, y))
        precondition(NumericFocusGeometry.distinctField(y, original: x, window: window))
        precondition(!NumericFocusGeometry.distinctField(x, original: x, window: window))
        precondition(!NumericFocusGeometry.distinctField(x.offsetBy(dx: 500, dy: 0), original: x, window: window))
        precondition(!NumericFocusGeometry.sameField(.zero, .zero))
        precondition(!NumericFocusGeometry.valid(CGRect(x: Double.infinity, y: 0, width: 40, height: 18)))
        print("NumericFocusGeometryTests passed")
    }
}
