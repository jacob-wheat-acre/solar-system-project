import Foundation
import SceneKit
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// SceneKit view of a `SandboxSimulation`. Sim coordinates (AU, z = up) map to scene
/// axes as (x, z, y) × `scale`, like the rest of the app. Bodies are drawn at true size
/// with a minimum on-screen size. Black holes get a glowing photon-sphere ring
/// (1.5 r_s, always facing the camera) and a faint ISCO circle (3 r_s, the innermost
/// stable circular orbit).
final class SandboxScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let scale: Double

    private let root = SCNNode()
    private let skyNode = CelestialSky.makeNode()
    private var bodyNodes: [Int: SCNNode] = [:]
    private var bodyKind: [Int: SandboxBodyKind] = [:]
    private var trueRadius: [Int: Float] = [:]
    private var names: [Int: String] = [:]
    private var lights: [Int: SCNNode] = [:]
    private let trailNode = SCNNode()
    private let grid: GravityGrid
    private let extent: Float

    var showTrails = true { didSet { trailNode.isHidden = !showTrails } }
    var showGrid = true { didSet { grid.node.isHidden = !showGrid } }

    init(scenario: SandboxScenario) {
        scale = scenario.sceneUnitsPerAU
        var maxR = 0.0
        for b in scenario.bodies { maxR = max(maxR, simd_length(b.position)) }
        extent = Float(max(maxR, scenario.gridHalfSizeAU) * scale)
        grid = GravityGrid(halfSize: Float(scenario.gridHalfSizeAU * scale))

        scene.background.contents = NSColorLike.black
        scene.rootNode.addChildNode(skyNode)
        scene.rootNode.addChildNode(root)
        root.addChildNode(trailNode)
        root.addChildNode(grid.node)

        let camera = SCNCamera()
        camera.fieldOfView = 60
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode(); ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = NSColorLike(white: 0.18, alpha: 1)
        scene.rootNode.addChildNode(ambient)
    }

    func scenePosition(_ p: SIMD3<Double>) -> SCNVector3 {
        SCNVector3(SCNFloat(p.x * scale), SCNFloat(p.z * scale), SCNFloat(p.y * scale))
    }

    func position(of id: Int) -> SCNVector3 { bodyNodes[id]?.position ?? SCNVector3Zero }

    // MARK: Per-frame update

    func update(sim: SandboxSimulation) {
        let alive = Set(sim.bodies.map(\.id))
        for (id, node) in bodyNodes where !alive.contains(id) {
            node.removeFromParentNode(); lights[id]?.removeFromParentNode()
            bodyNodes[id] = nil; lights[id] = nil
        }
        for b in sim.bodies {
            if bodyNodes[b.id] == nil || bodyKind[b.id] != b.kind { addBody(b, sim: sim) }
            trueRadius[b.id] = Float(sim.effectiveRadius(b) * scale)
            let p = scenePosition(b.position)
            bodyNodes[b.id]?.position = p
            lights[b.id]?.position = p
        }
        if showTrails { updateTrails(sim) }
        if showGrid { grid.update(sim: sim, scale: scale) }
    }

    /// Keeps bodies a minimum on-screen size and the sky at infinity.
    func updateForCamera(distance: Float) {
        let cam = cameraNode.worldPosition
        let camera = cameraNode.camera!
        camera.zNear = Double(max(1e-6, distance * 0.005))
        let skyR = 4 * (extent + distance)
        camera.zFar = Double(skyR * 2)
        CelestialSky.follow(skyNode, camera: cam, farRadius: skyR)
        for (id, node) in bodyNodes {
            let d = simd_distance(simd_float3(node.worldPosition), simd_float3(cam))
            let minFrac: Float = switch bodyKind[id] {
            case .star?: 0.009
            case .blackHole?: 0.007
            case .neutronStar?: 0.005
            default: 0.0045
            }
            let r = max(trueRadius[id] ?? 0, minFrac * d)
            node.scale = SCNVector3(SCNFloat(r), SCNFloat(r), SCNFloat(r))
        }
    }

    func labelAnchors() -> [(name: String, node: SCNNode)] {
        bodyNodes.compactMap { id, node in names[id].map { ($0, node) } }
    }

    // MARK: Bodies

    private func color(_ c: SIMD3<Float>) -> NSColorLike {
        NSColorLike(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    private func addBody(_ b: SandboxBody, sim: SandboxSimulation) {
        bodyNodes[b.id]?.removeFromParentNode(); lights[b.id]?.removeFromParentNode(); lights[b.id] = nil
        let node = SCNNode()
        let sphere = SCNSphere(radius: 1); sphere.segmentCount = 48
        let mat = SCNMaterial()
        switch b.kind {
        case .blackHole:
            mat.diffuse.contents = NSColorLike.black
            mat.lightingModel = .constant
            sphere.materials = [mat]
            node.addChildNode(SCNNode(geometry: sphere))
            // Photon sphere: light can orbit here. Drawn as a ring that faces the camera.
            let ring = SCNTorus(ringRadius: 1.5, pipeRadius: 0.07)
            let rm = SCNMaterial()
            rm.diffuse.contents = NSColorLike(red: 1, green: 0.62, blue: 0.25, alpha: 1)
            rm.lightingModel = .constant; rm.blendMode = .add
            ring.materials = [rm]
            let ringNode = SCNNode(geometry: ring)
            ringNode.eulerAngles.x = .pi / 2
            let facing = SCNNode(); facing.addChildNode(ringNode)
            facing.constraints = [SCNBillboardConstraint()]
            node.addChildNode(facing)
            // ISCO: nothing can orbit stably inside 3 r_s.
            let isco = SCNNode(geometry: SceneLines.circle(
                radius: 3, material: SceneLines.material(NSColorLike(red: 1, green: 0.5, blue: 0.3, alpha: 0.35))))
            node.addChildNode(isco)
        case .neutronStar:
            mat.diffuse.contents = color(b.color)
            mat.emission.contents = color(b.color)
            mat.lightingModel = .constant
            sphere.materials = [mat]
            node.addChildNode(SCNNode(geometry: sphere))
        case .star:
            mat.diffuse.contents = color(b.color)
            mat.emission.contents = color(b.color)
            mat.lightingModel = .constant
            sphere.materials = [mat]
            node.addChildNode(SCNNode(geometry: sphere))
            let light = SCNNode(); light.light = SCNLight()
            light.light!.type = .omni
            light.light!.color = color(simd_mix(b.color, SIMD3(1, 1, 1), SIMD3(repeating: 0.5)))
            root.addChildNode(light)
            lights[b.id] = light
        case .planet, .moon:
            mat.diffuse.contents = color(b.color)
            sphere.materials = [mat]
            node.addChildNode(SCNNode(geometry: sphere))
        }
        root.addChildNode(node)
        bodyNodes[b.id] = node
        bodyKind[b.id] = b.kind
        names[b.id] = b.name
    }

    // MARK: Trails

    private var trailGeometryCache: [Int: SCNNode] = [:]

    private func updateTrails(_ sim: SandboxSimulation) {
        let alive = Set(sim.bodies.map(\.id))
        for (id, n) in trailGeometryCache where !alive.contains(id) { n.removeFromParentNode(); trailGeometryCache[id] = nil }
        for b in sim.bodies {
            guard var pts = sim.trails[b.id], pts.count > 1 else { continue }
            pts.append(b.position)
            // Fade from transparent (oldest) to the body colour (newest), drawn additively.
            var verts: [SCNVector3] = [], colors: [SIMD4<Float>] = []
            verts.reserveCapacity(pts.count); colors.reserveCapacity(pts.count)
            let c = b.kind == .blackHole ? SIMD3<Float>(1, 0.6, 0.3) : b.color
            for (k, p) in pts.enumerated() {
                verts.append(scenePosition(p))
                let f = Float(k) / Float(pts.count - 1)
                colors.append(SIMD4(c * (0.08 + 0.75 * f * f), 1))
            }
            var idx: [Int32] = []; idx.reserveCapacity(verts.count * 2)
            for i in 0..<(verts.count - 1) { idx += [Int32(i), Int32(i + 1)] }
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                                usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), colorSource],
                                elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            let node = trailGeometryCache[b.id] ?? {
                let n = SCNNode(); trailNode.addChildNode(n); trailGeometryCache[b.id] = n; return n
            }()
            let m = node.geometry?.firstMaterial ?? {
                let m = SceneLines.material(.white); m.blendMode = .add; m.readsFromDepthBuffer = true; return m
            }()
            g.materials = [m]
            node.geometry = g
        }
    }
}

/// A sheet whose depth shows the gravitational potential: the "rubber sheet" picture of
/// gravity. It is a visualization of potential, not literal curved spacetime. Depth is
/// proportional to the potential (so a planet's dimple is honestly tiny next to its star's
/// well), flat at the edges, and each mass is softened over about one grid cell (or its radius).
final class GravityGrid {
    let node = SCNNode()
    /// Faint vertical lines from each body down to its spot on the sheet.
    private let drops = SCNNode()
    private let dropMaterial: SCNMaterial
    private let n: Int = 121
    private let halfSize: Float
    private let element: SCNGeometryElement
    private let colorSource: SCNGeometrySource
    private let material: SCNMaterial
    private var xs: [Float]

    init(halfSize: Float) {
        self.halfSize = halfSize
        let n = self.n
        xs = (0..<n).map { -halfSize + 2 * halfSize * Float($0) / Float(n - 1) }
        var idx: [Int32] = []
        for r in 0..<n { for c in 0..<(n - 1) {
            idx += [Int32(r * n + c), Int32(r * n + c + 1)]
            idx += [Int32(c * n + r), Int32((c + 1) * n + r)]
        }}
        element = SCNGeometryElement(indices: idx, primitiveType: .line)
        // Fade toward the edges.
        var colors: [SIMD4<Float>] = []
        for r in 0..<n { for c in 0..<n {
            let u = Float(r) / Float(n - 1) * 2 - 1, v = Float(c) / Float(n - 1) * 2 - 1
            let edge = max(0, 1 - pow(max(abs(u), abs(v)), 3))
            colors.append(SIMD4(SIMD3<Float>(0.25, 0.45, 0.85) * 0.38 * edge, 1))
        }}
        colorSource = SCNGeometrySource(data: colors.withUnsafeBufferPointer { Data(buffer: $0) },
                                        semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                        componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        material = SceneLines.material(.white)
        material.blendMode = .add
        material.readsFromDepthBuffer = true
        dropMaterial = SceneLines.material(NSColorLike(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.45))
        node.addChildNode(drops)
    }

    func update(sim: SandboxSimulation, scale: Double) {
        let bodies = sim.bodies
        guard !bodies.isEmpty else { return }
        let cell = 2 * halfSize / Float(n - 1)
        let src: [(x: Float, z: Float, m: Float, eps2: Float)] = bodies.map {
            let p = SIMD3<Float>(Float($0.position.x * scale), Float($0.position.z * scale), Float($0.position.y * scale))
            let eps = max(cell * 1.6, Float(sim.effectiveRadius($0) * scale))
            return (p.x, p.z, Float($0.mass), eps * eps)
        }
        let mTot = src.reduce(0) { $0 + $1.m }
        // Edge potential (Φ0) maps to the flat plane, the deepest well to `depth` below it.
        let phi0 = mTot / halfSize
        let phiMax = src.map { $0.m / sqrt($0.eps2) }.max() ?? phi0
        let depth = halfSize * 0.18
        let norm = max(phiMax - phi0, 1e-30)
        let planeY = -halfSize * 0.01
        var verts = [SCNVector3](); verts.reserveCapacity(n * n)
        for r in 0..<n {
            let x = xs[r]
            for c in 0..<n {
                let z = xs[c]
                var phi: Float = 0
                for s in src {
                    let dx = x - s.x, dz = z - s.z
                    phi += s.m / sqrt(dx * dx + dz * dz + s.eps2)
                }
                let y = planeY - depth * max(0, phi - phi0) / norm
                verts.append(SCNVector3(SCNFloat(x), SCNFloat(y), SCNFloat(z)))
            }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), colorSource], elements: [element])
        g.materials = [material]
        node.geometry = g

        var dropPts: [SCNVector3] = []
        for b in bodies {
            let x = Float(b.position.x * scale), y = Float(b.position.z * scale), z = Float(b.position.y * scale)
            guard abs(x) < halfSize, abs(z) < halfSize else { continue }
            var phi: Float = 0
            for s in src { let dx = x - s.x, dz = z - s.z; phi += s.m / sqrt(dx * dx + dz * dz + s.eps2) }
            let surface = planeY - depth * max(0, phi - phi0) / norm
            dropPts += [SCNVector3(SCNFloat(x), SCNFloat(y), SCNFloat(z)), SCNVector3(SCNFloat(x), SCNFloat(surface), SCNFloat(z))]
        }
        if dropPts.isEmpty { drops.geometry = nil; return }
        let dg = SCNGeometry(sources: [SCNGeometrySource(vertices: dropPts)],
                             elements: [SCNGeometryElement(indices: (0..<Int32(dropPts.count)).map { $0 }, primitiveType: .line)])
        dg.materials = [dropMaterial]
        drops.geometry = dg
    }
}
