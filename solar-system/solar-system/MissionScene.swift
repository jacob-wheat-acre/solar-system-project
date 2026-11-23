import Foundation
import SceneKit
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// SceneKit scene for one mission. Positions come from `Mission` tracks (ecliptic
/// J2000) and map to scene axes like the rest of the app: +X vernal equinox,
/// +Y ecliptic north, +Z = ecliptic y.
///
/// Scale: heliocentric missions use 1 AU = 10 units (same as the main view);
/// Apollo uses 1 unit = 1,000 km. Bodies and spacecraft are drawn at true size
/// but never smaller than a few pixels (`minScreenFraction`), so they read as
/// dots from afar and at real size during a close flyby.
final class MissionScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let mission: Mission

    private let root = SCNNode()
    private let skyNode = SCNNode()
    private let scale: Double                       // scene units per data unit
    private var bodyNodes: [String: SCNNode] = [:]
    private var craftNodes: [String: SCNNode] = [:]
    private var trueRadius: [String: Float] = [:]   // scene units
    private var minScreen: [String: Float] = [:]    // fraction of camera distance
    private var eventNodes: [String: SCNNode] = [:]
    private var bodyPathNodes: [SCNNode] = []
    private let extent: Float

    /// A spacecraft's path, drawn either in the mission frame or relative to a body
    /// (vertices = craft − body at each sample; the container rides along with the body).
    private struct Trail {
        let container: SCNNode
        let flown: SCNGeometryElement
        let tip: SCNNode
        let vertices: [SCNVector3]
    }
    private var trails: [String: Trail] = [:]
    private var craftColor: [String: NSColorLike] = [:]
    /// Body the trails are drawn relative to; nil = the mission's own frame (Sun / Earth).
    private(set) var referenceBody: String?
    /// When the reference changes, the trails morph from the old frame to the new one
    /// over `blendDuration` seconds instead of jumping.
    private var fromReference: String?
    private var blendProgress: Double = 1            // 0 = fromReference, 1 = referenceBody
    private var blendStart: CFTimeInterval = 0
    private static let blendDuration: CFTimeInterval = 0.9
    private var offsetCache: [String: [SIMD3<Double>]] = [:]
    private var blendWeight: Double { let x = blendProgress; return x * x * (3 - 2 * x) }

    init(mission: Mission) {
        self.mission = mission
        scale = mission.frame == .heliocentric ? 10 : 0.001
        var maxR = 1.0
        for t in mission.craft { for p in t.positions { maxR = max(maxR, simd_length(p)) } }
        extent = Float(maxR * scale)

        scene.background.contents = NSColorLike.black
        scene.rootNode.addChildNode(root)
        scene.rootNode.addChildNode(skyNode)
        skyNode.addChildNode(CelestialSky.makeNode())

        let camera = SCNCamera()
        camera.fieldOfView = 60
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        addLighting()
        for body in mission.bodies { addBody(body) }
        for (i, craft) in mission.craft.enumerated() { addCraft(craft, color: MissionScene.craftColors[i % MissionScene.craftColors.count]) }
        addEventMarkers()
        buildTrails()
    }

    // MARK: Reference frame

    /// Draw trails relative to `body` (e.g. Cassini's loops around Saturn, Apollo's
    /// figure-8 around the Moon); nil = the mission's own frame. See `Mission.referenceBody`.
    func setReference(_ next: String?) {
        guard next != referenceBody else { return }
        // Turning back mid-blend reverses it from where it is, so nothing jumps.
        let progress = next == fromReference && blendProgress < 1 ? 1 - blendProgress : 0
        fromReference = referenceBody
        referenceBody = next
        blendProgress = progress
        blendStart = CACurrentMediaTime() - progress * Self.blendDuration
        buildTrails()
    }

    private func offset(_ ref: String?, at t: Double) -> SIMD3<Double> {
        ref.flatMap { mission.body($0)?.position(at: t) } ?? .zero
    }

    /// Where the trails' frame sits at time `t`: between the old and new reference bodies while blending.
    private func referenceOffset(at t: Double) -> SIMD3<Double> {
        let to = offset(referenceBody, at: t)
        guard blendProgress < 1 else { return to }
        return simd_mix(offset(fromReference, at: t), to, SIMD3(repeating: blendWeight))
    }

    /// A reference body's position at each of a craft's samples (cached: the blend reuses them every frame).
    private func offsets(_ ref: String?, for craft: MissionTrack) -> [SIMD3<Double>] {
        guard let ref else { return Array(repeating: .zero, count: craft.times.count) }
        let key = ref + "|" + craft.name
        if let c = offsetCache[key] { return c }
        let c = craft.times.map { offset(ref, at: $0) }
        offsetCache[key] = c
        return c
    }

    private func buildTrails() {
        for trail in trails.values { trail.container.removeFromParentNode(); trail.tip.removeFromParentNode() }
        trails.removeAll()
        let w = blendWeight
        for craft in mission.craft {
            let color = craftColor[craft.name] ?? .white
            let to = offsets(referenceBody, for: craft)
            let from = blendProgress < 1 ? offsets(fromReference, for: craft) : to
            let verts = craft.positions.indices.map { i in
                scenePosition(craft.positions[i] - simd_mix(from[i], to[i], SIMD3(repeating: w)))
            }
            let source = SCNGeometrySource(vertices: verts)
            var idx: [Int32] = []; idx.reserveCapacity(verts.count * 2)
            for i in 0..<max(0, verts.count - 1) { idx += [Int32(i), Int32(i + 1)] }
            let container = SCNNode()
            let full = SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            full.materials = [SceneLines.material(color.withAlphaComponent(0.22))]
            container.addChildNode(SCNNode(geometry: full))
            // Bright "flown" copy: same vertices, limited to the segments flown so far.
            let flownEl = SCNGeometryElement(indices: idx, primitiveType: .line)
            flownEl.primitiveRange = NSRange(location: 0, length: 0)
            let flown = SCNGeometry(sources: [source], elements: [flownEl])
            let bright = SceneLines.material(color)
            flown.materials = [bright]
            container.addChildNode(SCNNode(geometry: flown))
            let tip = SCNNode(geometry: SceneLines.geometry([SCNVector3Zero, SCNVector3Zero], material: bright))
            root.addChildNode(tip)
            root.addChildNode(container)
            trails[craft.name] = Trail(container: container, flown: flownEl, tip: tip, vertices: verts)
        }
        // Body orbit paths only make sense in the mission's own frame: fade them with the blend.
        let shown = simd_mix(fromReference == nil ? 1.0 : 0, referenceBody == nil ? 1.0 : 0, w)
        for n in bodyPathNodes { n.opacity = CGFloat(shown); n.isHidden = shown <= 0.001 }
    }

    // MARK: Coordinates

    func scenePosition(_ p: SIMD3<Double>) -> SCNVector3 {
        SCNVector3(SCNFloat(p.x * scale), SCNFloat(p.z * scale), SCNFloat(p.y * scale))
    }

    /// Current scene position of a body or spacecraft.
    func position(of name: String, at date: Date) -> SCNVector3 {
        guard let track = mission.track(name) else { return SCNVector3Zero }
        return scenePosition(track.position(at: date.timeIntervalSince1970))
    }

    var zoomRange: ClosedRange<Float> { mission.frame == .heliocentric ? 0.0005...6000 : 0.01...3000 }

    // MARK: Per-frame update

    func update(date: Date) {
        let t = date.timeIntervalSince1970
        if blendProgress < 1 {
            blendProgress = min(1, (CACurrentMediaTime() - blendStart) / Self.blendDuration)
            buildTrails()
        }
        for body in mission.bodies {
            bodyNodes[body.name]?.position = scenePosition(body.position(at: t))
        }
        let refNow = scenePosition(referenceOffset(at: t))
        for craft in mission.craft {
            guard let node = craftNodes[craft.name], let trail = trails[craft.name] else { continue }
            let active = t >= craft.start
            // Eagle only exists between undocking and jettison; others stay at their last point.
            let visible = active && (t <= craft.end || craft.end >= mission.end.timeIntervalSince1970 - 1)
            node.isHidden = !visible
            trail.tip.isHidden = !visible
            let pos = scenePosition(craft.position(at: t))
            node.position = pos
            trail.container.position = refNow

            // Bright "flown" trail: whole segments via primitiveRange, plus a live tip segment.
            let i = active ? craft.segmentIndex(at: t) : 0
            let flown = active ? (t >= craft.end ? craft.times.count - 1 : i) : 0
            trail.flown.primitiveRange = NSRange(location: 0, length: flown)
            if active, t < craft.end {
                let v = trail.vertices[i]
                let a = SCNVector3(v.x + refNow.x, v.y + refNow.y, v.z + refNow.z)
                trail.tip.geometry = SceneLines.geometry([a, pos], material: trail.tip.geometry?.firstMaterial)
            }
        }
        // Event markers sit on the trail, so they move with the reference body too.
        for e in mission.events {
            guard let node = eventNodes[e.id], let name = e.craft, let track = mission.track(name) else { continue }
            let p = track.position(at: e.t) - referenceOffset(at: e.t)
            let q = scenePosition(p)
            node.position = SCNVector3(q.x + refNow.x, q.y + refNow.y, q.z + refNow.z)
        }
    }

    /// Call after the camera moved: keeps bodies a minimum on-screen size and the sky at infinity.
    func updateForCamera(distance: Float) {
        let cam = cameraNode.worldPosition
        let camera = cameraNode.camera!
        camera.zNear = Double(max(1e-5, distance * 0.01))
        let skyR = 4 * (extent + distance)
        camera.zFar = Double(skyR * 2)
        CelestialSky.follow(skyNode, camera: cam, farRadius: skyR)

        func size(_ node: SCNNode, _ name: String) {
            let d = simd_distance(simd_float3(node.worldPosition), simd_float3(cam))
            let r = max(trueRadius[name] ?? 0, (minScreen[name] ?? 0.004) * d)
            node.scale = SCNVector3(SCNFloat(r), SCNFloat(r), SCNFloat(r))
        }
        for (name, node) in bodyNodes { size(node, name) }
        for (name, node) in craftNodes { size(node, name) }
        for (id, node) in eventNodes { size(node, id) }
    }

    /// Things to label on screen: bodies and spacecraft (not hidden).
    func labelAnchors() -> [(name: String, node: SCNNode)] {
        var out: [(String, SCNNode)] = []
        for b in mission.bodies where b.name != "Sun" || mission.frame == .heliocentric {
            if let n = bodyNodes[b.name] { out.append((b.name, n)) }
        }
        for c in mission.craft { if let n = craftNodes[c.name], !n.isHidden { out.append((c.label ?? c.name, n)) } }
        return out
    }

    // MARK: Construction

    private static let craftColors: [NSColorLike] = [
        NSColorLike(red: 1.00, green: 0.78, blue: 0.30, alpha: 1),
        NSColorLike(red: 0.40, green: 0.85, blue: 1.00, alpha: 1),
    ]

    private static let bodyColors: [String: NSColorLike] = [
        "Sun": NSColorLike(red: 1.0, green: 0.86, blue: 0.45, alpha: 1),
        "Venus": NSColorLike(red: 0.93, green: 0.78, blue: 0.55, alpha: 1),
        "Earth": NSColorLike(red: 0.25, green: 0.50, blue: 1.00, alpha: 1),
        "Moon": NSColorLike(white: 0.72, alpha: 1),
        "Jupiter": NSColorLike(red: 0.85, green: 0.70, blue: 0.52, alpha: 1),
        "Saturn": NSColorLike(red: 0.92, green: 0.82, blue: 0.58, alpha: 1),
        "Uranus": NSColorLike(red: 0.60, green: 0.88, blue: 0.92, alpha: 1),
        "Neptune": NSColorLike(red: 0.30, green: 0.45, blue: 0.95, alpha: 1),
        "Pluto": NSColorLike(red: 0.85, green: 0.75, blue: 0.62, alpha: 1),
        "Arrokoth": NSColorLike(red: 0.80, green: 0.45, blue: 0.35, alpha: 1),
    ]

    private func addLighting() {
        let ambient = SCNNode(); ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = NSColorLike(white: 0.12, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode(); sun.light = SCNLight()
        if mission.frame == .heliocentric {
            sun.light!.type = .omni
            sun.position = SCNVector3Zero
        } else {
            sun.light!.type = .directional
            let d = mission.sunDirection ?? SIMD3(1, 0, 0)
            sun.position = scenePosition(d * 1e6)
            sun.look(at: SCNVector3Zero)
        }
        sun.light!.color = NSColorLike(white: 1.0, alpha: 1)
        root.addChildNode(sun)
    }

    private func addBody(_ body: MissionTrack) {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 48
        let mat = SCNMaterial()
        mat.diffuse.contents = MissionScene.bodyColors[body.name] ?? NSColorLike.lightGray
        if body.name == "Sun" { mat.lightingModel = .constant; mat.emission.contents = mat.diffuse.contents }
        sphere.materials = [mat]
        let node = SCNNode(geometry: sphere)
        trueRadius[body.name] = Float(body.radiusKm / mission.unitKm * scale)
        minScreen[body.name] = body.name == "Sun" ? 0.008 : 0.004
        if body.name == "Saturn" { node.addChildNode(MissionScene.saturnRings()) }
        root.addChildNode(node)
        bodyNodes[body.name] = node

        // Faint orbit path (skip the fixed center body)
        guard body.positions.count > 2, !(mission.frame == .heliocentric && body.name == "Sun"),
              !(mission.frame == .geocentric && body.name == "Earth") else { return }
        let stride = max(1, body.positions.count / 3000)
        let pts = Swift.stride(from: 0, to: body.positions.count, by: stride).map { scenePosition(body.positions[$0]) }
        let m = SceneLines.material(NSColorLike(white: 1, alpha: 0.16))
        let path = SCNNode(geometry: SceneLines.geometry(pts, material: m))
        root.addChildNode(path)
        bodyPathNodes.append(path)
    }

    private func addCraft(_ craft: MissionTrack, color: NSColorLike) {
        craftColor[craft.name] = color
        let marker = SCNSphere(radius: 1)
        let mm = SCNMaterial(); mm.diffuse.contents = color; mm.emission.contents = color; mm.lightingModel = .constant
        marker.materials = [mm]
        let node = SCNNode(geometry: marker)
        node.isHidden = true
        root.addChildNode(node)
        craftNodes[craft.name] = node
        trueRadius[craft.name] = 0
        minScreen[craft.name] = 0.007
    }

    private func addEventMarkers() {
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColorLike(white: 1, alpha: 0.85); mat.lightingModel = .constant
        for e in mission.events {
            guard let name = e.craft, let track = mission.track(name), e.t >= track.start, e.t <= track.end else { continue }
            let s = SCNSphere(radius: 1); s.segmentCount = 8; s.materials = [mat]
            let node = SCNNode(geometry: s)
            node.position = scenePosition(track.position(at: e.t))
            root.addChildNode(node)
            eventNodes[e.id] = node
            minScreen[e.id] = 0.0035
        }
    }

    private static func saturnRings() -> SCNNode {
        // Ring radii in Saturn radii (the parent node is scaled to Saturn's radius).
        let tube = SCNTube(innerRadius: 74_500 / 58_232, outerRadius: 140_220 / 58_232, height: 0.002)
        tube.radialSegmentCount = 96
        let m = SCNMaterial()
        m.diffuse.contents = NSColorLike(red: 0.88, green: 0.80, blue: 0.62, alpha: 0.55)
        m.isDoubleSided = true
        tube.materials = [m]
        let node = SCNNode(geometry: tube)
        // Saturn's north pole: RA 40.589°, Dec 83.537° (equatorial J2000) → ecliptic → scene.
        let ra = 40.589 * Double.pi / 180, dec = 83.537 * Double.pi / 180, eps = 23.4392911 * Double.pi / 180
        let q = SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
        let e = SIMD3(q.x, cos(eps) * q.y + sin(eps) * q.z, -sin(eps) * q.y + cos(eps) * q.z)
        let pole = simd_normalize(simd_float3(Float(e.x), Float(e.z), Float(e.y)))
        node.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: pole)
        return node
    }
}
