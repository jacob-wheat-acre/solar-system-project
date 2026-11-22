import Foundation
import SceneKit

#if os(macOS)
private typealias SceneFloat = CGFloat
#else
private typealias SceneFloat = Float
#endif

enum ObservationMode: String, CaseIterable, Identifiable {
    case fullSystem      = "Full System"
    case topDown         = "Top Down"
    case saturnSystem    = "Saturn System"
    case jovianSystem    = "Jovian System"
    case earthMoonSystem = "Earth & Moon"
    case galactic        = "Galactic Journey"

    var id: String { rawValue }
}

struct ResonancePair: Hashable, Identifiable {
    let primary: String
    let secondary: String
    let ratioLabel: String

    var id: String { "\(primary)-\(secondary)" }
}

// MARK: - Scene

final class SolarSystemScene {
    let scene: SCNScene = SCNScene()

    private let root          = SCNNode()
    private let orbitRoot     = SCNNode()
    private let bodyRoot      = SCNNode()
    private let jovianRoot    = SCNNode()
    private let saturnRoot    = SCNNode()
    private let resonanceRoot = SCNNode()

    private var orbitNodes:       [String: SCNNode] = [:]
    private var bodyNodes:        [String: SCNNode] = [:]
    private var axisNodes:        [String: SCNNode] = [:]
    private var jovianBodyNodes:  [String: SCNNode] = [:]
    private var saturnBodyNodes:  [String: SCNNode] = [:]
    private var saturnRingsMainNode: SCNNode?
    private var bodyColors:       [String: NSColorLike] = [:]
    private let celestialRoot   = SCNNode()
    private var celestialNodeDict: [String: SCNNode]   = [:]

    private let cameraNode = SCNNode()

    private let resonanceLinePrimary   = SCNNode()
    private let resonanceLineSecondary = SCNNode()
    private let resonanceLineBetween   = SCNNode()

    private var trailBuffer: [String: [SCNVector3]] = [:]
    private var trailNodes:  [String: SCNNode]      = [:]
    private let trailMaxLength = 800

    private struct ConjunctionMark {
        let node1: SCNNode
        let node2: SCNNode
    }
    private var conjunctionMarks:    [ConjunctionMark] = []
    private let maxConjunctionMarks  = 15
    private var prevResonancePhase:  Double = -1

    private var currentObservationMode: ObservationMode = .fullSystem
    private var activeResonancePair:    ResonancePair?
    private var highlightedBodies:      Set<String> = []
    private(set) var selectedBodyName:  String? = nil

    // 1 AU = 10 scene units; radii massively exaggerated for visibility
    private let auToScene:   CGFloat = 10.0
    private let radiusScale: CGFloat = 0.18

    private let epoch = Date(timeIntervalSinceReferenceDate: -31_579_200) // J2000: Jan 1.5, 2000 UTC

    init() {
        scene.rootNode.addChildNode(root)
        root.addChildNode(orbitRoot)
        root.addChildNode(bodyRoot)
        root.addChildNode(resonanceRoot)
        root.addChildNode(jovianRoot)
        root.addChildNode(saturnRoot)
        root.addChildNode(celestialRoot)

        addLighting()
        addCamera()
        buildBodies()
        buildAsteroidBelt()
        buildResonanceGuides()
        buildJovianSystem()
        buildSaturnianSystem()
        buildCelestialSphere()
        applyObservationMode()
    }

    // MARK: - Public API

    func setToggles(showOrbits: Bool, showAxes: Bool) {
        // Never re-expose the solar system orbit rings while in a system-specific mode
        let inSystemMode = currentObservationMode == .jovianSystem || currentObservationMode == .saturnSystem
        orbitRoot.isHidden = !showOrbits || inSystemMode
        for (_, axis) in axisNodes { axis.isHidden = !showAxes }
    }

    func setObservationMode(_ mode: ObservationMode) {
        guard mode != currentObservationMode else { return }
        clearResonanceHistory()
        currentObservationMode = mode
        applyObservationMode()
    }

    func clearHistory() {
        clearResonanceHistory()
    }

    func setResonancePair(_ pair: ResonancePair?) {
        if pair?.id != activeResonancePair?.id { clearResonanceHistory() }
        activeResonancePair = pair
        let next = Set([pair?.primary, pair?.secondary].compactMap { $0 })
        for name in highlightedBodies.subtracting(next) { setHighlight(false, for: name) }
        for name in next.subtracting(highlightedBodies)  { setHighlight(true,  for: name) }
        highlightedBodies = next
    }

    func update(simulationDate: Date) {
        let t = simulationDate.timeIntervalSince(epoch)

        for body in BodyCatalog.planetsAndDwarfs {
            guard let node = bodyNodes[body.name] else { continue }
            let M   = body.meanAnomalyAtEpoch + 2.0 * Double.pi * (t / body.orbitalPeriodSeconds)
            let E   = solveKepler(M: M, e: body.eccentricity)              // eccentric anomaly
            let nu  = 2.0 * atan2(sqrt(1 + body.eccentricity) * sin(E / 2),
                                  sqrt(1 - body.eccentricity) * cos(E / 2)) // true anomaly
            let a   = Double(body.semiMajorAxisAU) * Double(auToScene)
            let r   = a * (1.0 - body.eccentricity * cos(E))
            let ang = nu + body.argOfPerihelionRad
            let inc = body.inclinationRadians
            node.position = SCNVector3(
                x: SceneFloat(r * cos(ang)),
                y: SceneFloat(r * sin(ang) * sin(inc)),
                z: SceneFloat(r * sin(ang) * cos(inc))
            )
            if let axis = axisNodes[body.name] {
                axis.eulerAngles = SCNVector3(x: 0, y: 0, z: SceneFloat(body.obliquityRadians))
            }
            let spin = 2.0 * Double.pi * (t / body.rotationPeriodSeconds)
            node.eulerAngles = SCNVector3(x: 0, y: SceneFloat(spin), z: SceneFloat(body.obliquityRadians))
        }

        updateSolarSystemMoons(t: t)
        updateJovianSystem(t: t)
        updateSaturnianSystem(t: t)
        updateResonanceGuides()
    }

    func cameraReferenceNode() -> SCNNode { cameraNode }

    func visibleBodyPositions() -> [(name: String, node: SCNNode)] {
        switch currentObservationMode {
        case .jovianSystem:
            return jovianBodyNodes.map { ($0.key, $0.value) }
        case .saturnSystem:
            return saturnBodyNodes.map { ($0.key, $0.value) }
        default:
            var result: [(name: String, node: SCNNode)] = []
            if let sun = bodyNodes["Sun"] { result.append(("Sun", sun)) }
            for body in BodyCatalog.planetsAndDwarfs {
                if let node = bodyNodes[body.name] { result.append((body.name, node)) }
            }
            return result
        }
    }

    func setCelestialSphere(visible: Bool) {
        celestialRoot.isHidden = !visible
    }

    // MARK: - Body Selection

    func bodyName(atNodeNamed name: String) -> String? {
        if bodyNodes[name]        != nil { return name }
        if jovianBodyNodes[name]  != nil { return name }
        if saturnBodyNodes[name]  != nil { return name }
        return nil
    }

    func selectBody(_ name: String?) {
        guard name != selectedBodyName else { return }
        if let prev = selectedBodyName, !highlightedBodies.contains(prev) {
            setHighlight(false, for: prev)
        }
        selectedBodyName = name
        if let name = name, !highlightedBodies.contains(name) {
            setHighlight(true, for: name)
        }
    }

    func celestialLabelPositions() -> [(name: String, node: SCNNode)] {
        celestialNodeDict.map { ($0.key, $0.value) }
    }

    // MARK: - Scene Construction

    private func addLighting() {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 200
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .omni
        sun.intensity = 2000
        let sunNode = SCNNode()
        sunNode.light = sun
        root.addChildNode(sunNode)
    }

    private func addCamera() {
        let camera = SCNCamera()
        camera.zFar  = 5000
        camera.zNear = 0.1
        cameraNode.camera = camera
        root.addChildNode(cameraNode)
        applyObservationMode()
    }

    private func buildBodies() {
        // Sun
        let sun = makeSphere(radius: 2.2, emission: true)
        sun.geometry?.firstMaterial?.diffuse.contents  = NSColorLike.systemYellow
        sun.geometry?.firstMaterial?.emission.contents = NSColorLike.systemYellow
        sun.name = "Sun"
        bodyRoot.addChildNode(sun)
        bodyNodes["Sun"] = sun
        bodyColors["Sun"] = .systemYellow

        // Planets + Pluto
        for body in BodyCatalog.planetsAndDwarfs {
            let orbit = makeEllipticalOrbit(
                a:           CGFloat(body.semiMajorAxisAU) * auToScene,
                e:           body.eccentricity,
                omega:       body.argOfPerihelionRad,
                inclination: body.inclinationRadians)
            orbit.name = "\(body.name)-orbit"
            orbitRoot.addChildNode(orbit)
            orbitNodes[body.name] = orbit

            let planet = makeSphere(radius: CGFloat(body.radiusEarths) * radiusScale, emission: false)
            planet.geometry?.firstMaterial?.diffuse.contents = body.color
            planet.name = body.name
            bodyRoot.addChildNode(planet)
            bodyNodes[body.name] = planet
            bodyColors[body.name] = body.color as? NSColorLike

            let axis = makeAxisRod(length: max(0.8, CGFloat(body.radiusEarths) * radiusScale * 3.0))
            axis.name = "\(body.name)-axis"
            planet.addChildNode(axis)
            axisNodes[body.name] = axis
        }

        // === Moons visible in the main solar system view ===
        // Sizes are exaggerated for visibility at solar-system scale.

        // Earth — Moon
        addMainViewMoon("Moon",   radius: max(0.27 * radiusScale, 0.09), color: .systemGray)

        // Mars — Phobos (7.65 h) and Deimos (30.3 h)
        addMainViewMoon("Phobos", radius: 0.09, color: .darkGray)
        addMainViewMoon("Deimos", radius: 0.08, color: .systemGray)

        // Saturn — Titan (the most massive moon in the solar system besides Ganymede)
        addMainViewMoon("Titan",  radius: 0.22, color: .systemOrange)

        // Saturn — rings as a flattened torus, repositioned each frame
        let saturnR  = CGFloat(9.45) * radiusScale
        let mainRing = makeFlatRingNode(saturnVisualRadius: saturnR,
                                        color: NSColorLike(white: 0.85, alpha: 0.50))
        bodyRoot.addChildNode(mainRing)
        saturnRingsMainNode = mainRing

        // Neptune — Triton (large, retrograde)
        addMainViewMoon("Triton", radius: 0.15, color: .systemTeal)

        // Pluto — Charon (so large relative to Pluto it's nearly a binary system)
        addMainViewMoon("Charon", radius: 0.11, color: .lightGray)
    }

    private func addMainViewMoon(_ name: String, radius: CGFloat, color: NSColorLike) {
        let node = makeSphere(radius: radius, emission: false)
        node.geometry?.firstMaterial?.diffuse.contents = color
        node.name = name
        bodyRoot.addChildNode(node)
        bodyNodes[name] = node
        bodyColors[name] = color
    }

    private func buildAsteroidBelt() {
        // Kirkwood gaps: semi-major axes (AU) where Jupiter resonances clear the belt.
        let gaps: [(center: Double, half: Double)] = [
            (2.06, 0.07),  // 4:1
            (2.50, 0.10),  // 3:1  (widest)
            (2.82, 0.08),  // 5:2
            (2.95, 0.06),  // 7:3
            (3.27, 0.08),  // 2:1
        ]
        let count = 2200
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(count)
        var attempts = 0
        while vertices.count < count && attempts < count * 12 {
            attempts += 1
            let rAU  = Double.random(in: 2.2...3.2)
            if gaps.contains(where: { abs(rAU - $0.center) < $0.half }) { continue }
            let r     = rAU * Double(auToScene)
            let theta = Double.random(in: 0 ..< (2 * .pi))
            let yNoise = Double.random(in: -1.2...1.2)
            vertices.append(SCNVector3(
                x: SceneFloat(r * cos(theta)),
                y: SceneFloat(yNoise),
                z: SceneFloat(r * sin(theta))
            ))
        }
        let source  = SCNGeometrySource(vertices: vertices)
        let indices = (0..<count).map { Int32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 1.5
        element.minimumPointScreenSpaceRadius = 0.5
        element.maximumPointScreenSpaceRadius = 2.5
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColorLike(white: 0.72, alpha: 0.45)
        mat.lightingModel    = .constant
        geo.materials = [mat]
        bodyRoot.addChildNode(SCNNode(geometry: geo))
    }

    private func buildResonanceGuides() {
        resonanceLinePrimary.geometry   = makeLineGeometry(color: NSColorLike.systemMint)
        resonanceLineSecondary.geometry = makeLineGeometry(color: NSColorLike.systemOrange)
        resonanceLineBetween.geometry   = makeLineGeometry(color: NSColorLike.systemPink)
        resonanceRoot.addChildNode(resonanceLinePrimary)
        resonanceRoot.addChildNode(resonanceLineSecondary)
        resonanceRoot.addChildNode(resonanceLineBetween)
        resonanceRoot.isHidden = true
    }

    // MARK: - Jovian System

    private func buildJovianSystem() {
        let jupiterR = CGFloat(11.21) * radiusScale
        let jupiter = makeSphere(radius: jupiterR, emission: false)
        jupiter.geometry?.firstMaterial?.diffuse.contents = makeJupiterTexture() ?? NSColorLike.brown
        jupiter.name = "JupiterLocal"
        jovianRoot.addChildNode(jupiter)
        jovianBodyNodes["Jupiter"] = jupiter
        bodyColors["Jupiter"] = .brown

        let moons: [(name: String, periodDays: Double, rRJ: CGFloat, rEarths: CGFloat, color: NSColorLike)] = [
            ("Io",       1.769,  5.90, 0.286, .systemYellow),
            ("Europa",   3.551,  9.40, 0.245, .systemTeal),
            ("Ganymede", 7.155, 15.00, 0.413, .systemGray),
            ("Callisto",16.689, 26.30, 0.378, .lightGray)
        ]
        let scale: CGFloat = 0.45
        for m in moons {
            let r = jupiterR * m.rRJ * scale
            let orbit = makeOrbitRing(radius: r)
            orbit.geometry?.firstMaterial?.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.30)
            orbit.name = "\(m.name)-orbit"
            jovianRoot.addChildNode(orbit)
            let node = makeSphere(radius: max(m.rEarths * radiusScale * 1.4, 0.12), emission: false)
            node.geometry?.firstMaterial?.diffuse.contents = m.color
            node.name = m.name
            jovianRoot.addChildNode(node)
            jovianBodyNodes[m.name] = node
            bodyColors[m.name] = m.color
        }
    }

    private func updateJovianSystem(t: Double) {
        let day = 86_400.0
        let jupiterR = CGFloat(11.21) * radiusScale
        let scale: CGFloat = 0.45
        let data: [(name: String, periodDays: Double, rRJ: CGFloat)] = [
            ("Io",       1.769,  5.90),
            ("Europa",   3.551,  9.40),
            ("Ganymede", 7.155, 15.00),
            ("Callisto",16.689, 26.30)
        ]
        for m in data {
            guard let node = jovianBodyNodes[m.name] else { continue }
            let theta = 2.0 * Double.pi * (t / (m.periodDays * day))
            let r = jupiterR * m.rRJ * scale
            node.position = SCNVector3(r * CGFloat(cos(theta)), 0, r * CGFloat(sin(theta)))
        }
    }

    // MARK: - Saturn System

    private func buildSaturnianSystem() {
        let saturnR = CGFloat(9.45) * radiusScale

        // Local Saturn body (stationary — rings carry the tilt)
        let saturn = makeSphere(radius: saturnR, emission: false)
        saturn.geometry?.firstMaterial?.diffuse.contents = NSColorLike.systemYellow
        saturn.name = "SaturnLocal"
        saturnRoot.addChildNode(saturn)
        saturnBodyNodes["Saturn"] = saturn
        bodyColors["Saturn"] = .systemYellow

        // Rings tilted to Saturn's 26.73° obliquity
        let rings = makeFlatRingNode(saturnVisualRadius: saturnR,
                                     color: NSColorLike(white: 0.88, alpha: 0.60))
        rings.eulerAngles = SCNVector3(0, 0, CGFloat(BodyCatalog.deg(26.73)))
        saturnRoot.addChildNode(rings)

        // Moons (rSR = distance in Saturn radii)
        let moons: [(name: String, periodDays: Double, rSR: CGFloat, rEarths: CGFloat, color: NSColorLike)] = [
            ("Mimas",    0.942,   3.19, 0.031, .systemGray),
            ("Enceladus",1.370,   4.09, 0.040, .white),
            ("Tethys",   1.888,   5.06, 0.083, .systemGray),
            ("Dione",    2.737,   6.48, 0.088, .lightGray),
            ("Rhea",     4.518,   9.05, 0.120, .lightGray),
            ("Titan",   15.945,  20.98, 0.404, .systemOrange),
            ("Iapetus", 79.321,  61.10, 0.116, .darkGray),
        ]
        let scale: CGFloat = 0.80
        for m in moons {
            let r = saturnR * m.rSR * scale
            let orbit = makeOrbitRing(radius: r)
            orbit.geometry?.firstMaterial?.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.30)
            orbit.name = "\(m.name)-orbit"
            saturnRoot.addChildNode(orbit)
            let node = makeSphere(radius: max(m.rEarths * radiusScale * 1.4, 0.12), emission: false)
            node.geometry?.firstMaterial?.diffuse.contents = m.color
            node.name = m.name
            saturnRoot.addChildNode(node)
            saturnBodyNodes[m.name] = node
            bodyColors[m.name] = m.color
        }
    }

    private func updateSaturnianSystem(t: Double) {
        let day    = 86_400.0
        let saturnR = CGFloat(9.45) * radiusScale
        let scale: CGFloat = 0.80
        let data: [(name: String, periodDays: Double, rSR: CGFloat)] = [
            ("Mimas",    0.942,   3.19),
            ("Enceladus",1.370,   4.09),
            ("Tethys",   1.888,   5.06),
            ("Dione",    2.737,   6.48),
            ("Rhea",     4.518,   9.05),
            ("Titan",   15.945,  20.98),
            ("Iapetus", 79.321,  61.10),
        ]
        for m in data {
            guard let node = saturnBodyNodes[m.name] else { continue }
            let theta = 2.0 * Double.pi * (t / (m.periodDays * day))
            let r = saturnR * m.rSR * scale
            node.position = SCNVector3(r * CGFloat(cos(theta)), 0, r * CGFloat(sin(theta)))
        }
    }

    // MARK: - Solar System Moons

    private func updateSolarSystemMoons(t: Double) {
        let day = 86_400.0

        // Earth — Moon (27.3 d)
        place(moon: "Moon",   around: "Earth",   t: t, period: 27.322 * day,  radius: 1.60)

        // Mars — Phobos (7.65 h) and Deimos (30.3 h)
        place(moon: "Phobos", around: "Mars",    t: t, period: 0.3187 * day,  radius: 0.45)
        place(moon: "Deimos", around: "Mars",    t: t, period: 1.2625 * day,  radius: 0.70)

        // Saturn — Titan (15.9 d)
        place(moon: "Titan",  around: "Saturn",  t: t, period: 15.945 * day,  radius: 4.50)

        // Saturn rings follow Saturn's position but not its spin
        if let saturn = bodyNodes["Saturn"], let rings = saturnRingsMainNode {
            rings.position    = saturn.position
            rings.eulerAngles = SCNVector3(0, 0, CGFloat(BodyCatalog.deg(26.73)))
        }

        // Neptune — Triton (retrograde: negative period)
        place(moon: "Triton", around: "Neptune", t: t, period: -5.877 * day,  radius: 2.50)

        // Pluto — Charon (6.4 d, tidally locked — same face always toward Pluto)
        place(moon: "Charon", around: "Pluto",   t: t, period: 6.387 * day,   radius: 0.50)
    }

    private func place(moon: String, around parent: String, t: Double, period: Double, radius: CGFloat) {
        guard let parentNode = bodyNodes[parent], let moonNode = bodyNodes[moon] else { return }
        let theta = 2.0 * Double.pi * (t / period)
        moonNode.position = parentNode.position + SCNVector3(
            radius * CGFloat(cos(theta)),
            0,
            radius * CGFloat(sin(theta))
        )
    }

    // MARK: - Resonance Guide Lines

    private func updateResonanceGuides() {
        guard let pair = activeResonancePair else {
            resonanceRoot.isHidden = true
            return
        }

        // Choose the right body dictionary for the current mode
        let lookup: [String: SCNNode]
        switch currentObservationMode {
        case .jovianSystem: lookup = jovianBodyNodes
        case .saturnSystem: lookup = saturnBodyNodes
        default:            lookup = bodyNodes
        }

        guard let primary   = lookup[pair.primary],
              let secondary = lookup[pair.secondary] else {
            resonanceRoot.isHidden = true
            return
        }

        resonanceRoot.isHidden = false
        let pPos = primary.position
        let sPos = secondary.position
        setLine(resonanceLinePrimary,   from: .zero, to: pPos)
        setLine(resonanceLineSecondary, from: .zero, to: sPos)
        setLine(resonanceLineBetween,   from: pPos,  to: sPos)

        appendTrail(name: pair.primary,   position: pPos)
        appendTrail(name: pair.secondary, position: sPos)
        detectConjunction(primaryPos: pPos, secondaryPos: sPos)
    }

    private func detectConjunction(primaryPos: SCNVector3, secondaryPos: SCNVector3) {
        let pa = atan2(Double(primaryPos.z),   Double(primaryPos.x))
        let sa = atan2(Double(secondaryPos.z), Double(secondaryPos.x))
        var phase = (sa - pa).truncatingRemainder(dividingBy: 2 * .pi)
        if phase < 0 { phase += 2 * .pi }

        // Conjunction: phase angle crosses 0 in either direction
        let risingThrough0  = prevResonancePhase > 5.0 && phase < 1.0
        let fallingThrough0 = prevResonancePhase < 1.0 && phase > 5.0
        if risingThrough0 || fallingThrough0 {
            recordConjunction(primaryPos: primaryPos, secondaryPos: secondaryPos)
        }
        prevResonancePhase = phase
    }

    private func recordConjunction(primaryPos: SCNVector3, secondaryPos: SCNVector3) {
        let r1 = CGFloat(sqrt(Double(primaryPos.x)*Double(primaryPos.x)
                            + Double(primaryPos.y)*Double(primaryPos.y)
                            + Double(primaryPos.z)*Double(primaryPos.z)))
        let r2 = CGFloat(sqrt(Double(secondaryPos.x)*Double(secondaryPos.x)
                            + Double(secondaryPos.y)*Double(secondaryPos.y)
                            + Double(secondaryPos.z)*Double(secondaryPos.z)))
        let c1 = bodyColors[activeResonancePair?.primary   ?? ""] ?? NSColorLike.systemMint
        let c2 = bodyColors[activeResonancePair?.secondary ?? ""] ?? NSColorLike.systemOrange
        let n1 = makeConjunctionMarkNode(color: c1, radius: max(r1 * 0.06, 0.6))
        let n2 = makeConjunctionMarkNode(color: c2, radius: max(r2 * 0.06, 0.6))
        n1.position = primaryPos
        n2.position = secondaryPos
        resonanceRoot.addChildNode(n1)
        resonanceRoot.addChildNode(n2)
        conjunctionMarks.append(.init(node1: n1, node2: n2))

        while conjunctionMarks.count > maxConjunctionMarks {
            let old = conjunctionMarks.removeFirst()
            old.node1.removeFromParentNode()
            old.node2.removeFromParentNode()
        }

        let total = CGFloat(conjunctionMarks.count)
        for (i, mark) in conjunctionMarks.enumerated() {
            let alpha = 0.15 + 0.85 * CGFloat(i + 1) / total
            mark.node1.opacity = alpha
            mark.node2.opacity = alpha
        }
    }

    // MARK: - Trails

    private func appendTrail(name: String, position: SCNVector3) {
        var buf = trailBuffer[name] ?? []
        buf.append(position)
        if buf.count > trailMaxLength { buf.removeFirst() }
        trailBuffer[name] = buf
        renderTrail(name: name, positions: buf)
    }

    private func renderTrail(name: String, positions: [SCNVector3]) {
        guard positions.count >= 2 else { return }
        if trailNodes[name] == nil {
            let node = SCNNode()
            resonanceRoot.addChildNode(node)
            trailNodes[name] = node
        }
        let node    = trailNodes[name]!
        let source  = SCNGeometrySource(vertices: positions)
        let indices = (0..<positions.count).map { Int32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geo     = SCNGeometry(sources: [source], elements: [element])
        let mat     = SCNMaterial()
        mat.diffuse.contents = bodyNodes[name]?.geometry?.firstMaterial?.diffuse.contents
                               ?? NSColorLike(white: 1.0, alpha: 0.5)
        mat.lightingModel = .constant
        geo.materials = [mat]
        node.geometry = geo
    }

    private func clearResonanceHistory() {
        trailBuffer.removeAll()
        for (_, node) in trailNodes { node.removeFromParentNode() }
        trailNodes.removeAll()
        for mark in conjunctionMarks {
            mark.node1.removeFromParentNode()
            mark.node2.removeFromParentNode()
        }
        conjunctionMarks.removeAll()
        prevResonancePhase = -1
    }

    // MARK: - Observation Mode

    private func applyObservationMode() {
        let jovian = currentObservationMode == .jovianSystem
        let saturn = currentObservationMode == .saturnSystem
        orbitRoot.isHidden  = jovian || saturn
        bodyRoot.isHidden   = jovian || saturn
        jovianRoot.isHidden = !jovian
        saturnRoot.isHidden = !saturn
        // resonanceRoot visibility is managed per-frame by updateResonanceGuides
        cameraNode.camera?.fieldOfView = 60

        switch currentObservationMode {
        case .fullSystem, .earthMoonSystem, .galactic:
            cameraNode.position    = SCNVector3(0, 120, 260)
            cameraNode.eulerAngles = SCNVector3(-0.42, 0, 0)
        case .topDown:
            cameraNode.position    = SCNVector3(0, 320, 0.01)
            cameraNode.eulerAngles = SCNVector3(-SceneFloat.pi / 2, 0, 0)
        case .saturnSystem:
            // Iapetus orbit ≈ 83 scene units out at scale 0.80; pull back to fit
            cameraNode.position    = SCNVector3(0, 80, 170)
            cameraNode.eulerAngles = SCNVector3(-0.43, 0, 0)
        case .jovianSystem:
            cameraNode.position    = SCNVector3(0, 26, 58)
            cameraNode.eulerAngles = SCNVector3(-0.33, 0, 0)
        }
    }

    // MARK: - Geometry Helpers

    private func makeSphere(radius: CGFloat, emission: Bool) -> SCNNode {
        let geo = SCNSphere(radius: radius)
        geo.segmentCount = 48
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.metalness.contents = 0.0
        mat.roughness.contents = 0.6
        if emission { mat.emission.intensity = 1.0 }
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    // Kepler's equation solver: given mean anomaly M and eccentricity e,
    // returns eccentric anomaly E via Newton's method (5 iterations, plenty for e < 0.25).
    private func solveKepler(M: Double, e: Double) -> Double {
        var E = M
        for _ in 0..<8 {
            E -= (E - e * sin(E) - M) / (1.0 - e * cos(E))
        }
        return E
    }

    // Elliptical orbit ring as a 180-segment closed polyline.
    // a = semi-major axis (scene units), e = eccentricity, omega = argument of perihelion,
    // inclination = tilt around x-axis (same convention as the circular makeOrbitRing).
    private func makeEllipticalOrbit(a: CGFloat, e: Double, omega: Double, inclination: Double) -> SCNNode {
        let segments = 180
        let b        = a * CGFloat(sqrt(1.0 - e * e))
        let cosW = CGFloat(cos(omega)), sinW = CGFloat(sin(omega))
        let cosI = CGFloat(cos(inclination)), sinI = CGFloat(sin(inclination))
        var verts = [SCNVector3]()
        verts.reserveCapacity(segments + 1)
        for i in 0...segments {
            let u  = 2.0 * Double.pi * Double(i) / Double(segments)
            let xp = a * CGFloat(cos(u)) - a * CGFloat(e)  // a*(cos u − e)
            let yp = b * CGFloat(sin(u))
            let xr = xp * cosW - yp * sinW                 // rotate by ω
            let yr = xp * sinW + yp * cosW
            verts.append(SCNVector3(xr, yr * sinI, yr * cosI))  // tilt by inclination
        }
        var indices = [Int32]()
        indices.reserveCapacity(segments * 2)
        for i in 0..<segments {
            indices.append(Int32(i))
            indices.append(Int32(i + 1))
        }
        let src = SCNGeometrySource(vertices: verts)
        let elm = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geo = SCNGeometry(sources: [src], elements: [elm])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.22)
        mat.lightingModel    = .constant
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    private func makeOrbitRing(radius: CGFloat, inclination: Double = 0) -> SCNNode {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: 0.03)
        let mat   = SCNMaterial()
        mat.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.22)
        mat.lightingModel    = .constant
        torus.materials = [mat]
        let node = SCNNode(geometry: torus)
        // SCNTorus lies in XZ plane; subtract inclination to match inclined orbit
        node.eulerAngles = SCNVector3(-SceneFloat(inclination), 0, 0)
        return node
    }

    // Procedural Jupiter texture: horizontal gradient bands mimicking equatorial belt zones.
    private func makeJupiterTexture() -> CGImage? {
        let w = 512, h = 256
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Color stops: (y-fraction, R, G, B) top → bottom
        let stops: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.00, 0.87, 0.76, 0.62),  // north polar (cream)
            (0.11, 0.60, 0.40, 0.22),  // N. temperate belt (brown)
            (0.20, 0.84, 0.71, 0.51),  // N. tropical zone
            (0.31, 0.55, 0.33, 0.18),  // N. equatorial belt (dark)
            (0.43, 0.85, 0.70, 0.49),  // equatorial zone (bright cream)
            (0.54, 0.60, 0.37, 0.20),  // S. equatorial belt
            (0.65, 0.82, 0.70, 0.52),  // S. tropical zone
            (0.75, 0.56, 0.37, 0.23),  // S. temperate belt
            (0.85, 0.86, 0.77, 0.63),  // south polar
            (1.00, 0.87, 0.76, 0.62),
        ]
        for i in 0..<(stops.count - 1) {
            let (y0, r0, g0, b0) = stops[i]
            let (y1, r1, g1, b1) = stops[i + 1]
            let colors = [CGColor(red: r0, green: g0, blue: b0, alpha: 1),
                          CGColor(red: r1, green: g1, blue: b1, alpha: 1)] as CFArray
            guard let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { continue }
            let py0 = CGFloat(y0) * CGFloat(h)
            let py1 = CGFloat(y1) * CGFloat(h)
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: py0),
                                   end:   CGPoint(x: 0, y: py1),
                                   options: [])
        }
        return ctx.makeImage()
    }

    // Saturn ring: flat annular torus spanning the A+B ring system (1.58–2.35 Saturn radii)
    private func makeFlatRingNode(saturnVisualRadius r: CGFloat, color: NSColorLike) -> SCNNode {
        let midR  = r * 1.965    // midpoint of A+B rings
        let halfW = r * 0.385    // half-width spans 1.58 to 2.35 SR
        let torus = SCNTorus(ringRadius: midR, pipeRadius: halfW)
        let mat   = SCNMaterial()
        mat.diffuse.contents = color
        mat.isDoubleSided    = true
        mat.lightingModel    = .constant
        torus.materials = [mat]
        let node  = SCNNode(geometry: torus)
        node.scale = SCNVector3(1.0, 0.05, 1.0)   // squish to a flat disk
        return node
    }

    private func makeAxisRod(length: CGFloat) -> SCNNode {
        let cyl = SCNCylinder(radius: 0.02, height: length)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.85)
        mat.lightingModel    = .constant
        cyl.materials = [mat]
        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3(0, SceneFloat(length / 2), 0)
        return node
    }

    private func makeLineGeometry(color: NSColorLike) -> SCNGeometry {
        let source  = SCNGeometrySource(vertices: [.zero, .zero])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
        let geo     = SCNGeometry(sources: [source], elements: [element])
        let mat     = SCNMaterial()
        mat.diffuse.contents  = color
        mat.emission.contents = color
        mat.lightingModel     = .constant
        geo.materials = [mat]
        return geo
    }

    private func setLine(_ node: SCNNode, from: SCNVector3, to: SCNVector3) {
        let source  = SCNGeometrySource(vertices: [from, to])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
        let geo     = SCNGeometry(sources: [source], elements: [element])
        geo.materials = node.geometry?.materials ?? []
        node.geometry = geo
    }

    private func makeConjunctionMarkNode(color: NSColorLike, radius: CGFloat) -> SCNNode {
        let geo = SCNSphere(radius: radius)
        geo.segmentCount = 12
        let mat = SCNMaterial()
        mat.diffuse.contents   = color
        mat.emission.contents  = color
        mat.emission.intensity = 1.0
        mat.lightingModel      = .constant
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    // MARK: - Celestial Sphere

    private func buildCelestialSphere() {
        let R: CGFloat = 580
        buildStarField(radius: R)
        buildZodiacConstellations(radius: R)
        buildMilkyWayBand(radius: R)
        buildGalacticMarkers(radius: R)
    }

    // Ecliptic north = scene +Y; vernal equinox = scene +X; summer solstice = scene +Z
    private func eclipticToScene(lonDeg: Double, latDeg: Double, radius: CGFloat) -> SCNVector3 {
        let lon = lonDeg * .pi / 180
        let lat = latDeg * .pi / 180
        return SCNVector3(
            CGFloat(cos(lat) * cos(lon)) * radius,
            CGFloat(sin(lat)) * radius,
            CGFloat(cos(lat) * sin(lon)) * radius
        )
    }

    private func buildStarField(radius: CGFloat) {
        var verts: [SCNVector3] = []
        for star in CelestialCatalog.labeledStars {
            let pos = eclipticToScene(lonDeg: star.lon, latDeg: star.lat, radius: radius)
            verts.append(pos)
            let anchor = SCNNode(); anchor.position = pos; anchor.name = star.name
            celestialRoot.addChildNode(anchor)
            celestialNodeDict[star.name] = anchor
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<380 {
            let lon = Double.random(in: 0..<360, using: &rng)
            let lat = asin(Double.random(in: -1.0...1.0, using: &rng)) * 180 / .pi
            verts.append(eclipticToScene(lonDeg: lon, latDeg: lat, radius: radius * CGFloat.random(in: 0.97...1.0, using: &rng)))
        }
        let src = SCNGeometrySource(vertices: verts)
        let idx = (0..<verts.count).map { Int32($0) }
        let el  = SCNGeometryElement(indices: idx, primitiveType: .point)
        el.pointSize = 2.0; el.minimumPointScreenSpaceRadius = 0.4; el.maximumPointScreenSpaceRadius = 3.5
        let geo = SCNGeometry(sources: [src], elements: [el])
        let mat = SCNMaterial(); mat.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.75); mat.lightingModel = .constant
        geo.materials = [mat]; celestialRoot.addChildNode(SCNNode(geometry: geo))
    }

    private func buildZodiacConstellations(radius: CGFloat) {
        for cst in CelestialCatalog.zodiacConstellations {
            let labelPos = eclipticToScene(lonDeg: cst.labelLon, latDeg: cst.labelLat + 5, radius: radius)
            let anchor = SCNNode(); anchor.position = labelPos; anchor.name = cst.name
            celestialRoot.addChildNode(anchor); celestialNodeDict[cst.name] = anchor

            let pts = cst.stars.map { eclipticToScene(lonDeg: $0.lon, latDeg: $0.lat, radius: radius) }

            // Constellation stick lines
            var lineVerts: [SCNVector3] = []
            for (a, b) in cst.lines { lineVerts.append(pts[a]); lineVerts.append(pts[b]) }
            if !lineVerts.isEmpty {
                let lSrc = SCNGeometrySource(vertices: lineVerts)
                let lIdx = (0..<lineVerts.count).map { Int32($0) }
                let lEl  = SCNGeometryElement(indices: lIdx, primitiveType: .line)
                let lGeo = SCNGeometry(sources: [lSrc], elements: [lEl])
                let lMat = SCNMaterial()
                lMat.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.35); lMat.lightingModel = .constant
                lGeo.materials = [lMat]; celestialRoot.addChildNode(SCNNode(geometry: lGeo))
            }
            // Star dots
            let dSrc = SCNGeometrySource(vertices: pts)
            let dIdx = (0..<pts.count).map { Int32($0) }
            let dEl  = SCNGeometryElement(indices: dIdx, primitiveType: .point)
            dEl.pointSize = 2.5; dEl.minimumPointScreenSpaceRadius = 1.0; dEl.maximumPointScreenSpaceRadius = 4.5
            let dGeo = SCNGeometry(sources: [dSrc], elements: [dEl])
            let dMat = SCNMaterial()
            dMat.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.90); dMat.lightingModel = .constant
            dGeo.materials = [dMat]; celestialRoot.addChildNode(SCNNode(geometry: dGeo))
        }
    }

    private func buildMilkyWayBand(radius: CGFloat) {
        // Galactic plane torus — axis aimed at galactic north pole (ecl lon≈180°, lat≈+30°).
        // R_z(+60°) rotates +Y to (-0.866, 0.5, 0), matching that direction.
        let torus = SCNTorus(ringRadius: radius * 0.998, pipeRadius: radius * 0.055)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColorLike(white: 0.92, alpha: 0.10)
        mat.isDoubleSided = true; mat.lightingModel = .constant
        torus.materials = [mat]
        let node = SCNNode(geometry: torus)
        node.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 3)
        celestialRoot.addChildNode(node)

        // Brighter inner band core (galactic equator)
        let core = SCNTorus(ringRadius: radius * 0.998, pipeRadius: radius * 0.018)
        let coreMat = SCNMaterial()
        coreMat.diffuse.contents = NSColorLike(white: 1.0, alpha: 0.18)
        coreMat.isDoubleSided = true; coreMat.lightingModel = .constant
        core.materials = [coreMat]
        let coreNode = SCNNode(geometry: core)
        coreNode.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 3)
        celestialRoot.addChildNode(coreNode)
    }

    private func buildGalacticMarkers(radius: CGFloat) {
        // Galactic center direction: ecl lon≈267°, lat≈-5.5° (in Sagittarius)
        let gcPos = eclipticToScene(lonDeg: 267, latDeg: -5.5, radius: radius * 0.93)
        let gcAnchor = SCNNode(); gcAnchor.position = gcPos; gcAnchor.name = "Galactic Center ★"
        celestialRoot.addChildNode(gcAnchor); celestialNodeDict["Galactic Center ★"] = gcAnchor

        // EHT-style Sgr A* visual: photon ring + event horizon shadow, inspired by the
        // 2022 Event Horizon Telescope image of Sagittarius A*.
        let gcVisual = SCNNode()
        gcVisual.position = eclipticToScene(lonDeg: 267, latDeg: -5.5, radius: radius * 0.985)
        // Tilt so the disk reads as inclined — not perfectly face-on like the real EHT image.
        gcVisual.eulerAngles = SCNVector3(CGFloat.pi * 0.30, CGFloat.pi * 0.12, 0)

        // Outer diffuse halo — wide, very faint orange
        let haloGeo = SCNTorus(ringRadius: 8.5, pipeRadius: 6.0)
        let haloMat = SCNMaterial()
        haloMat.emission.contents = NSColorLike(red: 0.9, green: 0.35, blue: 0.0, alpha: 0.10)
        haloMat.lightingModel = .constant
        haloGeo.materials = [haloMat]
        gcVisual.addChildNode(SCNNode(geometry: haloGeo))

        // Photon ring — the bright orange-white ring seen in EHT images
        let ringGeo = SCNTorus(ringRadius: 7.0, pipeRadius: 1.3)
        let ringMat = SCNMaterial()
        ringMat.emission.contents = NSColorLike(red: 1.0, green: 0.68, blue: 0.15, alpha: 0.95)
        ringMat.lightingModel = .constant
        ringGeo.materials = [ringMat]
        gcVisual.addChildNode(SCNNode(geometry: ringGeo))

        // Event horizon shadow — dark sphere filling the ring's inner hole
        let shadowGeo = SCNSphere(radius: 5.8)
        shadowGeo.segmentCount = 24
        let shadowMat = SCNMaterial()
        shadowMat.diffuse.contents  = NSColorLike.black
        shadowMat.lightingModel     = .constant
        shadowGeo.materials = [shadowMat]
        gcVisual.addChildNode(SCNNode(geometry: shadowGeo))

        celestialRoot.addChildNode(gcVisual)

        // Sun's direction of travel in galactic orbit: ecl lon≈348°, lat≈+60° (toward Cygnus)
        let travelAnchor = SCNNode()
        travelAnchor.position = eclipticToScene(lonDeg: 348, latDeg: 60, radius: radius)
        travelAnchor.name = "☀ Galactic Motion"
        celestialRoot.addChildNode(travelAnchor); celestialNodeDict["☀ Galactic Motion"] = travelAnchor
    }

    private func setHighlight(_ enabled: Bool, for name: String) {
        for dict in [bodyNodes, jovianBodyNodes, saturnBodyNodes] {
            guard let mat = dict[name]?.geometry?.firstMaterial else { continue }
            mat.emission.contents  = enabled ? NSColorLike.white : NSColorLike.black
            mat.emission.intensity = enabled ? 0.5 : 0.0
        }
    }
}

// MARK: - Body Catalog

struct BodyDef {
    let name: String
    let semiMajorAxisAU: Double
    let eccentricity: Double
    let argOfPerihelionRad: Double
    let meanAnomalyAtEpoch: Double  // M₀ at J2000 = L₀ − ω̃
    let orbitalPeriodSeconds: Double
    let rotationPeriodSeconds: Double
    let obliquityRadians: Double
    let inclinationRadians: Double
    let radiusEarths: Double
    let color: Any
}

enum BodyCatalog {
    static func deg(_ d: Double) -> Double { d * .pi / 180.0 }

    static let planetsAndDwarfs: [BodyDef] = [
        //              name        a (AU)   ecc      ω̃ (°)                          M₀ at J2000 (°)             period (s)           rot (s)         obliq (°)  inc (°)  rEarths  color
        .init(name: "Mercury", semiMajorAxisAU:  0.387, eccentricity: 0.20563, argOfPerihelionRad: deg( 77.46), meanAnomalyAtEpoch: deg(174.79), orbitalPeriodSeconds:  87.969 * 86400, rotationPeriodSeconds:  58.646 * 86400, obliquityRadians: deg(  0.034), inclinationRadians: deg( 7.00), radiusEarths: 0.383, color: NSColorLike.systemGray),
        .init(name: "Venus",   semiMajorAxisAU:  0.723, eccentricity: 0.00677, argOfPerihelionRad: deg(131.77), meanAnomalyAtEpoch: deg( 50.21), orbitalPeriodSeconds: 224.701 * 86400, rotationPeriodSeconds: -243.025 * 86400, obliquityRadians: deg(177.36), inclinationRadians: deg( 3.39), radiusEarths: 0.949, color: NSColorLike.systemOrange),
        .init(name: "Earth",   semiMajorAxisAU:  1.000, eccentricity: 0.01671, argOfPerihelionRad: deg(102.94), meanAnomalyAtEpoch: deg(357.52), orbitalPeriodSeconds: 365.256 * 86400, rotationPeriodSeconds:   86164.0,        obliquityRadians: deg( 23.44), inclinationRadians: deg( 0.00), radiusEarths: 1.000, color: NSColorLike.systemBlue),
        .init(name: "Mars",    semiMajorAxisAU:  1.524, eccentricity: 0.09341, argOfPerihelionRad: deg(336.04), meanAnomalyAtEpoch: deg( 19.41), orbitalPeriodSeconds: 686.980 * 86400, rotationPeriodSeconds:   88642.0,        obliquityRadians: deg( 25.19), inclinationRadians: deg( 1.85), radiusEarths: 0.532, color: NSColorLike.systemRed),
        .init(name: "Jupiter", semiMajorAxisAU:  5.203, eccentricity: 0.04839, argOfPerihelionRad: deg( 14.73), meanAnomalyAtEpoch: deg( 19.67), orbitalPeriodSeconds: 4332.59 * 86400, rotationPeriodSeconds:   35730.0,        obliquityRadians: deg(  3.13), inclinationRadians: deg( 1.30), radiusEarths: 11.21, color: NSColorLike.brown),
        .init(name: "Saturn",  semiMajorAxisAU:  9.537, eccentricity: 0.05415, argOfPerihelionRad: deg( 92.43), meanAnomalyAtEpoch: deg(317.51), orbitalPeriodSeconds:10759.22 * 86400, rotationPeriodSeconds:   38270.0,        obliquityRadians: deg( 26.73), inclinationRadians: deg( 2.49), radiusEarths:  9.45, color: NSColorLike.systemYellow),
        .init(name: "Uranus",  semiMajorAxisAU: 19.191, eccentricity: 0.04717, argOfPerihelionRad: deg(170.96), meanAnomalyAtEpoch: deg(142.27), orbitalPeriodSeconds:30685.40 * 86400, rotationPeriodSeconds:  -62064.0,        obliquityRadians: deg( 97.77), inclinationRadians: deg( 0.77), radiusEarths:  4.01, color: NSColorLike.cyan),
        .init(name: "Neptune", semiMajorAxisAU: 30.070, eccentricity: 0.00859, argOfPerihelionRad: deg( 44.97), meanAnomalyAtEpoch: deg(259.91), orbitalPeriodSeconds:60190.00 * 86400, rotationPeriodSeconds:   57996.0,        obliquityRadians: deg( 28.32), inclinationRadians: deg( 1.77), radiusEarths:  3.88, color: NSColorLike.systemTeal),
        .init(name: "Pluto",   semiMajorAxisAU: 39.480, eccentricity: 0.24882, argOfPerihelionRad: deg(224.07), meanAnomalyAtEpoch: deg( 14.83), orbitalPeriodSeconds:90560.00 * 86400, rotationPeriodSeconds:  -6.387 * 86400,  obliquityRadians: deg(119.60), inclinationRadians: deg(17.14), radiusEarths: 0.186, color: NSColorLike.lightGray),
    ]
}

// MARK: - Celestial Catalog

struct StarEntry {
    let name: String; let lon: Double; let lat: Double; let mag: Float
}
struct ConstellationEntry {
    let name: String; let labelLon: Double; let labelLat: Double
    let stars: [(lon: Double, lat: Double)]; let lines: [(Int, Int)]
}

enum CelestialCatalog {
    // Prominent stars: (name, ecliptic longitude°, ecliptic latitude°, apparent magnitude)
    static let labeledStars: [StarEntry] = [
        .init(name: "Sirius",      lon: 104, lat: -40, mag: -1.46),
        .init(name: "Canopus",     lon:  98, lat: -76, mag: -0.72),
        .init(name: "Arcturus",    lon: 203, lat:  31, mag: -0.04),
        .init(name: "Vega",        lon: 280, lat:  62, mag:  0.03),
        .init(name: "Capella",     lon:  82, lat:  23, mag:  0.08),
        .init(name: "Rigel",       lon:  79, lat: -31, mag:  0.13),
        .init(name: "Procyon",     lon: 115, lat: -16, mag:  0.34),
        .init(name: "Achernar",    lon:  22, lat: -59, mag:  0.46),
        .init(name: "Betelgeuse",  lon:  89, lat: -16, mag:  0.50),
        .init(name: "Altair",      lon: 297, lat:  29, mag:  0.76),
        .init(name: "Aldebaran",   lon:  70, lat:  -5, mag:  0.86),
        .init(name: "Antares",     lon: 250, lat:  -5, mag:  0.96),
        .init(name: "Spica",       lon: 204, lat:  -2, mag:  0.98),
        .init(name: "Pollux",      lon: 114, lat:   7, mag:  1.14),
        .init(name: "Fomalhaut",   lon: 333, lat: -21, mag:  1.16),
        .init(name: "Deneb",       lon: 311, lat:  67, mag:  1.25),
        .init(name: "Regulus",     lon: 150, lat:   1, mag:  1.36),
        .init(name: "Castor",      lon: 113, lat:  10, mag:  1.58),
        .init(name: "Nunki",       lon: 283, lat:  -3, mag:  2.02),
        .init(name: "Denebola",    lon: 176, lat:  13, mag:  2.14),
    ]

    // Zodiac constellations: label position, star positions, connecting lines
    static let zodiacConstellations: [ConstellationEntry] = [
        .init(name: "Aries",
              labelLon:  20, labelLat: -6,
              stars: [(18,-2),(21,-10),(22,-17),(23,-18)],
              lines: [(0,1),(1,2),(2,3)]),
        .init(name: "Taurus",
              labelLon:  52, labelLat: -2,
              stars: [(57,4),(70,-5),(71,-2),(82,5)],
              lines: [(0,2),(2,1),(1,3)]),
        .init(name: "Gemini",
              labelLon:  82, labelLat:  9,
              stars: [(93,-1),(100,1),(113,10),(114,7),(111,2)],
              lines: [(0,1),(1,4),(4,2),(4,3)]),
        .init(name: "Cancer",
              labelLon: 108, labelLat:  3,
              stars: [(117,3),(118,1),(128,0),(131,-5)],
              lines: [(0,1),(1,2),(2,3),(0,2)]),
        .init(name: "Leo",
              labelLon: 141, labelLat:  7,
              stars: [(128,10),(130,9),(135,8),(143,8),(150,1),(154,14),(176,13)],
              lines: [(0,1),(1,2),(2,3),(3,4),(3,5),(5,6)]),
        .init(name: "Virgo",
              labelLon: 184, labelLat: -2,
              stars: [(167,10),(170,7),(178,16),(185,5),(189,3),(204,-2)],
              lines: [(0,1),(1,3),(3,4),(4,5),(2,3)]),
        .init(name: "Libra",
              labelLon: 218, labelLat: -8,
              stars: [(215,-7),(222,0),(229,9),(235,-3)],
              lines: [(0,1),(1,2),(1,3),(0,3)]),
        .init(name: "Scorpius",
              labelLon: 246, labelLat: -10,
              stars: [(232,2),(236,-2),(250,-5),(255,-7),(263,-14),(265,-20)],
              lines: [(0,1),(1,2),(2,3),(3,4),(4,5)]),
        .init(name: "Sagittarius",
              labelLon: 275, labelLat: -13,
              stars: [(266,-8),(270,-1),(272,-5),(276,-11),(280,-13),(283,-3),(285,-6)],
              lines: [(0,2),(2,1),(2,3),(3,0),(1,5),(5,6)]),
        .init(name: "Capricornus",
              labelLon: 305, labelLat: -14,
              stars: [(303,-11),(305,-8),(311,-12),(318,-7),(319,-6)],
              lines: [(0,1),(1,2),(2,3),(3,4),(4,0)]),
        .init(name: "Aquarius",
              labelLon: 324, labelLat: -13,
              stars: [(321,-10),(323,-8),(325,-6),(327,-14),(341,-12)],
              lines: [(0,1),(1,2),(1,3),(3,4)]),
        .init(name: "Pisces",
              labelLon: 352, labelLat:  5,
              stars: [(345,7),(352,5),(358,14),(10,19),(20,20)],
              lines: [(0,1),(1,2),(2,3),(3,4)]),
    ]
}

// MARK: - Platform Color Alias

#if os(iOS)
import UIKit
typealias NSColorLike = UIColor
#else
import AppKit
typealias NSColorLike = NSColor
#endif

// MARK: - SCNVector3 Helpers

extension SCNVector3 {
    static let zero = SCNVector3(0, 0, 0)

    static func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
}
