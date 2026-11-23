import SwiftUI
import simd

// The Sandbox system builder. It edits the *starting setup* of a system: while it's
// open the simulation sits paused at t = 0 and is rebuilt from the design on every
// change, with each body's planned orbit drawn as a dashed line.

struct SandboxEditor: View {
    @Bindable var state: SandboxState
    @State private var confirmDiscard = false

    var body: some View {
        let warnings = state.warnings
        VStack(alignment: .leading, spacing: 14) {
            header
            bodyList(warnings)
            addMenu
            if let id = state.selectedBodyID, let b = state.design.body(id) {
                Divider()
                BodyInspector(state: state, id: id, isAnchor: state.design.tree.first?.body.id == b.id)
                    .id(id)
            }
            if !warnings.isEmpty {
                Divider()
                warningList(warnings)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYSTEM BUILDER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Name", text: Binding(get: { state.design.name }, set: { state.rename($0) }))
                .textFieldStyle(.roundedBorder)
                .font(.headline)
            HStack {
                Button {
                    state.finishEditing()
                } label: {
                    Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    state.saveDesign()
                } label: {
                    Label(state.hasUnsavedChanges ? "Save" : "Saved", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(!state.hasUnsavedChanges)
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard changes", role: .destructive) { state.discardEdits() }
                }
            }
            .controlSize(.large)
            Text("Changes set up how the system starts. Press Done, then Play to see what physics does with it.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Body list

    private func bodyList(_ warnings: [SandboxWarning]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bodies").font(.subheadline).foregroundStyle(.secondary)
            ForEach(state.design.tree, id: \.body.id) { item in
                let b = item.body
                let worst = warnings.filter { $0.bodyID == b.id }.map(\.severity).max()
                Button {
                    state.selectedBodyID = b.id
                } label: {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: CGFloat(item.depth) * 16, height: 1)
                        BodySwatch(item: b)
                        Text(b.name).lineLimit(1)
                        Spacer()
                        if let worst, worst > .info {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(worst == .problem ? .red : .yellow)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 5).padding(.horizontal, 6)
                    .background(state.selectedBodyID == b.id ? Color.accentColor.opacity(0.2) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var addMenu: some View {
        let sel = state.selectedBodyID.flatMap { state.design.body($0) }
        return Menu {
            if let sel {
                Section("Orbiting \(sel.name)") {
                    if sel.kind == .planet || sel.kind == .moon {
                        Button("Moon") { state.addBody(.moon, around: sel.id) }
                    } else {
                        Button("Planet") { state.addBody(.planet, around: sel.id) }
                    }
                    Button("Star") { state.addBody(.star, around: sel.id) }
                    Button("Neutron star") { state.addBody(.neutronStar, around: sel.id) }
                    Button("Black hole") { state.addBody(.blackHole, around: sel.id) }
                }
            }
            Section("Orbiting the whole system") {
                Button("Planet") { state.addBody(.planet, around: nil) }
                Button("Star") { state.addBody(.star, around: nil) }
                Button("Black hole") { state.addBody(.blackHole, around: nil) }
            }
        } label: {
            Label("Add body", systemImage: "plus.circle.fill")
        }
    }

    // MARK: Warnings

    private func warningList(_ warnings: [SandboxWarning]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Physics check").font(.subheadline).foregroundStyle(.secondary)
            ForEach(warnings) { w in
                Button {
                    state.selectedBodyID = w.bodyID
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: w.severity == .problem ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(w.severity == .problem ? .red : .yellow)
                        Text(w.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Rules of thumb from orbital dynamics. Press Play to find out for real.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct BodySwatch: View {
    let item: DesignBody
    var body: some View {
        Circle()
            .fill(item.kind == .blackHole ? Color.black : Color(red: Double(item.color.x), green: Double(item.color.y), blue: Double(item.color.z)))
            .overlay(Circle().stroke(item.kind == .blackHole ? Color.orange : Color.white.opacity(0.25), lineWidth: 1))
            .frame(width: 11, height: 11)
    }
}

// MARK: - Inspector

private struct BodyInspector: View {
    let state: SandboxState
    let id: Int
    let isAnchor: Bool

    private var b: DesignBody { state.design.body(id) ?? state.design.bodies[0] }

    private func bind<T>(_ kp: WritableKeyPath<DesignBody, T>) -> Binding<T> {
        Binding(get: { b[keyPath: kp] }, set: { v in
            guard var x = state.design.body(id) else { return }
            x[keyPath: kp] = v
            state.updateBody(x)
        })
    }

    /// Slider on log10 of a value.
    private func logBinding(_ kp: WritableKeyPath<DesignBody, Double>, unit: Double = 1) -> Binding<Double> {
        Binding(get: { log10(max(b[keyPath: kp] / unit, 1e-30)) }, set: { v in
            guard var x = state.design.body(id) else { return }
            x[keyPath: kp] = pow(10, v) * unit
            state.updateBody(x)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodySwatch(item: b)
                TextField("Name", text: bind(\.name)).textFieldStyle(.roundedBorder)
                if b.kind == .planet || b.kind == .moon {
                    ColorPicker("Colour", selection: colorBinding).labelsHidden()
                }
            }
            Text(kindName).font(.caption).foregroundStyle(.secondary)

            massControl
            if b.kind == .star || b.kind == .planet || b.kind == .moon {
                Toggle("Size from mass", isOn: bind(\.autoRadius))
                if !b.autoRadius { radiusControl }
            }

            if isAnchor {
                Text("This is the system's anchor: everything else orbits it, directly or not.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                orbitControls
            }

            facts

            if !isAnchor {
                let moons = state.design.descendants(of: id).count - 1
                Button(role: .destructive) {
                    state.deleteBody(id)
                } label: {
                    Label(moons > 0 ? "Delete \(b.name) and \(moons) orbiting it" : "Delete \(b.name)", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var kindName: String {
        switch b.kind {
        case .star: "Star"
        case .planet: "Planet"
        case .moon: "Moon"
        case .neutronStar: "Neutron star"
        case .blackHole: "Black hole"
        }
    }

    // MARK: Mass and size

    @ViewBuilder private var massControl: some View {
        switch b.kind {
        case .star:
            labeled("Mass", SandboxFormat.mass(b.mass)) { Slider(value: logBinding(\.mass), in: -1.1...2) }
        case .planet:
            labeled("Mass", SandboxFormat.mass(b.mass)) {
                Slider(value: logBinding(\.mass, unit: SandboxUnits.earthMass), in: -2...3.6)
            }
        case .moon:
            labeled("Mass", SandboxFormat.mass(b.mass)) {
                Slider(value: logBinding(\.mass, unit: SandboxUnits.earthMass), in: -5...1)
            }
        case .neutronStar:
            labeled("Mass", SandboxFormat.mass(b.mass)) { Slider(value: bind(\.mass), in: 1...2.6) }
        case .blackHole:
            labeled("Mass", SandboxFormat.mass(b.mass)) { Slider(value: logBinding(\.mass), in: 0.5...10) }
        }
    }

    @ViewBuilder private var radiusControl: some View {
        if b.kind == .star {
            labeled("Radius", String(format: "%.2f × the Sun", b.radius / SandboxUnits.sunRadius)) {
                Slider(value: logBinding(\.radius, unit: SandboxUnits.sunRadius), in: -1...3)
            }
        } else {
            labeled("Radius", String(format: "%.2f × Earth", b.radius / SandboxUnits.earthRadius)) {
                Slider(value: logBinding(\.radius, unit: SandboxUnits.earthRadius), in: -1.5...1.3)
            }
        }
    }

    // MARK: Orbit

    private var parentOptions: [DesignBody] {
        let exclude = state.design.descendants(of: id)
        return state.design.tree.map(\.body).filter { !exclude.contains($0.id) }
    }

    /// Slider range (log10 AU) for the orbit's size, by what it orbits.
    private var distanceRange: ClosedRange<Double> {
        guard let p = b.parent, let par = state.design.body(p) else { return -2...5 }
        switch par.kind {
        case .planet, .moon: return -5 ... -0.3
        case .star, .neutronStar: return -3...3.3
        case .blackHole:
            let c = SandboxUnits.c * state.options.cScale
            let rs = 2 * SandboxUnits.G * par.mass / (c * c)
            return log10(max(rs * 2, 1e-6))...max(5, log10(rs * 2) + 2)
        }
    }

    @ViewBuilder private var orbitControls: some View {
        Picker("Orbits", selection: bind(\.parent)) {
            Text("The whole system").tag(Int?.none)
            ForEach(parentOptions) { Text($0.name).tag(Int?.some($0.id)) }
        }
        .pickerStyle(.menu)

        labeled("Distance", distanceText) { Slider(value: logBinding(\.a), in: distanceRange) }
        labeled("Eccentricity", String(format: "%.2f", b.e)) { Slider(value: bind(\.e), in: 0...0.95) }
        labeled("Tilt", String(format: "%.0f°", b.i)) { Slider(value: bind(\.i), in: 0...180) }
        labeled("Orbit orientation", String(format: "%.0f°", b.argPeri)) { Slider(value: bind(\.argPeri), in: 0...360) }
        labeled("Starting point", String(format: "%.0f°", b.meanAnomaly)) { Slider(value: bind(\.meanAnomaly), in: 0...360) }
    }

    private var distanceText: String {
        var s = SandboxFormat.distance(b.a)
        if let p = b.parent, let par = state.design.body(p), par.radius > 0, par.kind == .planet || par.kind == .moon {
            s += String(format: " (%.1f × %@'s radius)", b.a / par.radius, par.name)
        }
        return s
    }

    // MARK: Facts

    @ViewBuilder private var facts: some View {
        let d = state.design
        VStack(alignment: .leading, spacing: 3) {
            if let P = d.period(of: b) { fact("Orbit takes", SandboxFormat.elapsed(P)) }
            if b.kind == .star {
                let hz = SandboxAnalysis.habitableZone(starMass: b.mass)
                fact("Brightness", String(format: "%.3g × the Sun", SandboxPhysicalDefaults.luminosity(mass: b.mass)))
                fact("Habitable zone", "\(SandboxFormat.distance(hz.lowerBound)) – \(SandboxFormat.distance(hz.upperBound))")
            }
            if let hz = SandboxAnalysis.habitableStatus(b, in: d) { fact("Temperature", hz.rawValue) }
            let zone = SandboxAnalysis.moonZone(b, in: d)
            if let h = zone.hill, b.kind == .planet || b.kind == .moon {
                fact("Moons can orbit", "\(SandboxFormat.distance(max(zone.roche, b.radius))) – \(SandboxFormat.distance(h))")
            }
        }
        if state.selectedBodyID == id, zoneLegendVisible {
            Text("In the scene: red circle = Roche limit (closer moons are torn apart); dashed teal = where moons stay bound.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var zoneLegendVisible: Bool {
        let z = SandboxAnalysis.moonZone(b, in: state.design)
        return z.roche > 0 || z.hill != nil
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v).monospacedDigit()
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func labeled<C: View>(_ title: String, _ value: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(.caption, design: .monospaced))
            }
            control()
        }
    }

    // MARK: Colour

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(red: Double(b.color.x), green: Double(b.color.y), blue: Double(b.color.z)) },
                set: { c in
                    let r = c.resolve(in: EnvironmentValues())
                    // Resolved components are linear; the scene uses sRGB-encoded values.
                    func enc(_ x: Float) -> Float { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
                    guard var x = state.design.body(id) else { return }
                    x.color = SIMD3(enc(r.linearRed), enc(r.linearGreen), enc(r.linearBlue))
                    state.updateBody(x)
                })
    }
}
