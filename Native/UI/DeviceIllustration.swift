import SwiftUI

/// A scaled, interactive map of the K40's physical controls. The outer and inner
/// concentric dials each expose separate clockwise and counterclockwise bindings.
struct DeviceIllustration: View {
    let selectedControl: ControlID?
    let activeControls: Set<ControlID>
    let labels: [ControlID: String]
    let groupName: String
    let onSelect: (ControlID) -> Void

    private let designSize = CGSize(width: 1000, height: 432)

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / designSize.width,
                            geometry.size.height / designSize.height)

            illustration
                .frame(width: designSize.width, height: designSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: designSize.width * scale,
                       height: designSize.height * scale,
                       alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(designSize.width / designSize.height, contentMode: .fit)
    }

    private var illustration: some View {
        ZStack(alignment: .topLeading) {
            deviceHousing

            // The cable port and recessed display keep the vector faithful to
            // the photographed hardware without representing live device state.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioTheme.canvas)
                .frame(width: 58, height: 18)
                .position(x: 371, y: 29)
                .accessibilityHidden(true)

            displayPanel
                .frame(width: 454, height: 132)
                .position(x: 637, y: 185)

            ForEach(0..<4, id: \.self) { index in
                keyButton(number: index + 1)
                    .position(x: CGFloat(467 + 113 * index), y: 86)
                keyButton(number: index + 5)
                    .position(x: CGFloat(467 + 113 * index), y: 285)
            }

            groupButton(.setPrevious, title: "PREV", symbol: "chevron.up")
                .position(x: 931, y: 106)
            groupButton(.setNext, title: "NEXT", symbol: "chevron.down")
                .position(x: 931, y: 263)

            Text("HUION")
                .font(StudioTheme.font(13, weight: .medium))
                .tracking(3.5)
                .foregroundStyle(StudioTheme.mutedText)
                .rotationEffect(.degrees(-90))
                .position(x: 918, y: 185)
                .accessibilityHidden(true)

            outerDial
                .position(x: 190, y: 185)
            innerDial
                .position(x: 190, y: 185)

            directionSelector(name: "OUTER", counterclockwise: .dial1CCW, clockwise: .dial1CW)
                .position(x: 122, y: 399)
            directionSelector(name: "INNER", counterclockwise: .dial2CCW, clockwise: .dial2CW)
                .position(x: 332, y: 399)
        }
        .frame(width: designSize.width, height: designSize.height)
    }

    private var deviceHousing: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 104, style: .continuous)
                .fill(LinearGradient(colors: [StudioTheme.hardwareTop, StudioTheme.hardwareBottom],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 104, style: .continuous)
                .strokeBorder(StudioTheme.hardwareEdge.opacity(0.72), lineWidth: 2)
            RoundedRectangle(cornerRadius: 100, style: .continuous)
                .strokeBorder(StudioTheme.canvas.opacity(0.7), lineWidth: 5)
                .padding(5)
        }
        .frame(width: 893, height: 321)
        .position(x: 540, y: 185)
        .accessibilityHidden(true)
    }

    private var displayPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(StudioTheme.display)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(StudioTheme.hardwareEdge.opacity(0.65), lineWidth: 2)

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text(groupName.isEmpty ? "UNTITLED GROUP" : groupName.uppercased())
                        .font(StudioTheme.font(12, weight: .medium))
                        .tracking(1.3)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text("K40")
                        .font(StudioTheme.font(10, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(StudioTheme.secondaryText)
                }
                Rectangle()
                    .fill(StudioTheme.secondaryText.opacity(0.25))
                    .frame(height: 1)
                displayRow(startingAt: 1)
                displayRow(startingAt: 5)
            }
            .foregroundStyle(StudioTheme.text)
            .padding(.horizontal, 19)
            .padding(.vertical, 13)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display preview, group \(groupName)")
    }

    private func displayRow(startingAt first: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(first..<(first + 4), id: \.self) { number in
                let id = keyID(number)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(number)")
                        .foregroundStyle(StudioTheme.mutedText)
                    Text(shortLabel(for: id))
                        .foregroundStyle(StudioTheme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(StudioTheme.font(11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var outerDial: some View {
        DialButton(id: .dial1CW,
                   selected: selectedControl == .dial1CW || selectedControl == .dial1CCW,
                   active: activeControls.contains(.dial1CW) || activeControls.contains(.dial1CCW),
                   accessibilityName: "Outer dial clockwise",
                   action: { onSelect(.dial1CW) }) {
            ZStack {
                Circle()
                    .fill(StudioTheme.dialMetal)
                    .overlay(Circle().strokeBorder(StudioTheme.text.opacity(0.23), lineWidth: 3))
                ForEach(0..<72, id: \.self) { tick in
                    Capsule()
                        .fill(StudioTheme.canvas.opacity(tick.isMultiple(of: 3) ? 0.43 : 0.26))
                        .frame(width: 1.5, height: 10)
                        .offset(y: -162)
                        .rotationEffect(.degrees(Double(tick) * 5))
                }
                Circle()
                    .fill(StudioTheme.hardwareBottom)
                    .frame(width: 277, height: 277)
                    .overlay(Circle().strokeBorder(StudioTheme.canvas.opacity(0.85), lineWidth: 3))
            }
            .frame(width: 348, height: 348)
        }
    }

    private var innerDial: some View {
        DialButton(id: .dial2CW,
                   selected: selectedControl == .dial2CW || selectedControl == .dial2CCW,
                   active: activeControls.contains(.dial2CW) || activeControls.contains(.dial2CCW),
                   accessibilityName: "Inner dial clockwise",
                   action: { onSelect(.dial2CW) }) {
            Circle()
                .fill(LinearGradient(colors: [StudioTheme.dialCenter, StudioTheme.canvas],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(StudioTheme.hardwareEdge.opacity(0.8), lineWidth: 3))
                .overlay {
                    VStack(spacing: 6) {
                        Text("02")
                            .font(StudioTheme.font(30, weight: .light))
                            .tracking(2)
                        Text("INNER DIAL")
                            .font(StudioTheme.font(10, weight: .medium))
                            .tracking(2.4)
                    }
                    .foregroundStyle(StudioTheme.secondaryText)
                }
                .frame(width: 248, height: 248)
        }
    }

    private func keyButton(number: Int) -> some View {
        HardwareButton(id: keyID(number),
                       title: String(format: "%02d", number),
                       subtitle: "KEY",
                       accessibilityName: "Key \(number), \(fullLabel(for: keyID(number)))",
                       selected: selectedControl == keyID(number),
                       active: activeControls.contains(keyID(number)),
                       width: 108, height: 63) {
            onSelect(keyID(number))
        }
    }

    private func groupButton(_ id: ControlID, title: String, symbol: String) -> some View {
        HardwareButton(id: id,
                       title: title,
                       subtitle: symbol,
                       accessibilityName: "\(title == "PREV" ? "Previous" : "Next") group, \(fullLabel(for: id))",
                       selected: selectedControl == id,
                       active: activeControls.contains(id),
                       width: 69, height: 79) {
            onSelect(id)
        }
    }

    private func directionSelector(name: String, counterclockwise: ControlID, clockwise: ControlID) -> some View {
        HStack(spacing: 7) {
            Text(name)
                .font(StudioTheme.font(10, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(width: 58, alignment: .leading)
            DirectionButton(id: counterclockwise, title: "↶", name: "\(name.capitalized) dial counterclockwise",
                            selected: selectedControl == counterclockwise,
                            active: activeControls.contains(counterclockwise)) {
                onSelect(counterclockwise)
            }
            DirectionButton(id: clockwise, title: "↷", name: "\(name.capitalized) dial clockwise",
                            selected: selectedControl == clockwise,
                            active: activeControls.contains(clockwise)) {
                onSelect(clockwise)
            }
        }
    }

    private func keyID(_ number: Int) -> ControlID {
        switch number {
        case 1: .key1
        case 2: .key2
        case 3: .key3
        case 4: .key4
        case 5: .key5
        case 6: .key6
        case 7: .key7
        default: .key8
        }
    }

    private func fullLabel(for id: ControlID) -> String {
        let value = labels[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unassigned" : value
    }

    private func shortLabel(for id: ControlID) -> String {
        let value = labels[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "—" : value
    }
}

private struct HardwareButton: View {
    let id: ControlID
    let title: String
    let subtitle: String
    let accessibilityName: String
    let selected: Bool
    let active: Bool
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? StudioTheme.keyPressed : hovered ? StudioTheme.keyHover : StudioTheme.keyFace)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected || focused ? StudioTheme.accent : StudioTheme.hardwareEdge,
                                      lineWidth: selected || focused ? 2 : 1)
                }
                .overlay {
                    VStack(spacing: 4) {
                        Text(title)
                            .font(StudioTheme.font(id == .setNext || id == .setPrevious ? 11 : 15,
                                                   weight: .medium))
                            .tracking(id == .setNext || id == .setPrevious ? 1.2 : 1.6)
                        if subtitle == "KEY" {
                            Text(subtitle)
                                .font(StudioTheme.font(9, weight: .medium))
                                .tracking(1.5)
                                .foregroundStyle(StudioTheme.mutedText)
                        } else {
                            Image(systemName: subtitle)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(selected || active ? StudioTheme.accent : StudioTheme.secondaryText)
                }
                .frame(width: width, height: height)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .help(accessibilityName)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(selected ? "Selected" : active ? "Pressed" : "")
    }
}

private struct DialButton<Content: View>: View {
    let id: ControlID
    let selected: Bool
    let active: Bool
    let accessibilityName: String
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            content
                .overlay {
                    Circle()
                        .strokeBorder(selected || focused ? StudioTheme.accent :
                                      hovered ? StudioTheme.secondaryText : .clear,
                                      lineWidth: selected || focused ? 3 : 2)
                }
                .overlay(alignment: .bottom) {
                    if active {
                        Circle()
                            .fill(StudioTheme.accent)
                            .frame(width: 7, height: 7)
                            .offset(y: -12)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .help(accessibilityName)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(selected ? "Selected" : active ? "Active" : "")
    }
}

private struct DirectionButton: View {
    let id: ControlID
    let title: String
    let name: String
    let selected: Bool
    let active: Bool
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(StudioTheme.font(19, weight: .medium))
                .foregroundStyle(selected || active ? StudioTheme.accent : StudioTheme.secondaryText)
                .frame(width: 44, height: 31)
                .background(selected || active ? StudioTheme.accentSoft :
                            hovered ? StudioTheme.panelRaised : StudioTheme.panel,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected || focused ? StudioTheme.accent : StudioTheme.divider,
                                      lineWidth: selected || focused ? 1.5 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .help(name)
        .accessibilityLabel(name)
        .accessibilityValue(selected ? "Selected" : active ? "Active" : "")
    }
}
