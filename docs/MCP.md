# KDCustom MCP bridge

The installed Keydial Studio app exposes an MCP stdio helper for configuring the same K40 profiles and bindings shown in the native UI. Keep the app running; the helper connects to it and never becomes a second device controller or profile writer. The protocol implementation in `Native/MCP` is pinned to MCP **2025-11-25**. It uses newline-delimited UTF-8 JSON-RPC 2.0 on stdin/stdout, with no HTTP listener. The helper never executes a binding.

This implementation follows the official [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#stdio), and [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) definitions. A client sends `initialize`, waits for the response, then sends `notifications/initialized` before `tools/list` or `tools/call`. `ping` is accepted during initialization. Each JSON-RPC message occupies one line; diagnostics must go to stderr, never stdout. Input lines are capped at 4 MB. JSON-RPC batch arrays are unsupported by this protocol version; `kdcustom_apply_batch` is an application-level atomic edit tool.

## Connect an MCP client

Install the signed app at `/Applications/Keydial Studio.app` with `bash scripts/build-native.sh --install`, launch it, then choose **Settings → Copy MCP configuration**. The copied configuration uses the running app's executable path. The equivalent installed-path entry is:

```json
{
  "mcpServers": {
    "kdcustom": {
      "command": "/Applications/Keydial Studio.app/Contents/MacOS/KeydialStudio",
      "args": ["--mcp"]
    }
  }
}
```

The stable installed path and bundle identifier `life.mograph.KeydialStudio` also keep macOS permissions associated with one application identity. Launching the helper while the app is closed returns an explicit unavailable error; it does not launch the GUI or claim the K40.

## Application integration

`Native/App/main.swift` handles `--mcp` before creating AppKit, constructs `MCPServer(handle:)`, and calls `runStdio()`. The handler has this signature:

```swift
(_ operation: String, _ arguments: [String: Any]) throws -> [String: Any]
```

`LocalBridge` connects the helper to the already-running app at `~/Library/Application Support/KeydialStudio/agent.sock`. The socket is owner-only (`0600`) inside an owner-only directory (`0700`), and both ends verify the peer user ID. The GUI marshals requests to its main-thread `ConfigurationService`, the only writer of `KeydialDocument`. For each mutation, the service compares `expectedRevision` with the current opaque revision, applies the edit to a candidate document, runs `ProfileStore.validate`, persists the candidate once, and returns the new revision. For `configuration.applyBatch`, it applies **all** nested edits to one candidate and either commits all of them or none. A stale revision is an error. Reads and edits use the same in-memory authoritative document; profile editing does not itself activate a profile.

The service enforces document-specific rules that the protocol layer cannot know: the actual `globalProfileID` cannot be deleted or retargeted, only six existing groups are selectable, and bundle identifiers remain unique. The protocol layer rejects malformed complete bindings using the core decoder and `ProfileStore.validate`; the app also validates the entire resulting document. If the app or device is unavailable, the bridge returns an explicit error or an `availability` field. It never invents a device value. `device.querySetting` is asynchronous: the immediate result is `pending`; read a later observation through `kdcustom_get_device_settings`. Battery values are vendor display buckets, sleep units remain unconfirmed, and brightness readback is currently unverified after two live BLE timeouts.

No unrestricted key injection, immediate macro playback, shell execution, arbitrary USB/Bluetooth command, firmware operation, public network listener, or independent profile-file writer is exposed.

## Tools and callback operations

All mutating configuration tools require a nonempty opaque string `expectedRevision`. Obtain it from `kdcustom_list_profiles` or another app response before editing. Tool results contain both JSON text and `structuredContent`; app-side errors appear as `isError: true`.

| Tool | Callback operation | Arguments | Purpose |
| --- | --- | --- | --- |
| `kdcustom_list_profiles` | `profiles.list` | none | Profiles and current revision |
| `kdcustom_get_profile` | `profiles.get` | `profileId` | Complete profile |
| `kdcustom_create_profile` | `profiles.create` | `expectedRevision`, `name`, `appBundleIdentifier`, optional `profileId` | Create app profile |
| `kdcustom_update_profile` | `profiles.update` | `expectedRevision`, `profileId`, `name` and/or `appBundleIdentifier` | Update app profile |
| `kdcustom_delete_profile` | `profiles.delete` | `expectedRevision`, `profileId` | Delete non-global app profile |
| `kdcustom_list_groups` | `groups.list` | `profileId` | Six groups and selected group |
| `kdcustom_rename_group` | `groups.rename` | `expectedRevision`, `profileId`, `groupId`, `name` | Rename group |
| `kdcustom_select_group` | `groups.select` | `expectedRevision`, `profileId`, `groupId` | Select profile's group |
| `kdcustom_get_binding` | `bindings.get` | `profileId`, `groupId`, `controlId` | Complete binding |
| `kdcustom_set_binding` | `bindings.set` | `expectedRevision`, `profileId`, `groupId`, `binding` | Replace complete binding |
| `kdcustom_apply_batch` | `configuration.applyBatch` | `expectedRevision`, `operations` | Atomic group of 1–32 edits |
| `kdcustom_get_runtime` | `runtime.get` | none | Observed foreground app, effective profile, device and permissions |
| `kdcustom_get_device_settings` | `device.getSettings` | none | Cached observed settings and availability |
| `kdcustom_query_device_setting` | `device.querySetting` | `setting`: `battery`, `brightness`, `sleep`, or `rotation` | Query one allowlisted device setting |

`binding` is the complete JSON form of `ControlBinding`, including `controlID`, `label`, `pressActions`, `releaseActions`, `buttonBehavior`, `dialBehavior`, `repeatIntervalMilliseconds`, `heldModifiers`, `idleTimeoutMilliseconds`, `macroRetriggerPolicy`, `queueLimit`, and `macroRepeatCount`. Each action step uses the core `ActionStep` tagged shape (`kind`, `repeatCount`, and the fields required by that kind). For example:

```json
{
  "controlID": "dial1CCW",
  "label": "Zoom out",
  "pressActions": [
    {"kind": "keyTap", "repeatCount": 1, "keyCode": 27,
     "modifiers": {"rawValue": 1048576}}
  ],
  "releaseActions": [],
  "buttonBehavior": "pressRelease",
  "dialBehavior": "perStep",
  "repeatIntervalMilliseconds": 100,
  "heldModifiers": {"rawValue": 0},
  "idleTimeoutMilliseconds": 250,
  "macroRetriggerPolicy": "queue",
  "queueLimit": 8,
  "macroRepeatCount": 1
}
```

The batch tool accepts only these nested tool names: `kdcustom_create_profile`, `kdcustom_update_profile`, `kdcustom_delete_profile`, `kdcustom_rename_group`, `kdcustom_select_group`, and `kdcustom_set_binding`. Nested `arguments` omit `expectedRevision`; the outer revision applies to the whole transaction:

```json
{
  "expectedRevision": "opaque-current-revision",
  "operations": [
    {"name": "kdcustom_rename_group",
     "arguments": {"profileId": "global", "groupId": "group-1", "name": "Editing"}},
    {"name": "kdcustom_select_group",
     "arguments": {"profileId": "global", "groupId": "group-1"}}
  ]
}
```

## Local verification

```sh
bash scripts/test.sh
```

The focused suites include MCP protocol parsing, private bridge behavior, configuration atomicity and rollback, and the shared core models. A passing suite does not replace an installed-app permission or live-device check.
