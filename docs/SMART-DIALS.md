# Smart dials and focused-input rules

Each dial direction can independently use **Smart** mode in its Input behavior picker. Existing bindings retain their prior mode until explicitly changed.

## Numeric adjustment

The initial Smart preset is a step of 1, Option for 0.01, and Shift for 10. Direction, magnitude, exact held modifier combination, and optional shortcut are configurable independently for every direction, group, and profile. Extra unassigned modifier combinations do nothing; Option+Shift does not accidentally match either Option or Shift.

Automatic detection accepts accessibility controls that advertise numeric capabilities, plus narrowly recognized numeric field labels in Rive and Adobe apps (for example Width, Height, X, Opacity). A hint only permits checking the value: the default accessibility method also requires a working writable numeric AX value. **Numeric field · explicit override** allows a strictly numeric text field without an app-specific label hint. The keyboard method below instead requires readable numeric text. Neither makes an inaccessible canvas field editable.

Values are read only on a Smart detent, adjusted with decimal arithmetic, and sent back through the control's accessibility value. Advertised bounds are respected. This default accessibility method uses no clipboard, select-all, typed replacement, or expression evaluation. Passive focus observation and agent tools expose metadata only; numeric contents are never logged or returned to MCP. Unsupported fields do nothing by default.

A **Shortcut override** bypasses numeric editing and sends the recorded shortcut. The physically held rule-selector modifier is omitted from those synthetic events, while the actual keyboard key remains held. Each modifier rule can choose **Inherit**, **Shortcut**, or **Numeric**. Inherit keeps the base shortcut when one exists; Numeric explicitly uses its own numeric step even when the default is a shortcut. This permits native arrow output for whole units and typed numeric replacement for hundredths on the same dial. Existing rules retain their prior inheritance behavior. **Fallback actions** are optional and run the normal macro only when the numeric path is unsupported before attempting a write; they retain physically held modifiers. An uncertain write never triggers a second fallback action.

The observed foreground application, focus identity, revision and active profile constrain pending work. Focus, profile, configuration, pause, session, permission and connection changes revoke queued numeric work. AX requests are time bounded and queued work is bounded. As with any accessibility write, an app can change state immediately after the final check; no cross-process write is a transaction with the target app.

## Custom numeric text input

For fields that expose readable numeric text but ignore accessibility writes, choose **Numeric**, **Numeric field override**, and **Write value using → Custom numeric · keyboard text**. Set the base step or a modifier rule to `0.01` for hundredths. Each direction keeps its own step and sign.

This opt-in method reads the focused field, calculates with decimal arithmetic, sends Command+A through the production keyboard path, then types the calculated value. It checks that focus and the original value remain unchanged before typing, and reads back the new field text. It does not use or replace the clipboard. The **Apply changes** picker has three modes:

- **Leave input open · apply manually** types the result and leaves commitment to the user.
- **Native arrow · keep editing** types a compensated draft and immediately posts one unmodified arrow. Set **Native arrow step** to the amount one plain arrow changes this field (1 in the tested Rive field). For a target of 0.02, a draft of 1.02 followed by Down produces 0.02 through the native arrow handler. Known bounds may require the opposite arrow; if neither draft fits, no text is sent. The final field text and focus are checked. A mismatch stops further work; there is no automatic retry.
- **Enter · restore focus** sends Enter and requests focus back on the exact same accessible field. This failed in the tested Rive field because editing closed and focus restoration was not confirmed. Use the native-arrow method there.

All modes stop on changed window/app, physical editing input, timeout, or failed focus/value readback. Fast detents may be batched into one update. A physical button trial confirmed native-arrow commitment while keeping the Rive input open; integrated dial acceptance is recorded separately in VERIFICATION.md. Native arrow magnitude is target-specific, and field text readback alone is not proof of document commit.

Fast turns are accumulated into decimal batches, with direction reversals kept in order. Up to 256 pending detents are accepted; overflow is reported. Physical typing/clicking, focus or application changes, configuration changes, pause and device/session boundaries cancel pending edits. A failed or unconfirmed write stops the queue. This method has no macro fallback and refuses inaccessible, secure, non-text, expression and unit-bearing values.

The existing accessibility method remains the default for old and new profiles. No existing shortcut binding is converted automatically. This custom keyboard path still requires readable focused text; it does not make a generic inaccessible canvas editable.

## Focus rules

The **Intelligent dials** sheet lets each application profile define ordered metadata rules. The first enabled matching rule supplies the four dial bindings from a chosen group. The profile's default group and all physical button assignments remain unchanged. Rules can match kind, role, exact control identifier and case-insensitive label substring; all specified conditions must match. New rules are disabled until configured.

**Learn last focused input** uses the last observed metadata from the selected app. Its timestamp is historical: returning to KDCustom suspends output, and a stale observation is never a live routing target. Custom canvas widgets may expose no useful metadata. In that case, use the application's default bindings or a custom Smart shortcut.

## App-specific limits

Official shortcut documentation does not establish a universal 0.01 increment:

- [Rive shortcuts](https://rive.app/docs/editor/keyboard-shortcuts) documents object nudging, not a universal numeric-field fine increment.
- [Illustrator numeric values](https://helpx.adobe.com/uk/illustrator/desktop/get-started/learn-the-basics/enter-values-in-panels-and-dialog-boxes.html) describes arrow increments, Shift for larger changes, and fractional changes with Command, with exceptions by field.
- [After Effects layer properties](https://helpx.adobe.com/after-effects/desktop/work-with-layers/layer-properties/layer-properties.html) documents 1, 10 with Shift, and 0.1 with Command for underlined property values.
- [Photoshop panels](https://helpx.adobe.com/sg/photoshop/using/panels-menus.html) describes field-dependent behavior rather than one numeric shortcut contract.

KDCustom's exact 0.01 numeric path requires a readable supported numeric value and either a working AX setter or the explicitly configured keyboard method. A shortcut's effect is controlled by the target app. On build 19, the user confirmed physical outer-dial 0.01 steps in both directions in a selected Rive numeric field, with the final value retained after Enter. The user also confirmed Option at 0.001 and Shift at 0.1 in both directions with retained values. These establish the selected field and configured steps; other fields, fast turns, restart persistence of accessibility metadata, and individual Adobe targets still need hands-on checks. Synthetic test fields do not establish those applications' behavior.
