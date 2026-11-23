import SwiftUI
import SceneKit
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - State

enum DriveKind: String, CaseIterable, Identifiable {
    case cruise = "Cruise", thrust = "Thrust", warp = "Warp"
    var id: String { rawValue }
}

@Observable
final class StarMapState {
    var selected: String? = "Proxima Centauri"
    var from = "Sol" { didSet { resetTrip() } }
    var to: String? = "Proxima Centauri" { didSet { resetTrip() } }
    var drive: DriveKind = .thrust { didSet { resetTrip() } }
    /// Cruise speed, as −log₁₀(1 − β) so the slider spends its length near c.
    var cruiseNines = 1.0 { didSet { resetTrip() } }
    /// Thrust in g, as log₁₀ g.
    var thrustLog = 0.0 { didSet { resetTrip() } }
    /// Warp speed as log₁₀ (multiple of c).
    var warpLog = 1.0 { didSet { resetTrip() } }
    var showGuides = true
    var showLabels = true
    /// Bumped to move the camera to the selected star.
    private(set) var focusRequest = 0

    private(set) var isPlaying = false
    /// Earth years since departure during the trip animation.
    @ObservationIgnored private(set) var tripTime = 0.0
    @ObservationIgnored private var lastTick: Date?
    /// The trip has started (a ship is drawn), even if paused.
    private(set) var tripStarted = false
    /// Real seconds a trip animation takes.
    static let playSeconds = 15.0

    /// Set by ContentView: switch to the Sandbox with this preset.
    @ObservationIgnored var openSandbox: ((String) -> Void)?

    var beta: Double { 1 - pow(10, -cruiseNines) }
    var thrustG: Double { pow(10, thrustLog) }
    var warpMultiple: Double { pow(10, warpLog) }

    var shipDrive: ShipDrive {
        switch drive {
        case .cruise: .cruise(beta: beta)
        case .thrust: .thrust(g: thrustG)
        case .warp: .warp(multiple: warpMultiple)
        }
    }

    var fromStar: NearbyStar? { StarCatalog.star(from) }
    var toStar: NearbyStar? { to.flatMap(StarCatalog.star) }
    var selectedStar: NearbyStar? { selected.flatMap(StarCatalog.star) }

    var trip: StarTrip? {
        guard let a = fromStar, let b = toStar, a.name != b.name else { return nil }
        return StarTrip(distance: simd_distance(a.galactic, b.galactic), drive: shipDrive)
    }

    func select(_ name: String?, focus: Bool = false) {
        selected = name
        if focus { focusRequest += 1 }
    }

    func travelTo(_ name: String) { to = name }
    func departFrom(_ name: String) { from = name }

    func setPlaying(_ on: Bool) {
        if on, let t = trip, tripTime >= t.earthYears { tripTime = 0 }
        isPlaying = on && trip != nil
        if isPlaying { tripStarted = true }
        lastTick = nil
    }

    func resetTrip() {
        isPlaying = false
        tripStarted = false
        tripTime = 0
        lastTick = nil
    }

    /// Advance the trip animation; called once per frame from the TimelineView.
    func tick(_ now: Date) {
        defer { lastTick = isPlaying ? now : nil }
        guard isPlaying, let last = lastTick, let t = trip else { return }
        let dt = min(now.timeIntervalSince(last), 0.1)
        tripTime += dt * t.earthYears / Self.playSeconds
        if tripTime >= t.earthYears {
            tripTime = t.earthYears
            DispatchQueue.main.async { self.isPlaying = false }
        }
    }
}

// MARK: - Scene view

struct StarMapSceneView: View {
    let state: StarMapState
    var cardBottomInset: CGFloat = 0

    var body: some View {
        TimelineView(.animation(paused: !state.isPlaying)) { ctx in
            let _ = state.tick(ctx.date)
            ZStack {
                Color.black
                StarMapContainer(state: state, frame: ctx.date, selected: state.selected, from: state.from, to: state.to,
                                 tripStarted: state.tripStarted, focus: state.focusRequest,
                                 guides: state.showGuides, labels: state.showLabels)
                    .ignoresSafeArea()
            }
            .overlay(alignment: .top) {
                if state.tripStarted, let trip = state.trip {
                    let s = trip.state(earthTime: state.tripTime)
                    VStack(spacing: 2) {
                        Text("Earth \(TravelFormat.years(state.tripTime)) · Ship \(TravelFormat.years(s.shipTime))")
                        Text(String(format: "%.2f of %.2f ly · %@", s.x, trip.distance, TravelFormat.speed(s.speed)))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                StarInfoCard(state: state)
                    .padding(12)
                    .padding(.bottom, cardBottomInset)
            }
        }
    }
}

struct StarMapContainer: PlatformViewRepresentable {
    let state: StarMapState
    let frame: Date
    let selected: String?
    let from: String
    let to: String?
    let tripStarted: Bool
    let focus: Int
    let guides: Bool
    let labels: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(iOS)
    func makeUIView(context: Context) -> ZoomableSCNView { make(context) }
    func updateUIView(_ view: ZoomableSCNView, context: Context) { update(view, context) }
    #else
    func makeNSView(context: Context) -> ZoomableSCNView { make(context) }
    func updateNSView(_ view: ZoomableSCNView, context: Context) { update(view, context) }
    #endif

    private func make(_ context: Context) -> ZoomableSCNView {
        let c = context.coordinator
        let view = ZoomableSCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.scene = c.scene.scene
        view.pointOfView = c.scene.cameraNode
        view.cameraNode = c.scene.cameraNode
        view.minDistance = 1.5
        view.maxDistance = 400
        c.scene.cameraNode.position = SCNVector3(0, 40, 70)
        view.syncOrbit()
        #if os(iOS)
        view.setupGestures()
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        #else
        view.setupOrbitGesture()
        let tap = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        #endif
        c.labels = LabelOverlay(view: view)
        c.view = view
        view.onUserCameraMove = { [weak c] in c?.refresh() }
        return view
    }

    private func update(_ view: ZoomableSCNView, _ context: Context) {
        let c = context.coordinator
        c.state = state
        let scene = c.scene
        if c.focus != focus {
            c.focus = focus
            if let name = selected, let p = scene.position(of: name) {
                view.orbitCenter = p
                view.applyOrbit()
            }
        }
        scene.showGuides = guides
        scene.select(selected)
        var fraction: Double?
        if tripStarted, let trip = state.trip {
            fraction = trip.state(earthTime: state.tripTime).x / trip.distance
        }
        scene.showTrip(from: from, to: to, fraction: fraction)
        c.refresh()
    }

    final class Coordinator: NSObject {
        let scene = StarMapScene()
        var labels: LabelOverlay?
        weak var view: ZoomableSCNView?
        weak var state: StarMapState?
        var focus = 0

        func refresh() {
            guard let view, let state else { return }
            scene.updateForCamera()
            guard state.showLabels else { labels?.layout([]); return }
            var always: Set<String> = [state.from]
            if let s = state.selected { always.insert(s) }
            if let t = state.to { always.insert(t) }
            labels?.layout(scene.labelAnchors(center: view.orbitCenter, cameraDistance: view.orbitDistance,
                                              always: always, guidesOn: state.showGuides))
        }

        #if os(iOS)
        @objc func tapped(_ g: UITapGestureRecognizer) { pick(g.location(in: g.view)) }
        #else
        @objc func tapped(_ g: NSClickGestureRecognizer) { pick(g.location(in: g.view)) }
        #endif

        private func pick(_ point: CGPoint) {
            guard let view, let state else { return }
            if let star = scene.pick(in: view, at: point) { state.select(star.name) }
        }
    }
}

// MARK: - Info card

struct StarInfoCard: View {
    let state: StarMapState

    var body: some View {
        CollapsibleInfoCard {
            Text("STAR MAP · WITHIN 50 LIGHT-YEARS")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if let s = state.selectedStar {
                Text(s.displayName).font(.headline)
            } else {
                Text("Tap a star").font(.headline)
            }
        } details: {
            if let s = state.selectedStar {
                row("Type", s.sp.isEmpty ? s.kindDescription : "\(s.kindDescription) (\(s.sp))")
                if !s.isSun {
                    row("Distance", String(format: "%.2f ly", s.d))
                    if let here = state.fromStar, !here.isSun, here.name != s.name {
                        row("From \(here.displayName)", String(format: "%.2f ly", simd_distance(here.galactic, s.galactic)))
                    }
                }
                if let l = s.lum { row("Brightness", l >= 0.01 ? String(format: "%.3g × Sun", l) : String(format: "%.2g × Sun", l)) }
                row("Temperature", "≈ \(Int((s.temperature / 100).rounded()) * 100) K")
                if s.cat != s.name && !s.isSun { row("Catalogue", s.cat) }
                let companions = StarCatalog.all.filter { $0.group == s.group && $0.name != s.name }
                if !companions.isEmpty { row("Companions", companions.map(\.displayName).joined(separator: ", ")) }
                if let p = s.planets {
                    Text("Planets: \(p)").font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if s.name != state.to && s.name != state.from {
                        Button("Travel here") { state.travelTo(s.name) }
                    }
                    if s.name != state.from { Button("Start here") { state.departFrom(s.name) } }
                    Button("Centre") { state.select(s.name, focus: true) }
                    if let id = s.sandbox, !s.isSun {
                        Button("Open in Sandbox") { state.openSandbox?(id) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("Positions: HYG database v4.1 (CC BY-SA 4.0)")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 340, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(.caption2, design: .monospaced))
    }
}

// MARK: - Controls

struct StarMapPlayButtons: View {
    let state: StarMapState

    var body: some View {
        HStack {
            Button {
                state.setPlaying(!state.isPlaying)
            } label: {
                Label(state.isPlaying ? "Pause trip" : "Fly", systemImage: state.isPlaying ? "pause.fill" : "airplane")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.trip == nil)
            Button {
                state.resetTrip()
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

struct StarMapControls: View {
    @Bindable var state: StarMapState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Go to", selection: Binding(get: { state.selected ?? "" }, set: { state.select($0, focus: true) })) {
                if let s = state.selectedStar, !StarCatalog.notable.contains(s) { Text(s.displayName).tag(s.name) }
                ForEach(StarCatalog.notable) { Text(label($0)).tag($0.name) }
            }

            Text("TRIP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("From", selection: $state.from) {
                if let s = state.fromStar, !StarCatalog.notable.contains(s) { Text(s.displayName).tag(s.name) }
                ForEach(StarCatalog.notable) { Text(label($0)).tag($0.name) }
            }
            Picker("To", selection: Binding(get: { state.to ?? "" }, set: { state.to = $0 })) {
                if let s = state.toStar, !StarCatalog.notable.contains(s) { Text(s.displayName).tag(s.name) }
                ForEach(StarCatalog.notable) { Text(label($0)).tag($0.name) }
            }
            Picker("Drive", selection: $state.drive) {
                ForEach(DriveKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch state.drive {
            case .cruise:
                slider("Speed", TravelFormat.speed(state.beta), $state.cruiseNines, 0.0044...4)
            case .thrust:
                slider("Acceleration", String(format: state.thrustG < 1 ? "%.2f g" : "%.1f g", state.thrustG), $state.thrustLog, -1...1)
            case .warp:
                slider("Warp speed", TravelFormat.speed(state.warpMultiple), $state.warpLog, 0...3)
            }

            if let trip = state.trip { TripSummary(trip: trip, state: state) }

            Toggle("Distance rings and drop lines", isOn: $state.showGuides)
            Toggle("Star names", isOn: $state.showLabels)
        }
    }

    private func label(_ s: NearbyStar) -> String {
        s.isSun ? "Sun" : String(format: "%@ · %.1f ly", s.displayName, s.d)
    }

    private func slider(_ title: String, _ value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range)
        }
    }
}

struct TripSummary: View {
    let trip: StarTrip
    let state: StarMapState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Distance", String(format: "%.2f ly", trip.distance))
            row("Time on Earth", TravelFormat.years(trip.earthYears))
            row("Time on the ship", TravelFormat.years(trip.shipYears))
            row(state.drive == .warp ? "Bubble speed" : "Top speed", TravelFormat.speed(trip.peakSpeed))
            if trip.peakGamma > 1.0001 { row("Time dilation", String(format: "up to %.3g×", trip.peakGamma)) }
            row("Arrive (Earth calendar)", TravelFormat.arrival(after: trip.earthYears))
            Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var note: String {
        let aged = TravelFormat.years(trip.shipYears), home = TravelFormat.years(trip.earthYears)
        switch state.drive {
        case .cruise:
            let accel = TravelFormat.years(StarTrip.shipTimeToReach(state.beta))
            return "You'd age \(aged) while \(home) pass at home. Speeding up and slowing down are left out: reaching this speed at 1 g takes \(accel) of ship time each way."
        case .thrust:
            return "Accelerate to the midpoint, flip, and slow down, feeling a steady \(String(format: "%.2g", state.thrustG)) g. Special relativity: you'd age \(aged) while \(home) pass at home. Light itself would take \(TravelFormat.years(trip.distance))."
        case .warp:
            return "Speculative. An Alcubierre warp bubble carries the ship in free fall, so its clock keeps pace with Earth's: no time dilation. It needs negative energy, which no known physics provides, and any faster-than-light trip lets some observers see you arrive before you left. Light would take \(TravelFormat.years(trip.distance))."
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}
