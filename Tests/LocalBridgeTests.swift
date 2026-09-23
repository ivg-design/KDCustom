import Foundation
import Darwin

@main
struct LocalBridgeTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kd-bridge-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("a.sock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = LocalBridge(url: url) { operation, arguments in
            guard operation == "test" else { throw LocalBridgeError(message: "Rejected operation") }
            return ["echo": arguments]
        }
        try bridge.start()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let result = try LocalBridge.request(operation: "test", arguments: ["message": "roundtrip", "value": 19], url: url)
        precondition((result["echo"] as? [String: Any])?["message"] as? String == "roundtrip")
        do { _ = try LocalBridge.request(operation: "unknown", arguments: [:], url: url); preconditionFailure("Expected error") }
        catch { precondition(error.localizedDescription.contains("Rejected")) }
        let duplicate = LocalBridge(url: url) { _, _ in [:] }
        do { try duplicate.start(); preconditionFailure("Duplicate took active socket") }
        catch { precondition(error.localizedDescription.contains("already running")) }
        // Duplicate protection must leave the original endpoint usable.
        _ = try LocalBridge.request(operation: "test", arguments: [:], url: url)
        bridge.stop()
        do { _ = try LocalBridge.request(operation: "test", arguments: [:], url: url); preconditionFailure("Stopped endpoint reachable") }
        catch { precondition(error.localizedDescription.contains("Open KDCustom")) }
        print("LocalBridgeTests passed")
    }
}
