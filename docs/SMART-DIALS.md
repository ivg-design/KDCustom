# Smart dials and focused-input rules

Each dial direction can independently use **Smart** mode in its Input behavior picker. Existing bindings retain their prior mode until explicitly changed.

## Numeric adjustment

The initial Smart preset is a step of 1, Option for 0.01, and Shift for 10. Direction, magnitude, exact held modifier combination, and optional shortcut are configurable independently for every direction, group, and profile. Extra unassigned modifier combinations do nothing; Option+Shift does not accidentally match either Option or Shift.

Automatic detection accepts accessibility controls that advertise numeric capabilities, plus narrowly recognized numeric field labels in Rive and Adobe apps (for example Width, Height, X, Opacity). A hint only permits checking the value: the control must actually expose a writable numeric accessibility value. **Numeric field · explicit override** allows a strictly numeric text field without an app-specific label hint. It is useful for a targeted custom input rule, not a guarantee that an inaccessible canvas field becomes writable.

Values are read only on a Smart detent, adjusted with decimal arithmetic, and sent back through the control's accessibility value. Advertised bounds are respected. No clipboard, select-all, typed replacement, or expression evaluation is used. Passive focus observation and agent tools expose metadata only; numeric contents are never logged or returned to MCP. Unsupported fields do nothing by default.

A **Shortcut override** bypasses numeric editing and sends the recorded shortcut. The physically held rule-selector modifier is omitted from those synthetic events, while the actual keyboard key remains held. A rule without its own shortcut inherits the base shortcut when one exists. Otherwise it uses the rule's numeric step. **Fallback actions** are optional and run the normal macro only when the numeric path is unsupported before attempting a write; they retain physically held modifiers. An uncertain write never triggers a second fallback action.

The observed foreground application, focus identity, revision and active profile constrain pending work. Focus, profile, configuration, pause, session, permission and connection changes revoke queued numeric work. AX requests are time bounded and queued work is bounded. As with any accessibility write, an app can change state immediately after the final check; no cross-process write is a transaction with the target app.

## Focus rules

The **Intelligent dials** sheet lets each application profile define ordered metadata rules. The first enabled matching rule supplies the four dial bindings from a chosen group. The profile's default group and all physical button assignments remain unchanged. Rules can match kind, role, exact control identifier and case-insensitive label substring; all specified conditions must match. New rules are disabled until configured.

**Learn last focused input** uses the last observed metadata from the selected app. Its timestamp is historical: returning to KDCustom suspends output, and a stale observation is never a live routing target. Custom canvas widgets may expose no useful metadata. In that case, use the application's default bindings or a custom Smart shortcut.

## App-specific limits

Official shortcut documentation does not establish a universal 0.01 increment:

- [Rive shortcuts](https://rive.app/docs/editor/keyboard-shortcuts) documents object nudging, not a universal numeric-field fine increment.
- [Illustrator numeric values](https://helpx.adobe.com/uk/illustrator/desktop/get-started/learn-the-basics/enter-values-in-panels-and-dialog-boxes.html) describes arrow increments, Shift for larger changes, and fractional changes with Command, with exceptions by field.
- [After Effects layer properties](https://helpx.adobe.com/after-effects/desktop/work-with-layers/layer-properties/layer-properties.html) documents 1, 10 with Shift, and 0.1 with Command for underlined property values.
- [Photoshop panels](https://helpx.adobe.com/sg/photoshop/using/panels-menus.html) describes field-dependent behavior rather than one numeric shortcut contract.

KDCustom's exact 0.01 numeric path therefore requires a writable supported AX value. A shortcut's effect is controlled by the target app. Production acceptance in Rive and individual Adobe fields remains a separate hands-on check; synthetic test fields do not establish those applications' behavior.
