import Foundation
import Testing
import simd
@testable import SolarSystemMac

/// Checks the Sandbox physics against textbook and measured values.
struct SandboxPhysicsTests {

    private func body(_ id: Int, _ name: String, _ kind: SandboxBodyKind, mass: Double, radius: Double = 1e-9,
                      p: SIMD3<Double> = .zero, v: SIMD3<Double> = .zero) -> SandboxBody {
        SandboxBody(id: id, name: name, kind: kind, mass: mass, radius: radius, position: p, velocity: v, color: .one)
    }

    /// Two-body system with the secondary on the given orbit, in the barycentric frame.
    private func binary(m1: Double, m2: Double, a: Double, e: Double,
                        kind1: SandboxBodyKind = .star, kind2: SandboxBodyKind = .planet) -> [SandboxBody] {
        let (r, v) = Kepler.state(totalMass: m1 + m2, a: a, e: e)
        let m = m1 + m2
        return [body(0, "A", kind1, mass: m1, p: -m2 / m * r, v: -m2 / m * v),
                body(1, "B", kind2, mass: m2, p: m1 / m * r, v: m1 / m * v)]
    }

    @Test func newtonianEnergyIsConserved() {
        let sim = SandboxSimulation(bodies: binary(m1: 1, m2: SandboxUnits.earthMass, a: 1, e: 0.3),
                                    options: SandboxOptions(relativity: false))
        sim.rtol = 1e-12
        sim.advance(by: 1000)   // 1,000 orbits
        #expect(sim.energyDrift < 1e-8, "drift \(sim.energyDrift)")
    }

    @Test func mercuryPerihelionPrecession() {
        // Sun + Mercury only: relativity alone should give ≈ 42.98″ per century.
        let sim = SandboxSimulation(bodies: binary(m1: 1, m2: 1.6601e-7, a: 0.387098, e: 0.205630),
                                    options: SandboxOptions(relativity: true),
                                    tracker: PrecessionTracker(body: 1, primary: 0))
        sim.rtol = 1e-12
        sim.advance(by: 100)
        let t = try! #require(sim.tracker)
        let perOrbit = try! #require(t.measuredPerOrbit)
        let arcsecPerCentury = perOrbit * (100 / t.period) * 180 / .pi * 3600
        #expect(abs(arcsecPerCentury - 42.98) / 42.98 < 0.05, "\(arcsecPerCentury)″/century")
    }

    @Test func s2PrecessionAroundSagittariusAStar() {
        // S2: a ≈ 1,037 AU, e = 0.8847 around 4.297 million M☉ → ≈ 12.1′ per orbit.
        let sim = SandboxSimulation(bodies: binary(m1: 4.297e6, m2: 14, a: 1037, e: 0.8847,
                                                   kind1: .blackHole, kind2: .star),
                                    options: SandboxOptions(relativity: true),
                                    tracker: PrecessionTracker(body: 1, primary: 0))
        sim.rtol = 1e-11
        sim.advance(by: 16.05 * 5.2)
        let t = try! #require(sim.tracker)
        let measured = try! #require(t.measuredPerOrbit) * 180 / .pi * 60
        let theory = t.theoryPerOrbit * 180 / .pi * 60
        #expect(abs(theory - 12.1) / 12.1 < 0.05, "theory \(theory)′")
        #expect(abs(measured - theory) / theory < 0.05, "measured \(measured)′ vs \(theory)′")
    }

    @Test func hulseTaylorPeriastronAdvance() {
        // PSR B1913+16: observed 4.2266° per year.
        let P = 0.322997448918 / 365.25, m1 = 1.4398, m2 = 1.3886
        let a = pow((m1 + m2) * P * P, 1.0 / 3)
        let sim = SandboxSimulation(bodies: binary(m1: m1, m2: m2, a: a, e: 0.6171334,
                                                   kind1: .neutronStar, kind2: .neutronStar),
                                    options: SandboxOptions(relativity: true),
                                    tracker: PrecessionTracker(body: 1, primary: 0))
        sim.rtol = 1e-11
        sim.advance(by: 1)
        let t = try! #require(sim.tracker)
        let degPerYear = try! #require(t.measuredPerOrbit) / P * 180 / .pi
        #expect(abs(degPerYear - 4.2266) / 4.2266 < 0.05, "\(degPerYear)°/yr")
    }

    @Test func gravitationalWaveOrbitalDecayMatchesPetersMathews() {
        // Hulse–Taylor orbit with c × 0.05 so the decay is measurable in a few hundred orbits;
        // compare dP/dt with the Peters–Mathews formula at the same c.
        let P0 = 0.322997448918 / 365.25, m1 = 1.4398, m2 = 1.3886, e = 0.6171334
        let a = pow((m1 + m2) * P0 * P0, 1.0 / 3)
        let opts = SandboxOptions(relativity: true, gravitationalWaves: true, cScale: 0.05)
        let sim = SandboxSimulation(bodies: binary(m1: m1, m2: m2, a: a, e: e,
                                                   kind1: .neutronStar, kind2: .neutronStar),
                                    options: opts, tracker: PrecessionTracker(body: 1, primary: 0))
        sim.rtol = 1e-11
        var samples: [(Double, Double)] = []
        var seen = 0
        while samples.count < 300 {
            sim.advance(by: P0 / 8)
            if let t = sim.tracker, t.passages > seen { seen = t.passages; samples.append((t.lastTime, t.period)) }
        }
        // Least-squares slope of period vs time
        let n = Double(samples.count)
        let mt = samples.map(\.0).reduce(0, +) / n, mp = samples.map(\.1).reduce(0, +) / n
        let slope = samples.map { ($0.0 - mt) * ($0.1 - mp) }.reduce(0, +)
                  / samples.map { ($0.0 - mt) * ($0.0 - mt) }.reduce(0, +)
        let c = SandboxUnits.c * 0.05, G = SandboxUnits.G
        let mChirp = pow(m1 * m2, 0.6) / pow(m1 + m2, 0.2)
        let fe = (1 + 73.0 / 24 * e * e + 37.0 / 96 * pow(e, 4)) / pow(1 - e * e, 3.5)
        let expected = -192 * Double.pi / 5 * pow(2 * Double.pi * G * mChirp / (c * c * c * P0), 5.0 / 3) * fe
        #expect(slope < 0)
        #expect(abs(slope - expected) / abs(expected) < 0.10, "dP/dt \(slope) vs \(expected)")
    }

    @Test func blackHoleAbsorbsWhatFallsIn() {
        let bh = body(0, "BH", .blackHole, mass: 10)
        let rock = body(1, "Rock", .planet, mass: 1e-6, p: SIMD3(0.001, 0, 0), v: SIMD3(0, 0.5, 0))
        let sim = SandboxSimulation(bodies: [bh, rock], options: SandboxOptions(relativity: false))
        let p0 = bh.mass * bh.velocity + rock.mass * rock.velocity
        sim.advance(by: 0.01)
        #expect(sim.bodies.count == 1)
        #expect(sim.bodies[0].kind == .blackHole)
        #expect(abs(sim.bodies[0].mass - 10.000001) < 1e-12)
        #expect(simd_length(sim.bodies[0].mass * sim.bodies[0].velocity - p0) < 1e-12)
    }

    @Test func neutronStarsMergeIntoBlackHole() {
        let r = SandboxUnits.neutronStarRadius
        let a = body(0, "NS A", .neutronStar, mass: 1.4, radius: r, p: SIMD3(-3 * r, 0, 0))
        let b = body(1, "NS B", .neutronStar, mass: 1.4, radius: r, p: SIMD3(3 * r, 0, 0))
        let sim = SandboxSimulation(bodies: [a, b], options: SandboxOptions(relativity: false))
        sim.advance(by: 1e-6)
        #expect(sim.bodies.count == 1)
        #expect(sim.bodies[0].kind == .blackHole)
        #expect(sim.log.contains { $0.message.contains("black hole") })
    }

    @Test func clocksRunSlowDeepInAGravityWell() {
        // Earth's surface vs far away: 1 − GM/(Rc²) ≈ 1 − 6.96e-10
        let earth = body(0, "Earth", .planet, mass: SandboxUnits.earthMass)
        let clock = body(1, "Clock", .moon, mass: 1e-30, p: SIMD3(SandboxUnits.earthRadius, 0, 0))
        let sim = SandboxSimulation(bodies: [earth, clock], options: SandboxOptions())
        #expect(abs((1 - sim.clockRate(1)) - 6.96e-10) / 6.96e-10 < 0.01)
    }
}

/// The light-bending integration the black-hole shader uses (BlackHoleLens.metal).
struct SchwarzschildRayTests {
    @Test func shadowEdgeIsAtTheCriticalImpactParameter() {
        let bc = SchwarzschildRay.criticalImpactParameter
        #expect(SchwarzschildRay.deflection(b: bc * 0.999) == nil)
        #expect(SchwarzschildRay.deflection(b: bc * 1.001) != nil)
    }

    @Test func weakFieldMatchesEinstein() {
        // α = 2 r_s / b far from the hole (the 1919 eclipse result).
        for b in [200.0, 1000.0] {
            let a = try! #require(SchwarzschildRay.deflection(b: b))
            #expect(abs(a / (2 / b) - 1) < 0.01, "b = \(b): \(a)")
        }
    }

    @Test func bendingGrowsWithoutLimitNearThePhotonSphere() {
        let bc = SchwarzschildRay.criticalImpactParameter
        let a = [1.5, 1.1, 1.01, 1.001].map { SchwarzschildRay.deflection(b: bc * $0)! }
        #expect(a == a.sorted())
        #expect(a.last! > 2 * .pi)      // light circles the hole before escaping
    }
}
