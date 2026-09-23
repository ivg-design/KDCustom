import Foundation

@main struct LabelTests {
    static func main() throws {
        let key = try K40LabelPacket.key(1, group: 1, text: "A")
        precondition(key.count == 64 && Array(key.prefix(10)) == [0x18,2,5,3,1,0,1,2,0x41,0])
        precondition(key.dropFirst(10).allSatisfy { $0 == 0 })
        let topLeft = try K40LabelPacket.key(K40ButtonLayout.wireSlot(forPhysicalButton: 1)!, group: 1, text: "1")
        let bottomLeft = try K40LabelPacket.key(K40ButtonLayout.wireSlot(forPhysicalButton: 5)!, group: 1, text: "5")
        precondition(topLeft[6] == 2 && bottomLeft[6] == 1)
        let group = try K40LabelPacket.group(6, text: "⌘↑")
        precondition(Array(group.prefix(10)) == [0x18,1,5,3,6,4,0x18,0x23,0x91,0x21])
        let emoji = try K40LabelPacket.key(8, group: 6, text: "😀")
        precondition(Array(emoji[7..<12]) == [4,0x3d,0xd8,0,0xde])
        for bad in [0, 7, -1] {
            do { _ = try K40LabelPacket.group(bad, text: "test"); fatalError("Invalid group accepted") }
            catch LabelError.groupRange { }
        }
        do { _ = try K40LabelPacket.key(9, group: 1, text: "test"); fatalError("Invalid key accepted") }
        catch LabelError.keyRange { }
        do { _ = try K40LabelPacket.key(1, group: 1, text: String(repeating: "A", count: 29)); fatalError("Overflow accepted") }
        catch LabelError.tooLong { }
        print("Label protocol fixtures and bounds: passed")
    }
}
