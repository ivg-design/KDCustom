import Foundation

@main
enum NumericStepBufferTests {
    static func main() {
        var buffer = NumericStepBuffer()
        for _ in 0..<100 { precondition(buffer.append(0.01)) }
        let hundred = buffer.take()!
        precondition(hundred.delta == 1 && hundred.detents == 100 && buffer.pendingCount == 0)
        precondition(NumericAdjustment.adjustedString("1", delta: hundred.delta) == "2")
        precondition(buffer.append(0.01) && buffer.append(0.1) && buffer.append(-0.01))
        precondition(buffer.take()?.delta == 0.11 && buffer.take()?.delta == -0.01,
                     "Direction reversals remain ordered, including near bounds")
        precondition(buffer.append(1_000_000) && buffer.append(1))
        precondition(buffer.take()?.delta == 1_000_000 && buffer.take()?.delta == 1,
                     "Oversized combined deltas split without losing detents")
        for _ in 0..<NumericStepBuffer.capacity { precondition(buffer.append(-0.01)) }
        precondition(!buffer.append(-0.01) && buffer.pendingCount == NumericStepBuffer.capacity)
        buffer.removeAll()
        precondition(buffer.take() == nil && buffer.pendingCount == 0)
        precondition(!buffer.append(.nan) && !buffer.append(.infinity) && !buffer.append(0))
        precondition(NumericAdjustment.equalValues("0.010", "0.01"))
        precondition(!NumericAdjustment.equalValues("0.01px", "0.01") && !NumericAdjustment.equalValues("0.01", "0.02"))
        print("NumericStepBuffer tests passed")
    }
}
