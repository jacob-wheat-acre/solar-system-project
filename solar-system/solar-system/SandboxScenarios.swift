import Foundation
import simd

// Preset systems for the Sandbox. Several are real systems whose relativistic
// behaviour has been measured, so the simulation can be checked against nature.

nonisolated struct SandboxSpeed: Hashable, Sendable {
    let label: String
    let yearsPerSecond: Double
}

nonisolated struct SandboxScenario: Identifiable, Sendable {
    let id: String
    let name: String
    let blurb: String
    let bodies: [SandboxBody]
    let options: SandboxOptions
    let sceneUnitsPerAU: Double
    let speeds: [SandboxSpeed]
    let defaultSpeed: Int
    let follow: Int                 // body id
    let cameraDistance: Float       // scene units
    let gridHalfSizeAU: Double
    let tracker: (body: Int, primary: Int)?
    /// Text shown next to the precession meter.
    let precessionNote: String?
}

nonisolated enum SandboxScenarios {
    static var all: [SandboxScenario] { [solarSystem, sagittariusA, hulseTaylor, neutronStarMerger, alphaCentauri, trappist1] }
    static func scenario(_ id: String) -> SandboxScenario { all.first { $0.id == id } ?? all[0] }

    private static let hour = 1 / (365.25 * 24), day = 1 / 365.25

    private static func color(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> { SIMD3(r, g, b) }

    /// Builds a system: add bodies relative to a parent, then shift to the barycentre.
    private struct Builder {
        var bodies: [SandboxBody] = []
        mutating func add(_ name: String, _ kind: SandboxBodyKind, mass: Double, radius: Double,
                          color: SIMD3<Float>, around parent: Int? = nil, aroundAll: Bool = false,
                          a: Double = 0, e: Double = 0, i: Double = 0, node: Double = 0,
                          argPeri: Double = 0, meanAnomaly: Double = 0) -> Int {
            var p = SIMD3<Double>.zero, v = SIMD3<Double>.zero
            // Orbit one parent body, or (aroundAll) the barycentre of everything so far.
            var centre: (m: Double, p: SIMD3<Double>, v: SIMD3<Double>)?
            if let parent { centre = (bodies[parent].mass, bodies[parent].position, bodies[parent].velocity) }
            if aroundAll {
                var m = 0.0, cp = SIMD3<Double>.zero, cv = SIMD3<Double>.zero
                for b in bodies { m += b.mass; cp += b.mass * b.position; cv += b.mass * b.velocity }
                centre = (m, cp / m, cv / m)
            }
            if let centre {
                let (r, vel) = Kepler.state(totalMass: centre.m + mass, a: a, e: e, i: i, node: node,
                                            argPeri: argPeri, meanAnomaly: meanAnomaly)
                p = centre.p + r; v = centre.v + vel
            }
            let id = bodies.count
            bodies.append(SandboxBody(id: id, name: name, kind: kind, mass: mass, radius: radius,
                                      position: p, velocity: v, color: color))
            return id
        }
        func centred() -> [SandboxBody] {
            var m = 0.0, com = SIMD3<Double>.zero, vcom = SIMD3<Double>.zero
            for b in bodies { m += b.mass; com += b.mass * b.position; vcom += b.mass * b.velocity }
            com /= m; vcom /= m
            var out = bodies
            for i in out.indices { out[i].position -= com; out[i].velocity -= vcom }
            return out
        }
    }

    // MARK: Our Solar System (J2000 mean elements)

    static var solarSystem: SandboxScenario {
        var s = Builder()
        let sun = s.add("Sun", .star, mass: 1, radius: SandboxUnits.sunRadius, color: color(1, 0.86, 0.45))
        // name, mass (M☉), radius (Earth radii), a, e, i, Ω, ϖ, L (degrees)
        let planets: [(String, Double, Double, Double, Double, Double, Double, Double, Double, SIMD3<Float>)] = [
            ("Mercury", 1.6601e-7, 0.383, 0.38709927, 0.20563593, 7.00497902, 48.33076593, 77.45779628, 252.25032350, color(0.7, 0.7, 0.7)),
            ("Venus",   2.4478e-6, 0.949, 0.72333566, 0.00677672, 3.39467605, 76.67984255, 131.60246718, 181.97909950, color(0.93, 0.78, 0.55)),
            ("Earth",   3.0404e-6, 1.000, 1.00000261, 0.01671123, 0.00001531, 0, 102.93768193, 100.46457166, color(0.25, 0.5, 1)),
            ("Mars",    3.2272e-7, 0.532, 1.52371034, 0.09339410, 1.84969142, 49.55953891, -23.94362959, -4.55343205, color(0.9, 0.4, 0.25)),
            ("Jupiter", 9.5479e-4, 11.21, 5.20288700, 0.04838624, 1.30439695, 100.47390909, 14.72847983, 34.39644051, color(0.85, 0.7, 0.52)),
            ("Saturn",  2.8589e-4, 9.45, 9.53667594, 0.05386179, 2.48599187, 113.66242448, 92.59887831, 49.95424423, color(0.92, 0.82, 0.58)),
            ("Uranus",  4.3662e-5, 4.01, 19.18916464, 0.04725744, 0.77263783, 74.01692503, 170.95427630, 313.23810451, color(0.6, 0.88, 0.92)),
            ("Neptune", 5.1514e-5, 3.88, 30.06992276, 0.00859048, 1.77004347, 131.78422574, 44.96476227, -55.12002969, color(0.3, 0.45, 0.95)),
        ]
        for p in planets {
            _ = s.add(p.0, .planet, mass: p.1, radius: p.2 * SandboxUnits.earthRadius, color: p.9, around: sun,
                      a: p.3, e: p.4, i: p.5, node: p.6, argPeri: p.7 - p.6, meanAnomaly: p.8 - p.7)
        }
        return SandboxScenario(
            id: "solar", name: "Our Solar System",
            blurb: "The real planets, now pulling on each other. Mercury's orbit slowly turns: about 532″ per century from the other planets, plus 43″ that only general relativity explains. Turn the speed of light down to exaggerate it.",
            bodies: s.centred(), options: SandboxOptions(), sceneUnitsPerAU: 10,
            speeds: [.init(label: "0.1 y/s", yearsPerSecond: 0.1), .init(label: "1 y/s", yearsPerSecond: 1),
                     .init(label: "10 y/s", yearsPerSecond: 10), .init(label: "50 y/s", yearsPerSecond: 50)],
            defaultSpeed: 1, follow: 0, cameraDistance: 80, gridHalfSizeAU: 12,
            tracker: (1, 0),
            precessionNote: "Mercury · relativity alone: 43″/century")
    }

    // MARK: S-stars around Sagittarius A*

    static var sagittariusA: SandboxScenario {
        var s = Builder()
        let bh = s.add("Sagittarius A*", .blackHole, mass: 4.297e6, radius: 0, color: color(0, 0, 0))
        // Approximate published orbits (GRAVITY / Gillessen et al.), oriented for viewing.
        _ = s.add("S2", .star, mass: 14, radius: 7 * SandboxUnits.sunRadius, color: color(0.7, 0.8, 1),
                  around: bh, a: 1037, e: 0.8847, i: 25, argPeri: 66, meanAnomaly: 180)
        _ = s.add("S38", .star, mass: 8, radius: 5 * SandboxUnits.sunRadius, color: color(1, 0.8, 0.6),
                  around: bh, a: 1172, e: 0.818, i: 60, node: 100, argPeri: 18, meanAnomaly: 40)
        _ = s.add("S55", .star, mass: 8, radius: 5 * SandboxUnits.sunRadius, color: color(1, 0.95, 0.8),
                  around: bh, a: 892, e: 0.72, i: 110, node: 300, argPeri: 133, meanAnomaly: 250)
        return SandboxScenario(
            id: "sgra", name: "S2 and Sagittarius A*",
            blurb: "Stars orbiting the 4.3-million-solar-mass black hole at the centre of our galaxy. S2's orbit turns by about 12′ each 16-year lap: measured by the GRAVITY telescope in 2020, matching Einstein.",
            bodies: s.centred(), options: SandboxOptions(), sceneUnitsPerAU: 0.02,
            speeds: [.init(label: "1 y/s", yearsPerSecond: 1), .init(label: "4 y/s", yearsPerSecond: 4),
                     .init(label: "16 y/s", yearsPerSecond: 16)],
            defaultSpeed: 1, follow: 0, cameraDistance: 70, gridHalfSizeAU: 2200,
            tracker: (1, 0), precessionNote: "S2 · Einstein: ≈ 12′ per orbit")
    }

    // MARK: Hulse–Taylor binary pulsar

    private static func hulseTaylorBodies(cScale: Double, a overrideA: Double? = nil, e: Double = 0.6171334) -> [SandboxBody] {
        var s = Builder()
        let P = 0.322997448918 / 365.25, m1 = 1.4398, m2 = 1.3886
        let a = overrideA ?? pow((m1 + m2) * P * P, 1.0 / 3)
        // Neutron stars scaled with c so they stay neutron stars (radius ∝ r_s ∝ 1/c²).
        let r = SandboxUnits.neutronStarRadius / (cScale * cScale)
        let a1 = s.add("Pulsar", .neutronStar, mass: m1, radius: r, color: color(0.7, 0.85, 1))
        _ = s.add("Companion", .neutronStar, mass: m2, radius: r, color: color(0.85, 0.9, 1),
                  around: a1, a: a, e: e, i: 20)
        return s.centred()
    }

    static var hulseTaylor: SandboxScenario {
        SandboxScenario(
            id: "hulse-taylor", name: "Hulse–Taylor pulsar",
            blurb: "Two neutron stars on a 7.75-hour orbit. Its long axis turns 4.2° a year, and the orbit shrinks as gravitational waves carry energy away: the first evidence for gravitational waves (Nobel Prize, 1993).",
            bodies: hulseTaylorBodies(cScale: 1), options: SandboxOptions(relativity: true, gravitationalWaves: true),
            sceneUnitsPerAU: 1000,
            speeds: [.init(label: "1 h/s", yearsPerSecond: hour), .init(label: "6 h/s", yearsPerSecond: 6 * hour),
                     .init(label: "1 d/s", yearsPerSecond: day), .init(label: "10 d/s", yearsPerSecond: 10 * day)],
            defaultSpeed: 1, follow: 0, cameraDistance: 40, gridHalfSizeAU: 0.03,
            tracker: (1, 0), precessionNote: "Observed: 4.23° per year")
    }

    static var neutronStarMerger: SandboxScenario {
        let cs = 0.02
        return SandboxScenario(
            id: "ns-merger", name: "Neutron-star merger",
            blurb: "The speed of light is turned down to 2%, making relativity 2,500× stronger, so two neutron stars spiral together in about a month instead of millions of years. Above about 2.3 solar masses the remnant collapses into a black hole.",
            bodies: hulseTaylorBodies(cScale: cs, a: 0.0045, e: 0.2),
            options: SandboxOptions(relativity: true, gravitationalWaves: true, cScale: cs),
            sceneUnitsPerAU: 4000,
            speeds: [.init(label: "1 h/s", yearsPerSecond: hour), .init(label: "6 h/s", yearsPerSecond: 6 * hour),
                     .init(label: "1 d/s", yearsPerSecond: day)],
            defaultSpeed: 1, follow: 0, cameraDistance: 50, gridHalfSizeAU: 0.009,
            tracker: nil, precessionNote: nil)
    }

    // MARK: Alpha Centauri (with invented planets)

    static var alphaCentauri: SandboxScenario {
        var s = Builder()
        let a = s.add("Alpha Centauri A", .star, mass: 1.0788, radius: 1.2175 * SandboxUnits.sunRadius, color: color(1, 0.9, 0.6))
        let b = s.add("Alpha Centauri B", .star, mass: 0.9092, radius: 0.8591 * SandboxUnits.sunRadius, color: color(1, 0.72, 0.4),
                      around: a, a: 23.4, e: 0.5179, i: 5, argPeri: 0, meanAnomaly: 180)
        _ = s.add("Aurelia", .planet, mass: SandboxUnits.earthMass, radius: SandboxUnits.earthRadius, color: color(0.3, 0.6, 1),
                  around: a, a: 1.25, e: 0.02, i: 1)
        _ = s.add("Ember", .planet, mass: 0.5 * SandboxUnits.earthMass, radius: 0.8 * SandboxUnits.earthRadius, color: color(0.9, 0.45, 0.3),
                  around: b, a: 0.7, e: 0.05, i: 2, meanAnomaly: 120)
        _ = s.add("Far Wanderer", .planet, mass: 0.3 * SandboxUnits.jupiterMass, radius: 9 * SandboxUnits.earthRadius, color: color(0.6, 0.8, 0.9),
                  aroundAll: true, a: 110, e: 0.05, i: 3, meanAnomaly: 60)
        return SandboxScenario(
            id: "alpha-cen", name: "Alpha Centauri (fictional planets)",
            blurb: "Our nearest sunlike stars orbit each other every 80 years. The planets are invented, but placed where real physics allows: close to one star, or far outside both.",
            bodies: s.centred(), options: SandboxOptions(relativity: false), sceneUnitsPerAU: 0.35,
            speeds: [.init(label: "1 y/s", yearsPerSecond: 1), .init(label: "10 y/s", yearsPerSecond: 10),
                     .init(label: "40 y/s", yearsPerSecond: 40)],
            defaultSpeed: 1, follow: 0, cameraDistance: 80, gridHalfSizeAU: 130,
            tracker: nil, precessionNote: nil)
    }

    // MARK: TRAPPIST-1

    static var trappist1: SandboxScenario {
        var s = Builder()
        let mStar = 0.0898
        let star = s.add("TRAPPIST-1", .star, mass: mStar, radius: 0.1192 * SandboxUnits.sunRadius, color: color(1, 0.45, 0.3))
        // period (days), mass (Earth), radius (Earth) — Agol et al. 2021
        let planets: [(String, Double, Double, Double)] = [
            ("b", 1.510826, 1.374, 1.116), ("c", 2.421937, 1.308, 1.097), ("d", 4.049219, 0.388, 0.788),
            ("e", 6.101013, 0.692, 0.920), ("f", 9.207540, 1.039, 1.045), ("g", 12.352446, 1.321, 1.129),
            ("h", 18.772866, 0.326, 0.755)]
        for (k, p) in planets.enumerated() {
            let m = p.2 * SandboxUnits.earthMass, P = p.1 / 365.25
            let a = pow((mStar + m) * P * P, 1.0 / 3)
            _ = s.add("TRAPPIST-1\(p.0)", .planet, mass: m, radius: p.3 * SandboxUnits.earthRadius,
                      color: color(0.5 + 0.07 * Float(k), 0.6, 0.9 - 0.08 * Float(k)),
                      around: star, a: a, e: 0.005, i: 0.2, meanAnomaly: Double(k) * 51)
        }
        return SandboxScenario(
            id: "trappist", name: "TRAPPIST-1",
            blurb: "Seven Earth-sized planets packed around a small red star, all closer than Mercury is to the Sun. Neighbouring planets' periods form near-whole-number ratios (8:5, 5:3, 3:2, 3:2, 4:3, 3:2): a resonant chain.",
            bodies: s.centred(), options: SandboxOptions(relativity: false), sceneUnitsPerAU: 300,
            speeds: [.init(label: "1 d/s", yearsPerSecond: day), .init(label: "10 d/s", yearsPerSecond: 10 * day),
                     .init(label: "100 d/s", yearsPerSecond: 100 * day)],
            defaultSpeed: 1, follow: 0, cameraDistance: 45, gridHalfSizeAU: 0.08,
            tracker: nil, precessionNote: nil)
    }
}
