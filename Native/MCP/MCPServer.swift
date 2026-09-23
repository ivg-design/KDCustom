import CoreFoundation
import Foundation

/// Stateful MCP 2025-11-25 stdio endpoint. The injected handler is the only
/// path to application state; it must dispatch to the app's single writer.
final class MCPServer {
    typealias Handler = (_ operation: String, _ arguments: [String: Any]) throws -> [String: Any]

    private let handle: Handler
    private var didInitialize = false
    private var didReceiveInitialized = false

    init(handle: @escaping Handler) {
        self.handle = handle
    }

    /// Processes one UTF-8 JSON-RPC message, without its newline delimiter.
    /// Notifications return nil. Kept separate from stdio for protocol tests.
    func processLine(_ line: Data) -> Data? {
        guard line.count <= MCPTools.maxMessageBytes else {
            return encode(error(id: NSNull(), code: -32600, message: "Message exceeds 4 MB limit"))
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: line)
        } catch _ {
            return encode(error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let request = value as? [String: Any] else {
            // MCP 2025-11-25 does not support JSON-RPC batches.
            return encode(error(id: NSNull(), code: -32600, message: "Expected one request object"))
        }
        let id = validID(request["id"])
        let hasID = request.keys.contains("id")
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String, !method.isEmpty,
              !hasID || id != nil else {
            return encode(error(id: id ?? NSNull(), code: -32600, message: "Invalid JSON-RPC request"))
        }
        if !hasID {
            if method == "notifications/initialized", didInitialize {
                didReceiveInitialized = true
            }
            // Unknown notifications are intentionally ignored.
            return nil
        }
        let requestID = id ?? NSNull()
        switch method {
        case "initialize":
            guard !didInitialize,
                  let params = request["params"] as? [String: Any],
                  params["protocolVersion"] is String,
                  params["capabilities"] is [String: Any],
                  let client = params["clientInfo"] as? [String: Any],
                  client["name"] is String, client["version"] is String else {
                return encode(error(id: requestID, code: -32602,
                                    message: "Invalid or repeated initialize request"))
            }
            didInitialize = true
            // Per the lifecycle specification, a server may counter-offer its
            // supported version when the client requested another version.
            return encode(success(id: requestID, result: [
                "protocolVersion": MCPTools.protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "KDCustom", "version": "0.1.0"],
                "instructions": "Configure K40 profiles and bindings through these tools. Read the current revision before edits; use apply_batch for related changes."
            ]))
        case "ping":
            return encode(success(id: requestID, result: [:]))
        case "tools/list":
            guard didReceiveInitialized else {
                return encode(error(id: requestID, code: -32002, message: "Initialize first"))
            }
            if let params = request["params"] as? [String: Any], params["cursor"] != nil {
                return encode(error(id: requestID, code: -32602, message: "No pagination cursor is supported"))
            }
            return encode(success(id: requestID, result: ["tools": MCPTools.all.map(\.listing)]))
        case "tools/call":
            guard didReceiveInitialized else {
                return encode(error(id: requestID, code: -32002, message: "Initialize first"))
            }
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String,
                  let arguments = params["arguments"] as? [String: Any] else {
                return encode(error(id: requestID, code: -32602,
                                    message: "tools/call requires name and object arguments"))
            }
            guard let tool = MCPTools.byName[name] else {
                return encode(error(id: requestID, code: -32602, message: "Unknown tool: \(name)"))
            }
            do {
                try MCPTools.validate(name: name, arguments: arguments)
                let output = try handle(tool.operation, arguments)
                guard JSONSerialization.isValidJSONObject(output) else {
                    throw MCPInputError(reason: "App bridge returned a non-JSON object")
                }
                return encode(success(id: requestID, result: toolResult(output, isError: false)))
            } catch {
                let message = String(error.localizedDescription.prefix(1_024))
                return encode(success(id: requestID, result: toolResult(["error": message], isError: true)))
            }
        default:
            return encode(error(id: requestID, code: -32601, message: "Method not found: \(method)"))
        }
    }

    /// Run only in a dedicated MCP subprocess. Nothing except MCP messages
    /// reaches stdout; diagnostic logging belongs on stderr.
    func runStdio() {
        var line = Data()
        var overflow = false
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            for byte in chunk {
                if byte == 0x0A {
                    if overflow {
                        emit(error(id: NSNull(), code: -32600, message: "Message exceeds 4 MB limit"))
                    } else {
                        if line.last == 0x0D { line.removeLast() }
                        if let response = processLine(line) {
                            FileHandle.standardOutput.write(response + Data([0x0A]))
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                    overflow = false
                } else if !overflow {
                    if line.count < MCPTools.maxMessageBytes {
                        line.append(byte)
                    } else {
                        overflow = true
                        line.removeAll(keepingCapacity: false)
                    }
                }
            }
        }
        // The stdio specification requires newline-delimited messages. An
        // unterminated final message is discarded when the client closes stdin.
    }

    private func emit(_ object: [String: Any]) {
        guard let data = encode(object) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    private func toolResult(_ value: [String: Any], isError: Bool) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return [
            "content": [["type": "text", "text": text]],
            "structuredContent": value,
            "isError": isError
        ]
    }

    private func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validID(_ raw: Any?) -> Any? {
        guard let raw else { return nil }
        if raw is NSNull { return NSNull() }
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue {
            return number
        }
        return nil
    }
}
