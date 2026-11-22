import SwiftUI
import SceneKit
import simd

// MARK: - Galactic Stats

struct GalacticStats {
    let orbitFraction: Double    // 0–1, fraction of current galactic orbit completed
    let heightLY: Double         // approximate light-years above/below galactic plane
    let galacticYears: Double    // galactic years elapsed since J2000 (signed)
}

// MARK: - GalacticScene

final class GalacticScene {
    let scene      = SCNScene()
    let cameraNode = SCNNode()

    // Galactic orbit: 225 Myr, radius 280 scene units
    private let galYearSec: Double = 225_000_000 * 365.25 * 86_400
    private let galR:       CGFloat = 280
    // Vertical bob: 64 Myr, 35 scene units (exaggerated — real ~100 ly in 26 kly orbit)
    private let oscSec: Double  = 64_000_000 * 365.25 * 86_400
    private let oscAmp: CGFloat = 35
    // Ecliptic tilted 60.2° to galactic plane
    private let eclTilt: Double = 60.2 * .pi / 180
    // Solar system planet scale: 2 scene units / AU
    private let auPts: CGFloat = 2.0

    private let root       = SCNNode()
    private var solarMount = SCNNode()
    private var planetNodes: [String: SCNNode] = [:]
    private var trailSegNodes: [SCNNode] = []

    private let trailSegCount  = 5
    private let trailSegPoints = 70
    private let trailLookbackSec: Double = 150_000_000 * 365.25 * 86_400  // 150 Myr — less than one orbit


    private let j2000 = Date(timeIntervalSinceReferenceDate: -978_307_200)

    init() { build() }

    // MARK: Build

    private func build() {
        scene.background.contents = NSColor.black
        scene.rootNode.addChildNode(root)

        // Global ambient — kept low so galactic-center light dominates
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 35
        let ambNode = SCNNode(); ambNode.light = amb
        root.addChildNode(ambNode)

        // Warm omni at galactic center (Sgr A*)
        let galLight = SCNLight()
        galLight.type                  = .omni
        galLight.intensity             = 1000
        galLight.color                 = NSColor(red: 1.0, green: 0.90, blue: 0.70, alpha: 1)
        galLight.attenuationStartDistance = 30
        galLight.attenuationEndDistance   = 700
        let galLightNode = SCNNode(); galLightNode.light = galLight
        root.addChildNode(galLightNode)

        // Camera
        cameraNode.camera              = SCNCamera()
        cameraNode.camera?.zNear       = 1
        cameraNode.camera?.zFar        = 4000
        cameraNode.camera?.fieldOfView = 50
        cameraNode.position            = SCNVector3(0, 120, 380)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        buildGalaxy()
        buildSpiralArms()
        buildGalacticBar()
        buildSolarMount()
        buildLandmarks()
        buildTrailNodes()
    }

    // MARK: Galaxy

    private func buildGalaxy() {
        // Inner disk glow — sits inside the Sun's orbital radius (280 units),
        // representing the dense inner galaxy. SCNTorus is already xz-plane; no rotation needed.
        let diskGeo = SCNTorus(ringRadius: 80, pipeRadius: 55)
        diskGeo.ringSegmentCount = 72; diskGeo.pipeSegmentCount = 24
        addGlow(geo: diskGeo,
                color: NSColor(red: 0.95, green: 0.82, blue: 0.55, alpha: 0.07),
                parent: root, order: -3, rotateFlat: false)

        // Inner bulge
        let bulgeGeo = SCNSphere(radius: 35); bulgeGeo.segmentCount = 24
        addGlow(geo: bulgeGeo,
                color: NSColor(red: 1.0, green: 0.88, blue: 0.65, alpha: 0.09),
                parent: root, order: -3)

        // Sgr A* nucleus
        let sgrGeo = SCNSphere(radius: 2.5); sgrGeo.segmentCount = 16
        let sgrMat = SCNMaterial()
        sgrMat.diffuse.contents  = NSColor(red: 1.0, green: 0.92, blue: 0.55, alpha: 1)
        sgrMat.lightingModel     = .constant
        sgrGeo.materials = [sgrMat]
        root.addChildNode(SCNNode(geometry: sgrGeo))

        buildOrbitRing()
    }

    private func addGlow(geo: SCNGeometry, color: NSColor, parent: SCNNode,
                         order: Int, rotateFlat: Bool = false) {
        let mat = SCNMaterial()
        mat.diffuse.contents    = color
        mat.lightingModel       = .constant
        mat.isDoubleSided       = true
        mat.writesToDepthBuffer = false
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        node.renderingOrder = order
        if rotateFlat { node.eulerAngles.x = .pi / 2 }
        parent.addChildNode(node)
    }

    private func buildOrbitRing() {
        let N = 256
        var verts: [SCNVector3] = []
        var idx:   [Int32]      = []
        let R = Float(galR)
        for i in 0...N {
            let a = Float(i) / Float(N) * 2 * .pi
            verts.append(SCNVector3(R * cos(a), 0, R * sin(a)))
            if i > 0 { idx.append(Int32(i-1)); idx.append(Int32(i)) }
        }
        let geo = SCNGeometry(
            sources: [SCNGeometrySource(vertices: verts)],
            elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(white: 0.4, alpha: 0.35)
        mat.lightingModel    = .constant
        geo.materials = [mat]
        root.addChildNode(SCNNode(geometry: geo))
    }

    // MARK: Solar Mount

    private func buildSolarMount() {
        // Tilt the mount so planets orbit in Earth's ecliptic plane,
        // which is rotated 60.2° relative to the galactic plane.
        solarMount.eulerAngles.x = CGFloat(eclTilt)
        root.addChildNode(solarMount)

        // Sun sphere
        let sunGeo = SCNSphere(radius: 0.9); sunGeo.segmentCount = 24
        let sunMat = SCNMaterial()
        sunMat.diffuse.contents  = NSColor(red: 1.0, green: 0.96, blue: 0.55, alpha: 1)
        sunMat.emission.contents = NSColor(red: 1.0, green: 0.96, blue: 0.55, alpha: 1)
        sunMat.lightingModel     = .constant
        sunGeo.materials = [sunMat]
        solarMount.addChildNode(SCNNode(geometry: sunGeo))

        // Sun halo
        let haloGeo = SCNSphere(radius: 1.6); haloGeo.segmentCount = 16
        addGlow(geo: haloGeo,
                color: NSColor(red: 1.0, green: 0.90, blue: 0.40, alpha: 0.12),
                parent: solarMount, order: 1)

        // Local sun light for planet shading
        let sl = SCNLight(); sl.type = .omni; sl.intensity = 700
        sl.color = NSColor(red: 1.0, green: 0.98, blue: 0.90, alpha: 1)
        let slNode = SCNNode(); slNode.light = sl
        solarMount.addChildNode(slNode)

        buildPlanets()
    }

    private func buildPlanets() {
        let visible: Set<String> = ["Mercury","Venus","Earth","Mars","Jupiter","Saturn","Uranus","Neptune"]
        for body in BodyCatalog.planetsAndDwarfs where visible.contains(body.name) {
            let r = CGFloat(max(0.07, body.radiusEarths * 0.04))
            let geo = SCNSphere(radius: r); geo.segmentCount = 12
            let mat = SCNMaterial()
            mat.diffuse.contents = body.color as? NSColor ?? NSColor.white
            mat.lightingModel    = .phong
            geo.materials = [mat]
            let node = SCNNode(geometry: geo)
            solarMount.addChildNode(node)
            planetNodes[body.name] = node
        }
    }

    // MARK: Trail

    private func buildTrailNodes() {
        for i in 0..<trailSegCount {
            let alpha = CGFloat(1.0 - Double(i) / Double(trailSegCount)) * 0.75
            let mat = SCNMaterial()
            mat.diffuse.contents    = NSColor(red: 0.55, green: 0.80, blue: 1.0, alpha: alpha)
            mat.lightingModel       = .constant
            mat.writesToDepthBuffer = false
            let geo = SCNGeometry(
                sources: [SCNGeometrySource(vertices: [SCNVector3(0,0,0), SCNVector3(0,0,0)])],
                elements: [SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)])
            geo.materials = [mat]
            let node = SCNNode(geometry: geo)
            node.renderingOrder = -1
            root.addChildNode(node)
            trailSegNodes.append(node)
        }
    }

    // MARK: Spiral Arms

    private func buildSpiralArms() {
        // Background disk: faint haze of stars across the galactic disk
        do {
            var verts: [SCNVector3] = []
            for i in 0..<700 {
                let fi    = Double(i)
                let theta = fi * 2.399963
                let r     = Float(80 + (fi / 700) * 440)
                let y     = Float(sin(fi * 0.31) * 30.0 * max(0, 1.0 - Double(r) / 550.0))
                verts.append(SCNVector3(r * Float(cos(theta)), y, r * Float(sin(theta))))
            }
            var idx = (0..<Int32(verts.count)).map { $0 }
            let el = SCNGeometryElement(
                data: Data(bytes: &idx, count: idx.count * MemoryLayout<Int32>.size),
                primitiveType: .point, primitiveCount: verts.count,
                bytesPerIndex: MemoryLayout<Int32>.size)
            el.pointSize = 1.2
            el.minimumPointScreenSpaceRadius = 0.3
            el.maximumPointScreenSpaceRadius = 1.8
            let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [el])
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(white: 0.65, alpha: 0.35)
            mat.lightingModel    = .constant
            geo.materials = [mat]
            let node = SCNNode(geometry: geo)
            node.renderingOrder = -5
            root.addChildNode(node)
        }

        // 4 logarithmic spiral arms, ~13° pitch angle
        // Name / starting angle (radians) / color
        // Sun sits in the Orion Spur between Sagittarius and Perseus arms.
        let b = tan(13.0 * Double.pi / 180.0)
        let armDefs: [(offset: Double, color: NSColor)] = [
            (0,           NSColor(red: 0.90, green: 0.83, blue: 0.58, alpha: 0.55)),  // Norma
            (.pi / 2,     NSColor(red: 0.88, green: 0.80, blue: 0.55, alpha: 0.55)),  // Scutum-Centaurus
            (.pi,         NSColor(red: 0.92, green: 0.88, blue: 0.68, alpha: 0.60)),  // Sagittarius (Sun side)
            (3 * .pi / 2, NSColor(red: 0.70, green: 0.78, blue: 0.92, alpha: 0.52)),  // Perseus (bluer — younger stars)
        ]
        let rInner: Double = 45    // where arms emerge from the bar
        let thetaMax: Double = 3 * .pi  // arms wrap ~1.5 times
        let starsPerArm = 300

        for arm in armDefs {
            var verts: [SCNVector3] = []
            for _ in 0..<starsPerArm {
                let theta = Double.random(in: 0...thetaMax)
                let rBase = rInner * exp(b * theta)
                guard rBase < 490 else { continue }
                let scatter = rBase * 0.09
                let r       = rBase + Double.random(in: -scatter...scatter)
                let angle   = theta + arm.offset + Double.random(in: -0.06...0.06)
                let x = r * cos(angle)
                let z = r * sin(angle)
                let ySpread = 10.0 * max(0, 1.0 - r / 420)
                let y = Double.random(in: -ySpread...ySpread)
                verts.append(SCNVector3(x, y, z))
            }
            guard !verts.isEmpty else { continue }
            var idx = (0..<Int32(verts.count)).map { $0 }
            let el = SCNGeometryElement(
                data: Data(bytes: &idx, count: idx.count * MemoryLayout<Int32>.size),
                primitiveType: .point, primitiveCount: verts.count,
                bytesPerIndex: MemoryLayout<Int32>.size)
            el.pointSize = 1.7
            el.minimumPointScreenSpaceRadius = 0.4
            el.maximumPointScreenSpaceRadius = 2.4
            let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [el])
            let mat = SCNMaterial()
            mat.diffuse.contents = arm.color
            mat.lightingModel    = .constant
            geo.materials = [mat]
            let node = SCNNode(geometry: geo)
            node.renderingOrder = -4
            root.addChildNode(node)
        }

        // Orion Spur — minor arm where the Sun actually lives, between Sag and Perseus
        // Runs at ~Perseus offset - π/4, shorter arc
        do {
            let spurOffset = 3 * Double.pi / 2 - Double.pi / 4
            var verts: [SCNVector3] = []
            let spurTheta = Double.pi * 0.7   // short arc
            let rStart = rInner * exp(b * (Double.pi * 0.85))
            for _ in 0..<100 {
                let theta = Double.random(in: 0...spurTheta)
                let rBase = rStart * exp(b * theta)
                guard rBase < 380 else { continue }
                let r     = rBase + Double.random(in: -rBase * 0.07...rBase * 0.07)
                let angle = theta + spurOffset + Double.random(in: -0.05...0.05)
                let x = r * cos(angle)
                let z = r * sin(angle)
                verts.append(SCNVector3(x, Double.random(in: -6...6), z))
            }
            guard !verts.isEmpty else { return }
            var idx = (0..<Int32(verts.count)).map { $0 }
            let el = SCNGeometryElement(
                data: Data(bytes: &idx, count: idx.count * MemoryLayout<Int32>.size),
                primitiveType: .point, primitiveCount: verts.count,
                bytesPerIndex: MemoryLayout<Int32>.size)
            el.pointSize = 1.5
            el.minimumPointScreenSpaceRadius = 0.4
            el.maximumPointScreenSpaceRadius = 2.0
            let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [el])
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(red: 0.82, green: 0.88, blue: 0.80, alpha: 0.50)
            mat.lightingModel    = .constant
            geo.materials = [mat]
            let node = SCNNode(geometry: geo)
            node.renderingOrder = -4
            root.addChildNode(node)
        }
    }

    // MARK: Galactic Bar

    private func buildGalacticBar() {
        // The Milky Way bar is ~27,000 ly long, oriented ~44° to the Sun–center line.
        // In scene coords at t=0: toward-Sun is +x, so bar runs at 44° in the xz-plane.
        // Visually scaled to ~75 half-length units (bar fills the inner disk).
        let barAngle = 44.0 * Double.pi / 180.0
        let halfLen: Double = 72
        let perpAngle = barAngle + .pi / 2
        var verts: [SCNVector3] = []
        for _ in 0..<120 {
            let s = Double.random(in: -halfLen...halfLen)
            let widthFrac = 1.0 - abs(s) / halfLen
            let w = 14.0 * widthFrac
            let scatter = Double.random(in: -w...w)
            let x = s * cos(barAngle) + scatter * cos(perpAngle)
            let z = s * sin(barAngle) + scatter * sin(perpAngle)
            let y = Double.random(in: -3...3)
            verts.append(SCNVector3(x, y, z))
        }
        var idx = (0..<Int32(verts.count)).map { $0 }
        let el = SCNGeometryElement(
            data: Data(bytes: &idx, count: idx.count * MemoryLayout<Int32>.size),
            primitiveType: .point, primitiveCount: verts.count,
            bytesPerIndex: MemoryLayout<Int32>.size)
        el.pointSize = 2.2
        el.minimumPointScreenSpaceRadius = 0.5
        el.maximumPointScreenSpaceRadius = 3.0
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [el])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(red: 1.0, green: 0.90, blue: 0.62, alpha: 0.60)
        mat.lightingModel    = .constant
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        node.renderingOrder = -3
        root.addChildNode(node)
    }

    // MARK: Landmarks

    private func buildLandmarks() {
        // Scene scale: 280 units = 26,000 ly  →  1 kly = 10.769 units
        // Sun at scene (280, 0, 0) at t=0.
        // Galactic longitude l=0° = toward galactic center = scene (−1, 0, 0) from Sun.
        // l increases counterclockwise viewed from above (+y).
        let klyToUnits = 280.0 / 26.0

        func scenePos(l lDeg: Double, b bDeg: Double, dKly: Double) -> SCNVector3 {
            let l = lDeg * Double.pi / 180
            let b = bDeg * Double.pi / 180
            let dx = -cos(l) * cos(b)
            let dy =  sin(b)
            let dz =  sin(l) * cos(b)
            let d  = dKly * klyToUnits
            return SCNVector3(280.0 + d * dx, d * dy, d * dz)
        }

        struct LM {
            let label: String
            let pos: SCNVector3
            let color: NSColor
            let dot: CGFloat
        }

        let landmarks: [LM] = [
            LM(label: "Orion Nebula",
               pos: scenePos(l: 209, b: -19, dKly: 1.34),
               color: NSColor(red: 0.85, green: 0.55, blue: 1.00, alpha: 1), dot: 1.8),

            LM(label: "Eagle Nebula",
               pos: scenePos(l: 17, b: 1, dKly: 7.0),
               color: NSColor(red: 0.50, green: 0.80, blue: 1.00, alpha: 1), dot: 2.0),

            LM(label: "Crab Nebula",
               pos: scenePos(l: 185, b: -6, dKly: 6.5),
               color: NSColor(red: 0.65, green: 0.85, blue: 1.00, alpha: 1), dot: 1.8),

            LM(label: "ω Centauri",
               pos: scenePos(l: 309, b: 15, dKly: 17.0),
               color: NSColor(red: 1.00, green: 0.90, blue: 0.55, alpha: 1), dot: 2.4),

            LM(label: "47 Tucanae",
               pos: scenePos(l: 306, b: -45, dKly: 14.7),
               color: NSColor(red: 1.00, green: 0.85, blue: 0.50, alpha: 1), dot: 2.0),

            LM(label: "Anticenter",
               pos: scenePos(l: 180, b: 0, dKly: 24.0),
               color: NSColor(red: 0.50, green: 0.60, blue: 0.70, alpha: 0.75), dot: 1.4),
        ]

        for lm in landmarks {
            // Glowing dot
            let dotGeo = SCNSphere(radius: lm.dot)
            dotGeo.segmentCount = 8
            let dotMat = SCNMaterial()
            dotMat.diffuse.contents = lm.color
            dotMat.lightingModel    = .constant
            dotGeo.materials = [dotMat]
            let dotNode = SCNNode(geometry: dotGeo)
            dotNode.position = lm.pos
            dotNode.name = "lm_\(lm.label)"   // used by hit-test for landmark info
            root.addChildNode(dotNode)

            // Billboard text label
            let text = SCNText(string: lm.label, extrusionDepth: 0)
            text.font     = NSFont.systemFont(ofSize: 6, weight: .light)
            text.flatness = 0.5
            let txtMat = SCNMaterial()
            txtMat.diffuse.contents = lm.color.withAlphaComponent(0.88)
            txtMat.lightingModel    = .constant
            text.materials = [txtMat]
            let textNode = SCNNode(geometry: text)
            textNode.scale = SCNVector3(0.42, 0.42, 0.42)
            textNode.position = SCNVector3(lm.pos.x + lm.dot + 1.5,
                                           lm.pos.y + 1.5,
                                           lm.pos.z)
            let bb = SCNBillboardConstraint()
            bb.freeAxes = .all
            textNode.constraints = [bb]
            root.addChildNode(textNode)
        }

        // "Solar System" label — child of solarMount, moves with the sun
        let solarText = SCNText(string: "Solar System", extrusionDepth: 0)
        solarText.font    = NSFont.systemFont(ofSize: 6, weight: .medium)
        solarText.flatness = 0.5
        let solarMat = SCNMaterial()
        solarMat.diffuse.contents = NSColor(red: 1.0, green: 0.96, blue: 0.55, alpha: 0.92)
        solarMat.lightingModel    = .constant
        solarText.materials = [solarMat]
        let solarTextNode = SCNNode(geometry: solarText)
        solarTextNode.scale = SCNVector3(0.42, 0.42, 0.42)
        solarTextNode.position = SCNVector3(2, 3, 0)
        let solarBB = SCNBillboardConstraint()
        solarBB.freeAxes = .all
        solarTextNode.constraints = [solarBB]
        solarMount.addChildNode(solarTextNode)
    }

    // MARK: Update

    func update(date: Date) {
        let t   = date.timeIntervalSince(j2000)
        let pos = galPos(t: t)
        solarMount.position = pos

        let visible: Set<String> = ["Mercury","Venus","Earth","Mars","Jupiter","Saturn","Uranus","Neptune"]
        for body in BodyCatalog.planetsAndDwarfs where visible.contains(body.name) {
            guard let node = planetNodes[body.name] else { continue }
            let (px, pz) = keplerXZ(body: body, t: t, scale: Double(auPts))
            node.position = SCNVector3(px, 0, pz)
        }

        updateTrail(t: t)
    }

    private func galPos(t: Double) -> SCNVector3 {
        let omG = 2.0 * .pi / galYearSec
        let omO = 2.0 * .pi / oscSec
        let gx  = Double(galR) * cos(omG * t)
        let gz  = Double(galR) * sin(omG * t)
        let gy  = Double(oscAmp) * sin(omO * t)
        return SCNVector3(gx, gy, gz)
    }

    private func keplerXZ(body: BodyDef, t: Double, scale: Double) -> (Double, Double) {
        let n   = 2.0 * .pi / body.orbitalPeriodSeconds
        var M   = body.meanAnomalyAtEpoch + n * t
        M       = M.truncatingRemainder(dividingBy: 2 * .pi)
        var E   = M
        for _ in 0..<5 { E = M + body.eccentricity * sin(E) }
        let sqp  = sqrt(1 + body.eccentricity)
        let sqm  = sqrt(1 - body.eccentricity)
        let halfE = E / 2
        let nu   = 2.0 * atan2(sqp * sin(halfE), sqm * cos(halfE))
        let rAU  = body.semiMajorAxisAU * (1 - body.eccentricity * cos(E))
        let r    = rAU * scale
        let ang  = nu + body.argOfPerihelionRad
        return (r * cos(ang), r * sin(ang))
    }

    private func updateTrail(t: Double) {
        let segDur = trailLookbackSec / Double(trailSegCount)
        let ptStep = segDur / Double(trailSegPoints)

        for si in 0..<trailSegCount {
            let segStart = t - Double(si + 1) * segDur
            let verts = (0...trailSegPoints).map { pi -> SCNVector3 in
                galPos(t: segStart + Double(pi) * ptStep)
            }
            var idx: [Int32] = []
            for pi in 0..<trailSegPoints { idx.append(Int32(pi)); idx.append(Int32(pi + 1)) }

            let alpha = CGFloat(1.0 - Double(si) / Double(trailSegCount)) * 0.75
            let mat = SCNMaterial()
            mat.diffuse.contents    = NSColor(red: 0.55, green: 0.80, blue: 1.0, alpha: alpha)
            mat.lightingModel       = .constant
            mat.writesToDepthBuffer = false

            let geo = SCNGeometry(
                sources: [SCNGeometrySource(vertices: verts)],
                elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            geo.materials = [mat]
            trailSegNodes[si].geometry = geo
        }
    }
}

// MARK: - GalacticSCNView (zoom + orbit camera + landmark tap)

final class GalacticSCNView: SCNView {
    var onLandmarkTapped: ((String?) -> Void)?
    private var mouseDownLoc: CGPoint = .zero

    override func scrollWheel(with event: NSEvent) {
        guard let camera = pointOfView?.camera else { return }
        let newFOV = (camera.fieldOfView - event.deltaY * 1.5).clamped(to: 15...110)
        camera.fieldOfView = newFOV
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLoc = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dx = loc.x - mouseDownLoc.x
        let dy = loc.y - mouseDownLoc.y
        guard dx * dx + dy * dy < 25 else { return }  // was a drag, not a click
        let hits = hitTest(loc, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        for hit in hits {
            if let name = hit.node.name, name.hasPrefix("lm_") {
                onLandmarkTapped?(String(name.dropFirst(3)))
                return
            }
        }
        onLandmarkTapped?(nil)  // tap on background = dismiss
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pov = pointOfView else { return }
        let s: CGFloat = 0.005
        let dx = event.deltaX, dy = event.deltaY
        let yaw   = SCNMatrix4MakeRotation(-dx * s, 0, 1, 0)
        let right = SCNVector3(pov.transform.m11, pov.transform.m21, pov.transform.m31)
        let pitch = SCNMatrix4MakeRotation(-dy * s, right.x, right.y, right.z)
        let mat   = SCNMatrix4Mult(pitch, yaw)
        let p     = pov.position
        let len   = sqrt(p.x*p.x + p.y*p.y + p.z*p.z)
        var np = SCNVector3(
            p.x * mat.m11 + p.y * mat.m21 + p.z * mat.m31,
            p.x * mat.m12 + p.y * mat.m22 + p.z * mat.m32,
            p.x * mat.m13 + p.y * mat.m23 + p.z * mat.m33)
        let nl = sqrt(np.x*np.x + np.y*np.y + np.z*np.z)
        if nl > 0.001 {
            let scale = CGFloat(len / nl)
            np = SCNVector3(np.x * scale, np.y * scale, np.z * scale)
        }
        pov.position = np
        pov.look(at: SCNVector3(0, 0, 0))
    }

    override func rightMouseDragged(with event: NSEvent) { /* swallow — keep pivot at origin */ }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(range.upperBound, self))
    }
}

// MARK: - GalacticContainer (NSViewRepresentable)

struct GalacticContainer: NSViewRepresentable {
    var simulationDate: Date
    var onLandmarkTapped: ((String?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GalacticSCNView {
        let view = GalacticSCNView()
        let gal  = GalacticScene()
        view.scene                      = gal.scene
        view.pointOfView                = gal.cameraNode
        view.backgroundColor            = .black
        view.autoenablesDefaultLighting = false
        view.antialiasingMode           = .multisampling4X
        view.allowsCameraControl        = false
        context.coordinator.galactic    = gal
        context.coordinator.container   = self
        view.onLandmarkTapped = { name in
            context.coordinator.container?.onLandmarkTapped?(name)
        }
        gal.update(date: simulationDate)
        return view
    }

    func updateNSView(_ nsView: GalacticSCNView, context: Context) {
        context.coordinator.container = self
        context.coordinator.galactic?.update(date: simulationDate)
    }

    final class Coordinator {
        var galactic: GalacticScene?
        var container: GalacticContainer?
    }
}

// MARK: - Landmark Info Database

struct LandmarkInfo: Identifiable {
    let id: String
    let name: String
    let kind: String
    let distance: String
    let body: String
}

private let landmarkDatabase: [String: LandmarkInfo] = [
    "Orion Nebula": LandmarkInfo(
        id: "orion", name: "Orion Nebula", kind: "Stellar Nursery",
        distance: "1,344 light-years from us",
        body: "One of the most-studied star-forming regions in the sky. A vast cloud of gas and dust where new stars are being born right now. Visible to the naked eye as a hazy patch in Orion's sword — but it spans 24 light-years across."),

    "Eagle Nebula": LandmarkInfo(
        id: "eagle", name: "Eagle Nebula", kind: "Emission Nebula + Star Cluster",
        distance: "~7,000 light-years from us",
        body: "Home of the famous Pillars of Creation — towering columns of gas and dust first photographed by Hubble in 1995. The dense tips of the pillars are stellar incubators, with new stars forming inside. The cluster illuminating the nebula is only 1–2 million years old."),

    "Crab Nebula": LandmarkInfo(
        id: "crab", name: "Crab Nebula", kind: "Supernova Remnant",
        distance: "~6,500 light-years from us",
        body: "The expanding wreckage of a massive star that exploded on July 4, 1054 AD — bright enough that Chinese and Arab astronomers recorded it visible in daylight for 23 days. At its center spins a pulsar: a neutron star just 30 km across, rotating 30 times per second, blasting the nebula with radiation."),

    "ω Centauri": LandmarkInfo(
        id: "omega-cen", name: "Omega Centauri", kind: "Globular Cluster",
        distance: "~17,000 light-years from us",
        body: "The largest and most massive globular cluster in the Milky Way — containing roughly 10 million stars packed into a sphere 150 light-years across. Its age (~12 billion years) and the presence of multiple stellar generations suggest it may be the stripped core of a dwarf galaxy swallowed by the Milky Way long ago."),

    "47 Tucanae": LandmarkInfo(
        id: "47tuc", name: "47 Tucanae", kind: "Globular Cluster",
        distance: "~14,700 light-years from us",
        body: "The second most massive globular cluster in our galaxy, containing about 1 million stars in a sphere 120 light-years across. Visible to the naked eye from the southern hemisphere, it appears just west of the Small Magellanic Cloud. Hosts 22 confirmed millisecond pulsars — dense neutron stars left over from ancient supernovae."),

    "Anticenter": LandmarkInfo(
        id: "anticenter", name: "Galactic Anticenter", kind: "Direction Marker",
        distance: "Looking toward constellation Auriga",
        body: "The direction exactly opposite the galactic center — toward the outer edge of the Milky Way disk. When you look this way from Earth, you're peering through the thinner, less-crowded outer arm into open space beyond. The galactic disk is only ~1,000 light-years thick here, vs. ~3,000 light-years near the center."),
]

// MARK: - GalacticView

struct GalacticView: View {
    var simulationDate: Date

    @State private var selectedLandmark: LandmarkInfo? = nil

    private let galYearSec: Double = 225_000_000 * 365.25 * 86_400
    private let oscSec:     Double = 64_000_000  * 365.25 * 86_400
    private let oscAmp:     Double = 35.0
    private let j2000 = Date(timeIntervalSinceReferenceDate: -978_307_200)

    var body: some View {
        ZStack {
            GalacticContainer(simulationDate: simulationDate) { name in
                if let n = name, !n.isEmpty {
                    selectedLandmark = landmarkDatabase[n]
                } else {
                    selectedLandmark = nil
                }
            }
            .ignoresSafeArea()

            VStack {
                Text(galacticDateLabel(simulationDate))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 10)
                Spacer()
            }

            VStack {
                Spacer()
                statsCard
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let lm = selectedLandmark {
                VStack {
                    Spacer()
                    landmarkCard(lm)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedLandmark?.id)
    }

    private func galacticDateLabel(_ date: Date) -> String {
        let t  = date.timeIntervalSince(j2000)
        let yr = t / (365.25 * 86_400)
        let a  = abs(yr)
        if a < 2_000 {
            let cal = Int(2000.0 + yr)
            return cal < 0 ? "Year \(-cal) BC" : "Year \(cal) AD"
        } else if a < 1_000_000 {
            return String(format: "%+.1f kyr", yr / 1_000)
        } else if a < 1_000_000_000 {
            return String(format: "%+.2f Myr", yr / 1_000_000)
        } else {
            return String(format: "%+.3f Gyr", yr / 1_000_000_000)
        }
    }

    private func landmarkCard(_ lm: LandmarkInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lm.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(lm.kind)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { selectedLandmark = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(lm.distance)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.cyan)
            Divider()
            Text(lm.body)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statsCard: some View {
        let s = computeStats()
        return VStack(alignment: .leading, spacing: 4) {
            Text("GALACTIC POSITION")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(String(format: "Orbit: %.2f%%", s.orbitFraction * 100))
                .font(.system(size: 11, design: .monospaced))
            Text(String(format: "Height: %+.0f ly", s.heightLY))
                .font(.system(size: 11, design: .monospaced))
            Text(String(format: "%.4f galactic years", abs(s.galacticYears)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func computeStats() -> GalacticStats {
        let t    = simulationDate.timeIntervalSince(j2000)
        let omG  = 2.0 * .pi / galYearSec
        let omO  = 2.0 * .pi / oscSec
        var frac = (omG * t).truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)
        if frac < 0 { frac += 1 }
        let heightLY   = oscAmp * sin(omO * t) * (100.0 / oscAmp)
        let galacticYr = t / galYearSec
        return GalacticStats(orbitFraction: frac, heightLY: heightLY, galacticYears: galacticYr)
    }
}
