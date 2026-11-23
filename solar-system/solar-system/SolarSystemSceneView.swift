import SwiftUI
import SceneKit
import SpriteKit
import AVFoundation

/// Stages of a fling-mode drag (see `ZoomableSCNView.flingHandler`).
enum FlingPhase { case began, changed, ended, cancelled }

#if os(iOS)
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
typealias SCNFloat = Float
typealias PlatformPanState = UIGestureRecognizer.State

class ZoomableSCNView: SCNView {
    weak var cameraNode: SCNNode?

    /// Point the camera orbits around and looks at (moved per frame by views that follow a target).
    var orbitCenter = SCNVector3Zero
    /// Called after the user orbits or zooms, for views that must refresh camera-dependent state while paused.
    var onUserCameraMove: (() -> Void)?
    /// Fling mode: while set, one-finger (left-button) drags go here instead of orbiting,
    /// and the camera orbits with a two-finger (right-button or ⌥) drag.
    var flingHandler: ((FlingPhase, CGPoint) -> Void)? { didSet { altOrbitPan?.isEnabled = flingHandler != nil } }
    private var panFlinging = false
    var minDistance: Float = 5
    var maxDistance: Float = 900

    private var azimuth:   Float = 0
    private var elevation: Float = -0.42
    private var distance:  Float = 286

    func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let two = UIPanGestureRecognizer(target: self, action: #selector(handleAltOrbit(_:)))
        two.minimumNumberOfTouches = 2
        two.maximumNumberOfTouches = 2
        two.isEnabled = flingHandler != nil
        two.delegate = self
        addGestureRecognizer(two)
        altOrbitPan = two
    }

    private var altOrbitPan: UIPanGestureRecognizer?

    @objc private func handleAltOrbit(_ r: UIPanGestureRecognizer) {
        let t = r.translation(in: self)
        r.setTranslation(.zero, in: self)
        azimuth   += Float(t.x) * 0.005
        elevation -= Float(t.y) * 0.005
        elevation  = max(-Float.pi/2 + 0.02, min(Float.pi/2 - 0.02, elevation))
        applyOrbit()
        onUserCameraMove?()
    }

    func syncOrbit() {
        guard let cam = cameraNode else { return }
        let p = cam.position
        let px = Float(p.x - orbitCenter.x), py = Float(p.y - orbitCenter.y), pz = Float(p.z - orbitCenter.z)
        let d = sqrt(px*px + py*py + pz*pz)
        distance  = max(minDistance, d)
        elevation = d > 0.001 ? asin(max(-1, min(1, py / d))) : 0
        azimuth   = atan2(px, pz)
    }

    @objc private func handleOrbit(_ r: UIPanGestureRecognizer) {
        if r.state == .began { panFlinging = flingHandler != nil }
        if panFlinging { sendFling(r.state, r.location(in: self)); return }
        let t = r.translation(in: self)
        r.setTranslation(.zero, in: self)
        azimuth   += Float(t.x) * 0.005
        elevation -= Float(t.y) * 0.005  // UIKit y-axis is inverted vs AppKit
        elevation  = max(-Float.pi/2 + 0.02, min(Float.pi/2 - 0.02, elevation))
        applyOrbit()
        onUserCameraMove?()
    }

    @objc private func handlePinch(_ r: UIPinchGestureRecognizer) {
        guard r.state == .changed else { return }
        let magnification = Double(r.scale) - 1.0
        distance = max(minDistance, min(maxDistance, Float(Double(distance) * exp(-magnification * 2.0))))
        r.scale = 1.0
        applyOrbit()
        onUserCameraMove?()
    }

    var orbitDistance: Float {
        get { distance }
        set { distance = max(minDistance, min(maxDistance, newValue)); applyOrbit() }
    }

    func applyOrbit() {
        guard let cam = cameraNode else { return }
        let x = distance * cos(elevation) * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * cos(azimuth)
        cam.position = SCNVector3(orbitCenter.x + SCNFloat(x), orbitCenter.y + SCNFloat(y), orbitCenter.z + SCNFloat(z))
        cam.look(at: orbitCenter)
    }

    private func sendFling(_ state: PlatformPanState, _ p: CGPoint) {
        switch state {
        case .began: flingHandler?(.began, p)
        case .changed: flingHandler?(.changed, p)
        case .ended: flingHandler?(.ended, p)
        default: flingHandler?(.cancelled, p)
        }
    }
}
extension ZoomableSCNView: UIGestureRecognizerDelegate {
    /// Pinch and two-finger orbit work together.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#else
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
typealias SCNFloat = CGFloat
typealias PlatformPanState = NSGestureRecognizer.State

// Custom SCNView with manual orbit (left-drag) + logarithmic zoom (scroll/pinch).
class ZoomableSCNView: SCNView {
    weak var cameraNode: SCNNode?

    /// Point the camera orbits around and looks at (moved per frame by views that follow a target).
    var orbitCenter = SCNVector3Zero
    /// Called after the user orbits or zooms, for views that must refresh camera-dependent state while paused.
    var onUserCameraMove: (() -> Void)?
    /// Fling mode: while set, one-finger (left-button) drags go here instead of orbiting,
    /// and the camera orbits with a two-finger (right-button or ⌥) drag.
    var flingHandler: ((FlingPhase, CGPoint) -> Void)? { didSet { altOrbitPan?.isEnabled = flingHandler != nil } }
    private var panFlinging = false
    var minDistance: Float = 5
    var maxDistance: Float = 900

    private var azimuth:   Float = 0
    private var elevation: Float = -0.42
    private var distance:  Float = 286

    func setupOrbitGesture() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        pan.buttonMask = 0x1
        addGestureRecognizer(pan)
        let right = NSPanGestureRecognizer(target: self, action: #selector(handleAltOrbit(_:)))
        right.buttonMask = 0x2
        right.isEnabled = flingHandler != nil
        addGestureRecognizer(right)
        altOrbitPan = right
    }

    private var altOrbitPan: NSPanGestureRecognizer?

    // SCNVector3 components are CGFloat on macOS; convert to Float for trig ops.
    func syncOrbit() {
        guard let cam = cameraNode else { return }
        let p = cam.position
        let px = Float(p.x - orbitCenter.x), py = Float(p.y - orbitCenter.y), pz = Float(p.z - orbitCenter.z)
        let d = sqrt(px*px + py*py + pz*pz)
        distance  = max(minDistance, d)
        elevation = d > 0.001 ? asin(max(-1, min(1, py / d))) : 0
        azimuth   = atan2(px, pz)
    }

    @objc private func handleOrbit(_ r: NSPanGestureRecognizer) {
        if r.state == .began { panFlinging = flingHandler != nil && !NSEvent.modifierFlags.contains(.option) }
        if panFlinging { sendFling(r.state, r.location(in: self)); return }
        orbit(by: r)
    }

    @objc private func handleAltOrbit(_ r: NSPanGestureRecognizer) { orbit(by: r) }

    private func orbit(by r: NSPanGestureRecognizer) {
        let t = r.translation(in: self)
        r.setTranslation(.zero, in: self)
        azimuth   += Float(t.x) * 0.005
        elevation += Float(t.y) * 0.005
        elevation  = max(-Float.pi/2 + 0.02, min(Float.pi/2 - 0.02, elevation))
        applyOrbit()
        onUserCameraMove?()
    }

    override func scrollWheel(with event: NSEvent) {
        let normalized: Double = event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaY) * 0.008
            : Double(event.deltaY) * 0.18
        applyZoom(factor: exp(-normalized))
    }

    override func magnify(with event: NSEvent) {
        applyZoom(factor: exp(-event.magnification * 2.0))
    }

    private func applyZoom(factor: Double) {
        guard abs(factor - 1.0) > 0.0001 else { return }
        distance = max(minDistance, min(maxDistance, Float(Double(distance) * factor)))
        applyOrbit()
        onUserCameraMove?()
    }

    var orbitDistance: Float {
        get { distance }
        set { distance = max(minDistance, min(maxDistance, newValue)); applyOrbit() }
    }

    func applyOrbit() {
        guard let cam = cameraNode else { return }
        let x = distance * cos(elevation) * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * cos(azimuth)
        cam.position = SCNVector3(orbitCenter.x + SCNFloat(x), orbitCenter.y + SCNFloat(y), orbitCenter.z + SCNFloat(z))
        cam.look(at: orbitCenter)
    }

    private func sendFling(_ state: PlatformPanState, _ p: CGPoint) {
        switch state {
        case .began: flingHandler?(.began, p)
        case .changed: flingHandler?(.changed, p)
        case .ended: flingHandler?(.ended, p)
        default: flingHandler?(.cancelled, p)
        }
    }
}
#endif

struct SolarSystemSceneView: View {
    let simulationDate: Date
    let showOrbits: Bool
    let showAxes: Bool
    let observationMode: ObservationMode
    let resonancePair: ResonancePair?
    let clearCounter: Int
    let showLabels: Bool
    let showStars: Bool
    @Binding var selectedBody: String?

    var body: some View {
        SceneKitContainer(
            simulationDate: simulationDate,
            showOrbits: showOrbits,
            showAxes: showAxes,
            observationMode: observationMode,
            resonancePair: resonancePair,
            clearCounter: clearCounter,
            showLabels: showLabels,
            showStars: showStars,
            selectedBody: $selectedBody
        )
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        #endif
    }
}

struct SceneKitContainer: PlatformViewRepresentable {
    let simulationDate: Date
    let showOrbits: Bool
    let showAxes: Bool
    let observationMode: ObservationMode
    let resonancePair: ResonancePair?
    let clearCounter: Int
    let showLabels: Bool
    let showStars: Bool
    @Binding var selectedBody: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(iOS)
    func makeUIView(context: Context) -> SCNView {
        let view = ZoomableSCNView()
        configure(view: view, context: context)
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
        update(view: uiView, context: context)
    }
    #else
    func makeNSView(context: Context) -> SCNView {
        let view = ZoomableSCNView()
        configure(view: view, context: context)
        return view
    }
    func updateNSView(_ nsView: SCNView, context: Context) {
        update(view: nsView, context: context)
    }
    #endif

    private func configure(view: SCNView, context: Context) {
        let scene = SolarSystemScene()
        view.scene = scene.scene
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.pointOfView = scene.cameraReferenceNode()

        view.allowsCameraControl = false
        if let zView = view as? ZoomableSCNView {
            zView.cameraNode = scene.cameraReferenceNode()
            zView.syncOrbit()
            #if os(iOS)
            zView.setupGestures()
            #else
            zView.setupOrbitGesture()
            #endif
        }

        context.coordinator.scene = scene
        context.coordinator.setupLabels(in: view)
        view.delegate = context.coordinator
    }

    private func update(view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.showLabels = showLabels
        coordinator.showStars  = showStars
        coordinator.scene?.setCelestialSphere(visible: showStars)
        coordinator.scene?.setToggles(showOrbits: showOrbits, showAxes: showAxes)

        let modeChanged = observationMode != coordinator.lastObservationMode
        coordinator.scene?.setObservationMode(observationMode)
        if modeChanged {
            coordinator.lastObservationMode = observationMode
            if let zView = view as? ZoomableSCNView { zView.syncOrbit() }
        }

        // Drive body selection from SwiftUI state (picker).
        coordinator.scene?.selectBody(selectedBody)

        coordinator.scene?.setResonancePair(resonancePair)
        if clearCounter != coordinator.lastClearCounter {
            coordinator.lastClearCounter = clearCounter
            coordinator.scene?.clearHistory()
        }
        coordinator.scene?.update(simulationDate: simulationDate)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var scene: SolarSystemScene?
        var lastClearCounter: Int = 0
        var lastObservationMode: ObservationMode = .fullSystem
        var showLabels: Bool = true
        var showStars: Bool  = true

        private weak var scnView: SCNView?
        private var labelNodes: [String: SKLabelNode] = [:]

        func setupLabels(in view: SCNView) {
            scnView = view
            let overlay = SKScene()
            overlay.scaleMode = .resizeFill
            overlay.backgroundColor = .clear

            func makeLabel(_ text: String, size: CGFloat, color: SKColor,
                           hAlign: SKLabelHorizontalAlignmentMode = .left) -> SKLabelNode {
                let l = SKLabelNode(text: text)
                l.fontSize = size; l.fontName = "Menlo-Regular"; l.fontColor = color
                l.horizontalAlignmentMode = hAlign; l.verticalAlignmentMode = .bottom
                l.isHidden = true; overlay.addChild(l); return l
            }

            let bodyNames: [String] = ["Sun"]
                + BodyCatalog.planetsAndDwarfs.map(\.name)
                + ["Io", "Europa", "Ganymede", "Callisto"]
                + ["Mimas", "Enceladus", "Tethys", "Dione", "Rhea", "Titan", "Iapetus"]
            for name in bodyNames {
                labelNodes[name] = makeLabel(name, size: 10,
                    color: SKColor.white.withAlphaComponent(0.65))
            }
            for entry in CelestialCatalog.zodiacConstellations {
                labelNodes[entry.name] = makeLabel(entry.name, size: 11,
                    color: SKColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 0.55),
                    hAlign: .center)
            }
            for entry in CelestialCatalog.labeledStars {
                labelNodes[entry.name] = makeLabel(entry.name, size: 8,
                    color: SKColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 0.55))
            }
            for name in ["Galactic Center ★", "☀ Galactic Motion"] {
                labelNodes[name] = makeLabel(name, size: 9,
                    color: SKColor(red: 1.0, green: 0.75, blue: 0.2, alpha: 0.75),
                    hAlign: .center)
            }
            view.overlaySKScene = overlay
        }

        func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard let view = scnView, let solarScene = self.scene else {
                for (_, l) in labelNodes { l.isHidden = true }
                return
            }
            var positions: [(name: String, node: SCNNode)] = []
            if showLabels { positions += solarScene.visibleBodyPositions() }
            if showStars  { positions += solarScene.celestialLabelPositions() }

            let visibleNames = Set(positions.map(\.name))
            let viewHeight   = view.bounds.height

            for (name, labelNode) in labelNodes {
                guard visibleNames.contains(name),
                      let entry = positions.first(where: { $0.name == name }) else {
                    labelNode.isHidden = true; continue
                }
                let projected = view.projectPoint(entry.node.worldPosition)
                guard projected.z > 0.0 && projected.z < 1.0 else {
                    labelNode.isHidden = true; continue
                }
                #if os(iOS)
                let screenY = viewHeight - CGFloat(projected.y)
                #else
                let screenY = CGFloat(projected.y)
                #endif
                labelNode.isHidden = false
                let xOff: CGFloat = labelNode.horizontalAlignmentMode == .center ? 0 : 6
                labelNode.position = CGPoint(x: CGFloat(projected.x) + xOff, y: screenY + 4)
            }
        }
    }
}

// MARK: - Body Info Card

struct BodyStats {
    let type: String
    let radiusKm: Int
    let orbitalPeriodDays: Double?
    let orbitDisplay: String?
    let distanceLY: Double?

    init(type: String, radiusKm: Int, orbitalPeriodDays: Double? = nil,
         orbitDisplay: String? = nil, distanceLY: Double? = nil) {
        self.type = type; self.radiusKm = radiusKm
        self.orbitalPeriodDays = orbitalPeriodDays
        self.orbitDisplay = orbitDisplay; self.distanceLY = distanceLY
    }

    var radiusDisplay: String {
        if radiusKm == 0 { return "—" }
        return radiusKm >= 100_000 ? "\(radiusKm / 1000)k km" : "\(radiusKm) km"
    }

    var periodDisplay: String? {
        guard let d = orbitalPeriodDays else { return nil }
        if d < 1      { return String(format: "%.2f hr",  d * 24) }
        if d < 365.25 { return String(format: "%.2f d",   d) }
        return String(format: "%.2f yr", d / 365.25)
    }

    var distanceDisplay: String? {
        guard let d = distanceLY else { return nil }
        return d < 100 ? String(format: "%.1f ly", d) : String(format: "%.0f ly", d)
    }
}

enum BodyStatsCatalog {
    static func stats(for name: String) -> BodyStats? { all[name] }

    // Returns the nearest named musical interval for the resonance pair's orbital ratio,
    // prefixed with "≈" when more than 20 cents away from just intonation.
    static func intervalName(for pair: ResonancePair) -> String? {
        guard let s1 = stats(for: pair.primary),  let p1 = s1.orbitalPeriodDays,
              let s2 = stats(for: pair.secondary), let p2 = s2.orbitalPeriodDays else { return nil }
        let ratio = p1 > p2 ? p1 / p2 : p2 / p1   // always >= 1

        let table: [(r: Double, name: String)] = [
            (1.0000, "Unison"),
            (1.0667, "Minor 2nd"),    // 16:15
            (1.1250, "Major 2nd"),    // 9:8
            (1.2000, "Minor 3rd"),    // 6:5
            (1.2500, "Major 3rd"),    // 5:4
            (1.3333, "Perfect 4th"),  // 4:3
            (1.4142, "Tritone"),      // √2
            (1.5000, "Perfect 5th"),  // 3:2
            (1.6000, "Minor 6th"),    // 8:5
            (1.6667, "Major 6th"),    // 5:3
            (1.7778, "Minor 7th"),    // 16:9
            (1.8750, "Major 7th"),    // 15:8
            (2.0000, "Octave"),       // 2:1
            (2.2500, "Major 9th"),    // 9:4
            (2.5000, "Major 10th"),   // 5:2
            (3.0000, "Octave + 5th"), // 3:1
            (4.0000, "Two Octaves"),  // 4:1
        ]
        guard let best = table.min(by: { abs(log2($0.r / ratio)) < abs(log2($1.r / ratio)) }) else { return nil }
        let cents = abs(1200.0 * log2(ratio / best.r))
        return cents < 20 ? best.name : "≈ \(best.name)"
    }

    static func mythology(for name: String) -> String? { mythologyData[name] }

    private static let mythologyData: [String: String] = [
        "Sun":
            "Sol (Roman) / Helios (Greek), the divine charioteer who drove the sun across the sky each day. " +
            "In Egypt he was Ra, king of all gods; Rome's legions swore by Sol Invictus, the Unconquered Sun. " +
            "The Sun contains 99.86% of the solar system's total mass — without it, every planet would fly off into interstellar space.",

        "Mercury":
            "Roman messenger of the gods (Greek: Hermes), patron of trade, travelers, and tricksters — fitting for the fastest wanderer in the sky. " +
            "Babylonians called it Nabu, scribe of the heavens. " +
            "Mercury orbits in just 88 days, yet rotates so slowly that a single Mercurian day lasts 176 Earth days — longer than its year.",

        "Venus":
            "Roman goddess of love and beauty (Greek: Aphrodite), the brightest object in the sky after the Moon. " +
            "Ancients thought it was two separate stars — Phosphorus at dawn, Hesperus at dusk — before realizing they were one. " +
            "Venus rotates backwards and so slowly that a Venusian day is longer than its year; the Sun rises in the west.",

        "Earth":
            "Gaia (Greek) and Terra (Roman), the primordial mother who bore the sky, seas, and Titans. " +
            "Ancients placed Earth at the center of the cosmos for millennia, with all the heavens revolving around her. " +
            "She is the only body named after a Germanic / Old English root rather than a Greco-Roman deity.",

        "Mars":
            "Roman god of war (Greek: Ares), whose blood-red color the ancients read as an omen of battle and plague. " +
            "Babylonians called it Nergal, god of pestilence and the underworld. " +
            "Mars hosts Olympus Mons — the largest volcano in the solar system, three times the height of Everest — and Valles Marineris, a canyon as wide as the United States.",

        "Jupiter":
            "King of the Roman gods (Greek: Zeus), ruler of sky and thunder. " +
            "The brightest wandering star was seen as a bringer of fortune and divine authority; Babylonians called it Marduk, their supreme deity. " +
            "Jupiter's Great Red Spot is a storm that has raged for at least 350 years, and the planet emits more heat from its interior than it receives from the Sun.",

        "Saturn":
            "Roman god of agriculture and time (Greek: Kronos), who swallowed his children fearing a prophecy of overthrow. " +
            "As the slowest visible planet it marked the outer edge of the cosmos for millennia — a boundary deity. " +
            "Saturn's rings are less than 100 metres thick in places yet span 282,000 km; it takes 29.5 years to orbit the Sun, meaning most humans see it return to its birth position only two or three times in a lifetime.",

        "Uranus":
            "Primordial Greek sky god, father of the Titans, overthrown and castrated by his son Kronos (Saturn). " +
            "Uranus was invisible to the ancients — William Herschel discovered it by telescope in 1781. " +
            "Its extreme axial tilt (98°) makes it spin on its side, almost rolling around the Sun.",

        "Neptune":
            "Roman god of the sea (Greek: Poseidon), whose trident commands waves and earthquakes. " +
            "Neptune was found in 1846 through mathematics alone — its existence was predicted from gravitational wobbles before anyone looked. " +
            "It has the fastest winds in the solar system (up to 2,100 km/h), and its moon Triton orbits backwards, almost certainly a captured Kuiper Belt object.",

        "Pluto":
            "Roman lord of the underworld (Greek: Hades), ruler of the realm all souls enter after death. " +
            "Dark, distant, and frozen at the solar system's edge, the name fit perfectly when it was found in 1930. " +
            "Smaller than Earth's Moon, it takes 248 years to orbit the Sun; the New Horizons flyby in 2015 revealed a heart-shaped nitrogen ice plain called Tombaugh Regio.",

        "Ceres":
            "Roman goddess of grain and the harvest (Greek: Demeter), whose grief over her daughter Persephone's abduction to Hades caused winter. " +
            "Discovered in 1801, Ceres was called a planet, then an asteroid, and is now classified as a dwarf planet — the largest body in the asteroid belt.",

        "Eris":
            "Greek goddess of discord, who threw the Apple of Discord at a wedding feast and ignited the Trojan War. " +
            "Fittingly, Eris's 2005 discovery triggered the controversy that reclassified Pluto as a dwarf planet. " +
            "Slightly smaller than Pluto, it orbits far beyond and takes 559 years to circle the Sun.",

        "Haumea":
            "Hawaiian goddess of fertility and childbirth, associated with the element of stone. " +
            "This dwarf planet spins once every four hours — so fast that tidal forces have stretched it into an egg shape. " +
            "It also has two small moons, Hi'iaka and Namaka, named for Haumea's daughters.",

        "Makemake":
            "Creator god of the Rapa Nui (Easter Island) people, who brought humanity into being. " +
            "The Rapa Nui built the famous moai statues partly as tribute to ancestral deities including Makemake. " +
            "This distant dwarf planet orbits beyond Pluto and takes 310 years to complete one circuit of the Sun.",

        "Io":
            "Greek priestess of Hera, seduced by Zeus (Jupiter), who turned her into a white cow to hide the affair from his jealous wife. " +
            "Io is the most volcanically active body in the solar system — Jupiter's tidal gravity kneads its interior, generating intense heat and hundreds of erupting volcanoes.",

        "Europa":
            "Phoenician princess abducted by Zeus (Jupiter), who disguised himself as a white bull and swam her to Crete. " +
            "Europa the moon may hide a vast liquid-water ocean beneath its cracked ice shell — making it the best candidate for extraterrestrial life in our solar system.",

        "Ganymede":
            "Beautiful Trojan youth whom Zeus (Jupiter), in the form of an eagle, carried to Olympus to serve as cupbearer to the gods — the mythological origin of the word 'gannet.' " +
            "Ganymede is the largest moon in the solar system, bigger than Mercury, and has its own magnetic field.",

        "Callisto":
            "Arcadian nymph and companion of Artemis, seduced by Zeus (Jupiter) and transformed into a bear by jealous Hera — then placed among the stars as Ursa Major. " +
            "Callisto the moon has one of the most heavily cratered surfaces in the solar system, a face nearly unchanged for 4 billion years.",

        "Mimas":
            "One of the Giants (Gigantes), children of Gaia born to overthrow the Olympian gods — slain in battle by Hercules or Hephaestus. " +
            "Mimas is famous for its enormous Herschel crater, which gives it an uncanny resemblance to the Death Star — a coincidence of geology rather than mythology.",

        "Enceladus":
            "A Giant in Greek myth, buried beneath Sicily by Athena after the war of gods and Giants — his struggles beneath the rock were said to cause earthquakes and Etna's eruptions. " +
            "Fittingly, Enceladus the moon is violently active, venting geysers of water vapor from a subsurface ocean through fractures at its south pole.",

        "Tethys":
            "Titaness of fresh water, daughter of Uranus and Gaia, wife of Oceanus. Together they presided over the source of all the world's rivers, springs, and rain clouds. " +
            "Tethys the moon carries Ithaca Chasma, a vast canyon stretching three-quarters of its circumference.",

        "Dione":
            "Titaness or Oceanid in Greek myth, one of Zeus's early consorts and, by some accounts, mother of Aphrodite (Venus). " +
            "Dione's icy surface is traced with bright cliffs and 'wispy terrain' — long scarps that were among the more puzzling sights in early Voyager images.",

        "Rhea":
            "Titaness and mother of the six core Olympians: Zeus, Hera, Demeter, Poseidon, Hestia, and Hades. " +
            "She hid infant Zeus from Kronos (Saturn) by wrapping a stone in swaddling clothes for him to swallow instead. " +
            "Saturn's second-largest moon has a thin atmosphere of oxygen and carbon dioxide.",

        "Titan":
            "The Titans were the elder race of gods in Greek myth — primordial rulers overthrown by the Olympians. Saturn's largest moon bears their collective name. " +
            "With thick nitrogen air, methane rain, and hydrocarbon lakes, Titan is the most Earth-like world in the solar system.",

        "Iapetus":
            "Titan and father of Atlas, Prometheus, and Epimetheus — the figures who bound humanity to fate, fire, and folly. " +
            "Iapetus the moon is dramatically two-toned: one hemisphere jet black, the other bone white, a mystery that fascinated Cassini scientists for years and is now attributed to thermal segregation of dark dust.",

        // Named Stars
        "Sirius":
            "Greek 'Seirios' meaning 'scorching.' The brightest star in the sky, in Canis Major (the Great Dog). " +
            "Ancient Egyptians built temples aligned to its heliacal rising — Sirius reappearing at dawn after 70 days of absence signaled the Nile flood and the new year. " +
            "Romans called the hot late-summer weeks 'dog days' because Sirius rose with the Sun.",

        "Canopus":
            "Named for the chief navigator of the Greek fleet at Troy. The second-brightest star, deep in the southern sky in Carina (the Ship's Keel). " +
            "Ancient Egyptians and Babylonians used it as a calendar star. Today spacecraft attitude-control systems use it as a reference beacon.",

        "Arcturus":
            "Greek for 'Guardian of the Bear' — it follows Ursa Major across the sky as a celestial herdsman, in the constellation Boötes. " +
            "Greek sailors watched its morning rising as a warning of violent storms. " +
            "Its 37-year-old light was used to open the 1933 Chicago World's Fair, symbolizing the connection of past starlight to the present.",

        "Vega":
            "From Arabic Wāqiʿ al-nasr, 'the falling eagle.' The brightest star in Lyra, the lyre of Orpheus whose music charmed stones, rivers, and Hades himself. " +
            "Vega was the North Star ~12,000 BC due to Earth's axial precession, and will be again around AD 13,727. " +
            "In Japanese legend, Vega is Orihime (the weaver princess), separated from her lover Altair by the Milky Way — reunited once a year in the Tanabata festival.",

        "Capella":
            "Latin for 'the little she-goat,' representing Amalthea, the goat who nursed the infant Zeus in Crete after Rhea hid him from Kronos. " +
            "The brightest star in Auriga (the Charioteer), its golden color made it sacred to Egyptian temple builders. " +
            "It is actually two giant stars orbiting each other every 104 days.",

        "Rigel":
            "Arabic for 'the left foot of the giant,' marking Orion's foot. A brilliant blue supergiant — one of the most luminous stars known, shining ~120,000 times brighter than the Sun. " +
            "Babylonians associated it with Erra, god of plague. In Egyptian tradition it represented Sah, the god of stars and father of the soul.",

        "Procyon":
            "Greek for 'before the dog,' because it rises just before Sirius each morning. The brightest star in Canis Minor (the Little Dog). " +
            "Ancient Egyptians saw its heliacal rising as a warning of the approaching scorching season. " +
            "It has a white dwarf companion — a preview of our own Sun's distant future.",

        "Betelgeuse":
            "Corrupted Arabic roughly meaning 'the shoulder of the great one' (of Orion). A red supergiant so vast it would engulf Jupiter's orbit if placed at our Sun. " +
            "Its dramatic dimming in 2019-2020 sparked widespread supernova speculation. " +
            "When it finally explodes it will briefly outshine the full Moon and be visible in daylight from Earth.",

        "Altair":
            "Arabic for 'the flying eagle.' The brightest star in Aquila (the Eagle), the bird of Zeus who bore his thunderbolts. " +
            "In Japanese folklore Altair is Hikoboshi (the cowherd), separated from his lover Vega by the Milky Way and reunited once a year in the Tanabata festival. " +
            "Altair spins so fast (once every 9 hours) that it visibly bulges at its equator.",

        "Aldebaran":
            "Arabic for 'the follower' — it rises after the Pleiades, following that cluster across the sky. The red eye of Taurus (the Bull). " +
            "The Aztecs held a sacred ceremony timed to Aldebaran's midnight zenith crossing, fearing the world would end if it failed to appear. " +
            "One of the four Persian Royal Stars, it was the guardian of the eastern sky.",

        "Antares":
            "Greek for 'rival of Ares (Mars)' — its red-orange color rivaled the planet so closely that ancient astronomers considered them twins. The heart of Scorpius. " +
            "Another Persian Royal Star, guardian of the western sky. " +
            "A massive red supergiant and supernova candidate — if it exploded today, the light would take 554 years to reach us.",

        "Spica":
            "Latin for 'ear of grain,' the sheaf held by Virgo (the Maiden / Demeter). " +
            "Hipparchus used Spica to discover the precession of the equinoxes in 127 BC — one of the greatest observational discoveries of antiquity. " +
            "Ptolemy catalogued it; navigators used it for centuries to determine latitude at sea.",

        "Polaris":
            "The North Star, within 0.7° of the celestial north pole. The tip of Ursa Minor's tail. " +
            "Vikings, Arab traders, and explorers used it for navigation long before GPS — unlike other stars, it barely moves as the sky turns. " +
            "It is a pulsating Cepheid variable and will gradually drift from the pole over the next centuries as Earth's axis precesses.",

        "Deneb":
            "Arabic for 'tail' — the tail of Cygnus (the Swan). At ~2,600 light-years, it is one of the most distant and luminous bright stars visible to the naked eye. " +
            "Deneb anchors the Summer Triangle alongside Vega and Altair. " +
            "If it were as close as Sirius, it would cast shadows at night and be as bright as a crescent Moon.",

        "Fomalhaut":
            "Arabic for 'mouth of the southern fish' (Piscis Austrinus). Called the 'Loneliest Star' in Arabic tradition, isolated in an otherwise dim autumn sky. " +
            "It marks the point where water poured by Aquarius flows. " +
            "In 2008 Fomalhaut became the first star to have an orbiting planet directly photographed — a milestone in exoplanet science.",

        "Regulus":
            "Latin for 'little king.' The brightest star in Leo (the Lion), lying almost exactly on the ecliptic so planets pass close to it regularly. " +
            "One of the four Persian Royal Stars (Watcher of the North), it was considered one of the four pillars holding up the heavens. " +
            "Regulus spins so fast it would fly apart if it rotated just 16% faster.",

        "Pollux":
            "The immortal twin — son of Zeus — while his brother Castor was mortal (son of a king). Together they were the Dioscuri, sailing with Jason and protecting sailors from storms. " +
            "Romans believed they appeared as St. Elmo's fire on ship masts. " +
            "Pollux is known to host an exoplanet — one of the first confirmed around a giant star.",

        // Zodiac Constellations
        "Aries":
            "The Ram bearing the golden fleece, sent by the gods to rescue Phrixus and Helle. Phrixus sacrificed the ram in Colchis and hung its fleece in a sacred grove — inspiring Jason's quest. " +
            "The vernal equinox was in Aries ~2,000 years ago, making it the traditional 'first sign,' though precession has since moved the equinox into Pisces.",

        "Taurus":
            "The Bull, most often Zeus disguised to abduct Europa. Also associated with the Pleiades on its shoulder — ancient farmers and sailors timed planting and voyages by the Pleiades' rising and setting. " +
            "One of the oldest known constellations, depicted in Lascaux cave paintings (~15,000 BC). Aldebaran marks the bull's fierce red eye.",

        "Gemini":
            "The Twins, Castor and Pollux — heroes who sailed on the Argo and were revered as protectors of sailors; Romans believed they appeared as St. Elmo's fire in storms. " +
            "The Geminid meteor shower — the strongest of the year — radiates from this constellation each December. " +
            "Gemini once contained the summer solstice, giving its neighbor Cancer the Tropic of Cancer.",

        "Cancer":
            "The Crab sent by Hera to distract Hercules during his battle with the Hydra — crushed underfoot and placed among the stars as a small reward for its loyalty. " +
            "The summer solstice was in Cancer when the Tropic of Cancer was named. It is the faintest zodiac constellation, but contains the Beehive Cluster (M44), one of the nearest open star clusters.",

        "Leo":
            "The Nemean Lion, invulnerable to weapons — Hercules' first labor was to slay it. He strangled it and wore its skin as armor for all twelve labors. " +
            "Regulus (Leo's heart) was one of the four Persian Royal Stars, Watcher of the North. " +
            "The annual Leonid meteor storm — peaking every 33 years — radiates from within Leo's sickle.",

        "Virgo":
            "The Maiden, most often Demeter (goddess of the harvest) or Persephone, whose descent into Hades each year explains the seasons. " +
            "The autumnal equinox is currently in Virgo. Spica, Virgo's brightest star, was used by Hipparchus to discover the precession of the equinoxes. " +
            "Virgo is one of the richest constellations in galaxies — the Virgo Cluster, 60 million light-years away, contains over 1,300 galaxies.",

        "Libra":
            "The Scales of Justice, sometimes held by Virgo (identified as Astraea, goddess of justice). The only zodiac sign representing an inanimate object. " +
            "The autumnal equinox was once in Libra — day and night in balance, like the scales. " +
            "In Babylonian astronomy these stars were the 'Claws of the Scorpion'; the Romans separated them into their own constellation.",

        "Scorpius":
            "The Scorpion sent by Gaia to kill Orion — placed on opposite sides of the sky so the two can never meet. When Scorpius rises, Orion flees below the horizon. " +
            "Antares, its heart, was one of the four Persian Royal Stars (Watcher of the West). " +
            "Scorpius lies in the richest star fields of the Milky Way, pointing toward the galactic center in Sagittarius.",

        "Sagittarius":
            "The Archer, depicted as a centaur drawing a bow. Often identified with Chiron (Achilles' wise tutor) or Crotus (inventor of archery). " +
            "The center of our Milky Way galaxy lies here, near the 'spout' of the Teapot asterism — the densest star fields in the sky. " +
            "Babylonians identified it with Nergal, god of plague and the underworld.",

        "Capricornus":
            "The Sea-Goat — head of a goat, tail of a fish. Associated with Pan, who leaped into the Nile as a fish-goat to escape the monster Typhon. " +
            "The winter solstice was once in Capricorn, giving us the Tropic of Capricorn. " +
            "One of the oldest constellations, depicted on Babylonian boundary stones from ~1200 BC.",

        "Aquarius":
            "The Water-Bearer, one of the most ancient constellations. Identified with Ganymede (cupbearer to the gods), Deucalion (the Greek flood hero), and the Babylonian god Ea, lord of freshwater. " +
            "Ancient Egyptians believed Aquarius caused the Nile flood by dipping his jar into the river. " +
            "We are entering the 'Age of Aquarius' as the vernal equinox precesses from Pisces toward Aquarius.",

        "Pisces":
            "The Two Fish tied by a cord — Aphrodite and Eros, who transformed into fish to escape the monster Typhon, holding each other so they would not be separated. " +
            "The vernal equinox is currently in Pisces, placing us in the 'Age of Pisces' that is slowly ending as precession moves it into Aquarius. " +
            "One of the faintest zodiac constellations, with no star brighter than magnitude 3.6.",

        // Other constellations
        "Orion":
            "The Hunter, giant son of Poseidon, the greatest hunter who boasted he could kill every creature on Earth. Gaia sent the Scorpion to end his hubris — they were placed on opposite sides of the sky forever. " +
            "Betelgeuse (his shoulder) and Rigel (his foot) make Orion home to two of the sky's most extraordinary stars. " +
            "His three belt stars guided cultures for millennia; the three pyramids at Giza are aligned to mirror them.",

        "Ursa Major":
            "The Great Bear, identified with Callisto (nymph transformed into a bear by Zeus or Hera). Zeus placed her in the sky as the Great Bear, her small bear's tail stretched into the long arc of the Big Dipper's handle. " +
            "The Big Dipper's two 'pointer stars' always point to Polaris, the North Star. " +
            "Used for navigation by the Greeks, Vikings, and Native American peoples; the Big Dipper appears on the Alaskan state flag.",

        "Ursa Minor":
            "The Little Bear, said to be Arcas — son of Callisto and Zeus — placed in the sky to prevent him from accidentally hunting his own bear-mother. " +
            "Polaris sits at the tip of its tail, less than 1° from the celestial north pole. " +
            "Ancient Greek sailors called it 'the Phoenician constellation' because Phoenician navigators favored Ursa Minor over Ursa Major for its greater precision near the pole.",

        "Cassiopeia":
            "The vain queen of Aethiopia who boasted her daughter Andromeda was more beautiful than the sea-nymphs. Poseidon chained Andromeda to a rock as punishment; Cassiopeia was set spinning around the north pole — right-side-up then upside-down, forever. " +
            "In 1572 Tycho Brahe observed a brilliant supernova here that shook Aristotelian belief in unchanging heavens. " +
            "Its bright W shape is one of the most recognizable patterns in the northern sky.",

        "Cygnus":
            "The Swan, most often Zeus disguised to court Leda, whose eggs hatched Helen of Troy and the divine Twins. " +
            "The Northern Cross traces the swan's body; the Milky Way flows along its wings. Deneb anchors the Summer Triangle. " +
            "Cygnus X-1, within this constellation, was the first object confirmed as a black hole.",
    ]

    // Returns (lowerHz, upperHz) for the two bodies in a resonance pair,
    // scaled so both fall in a comfortable audible range.
    // Faster-orbiting body → higher pitch; ratio preserved from actual periods.
    static func resonanceTones(for pair: ResonancePair) -> (Double, Double) {
        guard let s1 = stats(for: pair.primary),  let p1 = s1.orbitalPeriodDays,
              let s2 = stats(for: pair.secondary), let p2 = s2.orbitalPeriodDays else {
            return (220, 440)
        }
        let (fast, slow) = p1 < p2 ? (p1, p2) : (p2, p1)
        let ratio = slow / fast   // ≥ 1
        var fLow  = 220.0
        var fHigh = 220.0 * ratio
        while fHigh > 880 { fHigh /= 2; fLow /= 2 }
        while fHigh < 220 { fHigh *= 2; fLow *= 2 }
        return (fLow, fHigh)
    }

    static let all: [String: BodyStats] = {
        var d: [String: BodyStats] = [:]
        d["Sun"] = BodyStats(type: "Star", radiusKm: 696_000,
                             orbitalPeriodDays: nil, orbitDisplay: nil)
        let dwarfs: Set<String> = ["Pluto", "Eris", "Ceres", "Haumea", "Makemake"]
        for body in BodyCatalog.planetsAndDwarfs {
            let type: String = dwarfs.contains(body.name) ? "Dwarf Planet" : "Planet"
            let km: Int = Int(body.radiusEarths * 6371)
            let period: Double = body.orbitalPeriodSeconds / 86400
            let orbit: String = String(format: "%.2f AU", body.semiMajorAxisAU)
            d[body.name] = BodyStats(type: type, radiusKm: km,
                                     orbitalPeriodDays: period, orbitDisplay: orbit)
        }
        typealias MoonData = (name: String, r: Int, p: Double, km: Int)
        let jovian: [MoonData] = [
            (name: "Io",       r: 1822, p:  1.769, km:   421_700),
            (name: "Europa",   r: 1561, p:  3.551, km:   671_034),
            (name: "Ganymede", r: 2634, p:  7.155, km: 1_070_412),
            (name: "Callisto", r: 2410, p: 16.689, km: 1_882_709),
        ]
        for m in jovian {
            d[m.name] = BodyStats(type: "Moon", radiusKm: m.r,
                                  orbitalPeriodDays: m.p, orbitDisplay: moonOrbit(m.km, "Jupiter"))
        }
        let saturnian: [MoonData] = [
            (name: "Mimas",     r:  198, p:  0.942, km:   185_539),
            (name: "Enceladus", r:  252, p:  1.370, km:   238_042),
            (name: "Tethys",    r:  533, p:  1.888, km:   294_619),
            (name: "Dione",     r:  562, p:  2.737, km:   377_396),
            (name: "Rhea",      r:  764, p:  4.518, km:   527_108),
            (name: "Titan",     r: 2575, p: 15.945, km: 1_221_870),
            (name: "Iapetus",   r:  735, p: 79.321, km: 3_560_820),
        ]
        for m in saturnian {
            d[m.name] = BodyStats(type: "Moon", radiusKm: m.r,
                                  orbitalPeriodDays: m.p, orbitDisplay: moonOrbit(m.km, "Saturn"))
        }

        // Dwarf planets not in BodyCatalog.planetsAndDwarfs
        d["Ceres"]   = BodyStats(type: "Dwarf Planet", radiusKm: 476,
                                 orbitalPeriodDays: 1680.50, orbitDisplay: "2.77 AU")
        d["Eris"]    = BodyStats(type: "Dwarf Planet", radiusKm: 1163,
                                 orbitalPeriodDays: 203_830, orbitDisplay: "67.7 AU")
        d["Haumea"]  = BodyStats(type: "Dwarf Planet", radiusKm: 816,
                                 orbitalPeriodDays: 103_468, orbitDisplay: "43.1 AU")
        d["Makemake"] = BodyStats(type: "Dwarf Planet", radiusKm: 715,
                                  orbitalPeriodDays: 111_867, orbitDisplay: "45.8 AU")

        // Named stars — orbitDisplay holds spectral class; distanceLY in light-years
        typealias StarData = (name: String, spectral: String, ly: Double)
        let namedStars: [StarData] = [
            ("Sirius",     "A1V",    8.6),
            ("Canopus",    "F0Ib",   310),
            ("Arcturus",   "K1.5III", 37),
            ("Vega",       "A0Va",    25),
            ("Capella",    "G8III",   43),
            ("Rigel",      "B8Ia",   860),
            ("Procyon",    "F5IV",   11.5),
            ("Betelgeuse", "M1Ia",   700),
            ("Altair",     "A7V",     17),
            ("Aldebaran",  "K5III",   65),
            ("Antares",    "M1Ia",   554),
            ("Spica",      "B1V",    250),
            ("Polaris",    "F7Ib",   433),
            ("Deneb",      "A2Ia",  2600),
            ("Fomalhaut",  "A3Va",    25),
            ("Regulus",    "B7V",     79),
            ("Pollux",     "K0III",   34),
        ]
        for s in namedStars {
            d[s.name] = BodyStats(type: "Star", radiusKm: 0,
                                  orbitDisplay: s.spectral, distanceLY: s.ly)
        }

        // Constellations
        let constellations: [String] = [
            "Aries", "Taurus", "Gemini", "Cancer", "Leo", "Virgo",
            "Libra", "Scorpius", "Sagittarius", "Capricornus", "Aquarius", "Pisces",
            "Orion", "Ursa Major", "Ursa Minor", "Cassiopeia", "Cygnus",
        ]
        for c in constellations {
            d[c] = BodyStats(type: "Constellation", radiusKm: 0)
        }

        return d
    }()

    private static func moonOrbit(_ km: Int, _ parent: String) -> String {
        km >= 1_000_000
            ? String(format: "%.2fM km / \(parent)", Double(km) / 1_000_000)
            : "\(km / 1000)k km / \(parent)"
    }
}

struct BodyInfoCard: View {
    let name: String
    let onDismiss: () -> Void

    @State private var position: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        if let stats = BodyStatsCatalog.stats(for: name) {
            VStack(alignment: .leading, spacing: 10) {
                // Drag handle
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 40, height: 4)
                    Spacer()
                }
                .padding(.bottom, 2)

                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(stats.type)
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(typeColor(stats.type))
                    .foregroundStyle(stats.type == "Star" ? Color.black : Color.white)
                    .clipShape(Capsule())
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    if stats.radiusKm > 0 { statCol("Radius", stats.radiusDisplay) }
                    if let p = stats.periodDisplay { statCol("Period", p) }
                    if let o = stats.orbitDisplay  {
                        statCol(stats.type == "Star" ? "Spectral" : "Orbit", o)
                    }
                    if let d = stats.distanceDisplay { statCol("Distance", d) }
                }
                if let myth = BodyStatsCatalog.mythology(for: name) {
                    Divider()
                    Text(myth)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: 480)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .offset(x: position.width + dragOffset.width,
                    y: position.height + dragOffset.height)
            .gesture(
                DragGesture()
                    .onChanged { value in dragOffset = value.translation }
                    .onEnded { value in
                        position = CGSize(width: position.width + value.translation.width,
                                         height: position.height + value.translation.height)
                        dragOffset = .zero
                    }
            )
        }
    }

    @ViewBuilder
    private func statCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 16)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium))
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "Star":          return .yellow
        case "Planet":        return .blue
        case "Dwarf Planet":  return .orange
        case "Constellation": return .purple
        default:              return .secondary
        }
    }
}

// MARK: - Notable Date Catalog

enum NotableDateCatalog {
    static func explanation(for name: String) -> String? { data[name] }

    static let data: [String: String] = [
        "Great Conjunction":
            "Look for Jupiter and Saturn crowded to nearly the same heliocentric longitude — both gas giants on the same radial line from the Sun. " +
            "They sit at very different distances (5.2 vs 9.5 AU) so they won't overlap from above, but the angular alignment is the closest it had been since 1623. " +
            "This date is recent enough that the simulation's Keplerian orbits should place the planets accurately.",

        "Planetary Parade":
            "Watch the inner solar system: Mercury, Venus, Mars, Jupiter, and Saturn are bunched within a ~90° arc of heliocentric longitude — all on the same side of the Sun. " +
            "The planets appear clustered rather than spread around their full orbits. This tight grouping of all five classical planets is rare — it hadn't occurred in this geometry for 18 years.",

        "Mars Great Opposition":
            "Earth is directly between the Sun and Mars — look for Earth and Mars nearly in line on the same side of the Sun, Mars at its closest orbital approach in 15 years (57.6 million km). " +
            "During opposition Mars is at its largest and brightest as seen from Earth. A global dust storm covered Mars for weeks before this date.",

        "Grand Tour Alignment":
            "Jupiter, Saturn, Uranus, and Neptune are arrayed on roughly the same side of the solar system within a ~90° arc — the rare geometry that let Voyager 2 reach all four giants by gravitational slingshot. " +
            "This window opens only every ~175 years. Voyager 2 launched on this date and is now the farthest human-made object after Voyager 1.",

        "5-Planet Arc":
            "Mercury, Venus, Mars, Jupiter, and Saturn are clustered within a tight 35° arc of heliocentric longitude — look for all five bunched together on one side of the Sun. " +
            "This kind of tight five-planet grouping occurs only a few times per century.",

        "Pluto at Perihelion":
            "Pluto is at its closest point to the Sun — look for it crossing inside Neptune's orbital ring. Its high eccentricity (0.25) swings it between 29.7 AU at perihelion and 49.3 AU at aphelion. " +
            "Pluto remained inside Neptune's orbit from 1979 to 1999. Voyager 2 flew past Neptune just 11 days before this date.",

        "Neptune Discovery":
            "Neptune sits near the position Le Verrier calculated from unexplained perturbations in Uranus's orbit — the first planet found by mathematics rather than observation. " +
            "Keplerian orbits are reasonably accurate for this era (~150 years from J2000), so the simulation should show Neptune near its correct 1846 position.",

        "Pluto Discovery":
            "Pluto is near its 1930 position. Note how its inclined, eccentric orbit sets it apart from the major planets. " +
            "Tombaugh found it by noticing it had moved between photographic plates taken six days apart. Lowell had predicted 'Planet X' based on what turned out to be errors in Uranus measurements.",

        "Next Great Conjunction":
            "A predicted Jupiter-Saturn alignment — watch the two outer planets converge to nearly the same heliocentric longitude. " +
            "Each ~20-year Jupiter-Saturn conjunction shifts ~117° eastward, so three conjunctions trace almost a full circle, repeating the same sky location every ~60 years.",

        "Joshua's Long Day":
            "⚠︎ Keplerian orbits accumulate significant error over 3,400 years — planet positions shown are not historically accurate. " +
            "The Book of Joshua (10:12–14) records the Sun standing still during the battle of Gibeon (~1405 BC). This date is a scholarly estimate from biblical chronology. Proposed explanations range from a solar eclipse to atmospheric refraction.",

        "Hezekiah's Sundial":
            "⚠︎ Keplerian orbits accumulate significant error over 2,700 years — planet positions shown are not historically accurate. " +
            "Isaiah 38:8 records the shadow on Hezekiah's sundial retreating ten steps (~701 BC), confirmed in the broader historical context by the Taylor Prism in the British Museum. The event has no accepted natural explanation.",

        "Star of Bethlehem":
            "⚠︎ Keplerian orbits accumulate large error over 2,000 years — planet positions shown are approximate at best. " +
            "In 7 BC, Jupiter and Saturn met three times in Pisces (May 27, Sept 6, Dec 1), recorded on Babylonian clay tablets. Kepler proposed this triple conjunction as the Star of Bethlehem in 1603. To Babylonian Magi, Jupiter meant kingship and Saturn the Jewish people.",

        "Jupiter-Venus Beacon":
            "⚠︎ Keplerian orbits accumulate significant error over 2,000 years — planet positions shown are approximate. " +
            "On June 17, 2 BC, Jupiter and Venus approached within 0.02° in Leo — appearing as a single blazing point at magnitude -3.9. Astronomer Michael Molnar proposed this as the Star of Bethlehem in 1999.",

        "Tycho's Conjunction":
            "Jupiter and Saturn should be converging toward the same heliocentric longitude — look for them relatively close together in the outer solar system arc. " +
            "This conjunction on August 24, 1563 inspired 16-year-old Tycho Brahe to become an astronomer after noticing existing tables predicted it days off. Tycho's subsequent measurements gave Kepler the data to derive his three laws. " +
            "Note: ~450 years from J2000 — positions are approximate.",

        "Black Death Conjunction":
            "Look for Jupiter, Saturn, and Mars in a rough grouping — a triple conjunction of the three planets. The exact alignment will be approximate; ~650 years of Keplerian drift is significant. " +
            "On March 20, 1345, the Paris Medical Faculty formally blamed this Jupiter-Saturn-Mars alignment for the Black Death. The plague killed a third of Europe's population beginning three years later.",
    ]
}

struct DateInfoCard: View {
    let entry: NamedDate
    let onDismiss: () -> Void

    @State private var position: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        if let explanation = NotableDateCatalog.explanation(for: entry.name) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 40, height: 4)
                    Spacer()
                }
                .padding(.bottom, 2)

                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name).font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text(entry.date, format: .dateTime.year().month(.wide).day())
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                Divider()

                Text(explanation)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: 480)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .offset(x: position.width + dragOffset.width,
                    y: position.height + dragOffset.height)
            .gesture(
                DragGesture()
                    .onChanged { value in dragOffset = value.translation }
                    .onEnded { value in
                        position = CGSize(width: position.width + value.translation.width,
                                         height: position.height + value.translation.height)
                        dragOffset = .zero
                    }
            )
        }
    }
}

// MARK: - Resonance Synth

final class ResonanceSynth {
    private var engine   = AVAudioEngine()
    private var srcNode: AVAudioSourceNode?
    private let lock     = NSLock()
    private var _freq1   = 220.0
    private var _freq2   = 440.0
    private var phase1   = 0.0
    private var phase2   = 0.0
    private let sr       = 44100.0
    private(set) var running = false

    func setFrequencies(_ f1: Double, _ f2: Double) {
        lock.lock(); _freq1 = f1; _freq2 = f2; lock.unlock()
    }

    func start() {
        guard !running else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                          options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        engine = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let renderBlock: AVAudioSourceNodeRenderBlock = { [weak self] _, _, frameCount, abl in
            guard let self else { return noErr }
            self.lock.lock()
            let f1 = self._freq1
            let f2 = self._freq2
            self.lock.unlock()
            let twoPi = 2.0 * Double.pi
            let ptr = UnsafeMutableAudioBufferListPointer(abl)
            for i in 0..<Int(frameCount) {
                let a = sin(self.phase1) * 0.13 + sin(self.phase1 * 2) * 0.04
                let b = sin(self.phase2) * 0.13 + sin(self.phase2 * 2) * 0.04
                let s = Float(a + b)
                self.phase1 = (self.phase1 + twoPi * f1 / self.sr).truncatingRemainder(dividingBy: twoPi)
                self.phase2 = (self.phase2 + twoPi * f2 / self.sr).truncatingRemainder(dividingBy: twoPi)
                for buf in ptr { UnsafeMutableBufferPointer<Float>(buf)[i] = s }
            }
            return noErr
        }
        let node = AVAudioSourceNode(format: fmt, renderBlock: renderBlock)
        srcNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.55
        do {
            try engine.start()
            running = true
        } catch {
            print("ResonanceSynth: \(error)")
        }
    }

    func stop() {
        guard running else { return }
        engine.stop()
        running = false
    }
}
