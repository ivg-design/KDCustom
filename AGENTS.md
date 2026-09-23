# KDCustom development

- Native macOS application. Keep UI, device transport, profile state, and action execution separate.
- Application profiles and foreground-app detection are core acceptance requirements.
- Both dial directions and every physical button must be independently configurable.
- UI and MCP must share one authoritative, validated configuration service. Apply multi-edit batches atomically with revision checks.
- Do not expose an unrestricted immediate keystroke, shell, or script-execution MCP tool.
- Release synthesized holds and cancel queued actions at profile, focus, device, and session boundaries. Preserve physical keyboard state.
- Use the observed K40 command allowlist. Never probe arbitrary device commands or firmware-update paths.
- Preserve the installed Huion configuration and application. Raw captures and local profile backups belong in ignored evidence/.
- Keep the application's signing/bundle identity stable across builds so privacy grants survive.
- Build using scripts/build-native.sh and the direct Command Line Tools paths when Xcode shims are unavailable. Do not change or accept system toolchain agreements automatically.
- Verification must distinguish unit fixtures, live device reports, and human confirmation of the physical display. Do not infer one from another.
- Public commits exclude local credentials, private profile files, captured events, build output, and proprietary binary dumps.
