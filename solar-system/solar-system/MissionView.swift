import SwiftUI
import SceneKit
import SpriteKit
import simd

// Missions mode UI, shared by the iOS and macOS ContentViews. The simulation clock
// stays in ContentView; these views read the date and report jumps / speed changes
// back through callbacks.

// MARK: - State

@Observable
final class MissionState {
    var selectedID: String = MissionCatalog.all[0].id
    private(set) var mission: Mission?
    private(set) var loadError: String?
    var follow: String = MissionCatalog.all[0].defaultFollow
    var speedIndex: Int = MissionCatalog.all[0].defaultSpeed

    var info: MissionInfo { MissionCatalog.info(selectedID) }

    /// Loads a mission (cached after the first time) and resets follow/speed to its defaults.
    func select(_ id: String) async {
        selectedID = id
        follow = MissionCatalog.info(id).defaultFollow
        speedIndex = MissionCatalog.info(id).defaultSpeed
        do {
            let m = try await MissionStore.shared.load(id)
            guard selectedID == id else { return }
            mission = m; loadError = nil
        } catch {
            mission = nil; loadError = error.localizedDescription
        }
    }

    /// The loaded mission if it matches the current selection.
    var current: Mission? { mission?.info.id == selectedID ? mission : nil }
}

// MARK: - Scene view

struct MissionSceneView: View {
    let state: MissionState
    let simulationDate: Date
    let secondsPerSecond: Double
    var cardBottomInset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
            if let mission = state.current {
                MissionContainer(mission: mission, date: simulationDate, follow: state.follow)
                    .ignoresSafeArea()
            } else if let err = state.loadError {
                Text(err).foregroundStyle(.secondary).padding()
            } else {
                ProgressView("Loading mission…").tint(.white).foregroundStyle(.white)
            }
        }
        .overlay(alignment: .top) {
            Text(solarDateLabel(simulationDate, secondsPerSecond: secondsPerSecond))
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.top, 10)
        }
        .overlay(alignment: .bottomLeading) {
            if let mission = state.current {
                MissionInfoCard(mission: mission, date: simulationDate, follow: state.follow)
                    .padding(12)
                    .padding(.bottom, cardBottomInset)
            }
        }
    }
}

// MARK: - SceneKit container

struct MissionContainer: PlatformViewRepresentable {
    let mission: Mission
    let date: Date
    let follow: String

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
        context.coordinator.setupLabels(in: view)
        view.delegate = context.coordinator
        return view
    }

    private func update(_ view: ZoomableSCNView, _ context: Context) {
        let c = context.coordinator
        if c.scene?.mission !== mission {
            let scene = MissionScene(mission: mission)
            c.scene = scene
            view.scene = scene.scene
            view.pointOfView = scene.cameraNode
            view.cameraNode = scene.cameraNode
            view.minDistance = scene.zoomRange.lowerBound
            view.maxDistance = scene.zoomRange.upperBound
            // Start above and behind the followed object at the mission's default distance.
            let d = mission.info.defaultDistance
            scene.update(date: date)
            let center = scene.position(of: follow, at: date)
            view.orbitCenter = center
            scene.cameraNode.position = SCNVector3(center.x, center.y + SCNFloat(d * 0.42), center.z + SCNFloat(d * 0.91))
            view.syncOrbit()
            c.lastFollow = follow
        }
        guard let scene = c.scene else { return }
        scene.setReference(mission.referenceBody(follow: follow, at: date.timeIntervalSince1970))
        scene.update(date: date)
        view.orbitCenter = scene.position(of: follow, at: date)
        view.applyOrbit()
        scene.updateForCamera(distance: view.orbitDistance)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var scene: MissionScene?
        var lastFollow = ""
        private var labels: LabelOverlay?

        func setupLabels(in view: SCNView) { labels = LabelOverlay(view: view) }

        func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scene = self.scene else { return }
                self.labels?.layout(scene.labelAnchors())
            }
        }
    }
}

// MARK: - Info card

struct MissionInfoCard: View {
    let mission: Mission
    let date: Date
    let follow: String

    var body: some View {
        let t = date.timeIntervalSince1970
        let (last, next) = mission.events(around: date)
        VStack(alignment: .leading, spacing: 6) {
            Text(mission.info.name.uppercased())
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if date < mission.start {
                Text("Launches in \(Self.duration(mission.start.timeIntervalSince(date)))").font(.headline)
            } else {
                Text(last?.title ?? "Launch").font(.headline)
                if let d = last?.detail {
                    Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("T+ \(Self.duration(t - mission.start.timeIntervalSince1970))")
                    .font(.system(.caption, design: .monospaced))
            }
            ForEach(stats(t), id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1).monospacedDigit()
                }
                .font(.system(.caption2, design: .monospaced))
            }
            if let ref = mission.referenceBody(follow: follow, at: t) {
                Text("Paths shown relative to \(ref)").font(.caption2).foregroundStyle(.tertiary)
            }
            if date >= mission.end {
                Text(mission.info.id == "voyager" || mission.info.id == "newhorizons"
                     ? "Still flying — this is where it is today." : "Mission complete.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let next {
                Text("Next: \(next.title) in \(Self.duration(next.t - t))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Distance / speed rows for each spacecraft in flight.
    private func stats(_ t: Double) -> [(String, String)] {
        var rows: [(String, String)] = []
        let k = mission.unitKm
        for craft in mission.craft where t >= craft.start && t <= max(craft.end, mission.end.timeIntervalSince1970) {
            if t > craft.end && craft.end < mission.end.timeIntervalSince1970 { continue }
            let p = craft.position(at: t), v = simd_length(craft.velocity(at: t)) * k
            let prefix = mission.craft.count > 1 ? "\(craft.label ?? craft.name) " : ""
            if mission.frame == .heliocentric {
                rows.append(("\(prefix)from Sun", String(format: "%.2f AU", simd_length(p))))
                if let earth = mission.body("Earth") {
                    rows.append(("\(prefix)from Earth", String(format: "%.2f AU", simd_length(p - earth.position(at: t)))))
                }
                rows.append(("\(prefix)speed", String(format: "%.1f km/s", v)))
            } else {
                rows.append(("\(prefix)from Earth", "\(Int(simd_length(p) * k).formatted()) km"))
                if let moon = mission.body("Moon") {
                    let d = simd_length(p - moon.position(at: t)) * k
                    rows.append(("\(prefix)from Moon", d < 1800 ? "on/near surface" : "\(Int(d).formatted()) km"))
                }
                rows.append(("\(prefix)speed", String(format: "%.2f km/s", v)))
            }
        }
        return rows
    }

    static func duration(_ s: Double) -> String {
        let s = max(0, s)
        let d = Int(s / 86_400), h = Int(s.truncatingRemainder(dividingBy: 86_400) / 3600)
        let m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        if d >= 365 { return String(format: "%.1f years", s / (365.25 * 86_400)) }
        if d > 0 { return "\(d)d \(h)h" }
        return "\(h)h \(String(format: "%02d", m))m"
    }
}

// MARK: - Play button

/// One big Play / Pause / Replay button. At the mission's end the clock stops
/// itself (ContentView clamps and pauses); the button then offers Replay from launch.
struct MissionPlayButton: View {
    let state: MissionState
    let simulationDate: Date
    @Binding var isRunning: Bool
    let onJump: (Date) -> Void

    private var atEnd: Bool { state.current.map { simulationDate >= $0.end } ?? false }

    var body: some View {
        Button {
            guard let mission = state.current else { return }
            if atEnd {
                onJump(mission.start)
                isRunning = true
            } else {
                isRunning.toggle()
            }
        } label: {
            Label(atEnd ? "Replay" : (isRunning ? "Pause" : "Play"),
                  systemImage: atEnd ? "arrow.counterclockwise" : (isRunning ? "pause.fill" : "play.fill"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(state.current == nil)
    }
}

// MARK: - Controls

struct MissionControls: View {
    let state: MissionState
    let simulationDate: Date
    @Binding var isRunning: Bool
    let onJump: (Date) -> Void
    let onSpeed: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mission", selection: Binding(get: { state.selectedID }, set: { state.selectedID = $0 })) {
                ForEach(MissionCatalog.all) { m in
                    Text(m.name).tag(m.id)
                }
            }
            .pickerStyle(.menu)
            Text(state.info.subtitle).font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Speed").font(.subheadline).foregroundStyle(.secondary)
                Picker("Speed", selection: Binding(get: { state.speedIndex }, set: { i in
                    state.speedIndex = i; onSpeed(state.info.speeds[i].secondsPerSecond)
                })) {
                    ForEach(Array(state.info.speeds.enumerated()), id: \.offset) { i, s in Text(s.label).tag(i) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let mission = state.current {
                Picker("Follow", selection: Binding(get: { state.follow }, set: { state.follow = $0 })) {
                    ForEach(mission.craft, id: \.name) { Text($0.label ?? $0.name).tag($0.name) }
                    Divider()
                    ForEach(mission.bodies, id: \.name) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Events").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(mission.events) { e in eventRow(e, mission: mission) }
                }
            }
        }
        // Runs on appear and whenever the picker changes the selection.
        .task(id: state.selectedID) { await load(state.selectedID) }
    }

    private func eventRow(_ e: MissionEvent, mission: Mission) -> some View {
        let passed = simulationDate.timeIntervalSince1970 >= e.t
        return Button {
            onJump(max(mission.start, e.date.addingTimeInterval(-mission.info.eventLead)))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(passed ? Color.accentColor : .secondary)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.callout)
                    Text(solarDateString(e.date)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Load a mission and park the clock at launch, paused, at its default speed.
    private func load(_ id: String) async {
        await state.select(id)
        guard let m = state.current else { return }
        isRunning = false
        onSpeed(m.info.speeds[m.info.defaultSpeed].secondsPerSecond)
        onJump(m.start)
    }
}
