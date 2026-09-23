import AppKit
import SwiftUI

/// Canonical positions follow the supplied photograph with the dials on the left.
/// Firmware dial 1 is inner; dial 2 is outer. A rotation changes presentation,
/// never the ControlID assigned to a physical control.
struct DeviceIllustration: View {
    let selectedControl: ControlID?
    let activeControls: Set<ControlID>
    let labels: [ControlID: String]
    let groupName: String
    let groupNumber: Int
    let orientationDegrees: Int
    let batteryPercent: Int?
    let connection: String?
    let showDirectionControls: Bool
    let onSelect: (ControlID) -> Void

    @State private var hoveredControl: ControlID?
    private let canvasSize = CGSize(width: 1000, height: 476)
    private static let deviceImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "kd-custom", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    init(selectedControl: ControlID?, activeControls: Set<ControlID>, labels: [ControlID: String],
         groupName: String, groupNumber: Int = 1, orientationDegrees: Int = 180,
         batteryPercent: Int? = nil, showDirectionControls: Bool = true, connection: String? = nil,
         onSelect: @escaping (ControlID) -> Void) {
        self.selectedControl = selectedControl
        self.activeControls = activeControls
        self.labels = labels
        self.groupName = groupName
        self.groupNumber = groupNumber
        self.orientationDegrees = orientationDegrees
        self.batteryPercent = batteryPercent
        self.connection = connection
        self.showDirectionControls = showDirectionControls
        self.onSelect = onSelect
    }

    private var rotation: Int {
        let observed = [0, 90, 180, 270].contains(orientationDegrees) ? orientationDegrees : 180
        // The device's orientation setting advances opposite the view's
        // rotation. Firmware 270 therefore places the dials below the OLED.
        return (180 - observed + 360) % 360
    }

    private var orientedSize: CGSize {
        rotation.isMultiple(of: 180) ? canvasSize : CGSize(width: canvasSize.height, height: canvasSize.width)
    }

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let dimensions = orientedSize
                let scale = min(geometry.size.width / dimensions.width,
                                geometry.size.height / dimensions.height)
                deviceCanvas
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .rotationEffect(.degrees(Double(rotation)))
                    .frame(width: dimensions.width, height: dimensions.height)
                    .scaleEffect(scale)
                    .frame(width: dimensions.width * scale, height: dimensions.height * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showDirectionControls { ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) {
                    directions("INNER · 1", cw: .dial1CW, ccw: .dial1CCW)
                    directions("OUTER · 2", cw: .dial2CW, ccw: .dial2CCW)
                }
                VStack(alignment: .leading, spacing: 8) {
                    directions("INNER · 1", cw: .dial1CW, ccw: .dial1CCW)
                    directions("OUTER · 2", cw: .dial2CW, ccw: .dial2CCW)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var deviceCanvas: some View {
        ZStack(alignment: .topLeading) {
            if let photo = Self.deviceImage {
                // The photo's shiny knurl has translucent white pixels. A rim-only
                // silver substrate restores its intended appearance on dark UI.
                DialAnnulus(outerInset: 2, innerInset: 40)
                    .fill(Color(red: 0.92, green: 0.92, blue: 0.90), style: FillStyle(eoFill: true))
                    .frame(width: 378, height: 378).position(x: 203, y: 238)
                Image(nsImage: photo).resizable().interpolation(.high)
                    .frame(width: 476, height: 1000)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 1000, height: 476)
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 100).fill(StudioTheme.hardwareBottom)
                    .frame(width: 930, height: 380).position(x: 500, y: 238)
            }

            screen.frame(width: 378, height: 136).position(x: 622, y: 238)
            // Face bounds follow the eight photographed seams after rotating
            // the 1190 × 2501 source into this 1000 × 476 canvas.
            physicalKey(.key1, title: "1", kind: .topLeft, width: 119, height: 68).position(x: 415, y: 109)
            physicalKey(.key2, title: "2", kind: .middle, width: 117, height: 68).position(x: 535, y: 109)
            physicalKey(.key3, title: "3", kind: .middle, width: 117, height: 68).position(x: 654, y: 109)
            physicalKey(.key4, title: "4", kind: .topRight, width: 119, height: 68).position(x: 773, y: 109)
            physicalKey(.key5, title: "5", kind: .bottomLeft, width: 119, height: 68).position(x: 415, y: 370)
            physicalKey(.key6, title: "6", kind: .middle, width: 117, height: 68).position(x: 535, y: 370)
            physicalKey(.key7, title: "7", kind: .middle, width: 117, height: 68).position(x: 654, y: 370)
            physicalKey(.key8, title: "8", kind: .bottomRight, width: 119, height: 68).position(x: 773, y: 370)

            outerDial.frame(width: 378, height: 378).position(x: 203, y: 238)
            innerDial.frame(width: 285, height: 285).position(x: 203, y: 238)
            physicalKey(.setPrevious, title: "PREV", kind: .previous, width: 140, height: 160)
                .position(x: 897, y: 158)
            physicalKey(.setNext, title: "NEXT", kind: .next, width: 140, height: 160)
                .position(x: 897, y: 318)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private var screen: some View {
        let portrait = !rotation.isMultiple(of: 180)
        return ZStack {
            StudioTheme.display
            screenContents(portrait: portrait)
                .frame(width: portrait ? 136 : 378, height: portrait ? 378 : 136)
                // The photograph and OLED glass rotate with the hardware. Only
                // rendered glyphs counter-rotate to remain readable on screen.
                .rotationEffect(.degrees(Double(-rotation)))
                .frame(width: 378, height: 136)
        }
        .frame(width: 378, height: 136)
        .accessibilityLabel("Display preview, group \(groupNumber), \(groupName)")
    }

    private var screenOrder: [ControlID] {
        switch rotation {
        case 90: return [.key5, .key1, .key6, .key2, .key7, .key3, .key8, .key4]
        case 180: return [.key8, .key7, .key6, .key5, .key4, .key3, .key2, .key1]
        case 270: return [.key4, .key8, .key3, .key7, .key2, .key6, .key1, .key5]
        default: return [.key1, .key2, .key3, .key4, .key5, .key6, .key7, .key8]
        }
    }

    private func screenContents(portrait: Bool) -> some View {
        let columns = portrait ? 2 : 4
        let rows = portrait ? 4 : 2
        let order = screenOrder
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().strokeBorder(StudioTheme.displaySecondaryText, lineWidth: 1.3)
                    .overlay(Text(String((1...6).contains(groupNumber) ? groupNumber : 1))
                        .font(StudioTheme.font(12, weight: .medium))
                        .foregroundStyle(StudioTheme.displayText))
                    .frame(width: 21, height: 21)
                Spacer(minLength: 2)
                if let connection, !connection.isEmpty, connection != "—" {
                    Image(systemName: connection.uppercased() == "USB" ? "cable.connector" :
                            "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text(connection.uppercased() == "BLUETOOTH" ? "BT" : connection.uppercased())
                        .font(StudioTheme.font(8, weight: .medium))
                        .foregroundStyle(StudioTheme.displaySecondaryText)
                        .lineLimit(1)
                }
                if let batteryPercent, (0...100).contains(batteryPercent) {
                    Image(systemName: batterySymbol(for: batteryPercent))
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 22)

            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: portrait ? 8 : 10) {
                    ForEach(0..<columns, id: \.self) { column in
                        let id = order[row * columns + column]
                        Text(labels[id].flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                            .font(StudioTheme.font(12, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(selectedControl == id ? StudioTheme.accent : StudioTheme.displayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, portrait ? 10 : 14)
        .padding(.top, portrait ? 7 : 8)
        .padding(.bottom, portrait ? 11 : 14)
    }

    private func batterySymbol(for percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }

    private func physicalKey(_ id: ControlID, title: String, kind: PhysicalKeyShape.Kind,
                             width: CGFloat, height: CGFloat) -> some View {
        let shape = PhysicalKeyShape(kind: kind)
        let emphasized = selectedControl == id || hoveredControl == id
        return Button { onSelect(id) } label: {
            shape.fill(activeControls.contains(id) ? StudioTheme.accent.opacity(0.20) : .clear)
                .overlay(shape.stroke(emphasized ? StudioTheme.accent : .clear,
                                      lineWidth: selectedControl == id ? 2.2 : 1.5))
                .overlay(Text(title).font(StudioTheme.font(id == .setPrevious || id == .setNext ? 14 : 15, weight: .medium))
                    .rotationEffect(.degrees(Double(-rotation)))
                    .foregroundStyle(selectedControl == id ? StudioTheme.accent : .white.opacity(0.82)))
                .contentShape(shape)
                .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .onHover { hoveredControl = $0 ? id : nil }
        .help("\(title): \(labels[id] ?? "Unassigned")")
        .accessibilityLabel("\(title), \(labels[id] ?? "Unassigned")")
    }

    private var outerDial: some View {
        let shape = DialAnnulus(outerInset: 4, innerInset: 48)
        let selected = selectedControl == .dial2CW || selectedControl == .dial2CCW
        let active = activeControls.contains(.dial2CW) || activeControls.contains(.dial2CCW)
        return Button { onSelect(.dial2CW) } label: {
            shape.fill(selected || active ? StudioTheme.accent.opacity(active ? 0.35 : 0.20) : .clear, style: FillStyle(eoFill: true))
                .overlay(Circle().inset(by: 3).strokeBorder(selected || hoveredControl == .dial2CW ? StudioTheme.accent : .clear,
                                      lineWidth: selected ? 5 : 2))
                .overlay(alignment: .top) {
                    if selected {
                        Text("OUTER · 2").font(StudioTheme.font(13, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(StudioTheme.accent, in: Capsule()).foregroundStyle(StudioTheme.canvas)
                            .rotationEffect(.degrees(Double(-rotation))).offset(y: -4)
                    }
                }
                .contentShape(shape, eoFill: true)
        }
        .buttonStyle(.plain)
        .onHover { hoveredControl = $0 ? .dial2CW : nil }
        .accessibilityLabel("Outer dial, clockwise by default; use direction selectors")
    }

    private var innerDial: some View {
        let selected = selectedControl == .dial1CW || selectedControl == .dial1CCW
        let active = activeControls.contains(.dial1CW) || activeControls.contains(.dial1CCW)
        return Button { onSelect(.dial1CW) } label: {
            Circle().fill(selected || active ? StudioTheme.accent.opacity(active ? 0.30 : 0.16) : .clear)
                .overlay(Circle().strokeBorder(selected || hoveredControl == .dial1CW ? StudioTheme.accent : .clear,
                                               lineWidth: selected ? 4 : 1.5))
                .overlay {
                    if selected {
                        Text("INNER · 1").font(StudioTheme.font(17, weight: .bold))
                            .foregroundStyle(StudioTheme.accent).rotationEffect(.degrees(Double(-rotation)))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredControl = $0 ? .dial1CW : nil }
        .accessibilityLabel("Inner dial, clockwise by default; use direction selectors")
    }

    private func directions(_ name: String, cw: ControlID, ccw: ControlID) -> some View {
        let fallback = name.hasPrefix("INNER") ? "Inner" : "Outer"
        return VStack(alignment: .leading, spacing: 6) {
            Text(name).font(StudioTheme.font(11, weight: .medium)).tracking(1.4)
                .foregroundStyle(StudioTheme.secondaryText)
            HStack(spacing: 7) {
                ForEach([ccw, cw], id: \.self) { id in
                    let assignment = labels[id].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                    Button { onSelect(id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: id == cw ? "arrow.clockwise" : "arrow.counterclockwise")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 17, height: 17)
                                Text(id == cw ? "CW" : "CCW")
                                    .font(StudioTheme.font(13, weight: .medium))
                            }
                            Text(assignment)
                                .font(StudioTheme.font(11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(selectedControl == id ? StudioTheme.accent : StudioTheme.secondaryText)
                        }
                        .frame(width: 103, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(selectedControl == id ? StudioTheme.accentSoft : StudioTheme.panelRaised,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(selectedControl == id ? StudioTheme.accent : StudioTheme.text)
                    }
                    .buttonStyle(.plain)
                    .help("\(name) \(id == cw ? "clockwise" : "counterclockwise"): \(assignment)")
                    .accessibilityLabel("\(name) \(id == cw ? "clockwise" : "counterclockwise"), \(assignment)")
                }
            }
        }
    }
}

/// Two nested ellipses use even-odd fill and hit-testing. The outer dial never
/// claims the inner dial's center.
private struct DialAnnulus: Shape {
    let outerInset: CGFloat
    let innerInset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: outerInset, dy: outerInset))
        path.addEllipse(in: rect.insetBy(dx: innerInset, dy: innerInset))
        return path
    }
}

/// These paths trace the photographed face seams, rather than framing the
/// buttons with generic rectangles. The small inset keeps amber inside the
/// black gaps between neighboring keys.
private struct PhysicalKeyShape: Shape {
    enum Kind { case topLeft, middle, topRight, bottomLeft, bottomRight, previous, next }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        switch kind {
        case .middle:
            path.move(to: point(0.06, 0.025))
            path.addLine(to: point(0.94, 0.025))
            path.addQuadCurve(to: point(0.985, 0.10), control: point(0.985, 0.025))
            path.addLine(to: point(0.985, 0.90))
            path.addQuadCurve(to: point(0.94, 0.975), control: point(0.985, 0.975))
            path.addLine(to: point(0.06, 0.975))
            path.addQuadCurve(to: point(0.015, 0.90), control: point(0.015, 0.975))
            path.addLine(to: point(0.015, 0.10))
            path.addQuadCurve(to: point(0.06, 0.025), control: point(0.015, 0.025))
            path.closeSubpath()
        case .topLeft:
            path.move(to: point(0.105, 0.025))
            path.addLine(to: point(0.985, 0.025))
            path.addLine(to: point(0.985, 0.975))
            path.addLine(to: point(0.315, 0.975))
            path.addQuadCurve(to: point(0.26, 0.90), control: point(0.28, 0.975))
            path.addLine(to: point(0.025, 0.38))
            path.addQuadCurve(to: point(0.105, 0.025), control: point(-0.015, 0.12))
            path.closeSubpath()
        case .topRight:
            path.move(to: point(0.015, 0.025))
            path.addLine(to: point(0.875, 0.025))
            path.addQuadCurve(to: point(0.985, 0.16), control: point(0.985, 0.025))
            path.addLine(to: point(0.985, 0.975))
            path.addLine(to: point(0.015, 0.975))
            path.closeSubpath()
        case .bottomLeft:
            path.move(to: point(0.315, 0.025))
            path.addLine(to: point(0.985, 0.025))
            path.addLine(to: point(0.985, 0.975))
            path.addLine(to: point(0.105, 0.975))
            path.addQuadCurve(to: point(0.025, 0.62), control: point(-0.015, 0.88))
            path.addLine(to: point(0.26, 0.10))
            path.addQuadCurve(to: point(0.315, 0.025), control: point(0.28, 0.025))
            path.closeSubpath()
        case .bottomRight:
            path.move(to: point(0.015, 0.025))
            path.addLine(to: point(0.985, 0.025))
            path.addLine(to: point(0.985, 0.84))
            path.addQuadCurve(to: point(0.875, 0.975), control: point(0.985, 0.975))
            path.addLine(to: point(0.015, 0.975))
            path.closeSubpath()
        case .previous:
            path.move(to: point(0.03, 0.03))
            path.addCurve(to: point(0.98, 0.97), control1: point(0.58, 0.03), control2: point(0.98, 0.53))
            path.addLine(to: point(0.58, 0.97))
            path.addCurve(to: point(0.03, 0.38), control1: point(0.55, 0.62), control2: point(0.27, 0.46))
            path.closeSubpath()
        case .next:
            path.move(to: point(0.58, 0.03))
            path.addLine(to: point(0.98, 0.03))
            // The outer edge is one continuous quarter-ring arc. The former
            // .42-to-.03 bottom chord cut across the photographed button face.
            path.addCurve(to: point(0.03, 0.97), control1: point(0.98, 0.47), control2: point(0.58, 0.97))
            path.addLine(to: point(0.03, 0.62))
            path.addCurve(to: point(0.58, 0.03), control1: point(0.27, 0.54), control2: point(0.55, 0.38))
            path.closeSubpath()
        }
        return path
    }
}
