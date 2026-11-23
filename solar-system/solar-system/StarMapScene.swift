import Foundation
import SceneKit
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The nearby-star map: every catalogued star within 50 light-years at its measured
/// position, in galactic coordinates (Sun at the origin, the galactic plane horizontal,
/// the galactic centre toward +x). 1 light-year = 1 scene unit.
final class StarMapScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let stars = StarCatalog.all

    private let root = SCNNode()
    private let guides = SCNNode()
    private let selectionNode = SCNNode()
    private let tripNode = SCNNode()
    private let shipNode = SCNNode()
    private var anchors: [String: SCNNode] = [:]
    private(set) var positions: [SCNVector3] = []

    var showGuides = true { didSet { guides.isHidden = !showGuides } }

    init() {
        scene.background.contents = NSColorLike.black
        scene.rootNode.addChildNode(root)
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.05
        camera.zFar = 2000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        positions = stars.map { Self.scenePosition($0) }
        buildStars()
        buildGuides()
        for (s, p) in zip(stars, positions) {
            let n = SCNNode(); n.position = p
            anchors[s.name] = n
            root.addChildNode(n)
        }

        selectionNode.geometry = Self.screenCircle(material: SceneLines.material(NSColorLike(red: 1, green: 0.85, blue: 0.4, alpha: 1)))
        selectionNode.constraints = [SCNBillboardConstraint()]
        selectionNode.isHidden = true
        root.addChildNode(selectionNode)

        root.addChildNode(tripNode)
        let ship = SCNSphere(radius: 1)
        ship.firstMaterial = SceneLines.material(NSColorLike(red: 0.4, green: 0.95, blue: 1, alpha: 1))
        shipNode.geometry = ship
        shipNode.isHidden = true
        root.addChildNode(shipNode)
    }

    /// Galactic (x to the centre, z to the north pole) → scene (y up).
    static func scenePosition(_ s: NearbyStar) -> SCNVector3 {
        let g = s.galactic
        return SCNVector3(SCNFloat(g.x), SCNFloat(g.z), SCNFloat(-g.y))
    }

    func position(of name: String) -> SCNVector3? { anchors[name]?.position }

    // MARK: Building

    private func buildStars() {
        // Grouped by luminosity so brighter stars draw as bigger points.
        let buckets: [(maxLum: Double, radius: CGFloat)] = [(0.003, 1.1), (0.1, 1.7), (2, 2.5), (25, 3.5), (.infinity, 4.6)]
        var groups = Array(repeating: [Int](), count: buckets.count)
        for (i, s) in stars.enumerated() {
            let lum = s.lum ?? 0.01
            let b = buckets.firstIndex { lum < $0.maxLum } ?? buckets.count - 1
            groups[b].append(i)
        }
        for (b, idx) in groups.enumerated() where !idx.isEmpty {
            var colors: [Float] = []
            for i in idx {
                // Saturated a little: true blackbody colours look almost white as tiny points.
                let raw = StarCatalog.blackbody(stars[i].temperature)
                let grey = (raw.x + raw.y + raw.z) / 3
                let c = simd_clamp(grey + (raw - grey) * 1.8, SIMD3(repeating: 0), SIMD3(repeating: 1))
                colors += [c.x, c.y, c.z, 1]
            }
            let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorSource = SCNGeometrySource(data: data, semantic: .color, vectorCount: idx.count,
                                                usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let el = SCNGeometryElement(indices: (0..<Int32(idx.count)).map { $0 }, primitiveType: .point)
            el.pointSize = 0.25
            el.minimumPointScreenSpaceRadius = buckets[b].radius
            el.maximumPointScreenSpaceRadius = buckets[b].radius * 2.2
            let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: idx.map { positions[$0] }), colorSource], elements: [el])
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = NSColorLike.white
            geo.materials = [m]
            root.addChildNode(SCNNode(geometry: geo))
        }
    }

    /// Distance rings every 10 ly in the galactic plane, a line toward the galactic
    /// centre, and a drop line from each star to the plane.
    private func buildGuides() {
        root.addChildNode(guides)
        for r in stride(from: 10, through: 50, by: 10) {
            let ring = SCNNode(geometry: SceneLines.circle(radius: Float(r), segments: 160,
                material: SceneLines.material(NSColorLike(red: 0.45, green: 0.6, blue: 1, alpha: r == 50 ? 0.3 : 0.16))))
            guides.addChildNode(ring)
            let label = SCNNode(); label.position = SCNVector3(0, 0, SCNFloat(r))
            label.name = "\(r) ly"
            guides.addChildNode(label)
            anchors["\(r) ly"] = label
        }
        let toCentre = SCNNode(geometry: SceneLines.geometry([SCNVector3(0, 0, 0), SCNVector3(56, 0, 0)],
            material: SceneLines.material(NSColorLike(red: 1, green: 0.8, blue: 0.5, alpha: 0.35))))
        guides.addChildNode(toCentre)
        let centreLabel = SCNNode(); centreLabel.position = SCNVector3(56, 0, 0)
        guides.addChildNode(centreLabel)
        anchors["→ Galactic centre (26,000 ly)"] = centreLabel

        // Only for well-known stars: a line from every one of ~1,000 turns into a curtain.
        let notable = Set(StarCatalog.notable.map(\.name))
        var drops: [SCNVector3] = []
        for (s, p) in zip(stars, positions) where notable.contains(s.name) && abs(Float(p.y)) > 0.3 {
            drops += [p, SCNVector3(p.x, 0, p.z)]
        }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: drops)],
                              elements: [SCNGeometryElement(indices: (0..<Int32(drops.count)).map { $0 }, primitiveType: .line)])
        geo.materials = [SceneLines.material(NSColorLike(white: 1, alpha: 0.09))]
        guides.addChildNode(SCNNode(geometry: geo))
    }

    /// A unit circle facing +z (billboarded to face the camera).
    private static func screenCircle(material: SCNMaterial) -> SCNGeometry {
        let pts = (0...48).map { k -> SCNVector3 in
            let a = Float(k) / 48 * 2 * .pi
            return SCNVector3(SCNFloat(cos(a)), SCNFloat(sin(a)), 0)
        }
        return SceneLines.geometry(pts, material: material)
    }

    // MARK: Updates

    func select(_ name: String?) {
        guard let name, let p = position(of: name) else { selectionNode.isHidden = true; return }
        selectionNode.position = p
        selectionNode.isHidden = false
    }

    /// The trip line, and the ship `fraction` of the way along (nil hides it).
    func showTrip(from: String?, to: String?, fraction: Double?) {
        tripNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let from, let to, from != to, let a = position(of: from), let b = position(of: to) else {
            shipNode.isHidden = true; return
        }
        let line = SceneLines.geometry([a, b], material: SceneLines.material(NSColorLike(red: 0.4, green: 0.95, blue: 1, alpha: 0.7)))
        tripNode.addChildNode(SCNNode(geometry: line))
        if let f = fraction {
            let t = SCNFloat(f)
            shipNode.position = SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
            shipNode.isHidden = false
        } else {
            shipNode.isHidden = true
        }
    }

    /// Keeps the selection ring and ship a constant size on screen.
    func updateForCamera() {
        let cam = simd_float3(cameraNode.worldPosition)
        let ds = simd_distance(simd_float3(selectionNode.worldPosition), cam)
        let r = SCNFloat(ds * 0.022)
        selectionNode.scale = SCNVector3(r, r, r)
        let dShip = simd_distance(simd_float3(shipNode.worldPosition), cam)
        let s = SCNFloat(dShip * 0.006)
        shipNode.scale = SCNVector3(s, s, s)
    }

    /// Labels: well-known stars near the point of interest, plus the Sun, the selection,
    /// the trip's ends and the guides.
    func labelAnchors(center: SCNVector3, cameraDistance: Float, always: Set<String>, guidesOn: Bool) -> [(name: String, node: SCNNode)] {
        let c = simd_float3(center)
        let reach = max(9, cameraDistance * 0.45)
        var out: [(String, SCNNode)] = []
        for s in StarCatalog.notable {
            guard let n = anchors[s.name] else { continue }
            if always.contains(s.name) || s.isSun || simd_distance(simd_float3(n.position), c) < reach {
                out.append((s.displayName, n))
            }
        }
        for name in always where !out.contains(where: { $0.0 == name }) {
            if let n = anchors[name], let s = StarCatalog.star(name) { out.append((s.displayName, n)) }
        }
        if guidesOn {
            for (name, n) in anchors where name.hasSuffix(" ly") || name.hasPrefix("→") { out.append((name, n)) }
        }
        return out
    }

    /// The star drawn nearest to a screen point, within `radius` points.
    func pick(in view: SCNView, at point: CGPoint, radius: CGFloat = 22) -> NearbyStar? {
        var best: Int?, bestD = radius
        for (i, p) in positions.enumerated() {
            let s = view.projectPoint(p)
            guard s.z > 0, s.z < 1 else { continue }
            let d = hypot(CGFloat(s.x) - point.x, CGFloat(s.y) - point.y)
            if d < bestD { bestD = d; best = i }
        }
        return best.map { stars[$0] }
    }
}
