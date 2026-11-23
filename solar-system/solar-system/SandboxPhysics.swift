import Foundation
import simd

// N-body gravity for the Sandbox, with optional general-relativistic corrections.
//
// Units: AU, years, solar masses (G = 4π²). Real c = 63,241 AU/yr; `cScale` turns it
// down to exaggerate relativity while everything else stays physical.
//
// Forces:
//  • Newtonian gravity.
//  • 1PN Einstein–Infeld–Hoffmann terms (the parametrized post-Newtonian form with
//    β = γ = 1 that JPL uses for planetary ephemerides) — gives perihelion precession.
//  • 2.5PN radiation reaction (harmonic gauge, applied pairwise) — energy lost to
//    gravitational waves, so tight binaries spiral in.
// Integrator: adaptive Dormand–Prince RK45 (velocity-dependent forces rule out leapfrog).

nonisolated enum SandboxUnits {
    static let G = 4 * Double.pi * Double.pi
    static let c = 63_241.077
    static let auKm = 149_597_870.7
    static let yearSeconds = 365.25 * 86_400
    static let earthMass = 3.003_489e-6
    static let jupiterMass = 9.547_919e-4
    static let earthRadius = 6_371 / auKm
    static let sunRadius = 695_700 / auKm
    static let neutronStarRadius = 12 / auKm
    /// Above this a neutron star can't support itself (≈ TOV limit).
    static let maxNeutronStarMass = 2.3
    static func kmPerSecond(_ auPerYear: Double) -> Double { auPerYear * auKm / yearSeconds }
}

nonisolated enum SandboxBodyKind: String, Codable, Hashable, Sendable {
    case star, planet, moon, neutronStar, blackHole
}

nonisolated struct SandboxBody: Identifiable, Sendable {
    let id: Int
    var name: String
    var kind: SandboxBodyKind
    var mass: Double                 // M☉
    var radius: Double               // AU (ignored for black holes: they use r_s)
    var position: SIMD3<Double>      // AU, ecliptic-like frame (z = "up")
    var velocity: SIMD3<Double>      // AU/yr
    var color: SIMD3<Float>
    var properTime: Double = 0       // years experienced by this body's clock
}

nonisolated struct SandboxOptions: Codable, Hashable, Sendable {
    var relativity = true
    var gravitationalWaves = false
    var cScale = 1.0
}

/// Tracks periapsis passages of `body` around `primary` and measures how fast the
/// orbit's long axis turns (perihelion precession).
nonisolated struct PrecessionTracker: Sendable {
    let body: Int
    let primary: Int
    private var prevRdot: Double?
    private var basis: (SIMD3<Double>, SIMD3<Double>)?
    private var firstAngle: Double?
    private var lastAngle: Double = 0
    private var unwrapped: Double = 0
    private var firstTime: Double = 0
    private(set) var lastTime: Double = 0
    private(set) var passages = 0
    private(set) var theoryPerOrbit: Double = 0    // radians, 6πGM / (c² a (1 − e²))
    private(set) var period: Double = 0            // years (osculating)

    init(body: Int, primary: Int) { self.body = body; self.primary = primary }

    /// Measured precession per orbit (radians), once two passages have been seen.
    var measuredPerOrbit: Double? {
        passages >= 2 ? (unwrapped) / Double(passages - 1) : nil
    }

    mutating func observe(_ a: SandboxBody, _ b: SandboxBody, time: Double, c: Double) {
        let r = a.position - b.position, v = a.velocity - b.velocity
        let rdot = simd_dot(r, v) / simd_length(r)
        defer { prevRdot = rdot }
        guard let prev = prevRdot, prev < 0, rdot >= 0 else { return }
        // Periapsis: direction of the (Newtonian) Laplace–Runge–Lenz vector.
        let gm = SandboxUnits.G * (a.mass + b.mass)
        let h = simd_cross(r, v)
        let lrl = simd_cross(v, h) / gm - simd_normalize(r)
        if basis == nil {
            let e1 = simd_normalize(lrl)
            basis = (e1, simd_normalize(simd_cross(simd_normalize(h), e1)))
        }
        let (e1, e2) = basis!
        let angle = atan2(simd_dot(lrl, e2), simd_dot(lrl, e1))
        if firstAngle == nil { firstAngle = angle; firstTime = time; lastAngle = angle }
        var d = angle - lastAngle
        if d > .pi { d -= 2 * .pi }; if d < -.pi { d += 2 * .pi }
        unwrapped += d; lastAngle = angle; lastTime = time
        passages += 1
        // Osculating elements for the theory value
        let e = simd_length(lrl)
        let energy = simd_length_squared(v) / 2 - gm / simd_length(r)
        let sma = -gm / (2 * energy)
        if sma > 0 {
            theoryPerOrbit = 6 * .pi * gm / (c * c * sma * (1 - e * e))
            period = sqrt(sma * sma * sma / (a.mass + b.mass))
        }
    }
}

nonisolated final class SandboxSimulation {
    private(set) var bodies: [SandboxBody]
    private(set) var time: Double = 0
    var options: SandboxOptions { didSet { fsal = nil } }
    var tracker: PrecessionTracker?
    /// Human-readable things that happened (mergers, collapse, absorption).
    private(set) var log: [(time: Double, message: String)] = []
    var rtol = 1e-10
    private var h: Double
    private var initialNewtonianEnergy: Double

    var c: Double { SandboxUnits.c * options.cScale }

    init(bodies: [SandboxBody], options: SandboxOptions, tracker: PrecessionTracker? = nil) {
        self.bodies = bodies; self.options = options; self.tracker = tracker
        // Start with a step of ~1/1000 of the fastest two-body period.
        var shortest = Double.infinity
        for i in bodies.indices { for j in bodies.indices where j > i {
            let r = simd_length(bodies[i].position - bodies[j].position)
            shortest = min(shortest, sqrt(r * r * r / (bodies[i].mass + bodies[j].mass)))
        }}
        h = shortest.isFinite ? shortest * 1e-3 : 1e-3
        initialNewtonianEnergy = SandboxSimulation.newtonianEnergy(bodies)
        checkCollapse()
    }

    func schwarzschildRadius(_ mass: Double) -> Double { 2 * SandboxUnits.G * mass / (c * c) }

    /// Size used for drawing and collisions: r_s for black holes, the physical radius otherwise.
    func effectiveRadius(_ b: SandboxBody) -> Double {
        b.kind == .blackHole ? schwarzschildRadius(b.mass) : b.radius
    }

    // MARK: Stepping

    /// Advance by `dt` years, stopping early if `budget` seconds of CPU are used.
    /// Returns false if it ran out of budget (the sim is falling behind real time).
    @discardableResult
    func advance(by dt: Double, budget: TimeInterval = .infinity) -> Bool {
        let target = time + dt
        let start = CFAbsoluteTimeGetCurrent()
        while time < target {
            step(maxStep: target - time)
            if bodies.count < 2 { time = target; break }
            if CFAbsoluteTimeGetCurrent() - start > budget { return false }
        }
        return true
    }

    private struct State { var p: [SIMD3<Double>]; var v: [SIMD3<Double>] }

    private func derivative(_ s: State) -> State {
        State(p: s.v, v: accelerations(positions: s.p, velocities: s.v))
    }

    private static func combine(_ y: State, _ hh: Double, _ ks: [(Double, State)]) -> State {
        var p = y.p, v = y.v
        for i in p.indices {
            var dp = SIMD3<Double>.zero, dv = SIMD3<Double>.zero
            for (w, k) in ks where w != 0 { dp += w * k.p[i]; dv += w * k.v[i] }
            p[i] += hh * dp; v[i] += hh * dv
        }
        return State(p: p, v: v)
    }

    private var fsal: State?

    /// One accepted Dormand–Prince step (retrying with smaller steps until the error fits).
    private func step(maxStep: Double) {
        let y = State(p: bodies.map(\.position), v: bodies.map(\.velocity))
        while true {
            let hh = min(h, maxStep)
            let k1 = fsal ?? derivative(y)
            let k2 = derivative(Self.combine(y, hh, [(1.0/5, k1)]))
            let k3 = derivative(Self.combine(y, hh, [(3.0/40, k1), (9.0/40, k2)]))
            let k4 = derivative(Self.combine(y, hh, [(44.0/45, k1), (-56.0/15, k2), (32.0/9, k3)]))
            let k5 = derivative(Self.combine(y, hh, [(19372.0/6561, k1), (-25360.0/2187, k2),
                                                    (64448.0/6561, k3), (-212.0/729, k4)]))
            let k6 = derivative(Self.combine(y, hh, [(9017.0/3168, k1), (-355.0/33, k2), (46732.0/5247, k3),
                                                    (49.0/176, k4), (-5103.0/18656, k5)]))
            let yNew = Self.combine(y, hh, [(35.0/384, k1), (500.0/1113, k3), (125.0/192, k4),
                                            (-2187.0/6784, k5), (11.0/84, k6)])
            let k7 = derivative(yNew)
            let errState = Self.combine(State(p: y.p.map { _ in .zero }, v: y.v.map { _ in .zero }), hh, [
                (71.0/57600, k1), (-71.0/16695, k3), (71.0/1920, k4),
                (-17253.0/339200, k5), (22.0/525, k6), (-1.0/40, k7)])
            // Error relative to each body's distance/speed from its nearest neighbour,
            // so a moon close to its planet is held to the moon's own scale.
            var err = 0.0
            for i in y.p.indices {
                let (ls, vs) = localScale(i, y)
                err = max(err, simd_length(errState.p[i]) / (rtol * ls),
                               simd_length(errState.v[i]) / (rtol * vs))
            }
            let factor = min(5, max(0.2, 0.9 * pow(max(err, 1e-30), -0.2)))
            if err <= 1 || hh < 1e-14 {
                time += hh
                for i in bodies.indices {
                    bodies[i].position = yNew.p[i]; bodies[i].velocity = yNew.v[i]
                }
                fsal = k7
                if hh >= h { h = hh * factor }   // a step clamped to the target doesn't shrink h
                afterStep(dt: hh)
                return
            }
            h = hh * factor
            fsal = k1
        }
    }

    private func localScale(_ i: Int, _ s: State) -> (Double, Double) {
        var best = Double.infinity, dv = 0.0, mj = 0.0
        for j in s.p.indices where j != i {
            let d = simd_length(s.p[i] - s.p[j])
            if d < best { best = d; dv = simd_length(s.v[i] - s.v[j]); mj = bodies[j].mass }
        }
        if !best.isFinite { return (1, 1) }
        let vOrbit = sqrt(SandboxUnits.G * (bodies[i].mass + mj) / best)
        return (best, max(dv, vOrbit, 1e-12))
    }

    private func afterStep(dt: Double) {
        // Proper time for every clock
        for i in bodies.indices { bodies[i].properTime += clockRate(i) * dt }
        recordTrails()
        if var t = tracker, t.body < bodies.count, t.primary < bodies.count {
            t.observe(bodies[t.body], bodies[t.primary], time: time, c: c)
            tracker = t
        }
        handleCollisions()
    }

    // MARK: Forces

    func accelerations(positions p: [SIMD3<Double>], velocities v: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let n = p.count, G = SandboxUnits.G
        let mu = bodies.map { G * $0.mass }
        var aN = [SIMD3<Double>](repeating: .zero, count: n)
        var invR = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                let d = p[j] - p[i]
                let r2 = simd_length_squared(d), r = sqrt(r2)
                invR[i * n + j] = 1 / r; invR[j * n + i] = 1 / r
                let f = d / (r2 * r)
                aN[i] += mu[j] * f; aN[j] -= mu[i] * f
            }
        }
        guard options.relativity || options.gravitationalWaves else { return aN }
        let c2 = c * c
        var a = aN
        if options.relativity {
            // Σ_l μ_l / r_il for each body
            var pot = [Double](repeating: 0, count: n)
            for i in 0..<n { for l in 0..<n where l != i { pot[i] += mu[l] * invR[i * n + l] } }
            for i in 0..<n {
                var corr = SIMD3<Double>.zero
                let vi2 = simd_length_squared(v[i])
                for j in 0..<n where j != i {
                    let rij = p[i] - p[j], ir = invR[i * n + j], ir3 = ir * ir * ir
                    let vj2 = simd_length_squared(v[j])
                    let rdotvj = simd_dot(rij, v[j]) * ir
                    let bracket = -4 * pot[i] / c2 - pot[j] / c2 + vi2 / c2 + 2 * vj2 / c2
                        - 4 * simd_dot(v[i], v[j]) / c2 - 1.5 * rdotvj * rdotvj / c2
                        + 0.5 * simd_dot(-rij, aN[j]) / c2
                    corr += mu[j] * (-rij) * ir3 * bracket
                    corr += mu[j] * ir3 / c2 * simd_dot(rij, 4 * v[i] - 3 * v[j]) * (v[i] - v[j])
                    corr += 3.5 / c2 * mu[j] * ir * aN[j]
                }
                a[i] += corr
            }
        }
        if options.gravitationalWaves {
            let c5 = c2 * c2 * c
            for i in 0..<n { for j in (i + 1)..<max(i + 1, n) {
                let m = bodies[i].mass + bodies[j].mass
                let eta = bodies[i].mass * bodies[j].mass / (m * m)
                let x = p[i] - p[j], vel = v[i] - v[j]
                let r = 1 / invR[i * n + j], nhat = x / r
                let gm = G * m, v2 = simd_length_squared(vel), rdot = simd_dot(nhat, vel)
                // Relative acceleration from radiation reaction (Kidder 1995, harmonic gauge)
                let k = 8.0 / 5.0 * eta * gm * gm / (c5 * r * r * r)
                let aRel = k * ((18 * v2 + 2.0 / 3.0 * gm / r - 25 * rdot * rdot) * rdot * nhat
                                - (6 * v2 - 2 * gm / r - 15 * rdot * rdot) * vel)
                a[i] += bodies[j].mass / m * aRel
                a[j] -= bodies[i].mass / m * aRel
            }}
        }
        return a
    }

    // MARK: Clocks

    /// How fast body `i`'s clock runs compared to a distant clock at rest (weak-field:
    /// √(1 − 2Φ/c² − v²/c²); this is exact for the gravity part of a static Schwarzschild field).
    func clockRate(_ i: Int) -> Double {
        let G = SandboxUnits.G, c2 = c * c
        var phi = 0.0
        for j in bodies.indices where j != i {
            phi += G * bodies[j].mass / simd_length(bodies[i].position - bodies[j].position)
        }
        return sqrt(max(0, 1 - 2 * phi / c2 - simd_length_squared(bodies[i].velocity) / c2))
    }

    // MARK: Energy

    static func newtonianEnergy(_ b: [SandboxBody]) -> Double {
        var e = 0.0
        for i in b.indices {
            e += 0.5 * b[i].mass * simd_length_squared(b[i].velocity)
            for j in b.indices where j > i {
                e -= SandboxUnits.G * b[i].mass * b[j].mass / simd_length(b[i].position - b[j].position)
            }
        }
        return e
    }

    /// Relative drift of Newtonian energy since the start. Only meaningful with relativity
    /// and gravitational waves off (they change the conserved quantity / remove energy).
    var energyDrift: Double {
        abs((Self.newtonianEnergy(bodies) - initialNewtonianEnergy) / initialNewtonianEnergy)
    }

    // MARK: Collisions, absorption, collapse

    private func handleCollisions() {
        var merged = true
        while merged {
            merged = false
            outer: for i in bodies.indices { for j in bodies.indices where j > i {
                let d = simd_length(bodies[i].position - bodies[j].position)
                if d < effectiveRadius(bodies[i]) + effectiveRadius(bodies[j]) {
                    merge(i, j); merged = true; break outer
                }
            }}
        }
        checkCollapse()
    }

    private func merge(_ i: Int, _ j: Int) {
        let a = bodies[i], b = bodies[j]
        let big = a.mass >= b.mass ? a : b, small = a.mass >= b.mass ? b : a
        let m = a.mass + b.mass
        var out = big
        out.mass = m
        out.position = (a.mass * a.position + b.mass * b.position) / m
        out.velocity = (a.mass * a.velocity + b.mass * b.velocity) / m
        out.radius = pow(pow(big.radius, 3) + pow(small.radius, 3), 1.0 / 3)
        let message: String
        if big.kind == .blackHole || small.kind == .blackHole {
            out.kind = .blackHole
            message = "\(small.name) fell into \(big.name)"
        } else if big.kind == .neutronStar && small.kind == .neutronStar {
            out.kind = m > SandboxUnits.maxNeutronStarMass ? .blackHole : .neutronStar
            out.name = "Merger remnant"
            out.radius = SandboxUnits.neutronStarRadius
            message = out.kind == .blackHole
                ? "Neutron stars merged and collapsed into a black hole"
                : "Neutron stars merged"
        } else {
            message = "\(small.name) collided with \(big.name)"
        }
        bodies.remove(at: max(i, j)); bodies.remove(at: min(i, j))
        bodies.append(out)
        tracker = nil
        fsal = nil
        trailInterval.removeAll()
        log.append((time, message))
    }

    /// A body smaller than its own Schwarzschild radius (possible when c is turned down)
    /// becomes a black hole; an overweight neutron star collapses.
    private func checkCollapse() {
        for i in bodies.indices where bodies[i].kind != .blackHole {
            let rs = schwarzschildRadius(bodies[i].mass)
            let tooHeavy = bodies[i].kind == .neutronStar && bodies[i].mass > SandboxUnits.maxNeutronStarMass
            if bodies[i].radius < rs || tooHeavy {
                bodies[i].kind = .blackHole
                log.append((time, "\(bodies[i].name) collapsed into a black hole"))
            }
        }
    }

    // MARK: Trails

    /// Recent positions per body id (oldest first), sampled inside the integrator so
    /// they stay smooth however fast the sim runs. Each body keeps ~2 orbits.
    private(set) var trails: [Int: [SIMD3<Double>]] = [:]
    private var trailInterval: [Int: Double] = [:]
    private var trailLast: [Int: Double] = [:]
    static let trailCapacity = 320

    /// The body each body orbits: the heavier body pulling hardest on it (nil for the
    /// dominant body of a system).
    func primary(of i: Int) -> Int? {
        var best: Int?, pull = 0.0
        for j in bodies.indices where j != i && bodies[j].mass > bodies[i].mass {
            let f = bodies[j].mass / simd_length_squared(bodies[i].position - bodies[j].position)
            if f > pull { pull = f; best = j }
        }
        return best
    }

    /// Osculating two-body period of `i` around `j` (or a crossing time if unbound).
    func period(_ i: Int, around j: Int) -> Double {
        let r = bodies[i].position - bodies[j].position, v = bodies[i].velocity - bodies[j].velocity
        let m = bodies[i].mass + bodies[j].mass
        let energy = simd_length_squared(v) / 2 - SandboxUnits.G * m / simd_length(r)
        if energy < 0 {
            let a = -SandboxUnits.G * m / (2 * energy)
            return sqrt(a * a * a / m)
        }
        return 2 * .pi * simd_length(r) / max(simd_length(v), 1e-12)
    }

    private func updateTrailIntervals() {
        trailInterval.removeAll()
        for i in bodies.indices {
            var P: Double?
            if let p = primary(of: i) { P = period(i, around: p) }
            else {
                // Dominant body: its wobble follows its heaviest companion.
                let others = bodies.indices.filter { $0 != i }
                if let k = others.max(by: { bodies[$0].mass / simd_length_squared(bodies[$0].position - bodies[i].position)
                                          < bodies[$1].mass / simd_length_squared(bodies[$1].position - bodies[i].position) }) {
                    P = period(k, around: i)
                }
            }
            if let P { trailInterval[bodies[i].id] = P * 2 / Double(Self.trailCapacity) }
        }
        let ids = Set(bodies.map(\.id))
        trails = trails.filter { ids.contains($0.key) }
    }

    private func recordTrails() {
        if trailInterval.count != bodies.count { updateTrailIntervals() }
        for b in bodies {
            guard let dt = trailInterval[b.id] else { continue }
            if let last = trailLast[b.id], time - last < dt { continue }
            trailLast[b.id] = time
            var t = trails[b.id] ?? []
            t.append(b.position)
            if t.count > Self.trailCapacity { t.removeFirst(t.count - Self.trailCapacity) }
            trails[b.id] = t
        }
    }

    /// Next unused body id.
    var nextID: Int { (bodies.map(\.id).max() ?? 0) + 1 }

    // MARK: Adding bodies (fling mode)

    /// Add a body mid-run. The energy baseline moves by the energy it brings, so the
    /// drift readout keeps measuring the integrator rather than the new arrival.
    func add(_ b: SandboxBody) {
        let before = Self.newtonianEnergy(bodies)
        var shortest = Double.infinity
        for o in bodies {
            let r = simd_length(b.position - o.position)
            shortest = min(shortest, sqrt(r * r * r / (b.mass + o.mass)))
        }
        bodies.append(b)
        initialNewtonianEnergy += Self.newtonianEnergy(bodies) - before
        fsal = nil
        if shortest.isFinite { h = min(h, shortest * 1e-3) }
        trailInterval.removeAll()
    }

    /// The body that controls motion at `p`: the one with the smallest Hill sphere
    /// containing it (a planet near a planet, the star elsewhere). The heaviest body's
    /// sphere is unbounded.
    func dominantBody(at p: SIMD3<Double>) -> Int? {
        guard let heaviest = bodies.indices.max(by: { bodies[$0].mass < bodies[$1].mass }) else { return nil }
        var best = heaviest, bestHill = Double.infinity
        for j in bodies.indices where j != heaviest {
            guard let k = primary(of: j) else { continue }
            let a = simd_length(bodies[j].position - bodies[k].position)
            let hill = a * cbrt(bodies[j].mass / (3 * bodies[k].mass))
            if simd_length(p - bodies[j].position) < hill && hill < bestHill { best = j; bestHill = hill }
        }
        return best
    }

    /// Where body `b` would go if added now: its positions relative to body `relativeTo`,
    /// sampled `samples` times over `duration` years (shorter if `budget` runs out or it
    /// merges). Runs a scratch copy with the same physics as the live sim.
    func predictPath(adding b: SandboxBody, relativeTo ref: Int, duration: Double, samples: Int = 240,
                     budget: TimeInterval = 0.012) -> [SIMD3<Double>] {
        let scratch = SandboxSimulation(bodies: bodies + [b], options: options)
        scratch.rtol = max(rtol, 1e-9)
        let refID = bodies[ref].id
        let start = CFAbsoluteTimeGetCurrent()
        var out: [SIMD3<Double>] = []
        for k in 0...samples {
            if k > 0 {
                let left = budget - (CFAbsoluteTimeGetCurrent() - start)
                guard left > 0, scratch.advance(by: duration / Double(samples), budget: left) else { break }
            }
            guard let me = scratch.bodies.first(where: { $0.id == b.id }),
                  let r = scratch.bodies.first(where: { $0.id == refID }) else { break }
            out.append(me.position - r.position)
        }
        return out
    }
}

// MARK: - Orbit setup helper

nonisolated enum Kepler {
    /// Relative state (secondary − primary) for an orbit with the given elements.
    /// Angles in degrees; `meanAnomaly` 0 = periapsis. Frame: x toward the reference
    /// direction, z = orbit-plane normal at zero inclination.
    static func state(totalMass m: Double, a: Double, e: Double, i: Double = 0, node: Double = 0,
                      argPeri: Double = 0, meanAnomaly: Double = 0) -> (SIMD3<Double>, SIMD3<Double>) {
        let rad = Double.pi / 180
        let M = meanAnomaly * rad
        var E = M
        for _ in 0..<60 { E -= (E - e * sin(E) - M) / (1 - e * cos(E)) }
        let nu = 2 * atan2(sqrt(1 + e) * sin(E / 2), sqrt(1 - e) * cos(E / 2))
        let r = a * (1 - e * cos(E))
        let gm = SandboxUnits.G * m, p = a * (1 - e * e)
        let px = SIMD3(r * cos(nu), r * sin(nu), 0)
        let vx = SIMD3(-sqrt(gm / p) * sin(nu), sqrt(gm / p) * (e + cos(nu)), 0)
        // Rotate: argPeri about z, inclination about x, node about z
        func rz(_ v: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
            SIMD3(v.x * cos(t) - v.y * sin(t), v.x * sin(t) + v.y * cos(t), v.z)
        }
        func rx(_ v: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
            SIMD3(v.x, v.y * cos(t) - v.z * sin(t), v.y * sin(t) + v.z * cos(t))
        }
        let rot = { (v: SIMD3<Double>) in rz(rx(rz(v, argPeri * rad), i * rad), node * rad) }
        return (rot(px), rot(vx))
    }
}
