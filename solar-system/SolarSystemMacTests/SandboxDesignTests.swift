import Foundation
import Testing
import simd
@testable import SolarSystemMac

/// The system builder: designs, building them into starting states, and the physics checks.
struct SandboxDesignTests {

    private func body(_ id: Int, _ name: String, _ kind: SandboxBodyKind, mass: Double, parent: Int? = nil,
                      a: Double = 0, e: Double = 0, radius: Double? = nil) -> DesignBody {
        var b = SandboxPhysicalDefaults.body(kind: kind, id: id, name: name)
        b.mass = mass
        SandboxPhysicalDefaults.applyMass(&b)
        if let radius { b.radius = radius; b.autoRadius = false }
        b.parent = parent; b.a = a; b.e = e
        return b
    }

    private func messages(_ d: SandboxDesign, for id: Int) -> [String] {
        SandboxAnalysis.check(d).filter { $0.bodyID == id }.map(\.message)
    }

    // MARK: Building

    @Test(arguments: SandboxScenarios.all.map(\.id))
    func presetsBuildIntoTheirOrbits(id: String) throws {
        let s = SandboxScenarios.scenario(id)
        let (bodies, _) = s.design.build()
        #expect(bodies.map(\.id) == s.design.bodies.map(\.id))
        // Barycentric: no net momentum, centre of mass at the origin.
        let m = bodies.map(\.mass).reduce(0, +)
        let p = bodies.reduce(SIMD3<Double>.zero) { $0 + $1.mass * $1.velocity }
        let com = bodies.reduce(SIMD3<Double>.zero) { $0 + $1.mass * $1.position } / m
        #expect(simd_length(p) / m < 1e-9)
        #expect(simd_length(com) < 1e-9 * max(1, bodies.map { simd_length($0.position) }.max()!))
        // Each body sits on its Kepler orbit relative to its parent.
        let byID = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0) })
        for b in s.design.bodies {
            guard let pid = b.parent, let par = byID[pid], let me = byID[b.id] else { continue }
            let (r, v) = Kepler.state(totalMass: par.mass + b.mass, a: b.a, e: b.e, i: b.i, node: b.node,
                                      argPeri: b.argPeri, meanAnomaly: b.meanAnomaly)
            #expect(simd_length(me.position - par.position - r) < 1e-9 * max(b.a, 1e-6), "\(b.name) position")
            #expect(simd_length(me.velocity - par.velocity - v) < 1e-9 * max(simd_length(v), 1e-6), "\(b.name) velocity")
        }
    }

    @Test func circumbinaryPlanetOrbitsBothStars() {
        let d = SandboxScenarios.alphaCentauri.design
        let (bodies, centres) = d.build()
        let wanderer = try! #require(d.bodies.first { $0.name == "Far Wanderer" })
        // Its orbit is centred on the centre of mass of everything above it (the whole rest of the system).
        let rest = bodies.filter { $0.id != wanderer.id }
        let m = rest.map(\.mass).reduce(0, +)
        let com = rest.reduce(SIMD3<Double>.zero) { $0 + $1.mass * $1.position } / m
        #expect(simd_length(try! #require(centres[wanderer.id]) - com) < 1e-9)
    }

    @Test func designSurvivesSaving() throws {
        var d = SandboxScenarios.trappist1.design
        d.name = "Round trip"
        d.options.cScale = 0.1
        let back = try JSONDecoder().decode(SandboxDesign.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    @Test func orbitPreviewMatchesTheBody() {
        // The dashed preview passes through the body's starting position.
        let b = body(1, "P", .planet, mass: SandboxUnits.earthMass, parent: 0, a: 2, e: 0.4)
        var bb = b; bb.i = 30; bb.node = 40; bb.argPeri = 70; bb.meanAnomaly = 0
        let (r, _) = Kepler.state(totalMass: 1 + bb.mass, a: 2, e: 0.4, i: 30, node: 40, argPeri: 70, meanAnomaly: 0)
        let pts = Kepler.orbitPoints(a: 2, e: 0.4, i: 30, node: 40, argPeri: 70)
        #expect(simd_length(pts[0] - r) < 1e-12)   // E = 0 is periapsis
    }

    // MARK: Physics checks

    @Test func habitableZone() {
        let d = SandboxScenarios.solarSystem.design
        let earth = d.bodies.first { $0.name == "Earth" }!, venus = d.bodies.first { $0.name == "Venus" }!
        #expect(SandboxAnalysis.habitableStatus(earth, in: d) == .inside)
        #expect(SandboxAnalysis.habitableStatus(venus, in: d) == .tooHot)
        #expect(SandboxAnalysis.check(d).isEmpty, "\(SandboxAnalysis.check(d).map(\.message))")
    }

    private func earthMoon(moonAt a: Double) -> SandboxDesign {
        SandboxDesign(name: "t", bodies: [
            body(0, "Sun", .star, mass: 1),
            body(1, "Earth", .planet, mass: SandboxUnits.earthMass, parent: 0, a: 1, radius: SandboxUnits.earthRadius),
            body(2, "Moon", .moon, mass: 0.0123 * SandboxUnits.earthMass, parent: 1, a: a, radius: 1737.4 / SandboxUnits.auKm),
        ])
    }

    @Test func moonInsideHillSphereIsFine() {
        #expect(messages(earthMoon(moonAt: 384_400 / SandboxUnits.auKm), for: 2).isEmpty)
    }

    @Test func moonTooFarEscapes() {
        // Earth's Hill radius is ~1.5 million km.
        #expect(messages(earthMoon(moonAt: 2e6 / SandboxUnits.auKm), for: 2).contains { $0.contains("Hill sphere") })
    }

    @Test func moonTooCloseIsTornApart() {
        let close = earthMoon(moonAt: 1.5 * SandboxUnits.earthRadius + 1737.4 / SandboxUnits.auKm * 1.01)
        #expect(messages(close, for: 2).contains { $0.contains("Roche limit") })
    }

    @Test func tightlyPackedPlanetsAreFlagged() {
        let d = SandboxDesign(name: "t", bodies: [
            body(0, "Sun", .star, mass: 1),
            body(1, "A", .planet, mass: SandboxUnits.earthMass, parent: 0, a: 1.00),
            body(2, "B", .planet, mass: SandboxUnits.earthMass, parent: 0, a: 1.02),
        ])
        #expect(messages(d, for: 2).contains { $0.contains("mutual Hill radii") })
    }

    @Test func circumbinaryStabilityLimit() {
        var d = SandboxScenarios.alphaCentauri.design
        let k = d.bodies.firstIndex { $0.name == "Far Wanderer" }!
        #expect(messages(d, for: d.bodies[k].id).isEmpty)                    // 110 AU: fine
        d.bodies[k].a = 85
        #expect(messages(d, for: d.bodies[k].id).contains { $0.contains("both stars") })
    }

    @Test func planetTooFarFromOneStarOfABinary() {
        var d = SandboxScenarios.alphaCentauri.design
        let k = d.bodies.firstIndex { $0.name == "Aurelia" }!
        #expect(messages(d, for: d.bodies[k].id).isEmpty)
        d.bodies[k].a = 6     // A's limit is ~3 AU
        #expect(messages(d, for: d.bodies[k].id).contains { $0.contains("disrupts") })
    }

    @Test func insideTheISCO() {
        let rs = 2 * SandboxUnits.G * 10 / (SandboxUnits.c * SandboxUnits.c)
        let d = SandboxDesign(name: "t", bodies: [
            body(0, "BH", .blackHole, mass: 10),
            body(1, "NS", .neutronStar, mass: 1.4, parent: 0, a: 2 * rs),
        ])
        #expect(messages(d, for: 1).contains { $0.contains("innermost stable orbit") })
    }

    @Test func crossingOrbits() {
        let d = SandboxDesign(name: "t", bodies: [
            body(0, "Sun", .star, mass: 1),
            body(1, "A", .planet, mass: SandboxUnits.earthMass, parent: 0, a: 1),
            body(2, "B", .planet, mass: SandboxUnits.earthMass, parent: 0, a: 1.5, e: 0.5),
        ])
        #expect(messages(d, for: 2).contains { $0.contains("crossing") })
    }

    // MARK: Automatic view

    @Test func autoViewFitsTheSystem() {
        let t = SandboxAutoView.settings(for: SandboxScenarios.trappist1.design)
        #expect(t.speeds.first!.label.hasSuffix("h/s"))           // TRAPPIST-1b orbits in 36 h
        #expect(abs(t.sceneUnitsPerAU * 0.0619 - 40) < 4)          // h's orbit fills ~40 units
        let ac = SandboxAutoView.settings(for: SandboxScenarios.alphaCentauri.design)
        #expect(ac.speeds.last!.label.hasSuffix("y/s"))
        #expect(ac.speeds.count >= 3)
        #expect(ac.speeds.map(\.yearsPerSecond) == ac.speeds.map(\.yearsPerSecond).sorted())
    }

    @Test func friendlySpeedLabels() {
        #expect(SandboxAutoView.friendlySpeed(1.0 / 365.25).label == "1 d/s")
        #expect(SandboxAutoView.friendlySpeed(4.8).label == "5 y/s")
        #expect(SandboxAutoView.friendlySpeed(0.3 / (365.25 * 24)).label == "0.2 h/s")
    }

    @Test func physicalDefaults() {
        #expect(abs(SandboxPhysicalDefaults.radius(kind: .planet, mass: SandboxUnits.earthMass) / SandboxUnits.earthRadius - 1) < 0.01)
        let jup = SandboxPhysicalDefaults.radius(kind: .planet, mass: SandboxUnits.jupiterMass) / SandboxUnits.earthRadius
        #expect(abs(jup - 11.2) < 0.5)
        #expect(abs(SandboxPhysicalDefaults.radius(kind: .star, mass: 1) / SandboxUnits.sunRadius - 1) < 1e-9)
        #expect(SandboxAnalysis.habitableZone(starMass: 1).contains(1))
    }
}
