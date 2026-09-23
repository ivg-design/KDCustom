import Foundation

@main
enum MCPTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func send(_ server: MCPServer, _ object: [String: Any]) -> [String: Any]? {
        let input = try! JSONSerialization.data(withJSONObject: object)
        guard let output = server.processLine(input) else { return nil }
        return try! JSONSerialization.jsonObject(with: output) as? [String: Any]
    }

    static func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    static func call(_ id: Int, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
        request(id, "tools/call", ["name": name, "arguments": arguments])
    }

    static func code(_ response: [String: Any]?) -> Int? {
        (response?["error"] as? [String: Any])?["code"] as? Int
    }

    static func result(_ response: [String: Any]?) -> [String: Any]? {
        response?["result"] as? [String: Any]
    }

    static func main() throws {
        var calls: [(String, [String: Any])] = []
        let server = MCPServer { operation, arguments in
            calls.append((operation, arguments))
            if operation == "device.querySetting" {
                throw MCPInputError(reason: "Device unavailable")
            }
            return ["revision": "r2", "ok": true]
        }

        check(code(send(server, request(1, "tools/list"))) == -32002,
              "tools are unavailable before initialization")
        check(code(send(server, request(2, "initialize", ["protocolVersion": "2025-11-25"]))) == -32602,
              "initialize requires capabilities and clientInfo")
        let initialized = send(server, request(3, "initialize", [
            "protocolVersion": "2025-11-25",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "test-client", "version": "1.0"]
        ]))
        check(result(initialized)?["protocolVersion"] as? String == "2025-11-25",
              "initialize pins the supported version")
        check(code(send(server, request(4, "tools/list"))) == -32002,
              "initialized notification is required before operations")
        check(result(send(server, request(5, "ping")))?.isEmpty == true,
              "ping responds with an empty object")
        check(send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil,
              "initialized notification has no response")

        let listed = result(send(server, request(6, "tools/list")))?["tools"] as? [[String: Any]]
        check(listed?.count == 19, "all tools are listed")
        let read = listed?.first { $0["name"] as? String == "kdcustom_list_profiles" }
        let write = listed?.first { $0["name"] as? String == "kdcustom_set_binding" }
        let focusedRead = listed?.first { $0["name"] as? String == "kdcustom_get_focused_input" }
        check((read?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true,
              "read operation has readOnly annotation")
        check((write?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false,
              "write operation has non-read-only annotation")
        check((write?["inputSchema"] as? [String: Any])?["type"] as? String == "object",
              "tool input schema is an object")
        check((focusedRead?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true &&
              send(server, call(60, "kdcustom_get_focused_input", [:])) != nil &&
              calls.last?.0 == "runtime.focus",
              "focused-input metadata tool is read-only and routed to the app")
        check(send(server, call(61, "kdcustom_get_focused_input", ["panelCapture": "start"])) != nil &&
              calls.last?.1["panelCapture"] as? String == "start", "bounded panel inspection reaches the app")
        let beforeInvalidPanel = calls.count
        check(result(send(server, call(62, "kdcustom_get_focused_input", ["panelCapture": "forever"])))?["isError"] as? Bool == true &&
              calls.count == beforeInvalidPanel, "unbounded panel capture is rejected before the app")

        check(code(send(server, request(7, "unknown"))) == -32601,
              "unknown methods return method-not-found")
        check(code(send(server, call(8, "unknown_tool", [:]))) == -32602,
              "unknown tool is a protocol error")
        check(code(send(server, request(9, "tools/call", ["name": "kdcustom_list_profiles"]))) == -32602,
              "missing tool arguments are a protocol error")
        check(send(server, call(10, "kdcustom_list_profiles", [:])) != nil &&
              calls.last?.0 == "profiles.list", "read call reaches only the injected handler")

        let bindingData = try JSONEncoder().encode(ControlBinding(controlID: .dial1CCW,
                                                                  pressActions: [.keyTap(24, modifiers: [.command])]))
        let binding = try JSONSerialization.jsonObject(with: bindingData) as! [String: Any]
        let setArguments: [String: Any] = [
            "expectedRevision": "r1", "profileId": "global", "groupId": "group-1",
            "binding": binding
        ]
        let setResult = result(send(server, call(11, "kdcustom_set_binding", setArguments)))
        check(setResult?["isError"] as? Bool == false && calls.last?.0 == "bindings.set",
              "complete valid binding reaches handler")

        var malformedBinding = binding
        malformedBinding["unexpected"] = true
        let beforeInvalid = calls.count
        let invalidResult = result(send(server, call(12, "kdcustom_set_binding", [
            "expectedRevision": "r1", "profileId": "global", "groupId": "group-1",
            "binding": malformedBinding
        ])))
        check(invalidResult?["isError"] as? Bool == true && calls.count == beforeInvalid,
              "malformed binding is rejected before reaching handler")

        let focusRule: [String: Any] = [
            "id": "numeric", "name": "Numeric fields", "enabled": true,
            "targetGroupID": "group-2", "kind": "numeric", "role": "AXTextField"
        ]
        let focusResult = result(send(server, call(61, "kdcustom_set_context_rule", [
            "expectedRevision": "r1", "profileId": "editor", "rule": focusRule
        ])))
        check(focusResult?["isError"] as? Bool == false && calls.last?.0 == "contextRules.set",
              "complete focus rule reaches the shared configuration handler")
        let setFocusTool = listed?.first { $0["name"] as? String == "kdcustom_set_context_rule" }
        let ruleSchema = ((setFocusTool?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["rule"] as? [String: Any]
        let areaSchema = (ruleSchema?["properties"] as? [String: Any])?["area"] as? [String: Any]
        check(Set(areaSchema?["enum"] as? [String] ?? []) == Set(InputArea.allCases.map(\.rawValue)),
              "MCP schema advertises only supported active areas")
        var areaRule = focusRule
        areaRule.removeValue(forKey: "kind")
        areaRule.removeValue(forKey: "role")
        areaRule["area"] = "timeline"
        check(result(send(server, call(63, "kdcustom_set_context_rule", [
            "expectedRevision": "r1", "profileId": "editor", "rule": areaRule
        ])))?["isError"] as? Bool == false && calls.last?.0 == "contextRules.set",
              "MCP accepts a valid area-only rule")
        let beforeUnknownArea = calls.count
        areaRule["area"] = "unknown"
        check(result(send(server, call(64, "kdcustom_set_context_rule", [
            "expectedRevision": "r1", "profileId": "editor", "rule": areaRule
        ])))?["isError"] as? Bool == true && calls.count == beforeUnknownArea,
              "MCP rejects an unknown active area before app dispatch")
        var malformedRule = focusRule
        malformedRule["fieldValue"] = "123456"
        let beforeMalformedRule = calls.count
        check(result(send(server, call(62, "kdcustom_set_context_rule", [
            "expectedRevision": "r1", "profileId": "editor", "rule": malformedRule
        ])))?["isError"] as? Bool == true && calls.count == beforeMalformedRule,
              "field values and unknown focus-rule fields are rejected before app dispatch")
        check(result(send(server, call(63, "kdcustom_list_context_rules",
                                       ["profileId": "editor"])))?["isError"] as? Bool == false &&
              calls.last?.0 == "contextRules.list",
              "ordered focus-rule read reaches the app")

        let batch: [String: Any] = [
            "expectedRevision": "r1",
            "operations": [
                ["name": "kdcustom_rename_group",
                 "arguments": ["profileId": "global", "groupId": "group-1", "name": "Editing"]],
                ["name": "kdcustom_set_binding",
                 "arguments": ["profileId": "global", "groupId": "group-1", "binding": binding]],
                ["name": "kdcustom_set_context_rule",
                 "arguments": ["profileId": "editor", "rule": focusRule]]
            ]
        ]
        let batchResult = result(send(server, call(13, "kdcustom_apply_batch", batch)))
        check(batchResult?["isError"] as? Bool == false && calls.last?.0 == "configuration.applyBatch",
              "valid batch is handed to app as one operation")
        let beforeBadBatch = calls.count
        let badBatch = [
            "expectedRevision": "r1",
            "operations": [["name": "kdcustom_list_profiles", "arguments": [String: Any]()]]
        ] as [String: Any]
        check(result(send(server, call(14, "kdcustom_apply_batch", badBatch)))?["isError"] as? Bool == true &&
              calls.count == beforeBadBatch, "read tools cannot be nested in a write batch")

        let deviceError = result(send(server, call(15, "kdcustom_query_device_setting",
                                                  ["setting": "brightness"])))
        check(deviceError?["isError"] as? Bool == true,
              "app-side device failures are visible as tool errors")
        let batchArrayResponse = try JSONSerialization.jsonObject(
            with: server.processLine(Data("[1,2]".utf8))!
        ) as? [String: Any]
        check(code(batchArrayResponse) == -32600,
              "JSON-RPC batch arrays are rejected")
        check(code(try JSONSerialization.jsonObject(with: server.processLine(Data("{".utf8))!) as? [String: Any]) == -32700,
              "malformed JSON returns parse error")
        check(code(try JSONSerialization.jsonObject(
            with: server.processLine(Data(repeating: 0x20, count: MCPTools.maxMessageBytes + 1))!
        ) as? [String: Any]) == -32600, "message size is bounded")

        print("MCPTests passed")
    }
}
