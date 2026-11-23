import Foundation
import simd

// A Sandbox system as the user designs it: bodies described by what they orbit and
// their orbital elements, not raw positions. `build()` turns it into starting states
// for the simulation. Presets are designs too, so any of them can be copied and edited.

nonisolated struct DesignBody: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var kind: SandboxBodyKind
    var mass: Double                    // M☉
    var radius: Double                  // AU (ignored for black holes)
    var autoRadius = true               // radius follows mass (see `SandboxPhysicalDefaults`)
    var color: SIMD3<Float>
    /// Body it orbits. nil = the centre of mass of everything before it in the tree
    /// (the first body sits at the origin; later ones orbit everything above them).
    var parent: Int?
    var a = 0.0                         // AU
    var e = 0.0
    var i = 0.0                         // degrees
    var node = 0.0
    var argPeri = 0.0
    var meanAnomaly = 0.0
}

nonisolated struct SandboxDesign: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var bodies: [DesignBody]
    var options = SandboxOptions()
    /// The preset this was copied from, if any.
    var presetID: String?

    func body(_ id: Int) -> DesignBody? { bodies.first { $0.id == id } }
    var nextID: Int { (bodies.map(\.id).max() ?? -1) + 1 }

    func children(of id: Int?) -> [DesignBody] { bodies.filter { $0.parent == id } }

    /// Bodies in tree order (each parent before its satellites; roots in list order),
    /// with their depth. This is also the build order.
    var tree: [(body: DesignBody, depth: Int)] {
        var out: [(DesignBody, Int)] = []
        let ids = Set(bodies.map(\.id))
        func visit(_ b: DesignBody, _ depth: Int) {
            out.append((b, depth))
            for c in bodies where c.parent == b.id && c.id != b.id { visit(c, depth + 1) }
        }
        // Roots: no parent, or a parent that no longer exists.
        for b in bodies where b.parent == nil || !ids.contains(b.parent!) { visit(b, 0) }
        return out
    }

    /// The body and everything orbiting it (directly or not).
    func descendants(of id: Int) -> Set<Int> {
        var out: Set<Int> = [id], grew = true
        while grew {
            grew = false
            for b in bodies where !out.contains(b.id) { if let p = b.parent, out.contains(p) { out.insert(b.id); grew = true } }
        }
        return out
    }

    /// Mass of whatever `b` orbits: its parent, or everything before it in the tree.
    func centralMass(of b: DesignBody) -> Double {
        if let p = b.parent, let pb = body(p) { return pb.mass }
        var m = 0.0
        for (x, _) in tree { if x.id == b.id { break }; m += x.mass }
        return m
    }

    /// Starting states in the barycentric frame, in list order, plus the position each
    /// body's orbit is centred on (its parent or the centre of mass it orbits).
    func build() -> (bodies: [SandboxBody], centres: [Int: SIMD3<Double>]) {
        var built: [Int: SandboxBody] = [:]
        var order: [Int] = []
        var centres: [Int: SIMD3<Double>] = [:]
        var mSum = 0.0, pSum = SIMD3<Double>.zero, vSum = SIMD3<Double>.zero
        for (b, _) in tree {
            var p = SIMD3<Double>.zero, v = SIMD3<Double>.zero
            var centre: (m: Double, p: SIMD3<Double>, v: SIMD3<Double>)?
            if let pid = b.parent, let par = built[pid] {
                centre = (par.mass, par.position, par.velocity)
            } else if mSum > 0 {
                centre = (mSum, pSum / mSum, vSum / mSum)
            }
            if let c = centre {
                let (r, vel) = Kepler.state(totalMass: c.m + b.mass, a: b.a, e: b.e, i: b.i, node: b.node,
                                            argPeri: b.argPeri, meanAnomaly: b.meanAnomaly)
                p = c.p + r; v = c.v + vel
                centres[b.id] = c.p
            }
            built[b.id] = SandboxBody(id: b.id, name: b.name, kind: b.kind, mass: b.mass, radius: b.radius,
                                      position: p, velocity: v, color: b.color)
            order.append(b.id)
            mSum += b.mass; pSum += b.mass * p; vSum += b.mass * v
        }
        guard mSum > 0 else { return ([], [:]) }
        let com = pSum / mSum, vcom = vSum / mSum
        var out: [SandboxBody] = []
        for b in bodies {
            guard var s = built[b.id] else { continue }
            s.position -= com; s.velocity -= vcom
            out.append(s)
        }
        for k in centres.keys { centres[k]! -= com }
        return (out, centres)
    }

    /// Orbital period of `b` around what it orbits (years), if it orbits something.
    func period(of b: DesignBody) -> Double? {
        let M = centralMass(of: b)
        guard M > 0, b.a > 0, b.e < 1 else { return nil }
        return sqrt(b.a * b.a * b.a / (M + b.mass))
    }

    /// A blank system: one Sun-like star.
    static func blank(name: String = "New system") -> SandboxDesign {
        var star = SandboxPhysicalDefaults.body(kind: .star, id: 0, name: "Star")
        star.mass = 1
        SandboxPhysicalDefaults.applyMass(&star)
        return SandboxDesign(name: name, bodies: [star])
    }
}

// MARK: - Physical defaults

nonisolated enum SandboxPhysicalDefaults {
    /// Main-sequence luminosity in L☉.
    static func luminosity(mass m: Double) -> Double {
        m < 0.43 ? 0.23 * pow(m, 2.3) : pow(m, 4)
    }

    /// Radius in AU that follows from mass for this kind of body.
    static func radius(kind: SandboxBodyKind, mass m: Double) -> Double {
        switch kind {
        case .star:
            return (m < 1 ? pow(m, 0.8) : pow(m, 0.57)) * SandboxUnits.sunRadius
        case .planet, .moon:
            // Chen & Kipping (2017), with gas giants capped at Jupiter's radius.
            let me = m / SandboxUnits.earthMass
            let re = me < 2 ? pow(me, 0.279) : min(0.808 * pow(me, 0.589), 11.2)
            return re * SandboxUnits.earthRadius
        case .neutronStar: return SandboxUnits.neutronStarRadius
        case .blackHole: return 0
        }
    }

    /// Star colour from mass (via main-sequence temperature).
    static func starColor(mass m: Double) -> SIMD3<Float> {
        let stops: [(Double, SIMD3<Float>)] = [
            (0.1, SIMD3(1, 0.42, 0.28)), (0.45, SIMD3(1, 0.58, 0.32)), (0.8, SIMD3(1, 0.76, 0.45)),
            (1.0, SIMD3(1, 0.86, 0.5)), (1.5, SIMD3(1, 0.95, 0.82)), (3, SIMD3(0.82, 0.88, 1)), (20, SIMD3(0.62, 0.74, 1))]
        let lm = log(max(m, 0.1))
        for k in 1..<stops.count where lm <= log(stops[k].0) {
            let (m0, c0) = stops[k - 1], (m1, c1) = stops[k]
            let t = Float((lm - log(m0)) / (log(m1) - log(m0)))
            return simd_mix(c0, c1, SIMD3(repeating: max(0, min(1, t))))
        }
        return stops.last!.1
    }

    static func applyMass(_ b: inout DesignBody) {
        if b.autoRadius { b.radius = radius(kind: b.kind, mass: b.mass) }
        if b.kind == .star { b.color = starColor(mass: b.mass) }
    }

    private static let planetPalette: [SIMD3<Float>] = [
        SIMD3(0.3, 0.55, 1), SIMD3(0.85, 0.5, 0.3), SIMD3(0.55, 0.8, 0.55), SIMD3(0.85, 0.75, 0.55),
        SIMD3(0.6, 0.85, 0.95), SIMD3(0.75, 0.55, 0.85), SIMD3(0.9, 0.85, 0.7)]

    static func body(kind: SandboxBodyKind, id: Int, name: String) -> DesignBody {
        var b: DesignBody
        switch kind {
        case .star:
            b = DesignBody(id: id, name: name, kind: .star, mass: 0.5, radius: 0, color: .one)
        case .planet:
            b = DesignBody(id: id, name: name, kind: .planet, mass: SandboxUnits.earthMass, radius: 0,
                           color: planetPalette[id % planetPalette.count])
        case .moon:
            b = DesignBody(id: id, name: name, kind: .moon, mass: 0.0123 * SandboxUnits.earthMass, radius: 0,
                           color: SIMD3(0.72, 0.72, 0.72))
        case .neutronStar:
            b = DesignBody(id: id, name: name, kind: .neutronStar, mass: 1.4, radius: 0, color: SIMD3(0.7, 0.85, 1))
        case .blackHole:
            b = DesignBody(id: id, name: name, kind: .blackHole, mass: 10, radius: 0, color: .zero)
        }
        applyMass(&b)
        return b
    }
}

// MARK: - Automatic view settings

nonisolated enum SandboxAutoView {
    /// Scene scale, camera distance, grid size and speeds that fit a design.
    static func settings(for d: SandboxDesign) -> (sceneUnitsPerAU: Double, cameraDistance: Float,
                                                   gridHalfSizeAU: Double, speeds: [SandboxSpeed], defaultSpeed: Int) {
        let (_, centres) = d.build()
        var extent = 0.0
        var periods: [Double] = []
        for b in d.bodies {
            if let c = centres[b.id] { extent = max(extent, simd_length(c) + b.a * (1 + b.e)) }
            if let P = d.period(of: b) { periods.append(P) }
        }
        if extent <= 0 { extent = 1 }
        let scale = 40 / extent
        let pMin = periods.min() ?? 1, pMax = periods.max() ?? 1
        // From "fastest orbit in ~10 s" up to "slowest orbit in ~5 s", four steps.
        let lo = pMin / 10, hi = max(pMax / 5, lo * 30)
        var speeds: [SandboxSpeed] = []
        for k in 0..<4 {
            let raw = lo * pow(hi / lo, Double(k) / 3)
            let s = friendlySpeed(raw)
            if speeds.last?.label != s.label { speeds.append(s) }
        }
        return (scale, 80, extent * 1.25, speeds, min(1, speeds.count - 1))
    }

    /// Rounds years-per-second to 1, 2 or 5 × a power of ten in hours, days or years.
    static func friendlySpeed(_ yearsPerSecond: Double) -> SandboxSpeed {
        let hours = yearsPerSecond * 365.25 * 24
        let (value, unit, perYear): (Double, String, Double) =
            hours < 24 ? (hours, "h", 365.25 * 24) : hours < 24 * 200 ? (hours / 24, "d", 365.25) : (yearsPerSecond, "y", 1)
        let exp = floor(log10(value))
        let mant = value / pow(10, exp)
        let nice = mant < 1.5 ? 1.0 : mant < 3.5 ? 2.0 : mant < 7.5 ? 5.0 : 10.0
        let v = nice * pow(10, exp)
        let label = v >= 1 ? "\(Int(v.rounded())) \(unit)/s" : "\(v.formatted(.number.precision(.significantDigits(1)))) \(unit)/s"
        return SandboxSpeed(label: label, yearsPerSecond: v / perYear)
    }
}

// MARK: - Saved designs

enum SandboxDesignStore {
    private static let key = "sandboxDesigns"

    static func load() -> [SandboxDesign] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SandboxDesign].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SandboxDesign]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Orbit geometry

nonisolated extension Kepler {
    /// Points around a full orbit (relative to what it orbits), sampled evenly in eccentric anomaly.
    static func orbitPoints(a: Double, e: Double, i: Double, node: Double, argPeri: Double,
                            count: Int = 128) -> [SIMD3<Double>] {
        let rad = Double.pi / 180, b = a * sqrt(max(0, 1 - e * e))
        let (cw, sw) = (cos(argPeri * rad), sin(argPeri * rad))
        let (ci, si) = (cos(i * rad), sin(i * rad))
        let (cn, sn) = (cos(node * rad), sin(node * rad))
        return (0...count).map { k in
            let E = Double(k) / Double(count) * 2 * .pi
            let x0 = a * (cos(E) - e), y0 = b * sin(E)
            let x1 = x0 * cw - y0 * sw, y1 = x0 * sw + y0 * cw
            let y2 = y1 * ci, z2 = y1 * si
            return SIMD3(x1 * cn - y2 * sn, x1 * sn + y2 * cn, z2)
        }
    }
}
