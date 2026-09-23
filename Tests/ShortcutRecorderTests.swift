import AppKit
import Foundation

@main
enum ShortcutRecorderTests {
    private static func check(_ actual: KeyModifiers, _ expected: KeyModifiers, _ name: String) {
        guard actual == expected else {
            fatalError("\(name): expected \(expected.rawValue), got \(actual.rawValue)")
        }
    }

    static func main() {
        // AppKit marks navigation keys with .function even when Fn is untouched.
        check(ShortcutRecordedModifiers.from([.command, .function], physicalFunctionDown: false),
              .command, "Command + Up does not accidentally record Fn")
        check(ShortcutRecordedModifiers.from([.command, .function], physicalFunctionDown: true),
              [.command, .function], "a physically held Fn remains recordable")
        check(ShortcutRecordedModifiers.from([.option, .control, .shift], physicalFunctionDown: false),
              [.option, .control, .shift], "ordinary modifiers are unchanged")
        check(ShortcutRecordedModifiers.from([], physicalFunctionDown: true),
              .function, "hardware Fn remains explicit if the event omits its flag")
        print("Shortcut recorder modifier tests passed")
    }
}
