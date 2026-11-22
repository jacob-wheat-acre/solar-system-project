import SwiftUI
import SceneKit
import simd

// Sandbox mode UI, shared by the iOS and macOS ContentViews. Unlike the other modes the
// sandbox keeps its own clock in simulated years: invented systems have no calendar,
// and the physics is integrated step by step, so it can't jump to an arbitrary date.

// MARK: - State

@Observable
final class SandboxState {
    private(set) var scenario: SandboxScenario = SandboxScenarios.all[0]
    var scenarioID: String = SandboxScenarios.all[0].id
    var options = SandboxScenarios.all[0].options { didSet { applyOptions() } }
    var speedIndex = SandboxScenarios.all[0].defaultSpeed
    var follow = SandboxScenarios.all[0].follow
    var showGrid = true
    var showTrails = true
    private(set) var isRunning = false
    /// Bumped when the simulation is rebuilt, so the scene is rebuilt too.
    private(set) var generation = 0
    /// Bumped (asynchronously) when bodies merge or collapse, so pickers refresh.
    private(set) var bodiesVersion = 0

    @ObservationIgnored private(set) var sim: SandboxSimulation
    @ObservationIgnored private(set) var runningSlow = false
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var lastBodySignature = ""

    init() {
        sim = SandboxState.makeSim(SandboxScenarios.all[0], options: SandboxScenarios.all[0].options)
    }

    private static func makeSim(_ s: SandboxScenario, options: SandboxOptions) -> SandboxSimulation {
        let sim = SandboxSimulation(bodies: s.bodies, options: options,
                                    tracker: s.tracker.map { PrecessionTracker(body: $0.body, primary: $0.primary) })
        sim.rtol = 1e-10
        return sim
    }

    var speed: SandboxSpeed { scenario.speeds[min(speedIndex, scenario.speeds.count - 1)] }

    func select(_ id: String) {
        let s = SandboxScenarios.scenario(id)
        scenario = s
        scenarioID = id
        speedIndex = s.defaultSpeed
        follow = s.follow
        options = s.options       // rebuilds via applyOptions → reset below anyway
        reset()
    }

    /// Back to the scenario's starting state (keeps the current physics settings).
    func reset() {
        isRunning = false
        lastTick = nil
        sim = SandboxState.makeSim(scenario, options: options)
        lastBodySignature = ""
        runningSlow = false
        generation += 1
    }

    func setRunning(_ on: Bool) {
        isRunning = on
        lastTick = nil
    }

    private func applyOptions() {
        guard sim.options != options else { return }
        sim.options = options
        // The precession meter measures the current physics; start it over.
        if let t = scenario.tracker { sim.tracker = PrecessionTracker(body: t.body, primary: t.primary) }
    }

    /// Advance the simulation to `now`. Called once per frame from the TimelineView; touches
    /// only unobserved state so it's safe during a view update.
    func tick(_ now: Date) {
        defer { lastTick = isRunning ? now : nil }
        guard isRunning, let last = lastTick else { return }
        let dt = min(now.timeIntervalSince(last), 0.1)
        runningSlow = !sim.advance(by: dt * speed.yearsPerSecond, budget: 0.008)
        let sig = sim.bodies.map { "\($0.id)\($0.kind)" }.joined()
        if sig != lastBodySignature {
            let first = lastBodySignature.isEmpty
            lastBodySignature = sig
            if !first { DispatchQueue.main.async { self.bodiesVersion += 1 } }
        }
    }

    /// The followed body, or the heaviest one if it no longer exists (merged / swallowed).
    var followedIndex: Int? {
        sim.bodies.firstIndex { $0.id == follow } ?? sim.bodies.indices.max { sim.bodies[$0].mass < sim.bodies[$1].mass }
    }
}

// MARK: - Formatting

enum SandboxFormat {
    static func elapsed(_ years: Double) -> String {
        let hours = years * 365.25 * 24
        if hours < 48 { return String(format: "%.1f hours", hours) }
        if years < 2 { return String(format: "%.1f days", hours / 24) }
        if years < 10_000 { return String(format: "%.2f years", years) }
        return "\(Int(years).formatted()) years"
    }

    static func angle(_ rad: Double) -> String {
        let deg = abs(rad) * 180 / .pi, sign = rad < 0 ? "−" : ""
        if deg >= 1 { return sign + String(format: "%.2f°", deg) }
        if deg * 60 >= 1 { return sign + String(format: "%.1f′", deg * 60) }
        return sign + String(format: "%.2f″", deg * 3600)
    }

    static func distance(_ au: Double) -> String {
        let km = au * SandboxUnits.auKm
        if au >= 0.1 { return String(format: "%.2f AU", au) }
        if km >= 1e6 { return String(format: "%.2f million km", km / 1e6) }
        return "\(Int(km).formatted()) km"
    }

    static func duration(seconds s: Double) -> String {
        let s = abs(s)
        if s < 1e-3 { return String(format: "%.1f µs", s * 1e6) }
        if s < 1 { return String(format: "%.1f ms", s * 1e3) }
        if s < 120 { return String(format: "%.1f s", s) }
        if s < 7200 { return String(format: "%.1f min", s / 60) }
        if s < 2 * 86_400 { return String(format: "%.1f h", s / 3600) }
        return String(format: "%.1f days", s / 86_400)
    }
}

// MARK: - Scene view

struct SandboxSceneView: View {
    let state: SandboxState
    var cardBottomInset: CGFloat = 0

    var body: some View {
        TimelineView(.animation(paused: !state.isRunning)) { ctx in
            let _ = state.tick(ctx.date)
            ZStack {
                Color.black
                SandboxContainer(state: state, generation: state.generation, frame: ctx.date)
                    .ignoresSafeArea()
            }
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    Text("T + \(SandboxFormat.elapsed(state.sim.time))")
                    if state.runningSlow && state.isRunning {
                        Text("· sim running slow").foregroundStyle(.orange)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.top, 10)
            }
            .overlay(alignment: .bottomLeading) {
                SandboxInfoCard(state: state)
                    .padding(12)
                    .padding(.bottom, cardBottomInset)
            }
        }
    }
}

// MARK: - SceneKit container

struct SandboxContainer: PlatformViewRepresentable {
    let state: SandboxState
    let generation: Int
    let frame: Date

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(iOS)
    func makeUIView(context: Context) -> ZoomableSCNView { make(context) }
    func updateUIView(_ view: ZoomableSCNView, context: Context) { update(view, context) }
    #else
    func makeNSView(context: Context) -> ZoomableSCNView { make(context) }
    func updateNSView(_ view: ZoomableSCNView, context: Context) { update(view, context) }
    #endif

    private func make(_ context: Context) -> ZoomableSCNView {
        let view = ZoomableSCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = false
        #if os(iOS)
        view.setupGestures()
        #else
        view.setupOrbitGesture()
        #endif
        context.coordinator.labels = LabelOverlay(view: view)
        view.delegate = context.coordinator
        return view
    }

    private func update(_ view: ZoomableSCNView, _ context: Context) {
        let c = context.coordinator
        let sim = state.sim
        if c.generation != generation || c.scene == nil {
            let scenario = state.scenario
            let scene = SandboxScene(scenario: scenario)
            c.scene = scene
            c.generation = generation
            view.scene = scene.scene
            view.pointOfView = scene.cameraNode
            view.cameraNode = scene.cameraNode
            view.minDistance = scenario.cameraDistance * 1e-5
            view.maxDistance = scenario.cameraDistance * 25
            scene.update(sim: sim)
            let center = scene.position(of: scenario.follow)
            let d = SCNFloat(scenario.cameraDistance)
            view.orbitCenter = center
            scene.cameraNode.position = SCNVector3(center.x, center.y + d * 0.5, center.z + d * 0.87)
            view.syncOrbit()
        }
        guard let scene = c.scene else { return }
        scene.showGrid = state.showGrid
        scene.showTrails = state.showTrails
        scene.update(sim: sim)
        if let i = state.followedIndex { view.orbitCenter = scene.position(of: sim.bodies[i].id) }
        view.applyOrbit()
        scene.updateForCamera(distance: view.orbitDistance)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var scene: SandboxScene?
        var generation = -1
        var labels: LabelOverlay?

        func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scene = self.scene else { return }
                self.labels?.layout(scene.labelAnchors())
            }
        }
    }
}

// MARK: - Info card

struct SandboxInfoCard: View {
    let state: SandboxState

    var body: some View {
        let sim = state.sim
        CollapsibleInfoCard {
            Text(state.scenario.name.uppercased())
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if let i = state.followedIndex { Text(sim.bodies[i].name).font(.headline) }
            if let event = sim.log.last {
                Text("\(event.message) · T + \(SandboxFormat.elapsed(event.time))")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } details: {
            if let i = state.followedIndex {
                ForEach(rows(sim, i), id: \.0) { row in
                    HStack {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.1).monospacedDigit()
                    }
                    .font(.system(.caption2, design: .monospaced))
                }
            }
            if let t = sim.tracker, let note = state.scenario.precessionNote {
                Divider()
                Text("ORBIT PRECESSION").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if let m = t.measuredPerOrbit, t.period > 0 {
                    stat("Measured", "\(SandboxFormat.angle(m)) per orbit")
                    stat("", perTime(m / t.period))
                    if state.options.relativity {
                        stat("Relativity alone", "\(SandboxFormat.angle(t.theoryPerOrbit)) per orbit")
                    }
                } else {
                    Text("Measuring… (\(t.passages) of 2 closest approaches)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
            if !state.options.relativity && !state.options.gravitationalWaves && sim.log.isEmpty {
                Text("Energy drift \(String(format: "%.1e", sim.energyDrift))")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v).monospacedDigit()
        }
        .font(.system(.caption2, design: .monospaced))
    }

    private func perTime(_ radPerYear: Double) -> String {
        if abs(radPerYear) * 180 / .pi >= 1 { return "\(SandboxFormat.angle(radPerYear)) per year" }
        return "\(SandboxFormat.angle(radPerYear * 100)) per century"
    }

    private func rows(_ sim: SandboxSimulation, _ i: Int) -> [(String, String)] {
        let b = sim.bodies[i]
        var out: [(String, String)] = []
        out.append(("Mass", mass(b.mass)))
        if b.kind == .blackHole {
            out.append(("Event horizon", SandboxFormat.distance(sim.schwarzschildRadius(b.mass))))
        }
        if let p = sim.primary(of: i) {
            let d = simd_length(b.position - sim.bodies[p].position)
            let v = simd_length(b.velocity - sim.bodies[p].velocity)
            out.append(("From \(sim.bodies[p].name)", SandboxFormat.distance(d)))
            out.append(("Speed", String(format: "%.1f km/s", SandboxUnits.kmPerSecond(v))))
            if sim.bodies[p].kind == .blackHole {
                out.append(("Distance / r_s", String(format: "%.0f", d / sim.schwarzschildRadius(sim.bodies[p].mass))))
            }
        }
        // Clock: how much slower than a clock far away at rest.
        let lag = 1 - sim.clockRate(i)
        if lag < 1e-3 {
            out.append(("Clock runs slow", "\(SandboxFormat.duration(seconds: lag * SandboxUnits.yearSeconds))/yr"))
        } else {
            out.append(("Clock rate", String(format: "%.4f×", 1 - lag)))
        }
        let lost = (sim.time - b.properTime) * SandboxUnits.yearSeconds
        out.append(("Clock behind by", SandboxFormat.duration(seconds: lost)))
        return out
    }

    private func mass(_ m: Double) -> String {
        if m >= 0.05 { return m >= 1e5 ? "\(String(format: "%.2f", m / 1e6)) million M☉" : String(format: "%.3g M☉", m) }
        if m >= SandboxUnits.jupiterMass * 0.05 { return String(format: "%.2f Jupiters", m / SandboxUnits.jupiterMass) }
        return String(format: "%.2f Earths", m / SandboxUnits.earthMass)
    }
}

// MARK: - Controls

/// Play / Pause and Reset.
struct SandboxPlayButtons: View {
    let state: SandboxState

    var body: some View {
        HStack {
            Button {
                state.setRunning(!state.isRunning)
            } label: {
                Label(state.isRunning ? "Pause" : "Play", systemImage: state.isRunning ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Button {
                state.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3.weight(.semibold))
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }
}

struct SandboxControls: View {
    @Bindable var state: SandboxState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("System", selection: Binding(get: { state.scenarioID }, set: { state.select($0) })) {
                ForEach(SandboxScenarios.all) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            Text(state.scenario.blurb).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Speed").font(.subheadline).foregroundStyle(.secondary)
                Picker("Speed", selection: $state.speedIndex) {
                    ForEach(Array(state.scenario.speeds.enumerated()), id: \.offset) { i, s in Text(s.label).tag(i) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Picker("Follow", selection: $state.follow) {
                let _ = state.bodiesVersion
                ForEach(state.sim.bodies) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed of light").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(state.options.cScale >= 0.995 ? "real" : "c × \(cLabel(state.options.cScale))")
                        .font(.system(.caption, design: .monospaced))
                }
                Slider(value: Binding(get: { log10(state.options.cScale) },
                                      set: { state.options.cScale = pow(10, $0) }),
                       in: -3...0)
                Text("Slower light makes relativity stronger: orbits precess faster, clocks slow more, and compact objects grow bigger event horizons.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Relativity (1PN)", isOn: $state.options.relativity)
            Toggle("Gravitational waves", isOn: $state.options.gravitationalWaves)
            Toggle("Gravity well grid", isOn: $state.showGrid)
            if state.showGrid {
                Text("Sheet depth shows gravitational potential: a picture of how deep each well is, not literal curved spacetime.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Trails", isOn: $state.showTrails)
        }
    }

    private func cLabel(_ s: Double) -> String {
        s >= 0.1 ? String(format: "%.2f", s) : s >= 0.01 ? String(format: "%.3f", s) : String(format: "%.4f", s)
    }
}
