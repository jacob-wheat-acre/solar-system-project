import SwiftUI
import SceneKit
import simd

// Sandbox mode UI, shared by the iOS and macOS ContentViews. Unlike the other modes the
// sandbox keeps its own clock in simulated years: invented systems have no calendar,
// and the physics is integrated step by step, so it can't jump to an arbitrary date.

// MARK: - State

@Observable
final class SandboxState {
    /// View settings (scale, speeds, camera…) for what's on screen.
    private(set) var scenario: SandboxScenario = SandboxScenarios.all[0]
    /// The system being simulated (a preset's design, or the user's own).
    private(set) var design: SandboxDesign = SandboxScenarios.all[0].design
    var scenarioID: String = SandboxScenarios.all[0].id
    var options = SandboxScenarios.all[0].options { didSet { applyOptions() } }
    var speedIndex = SandboxScenarios.all[0].defaultSpeed
    var follow = SandboxScenarios.all[0].follow
    var showGrid = true
    var showTrails = true
    var showHabitableZones = false
    /// Ray-traced accretion disks around black holes (the sandbox has no gas, so this is
    /// a picture of what a fed black hole looks like, not part of the simulation).
    var showAccretionDisk = false
    private(set) var isRunning = false
    /// Bumped when the simulation is rebuilt and the view should refit, so the scene is rebuilt too.
    private(set) var generation = 0
    /// Bumped (asynchronously) when bodies merge or collapse, so pickers refresh.
    private(set) var bodiesVersion = 0

    // Editing
    private(set) var isEditing = false
    var selectedBodyID: Int? { didSet { if let id = selectedBodyID { follow = id } } }
    /// Bumped on every design edit (the scene redraws planned orbits).
    private(set) var designVersion = 0
    private(set) var saved: [SandboxDesign] = SandboxDesignStore.load()
    /// The design as it was when editing began, for Discard.
    @ObservationIgnored private var designBeforeEditing: SandboxDesign?

    @ObservationIgnored private(set) var sim: SandboxSimulation
    @ObservationIgnored private(set) var runningSlow = false
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var lastBodySignature = ""

    // Fling mode: drag in the scene to throw a body into the running system.
    var flingMode = false { didSet { if !flingMode { cancelFling() } } }
    var flingKind: FlingKind = .planet
    /// Speed readout while dragging.
    private(set) var flingReadout: String?
    @ObservationIgnored private(set) var flingDrag: FlingDrag?
    @ObservationIgnored private var flingCount = 0

    init() {
        let s = SandboxScenarios.all[0]
        sim = SandboxState.makeSim(s.bodies, tracker: s.tracker, options: s.options)
    }

    private static func makeSim(_ bodies: [SandboxBody], tracker: (body: Int, primary: Int)?,
                                options: SandboxOptions) -> SandboxSimulation {
        let sim = SandboxSimulation(bodies: bodies, options: options,
                                    tracker: tracker.map { PrecessionTracker(body: $0.body, primary: $0.primary) })
        sim.rtol = 1e-10
        return sim
    }

    var speed: SandboxSpeed { scenario.speeds[min(speedIndex, scenario.speeds.count - 1)] }
    var warnings: [SandboxWarning] { SandboxAnalysis.check(design) }
    /// True when the current own design differs from its saved copy (or was never saved).
    var hasUnsavedChanges: Bool {
        guard !scenario.isPreset || isEditing else { return false }
        var d = design; d.options = options
        return saved.first { $0.id == design.id } != d
    }

    // MARK: Choosing a system

    static let newSystemTag = "new"

    func select(_ id: String) {
        if isEditing { isEditing = false }
        if id == Self.newSystemTag {
            show(.custom(.blank()))
            beginEditing()
            return
        }
        if let p = SandboxScenarios.preset(id) {
            if p.id == SandboxScenarios.blackHoleCloseUp.id { showAccretionDisk = true }
            show(p); return
        }
        if let d = saved.first(where: { SandboxScenario.customID($0.id) == id }) { show(.custom(d)); return }
        if id == SandboxScenario.customID(design.id) { show(.custom(design)) }
    }

    private func show(_ s: SandboxScenario) {
        scenario = s
        design = s.design
        scenarioID = s.id
        speedIndex = s.defaultSpeed
        follow = s.follow
        options = s.options
        reset()
    }

    /// Back to the starting state (keeps the current physics settings).
    func reset() {
        isRunning = false
        lastTick = nil
        sim = SandboxState.makeSim(design.build().bodies, tracker: isEditing ? nil : scenario.tracker, options: options)
        lastBodySignature = ""
        runningSlow = false
        flingCount = 0
        cancelFling()
        generation += 1
    }

    func setRunning(_ on: Bool) {
        isRunning = on
        lastTick = nil
    }

    // MARK: Editing

    /// Edit the starting setup. A preset is copied first ("My Our Solar System" etc.).
    func beginEditing() {
        flingMode = false
        setRunning(false)
        designBeforeEditing = design
        if scenario.isPreset {
            design.id = UUID()
            design.name = "My \(scenario.name)"
        }
        design.options = options
        isEditing = true
        selectedBodyID = design.bodies.contains { $0.id == follow } ? follow : design.bodies.first?.id
        rebuildForEdit()
    }

    func updateDesign(_ d: SandboxDesign) {
        design = d
        designVersion += 1
        rebuildForEdit()
    }

    func updateBody(_ b: DesignBody) {
        guard let k = design.bodies.firstIndex(where: { $0.id == b.id }) else { return }
        var d = design
        var nb = b
        if nb.mass != d.bodies[k].mass || nb.kind != d.bodies[k].kind { SandboxPhysicalDefaults.applyMass(&nb) }
        d.bodies[k] = nb
        updateDesign(d)
    }

    /// Add a body around `parent`, just outside its outermost satellite.
    func addBody(_ kind: SandboxBodyKind, around parent: Int?) {
        var d = design
        let id = d.nextID
        let count = d.bodies.filter { $0.kind == kind }.count + 1
        let label = switch kind {
        case .star: "Star"; case .planet: "Planet"; case .moon: "Moon"
        case .neutronStar: "Neutron star"; case .blackHole: "Black hole"
        }
        var b = SandboxPhysicalDefaults.body(kind: kind, id: id, name: "\(label) \(count)")
        b.parent = parent
        let par = parent.flatMap { d.body($0) }
        let siblings = d.children(of: parent)
        if let outer = siblings.map({ $0.a * (1 + $0.e) }).max(), outer > 0 {
            b.a = outer * 1.6
        } else if let par {
            switch par.kind {
            case .star: b.a = sqrt(SandboxPhysicalDefaults.luminosity(mass: par.mass))   // the middle of the habitable zone
            case .planet, .moon: b.a = max(par.radius * 30, 1e-4)
            case .neutronStar: b.a = 0.05
            case .blackHole: b.a = max(2000 * SandboxUnits.G * par.mass / (SandboxUnits.c * SandboxUnits.c), 0.05)
            }
        } else {
            b.a = 5
        }
        if kind == .star && par?.kind == .star { b.a = max(b.a, 20) }    // a wide companion
        b.meanAnomaly = Double((id * 137) % 360)
        d.bodies.append(b)
        updateDesign(d)
        selectedBodyID = id
    }

    /// Remove a body and everything orbiting it.
    func deleteBody(_ id: Int) {
        var d = design
        let gone = d.descendants(of: id)
        guard gone.count < d.bodies.count else { return }
        d.bodies.removeAll { gone.contains($0.id) }
        if let s = selectedBodyID, gone.contains(s) { selectedBodyID = d.bodies.first?.id }
        updateDesign(d)
    }

    /// Leave edit mode and refit the view to the new system.
    func finishEditing() {
        isEditing = false
        designBeforeEditing = nil
        let keepFollow = follow
        let s = SandboxScenario.custom(design)
        scenario = s
        scenarioID = s.id
        speedIndex = s.defaultSpeed
        follow = design.bodies.contains { $0.id == keepFollow } ? keepFollow : s.follow
        reset()
    }

    func discardEdits() {
        guard let before = designBeforeEditing else { return }
        isEditing = false
        designBeforeEditing = nil
        if scenario.isPreset, let p = SandboxScenarios.preset(scenario.id) {
            show(p)
        } else {
            show(.custom(before))
        }
    }

    func saveDesign() {
        var d = design
        d.options = options
        design = d
        if let k = saved.firstIndex(where: { $0.id == d.id }) { saved[k] = d } else { saved.append(d) }
        SandboxDesignStore.save(saved)
        if !isEditing { scenarioID = SandboxScenario.customID(d.id) }
    }

    func deleteSavedDesign() {
        saved.removeAll { $0.id == design.id }
        SandboxDesignStore.save(saved)
        isEditing = false
        show(SandboxScenarios.all[0])
    }

    func rename(_ name: String) {
        var d = design; d.name = name; design = d
    }

    /// Rebuild the simulation at t = 0 from the design, paused, without refitting the view.
    private func rebuildForEdit() {
        isRunning = false
        lastTick = nil
        sim = SandboxState.makeSim(design.build().bodies, tracker: nil, options: options)
        lastBodySignature = ""
        runningSlow = false
        bodiesVersion += 1
    }

    private func applyOptions() {
        guard sim.options != options else { return }
        sim.options = options
        // The precession meter measures the current physics; start it over.
        if let t = scenario.tracker, !isEditing { sim.tracker = PrecessionTracker(body: t.body, primary: t.primary) }
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

    // MARK: Fling

    /// A drag started at `p` (sim coordinates, AU). The throw is set up relative to the
    /// body that controls motion there, so it rides along with it while the sim runs.
    func flingBegan(at p: SIMD3<Double>) {
        guard flingMode, !isEditing, let j = sim.dominantBody(at: p) else { return }
        let c = sim.bodies[j]
        let offset = p - c.position
        let d = simd_length(offset)
        guard d > max(sim.effectiveRadius(c) * 1.5, 1e-12) else { return }   // not from inside a body
        flingDrag = FlingDrag(dominantID: c.id, dominantName: c.name, startOffset: offset, endOffset: offset, distance: d)
        flingReadout = "Drag out to set speed · to the \(c.name)'s distance = circular orbit"
    }

    func flingMoved(to p: SIMD3<Double>) {
        guard var f = flingDrag, let j = sim.bodies.firstIndex(where: { $0.id == f.dominantID }) else { return }
        let c = sim.bodies[j]
        f.endOffset = p - c.position
        f.ratio = simd_length(f.endOffset - f.startOffset) / f.distance
        let moved = f.predictedFor.map { simd_length(f.endOffset - $0) >= 0.01 * f.distance } ?? true
        if moved && f.ratio > 0.02 {
            // Long enough to show a whole bound orbit (vis-viva: 1/a = (2 − ratio²)/d), or 1.5
            // circular periods for an escape.
            let m = c.mass + flingKind.mass
            let a = f.ratio * f.ratio < 1.96 ? f.distance / (2 - f.ratio * f.ratio) : f.distance
            let periods = f.ratio * f.ratio < 1.96 ? 1.05 : 1.5
            f.path = sim.predictPath(adding: flungBody(f, c), relativeTo: j, duration: periods * sqrt(a * a * a / m))
            f.predictedFor = f.endOffset
        }
        flingDrag = f
        let what = f.ratio < 0.98 ? "ellipse, falls inward" : f.ratio <= 1.02 ? "circular orbit"
                 : f.ratio < 2.0.squareRoot() ? "ellipse, swings outward" : "escapes"
        flingReadout = String(format: "%.2f× circular speed around %@ · %@", f.ratio, f.dominantName, what)
    }

    func flingEnded() {
        defer { cancelFling() }
        guard let f = flingDrag, f.ratio > 0.02, let c = sim.bodies.first(where: { $0.id == f.dominantID }) else { return }
        sim.add(flungBody(f, c))
        flingCount += 1
        bodiesVersion += 1
    }

    func cancelFling() {
        flingDrag = nil
        if flingReadout != nil { flingReadout = nil }
    }

    private func flungBody(_ f: FlingDrag, _ c: SandboxBody) -> SandboxBody {
        let drag = f.endOffset - f.startOffset
        let len = simd_length(drag)
        let vCirc = sqrt(SandboxUnits.G * (c.mass + flingKind.mass) / f.distance)
        var b = flingKind.body(id: sim.nextID, name: "Flung \(flingKind.noun) \(flingCount + 1)")
        b.position = c.position + f.startOffset
        b.velocity = c.velocity + (len > 0 ? drag / len * f.ratio * vCirc : .zero)
        return b
    }

    /// The followed body, or the heaviest one if it no longer exists (merged / swallowed).
    var followedIndex: Int? {
        sim.bodies.firstIndex { $0.id == follow } ?? sim.bodies.indices.max { sim.bodies[$0].mass < sim.bodies[$1].mass }
    }
}

// MARK: - Formatting

nonisolated enum SandboxFormat {
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

    static func mass(_ m: Double) -> String {
        if m >= 0.05 {
            if m >= 1e9 { return String(format: "%.2f billion M☉", m / 1e9) }
            if m >= 1e5 { return String(format: "%.2f million M☉", m / 1e6) }
            return String(format: "%.3g M☉", m)
        }
        if m >= SandboxUnits.jupiterMass * 0.05 { return String(format: "%.2f Jupiters", m / SandboxUnits.jupiterMass) }
        let me = m / SandboxUnits.earthMass
        return me < 0.01 ? String(format: "%.2g Earths", me) : String(format: "%.2f Earths", me)
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

    #if os(iOS)
    static let flingHint = "Drag from where it starts, the way to throw · two fingers to orbit"
    #else
    static let flingHint = "Drag from where it starts, the way to throw · right-drag or ⌥-drag to orbit"
    #endif

    var body: some View {
        TimelineView(.animation(paused: !state.isRunning)) { ctx in
            let _ = state.tick(ctx.date)
            ZStack {
                Color.black
                SandboxContainer(state: state, generation: state.generation, frame: ctx.date,
                                 fling: state.flingMode && !state.isEditing,
                                 overlay: .init(editing: state.isEditing, designVersion: state.designVersion,
                                                selected: state.isEditing ? state.selectedBodyID : nil,
                                                habitableZones: state.showHabitableZones || state.isEditing))
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
            .overlay(alignment: .top) {
                if state.flingMode && !state.isEditing {
                    Text(state.flingReadout ?? Self.flingHint)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.top, 56)
                        .padding(.horizontal, 16)
                        .allowsHitTesting(false)
                }
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
    let fling: Bool
    let overlay: SandboxScene.OverlaySettings

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
        // While paused nothing else redraws, so camera moves refresh the lens, sizes and labels.
        view.onUserCameraMove = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.cameraMoved(view)
        }
        return view
    }

    private func update(_ view: ZoomableSCNView, _ context: Context) {
        let c = context.coordinator
        let sim = state.sim
        c.state = state
        if fling != (view.flingHandler != nil) {
            view.flingHandler = fling ? { [weak view, weak c] phase, point in
                guard let view, let c else { return }
                c.fling(view, phase, point)
            } : nil
        }
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
        scene.updateOverlay(overlay, design: state.design)
        if let i = state.followedIndex { view.orbitCenter = scene.position(of: sim.bodies[i].id) }
        view.applyOrbit()
        c.showDisk = state.showAccretionDisk
        scene.updateFling(state.flingDrag, sim: sim)
        c.cameraMoved(view)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var scene: SandboxScene?
        var generation = -1
        var labels: LabelOverlay?
        var showDisk = false
        weak var state: SandboxState?

        /// A fling-mode drag: hit the orbital plane through the camera's centre, update the
        /// throw, and redraw (nothing else redraws while paused).
        func fling(_ view: ZoomableSCNView, _ phase: FlingPhase, _ point: CGPoint) {
            guard let state, let scene else { return }
            let hit = scene.simPoint(view: view, point: point, planeY: view.orbitCenter.y)
            switch phase {
            case .began: if let hit { state.flingBegan(at: hit) }
            case .changed: if let hit { state.flingMoved(to: hit) }
            case .ended:
                if let hit { state.flingMoved(to: hit) }
                state.flingEnded()
            case .cancelled: state.cancelFling()
            }
            scene.update(sim: state.sim)
            scene.updateFling(state.flingDrag, sim: state.sim)
            cameraMoved(view)
        }

        /// Everything that depends on the camera: minimum body sizes, the lens, and labels
        /// (laid out here too: with the lens technique on, SceneKit's render callbacks don't
        /// reliably fire, and the labels would freeze).
        func cameraMoved(_ view: ZoomableSCNView) {
            guard let scene else { return }
            scene.updateForCamera(distance: view.orbitDistance)
            updateLens(view, scene)
            labels?.layout(scene.labelAnchors())
        }

        /// Ray-traced black holes: the lens pass runs only while the system has one.
        private func updateLens(_ view: ZoomableSCNView, _ scene: SandboxScene) {
            guard scene.hasBlackHoles else {
                if view.technique != nil { view.technique = nil }
                scene.lensActive = false
                return
            }
            // The view keeps its own copy of a technique, so install it once and then update
            // the view's copy; comparing against our instance would reinstall it every frame.
            if view.technique == nil { view.technique = BlackHoleLens.makeTechnique() }
            guard let lens = view.technique else { scene.lensActive = false; return }
            scene.lensActive = true
            BlackHoleLens.set(lens, camera: scene.cameraNode, viewport: view.bounds.size, reverseZ: view.usesReverseZ,
                              holes: scene.lensHoles(), disk: showDisk)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
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
        out.append(("Mass", SandboxFormat.mass(b.mass)))
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

}

// MARK: - Controls

/// Play / Pause and Reset.
/// A throw being set up in fling mode. Offsets are from the dominant body (sim AU).
struct FlingDrag {
    var dominantID: Int
    var dominantName: String
    var startOffset: SIMD3<Double>
    var endOffset: SIMD3<Double>
    /// Distance from the dominant body: dragging this far gives circular-orbit speed.
    var distance: Double
    /// Speed as a multiple of circular speed (√2 escapes).
    var ratio = 0.0
    /// Predicted path, relative to the dominant body.
    var path: [SIMD3<Double>] = []
    var predictedFor: SIMD3<Double>?
}

enum FlingKind: String, CaseIterable, Identifiable {
    case planet, gasGiant, moon, star, neutronStar, blackHole
    var id: String { rawValue }

    var label: String {
        switch self {
        case .planet: "Planet (1 Earth)"
        case .gasGiant: "Gas giant (1 Jupiter)"
        case .moon: "Moon (1 Luna)"
        case .star: "Star (1 Sun)"
        case .neutronStar: "Neutron star (1.4 Suns)"
        case .blackHole: "Black hole (10 Suns)"
        }
    }

    var noun: String {
        switch self {
        case .planet: "planet"
        case .gasGiant: "giant"
        case .moon: "moon"
        case .star: "star"
        case .neutronStar: "neutron star"
        case .blackHole: "black hole"
        }
    }

    var icon: String {
        switch self {
        case .planet: "globe.americas.fill"
        case .gasGiant: "circle.circle.fill"
        case .moon: "moon.fill"
        case .star: "sun.max.fill"
        case .neutronStar: "sparkle"
        case .blackHole: "circle.dashed"
        }
    }

    var mass: Double { template(id: 0, name: "").mass }

    private func template(id: Int, name: String) -> DesignBody {
        switch self {
        case .planet: return SandboxPhysicalDefaults.body(kind: .planet, id: id, name: name)
        case .gasGiant:
            var b = SandboxPhysicalDefaults.body(kind: .planet, id: id, name: name)
            b.mass = SandboxUnits.jupiterMass
            b.color = SIMD3(0.85, 0.72, 0.55)
            SandboxPhysicalDefaults.applyMass(&b)
            return b
        case .moon: return SandboxPhysicalDefaults.body(kind: .moon, id: id, name: name)
        case .star:
            var b = SandboxPhysicalDefaults.body(kind: .star, id: id, name: name)
            b.mass = 1
            SandboxPhysicalDefaults.applyMass(&b)
            return b
        case .neutronStar: return SandboxPhysicalDefaults.body(kind: .neutronStar, id: id, name: name)
        case .blackHole: return SandboxPhysicalDefaults.body(kind: .blackHole, id: id, name: name)
        }
    }

    func body(id: Int, name: String) -> SandboxBody {
        let d = template(id: id, name: name)
        return SandboxBody(id: id, name: name, kind: d.kind, mass: d.mass, radius: d.radius,
                           position: .zero, velocity: .zero, color: d.color)
    }
}

struct SandboxPlayButtons: View {
    @Bindable var state: SandboxState

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
            .help("Back to the start (removes flung bodies)")
            if !state.isEditing {
                Button {
                    state.flingMode.toggle()
                } label: {
                    Image(systemName: "scope")
                        .font(.title3.weight(.semibold))
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(state.flingMode ? .orange : nil)
                .help("Fling mode: drag in the scene to throw a body in")
                if state.flingMode {
                    Menu {
                        Picker("Throw", selection: $state.flingKind) {
                            ForEach(FlingKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                        }
                    } label: {
                        Image(systemName: state.flingKind.icon)
                            .font(.title3.weight(.semibold))
                            .padding(.vertical, 6)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help("What to throw")
                }
            }
        }
        .controlSize(.large)
    }
}

struct SandboxControls: View {
    @Bindable var state: SandboxState
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("System", selection: Binding(get: { state.scenarioID }, set: { state.select($0) })) {
                Section("Presets") {
                    ForEach(SandboxScenarios.all) { Text($0.name).tag($0.id) }
                }
                Section("My systems") {
                    ForEach(state.saved) { Text($0.name).tag(SandboxScenario.customID($0.id)) }
                    if !state.scenario.isPreset && !state.saved.contains(where: { $0.id == state.design.id }) {
                        Text("\(state.design.name) (not saved)").tag(SandboxScenario.customID(state.design.id))
                    }
                    Text("New system…").tag(SandboxState.newSystemTag)
                }
            }
            .pickerStyle(.menu)
            if !state.scenario.blurb.isEmpty {
                Text(state.scenario.blurb).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    state.beginEditing()
                } label: {
                    Label(state.scenario.isPreset ? "Edit a copy" : "Edit", systemImage: "pencil")
                }
                if state.hasUnsavedChanges {
                    Button { state.saveDesign() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                }
                Spacer()
                if !state.scenario.isPreset && state.saved.contains(where: { $0.id == state.design.id }) {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                }
            }
            .buttonStyle(.bordered)
            .confirmationDialog("Delete \(state.design.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { state.deleteSavedDesign() }
            } message: {
                Text("This removes the saved system. It can't be undone.")
            }

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
            Toggle("Habitable zones", isOn: $state.showHabitableZones)
            if state.design.bodies.contains(where: { $0.kind == .blackHole }) {
                Toggle("Accretion disk", isOn: $state.showAccretionDisk)
                if state.showAccretionDisk {
                    Text("Glowing gas spiralling into the black hole, ray traced: its light bends over the top, and the side coming toward you is brighter. Drawn for looks; the simulation has no gas.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func cLabel(_ s: Double) -> String {
        s >= 0.1 ? String(format: "%.2f", s) : s >= 0.01 ? String(format: "%.3f", s) : String(format: "%.4f", s)
    }
}
