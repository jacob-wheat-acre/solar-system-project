import Foundation

// Predictions about a designed system, from standard rules of thumb. They're warnings,
// not verdicts: pressing Play runs the real N-body simulation and shows what happens.

nonisolated struct SandboxWarning: Identifiable, Hashable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case info, caution, problem
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    let bodyID: Int
    let severity: Severity
    let message: String
    var id: String { "\(bodyID)|\(message)" }
}

nonisolated enum HabitableZoneStatus: String, Sendable {
    case tooHot = "too hot", inside = "in the habitable zone", tooCold = "too cold"
}

nonisolated enum SandboxAnalysis {

    // MARK: Building blocks

    /// Conservative habitable zone (AU) for a main-sequence star: where liquid water is
    /// possible on an Earth-like planet (Kopparapu et al. 2013, simplified).
    static func habitableZone(starMass m: Double) -> ClosedRange<Double> {
        let L = SandboxPhysicalDefaults.luminosity(mass: m)
        return sqrt(L / 1.1)...sqrt(L / 0.53)
    }

    /// Hill radius (AU): how far out a body's gravity beats its parent's tides.
    static func hillRadius(_ b: DesignBody, in d: SandboxDesign) -> Double? {
        let M = d.centralMass(of: b)
        guard M > 0, b.a > 0, b.parent != nil || d.tree.first?.body.id != b.id else { return nil }
        return b.a * (1 - b.e) * cbrt(b.mass / (3 * M))
    }

    /// Distance (AU) inside which `b` would be torn apart by a parent of mass `parentMass`
    /// (fluid Roche limit, 2.44 R (M/m)^⅓).
    static func rocheLimit(of b: DesignBody, parentMass: Double) -> Double {
        guard b.kind != .blackHole, b.radius > 0, b.mass > 0 else { return 0 }
        return 2.44 * b.radius * cbrt(parentMass / b.mass)
    }

    /// Range of distances where a rocky moon could orbit `b` stably: outside the Roche
    /// limit for rock (density 3 g/cm³), inside half the Hill radius.
    static func moonZone(_ b: DesignBody, in d: SandboxDesign) -> (roche: Double, hill: Double?) {
        let rockDensity = 3000.0, auM = SandboxUnits.auKm * 1000
        var roche = 0.0
        if b.radius > 0, b.kind != .blackHole {
            let volume = 4.0 / 3 * Double.pi * pow(b.radius * auM, 3)
            let density = b.mass * 1.98847e30 / volume
            roche = 2.44 * b.radius * cbrt(density / rockDensity)
        }
        return (roche, hillRadius(b, in: d).map { $0 / 2 })
    }

    /// The star a body ultimately orbits, and its distance from that star (AU).
    static func hostStar(of b: DesignBody, in d: SandboxDesign) -> (star: DesignBody, distance: Double)? {
        var cur = b
        while let p = cur.parent, let par = d.body(p) {
            if par.kind == .star { return (par, cur.a) }
            cur = par
        }
        return nil
    }

    static func habitableStatus(_ b: DesignBody, in d: SandboxDesign) -> HabitableZoneStatus? {
        guard b.kind == .planet || b.kind == .moon, let (star, dist) = hostStar(of: b, in: d) else { return nil }
        let hz = habitableZone(starMass: star.mass)
        return dist < hz.lowerBound ? .tooHot : dist > hz.upperBound ? .tooCold : .inside
    }

    /// Two stars orbiting each other: (primary, secondary, a, e) when `star` is in one.
    static func binary(containing star: DesignBody, in d: SandboxDesign) -> (DesignBody, DesignBody, Double, Double)? {
        let isStellar: (DesignBody) -> Bool = { $0.kind == .star || $0.kind == .neutronStar || $0.kind == .blackHole }
        if let p = star.parent, let par = d.body(p), isStellar(par) { return (par, star, star.a, star.e) }
        if let c = d.children(of: star.id).filter(isStellar).max(by: { $0.mass < $1.mass }) { return (star, c, c.a, c.e) }
        return nil
    }

    /// Holman & Wiegert (1999): widest stable orbit around one star of a binary
    /// (`mu` = companion mass fraction).
    static func sTypeLimit(aBin: Double, e: Double, mu: Double) -> Double {
        (0.464 - 0.380 * mu - 0.631 * e + 0.586 * mu * e + 0.150 * e * e - 0.198 * mu * e * e) * aBin
    }

    /// Holman & Wiegert (1999): closest stable orbit around both stars of a binary.
    static func pTypeLimit(aBin: Double, e: Double, mu: Double) -> Double {
        (1.60 + 5.10 * e - 2.22 * e * e + 4.12 * mu - 4.27 * e * mu - 5.09 * mu * mu + 4.61 * e * e * mu * mu) * aBin
    }

    // MARK: Checks

    static func check(_ d: SandboxDesign) -> [SandboxWarning] {
        var out: [SandboxWarning] = []
        let c = SandboxUnits.c * d.options.cScale
        let firstID = d.tree.first?.body.id
        func warn(_ b: DesignBody, _ s: SandboxWarning.Severity, _ m: String) { out.append(.init(bodyID: b.id, severity: s, message: m)) }

        for b in d.bodies {
            if b.kind == .neutronStar && b.mass > SandboxUnits.maxNeutronStarMass {
                warn(b, .caution, "\(b.name) is too heavy to be a neutron star (over 2.3 M☉): it will collapse into a black hole.")
            }
            guard b.id != firstID else { continue }
            if b.e >= 1 { warn(b, .problem, "\(b.name) is on an escape orbit (eccentricity ≥ 1)."); continue }
            let peri = b.a * (1 - b.e), apo = b.a * (1 + b.e)

            if let p = b.parent, let par = d.body(p) {
                // Collisions, the black hole's innermost stable orbit, tides
                if par.kind == .blackHole {
                    let rs = 2 * SandboxUnits.G * par.mass / (c * c)
                    if peri < 3 * rs {
                        warn(b, .problem, "\(b.name) comes inside \(par.name)'s innermost stable orbit (3 × the event horizon) and will plunge in.")
                    }
                } else if peri < par.radius + max(b.radius, 0) {
                    warn(b, .problem, "\(b.name)'s orbit passes inside \(par.name): they'll collide.")
                }
                let roche = rocheLimit(of: b, parentMass: par.mass)
                if peri < roche && peri >= par.radius + b.radius {
                    let fate = b.kind == .star ? "stripped into a stream of gas" : "torn apart into a ring"
                    warn(b, .problem, "\(b.name) comes inside \(par.name)'s Roche limit (\(SandboxFormat.distance(roche))) and would be \(fate).")
                }
                // Moons must stay well inside their planet's Hill sphere.
                if par.kind == .planet || par.kind == .moon, let rh = hillRadius(par, in: d) {
                    if apo > rh {
                        warn(b, .problem, "\(b.name) reaches beyond \(par.name)'s Hill sphere (\(SandboxFormat.distance(rh))): \(par.name)'s parent will pull it away.")
                    } else if apo > rh / 2 {
                        warn(b, .caution, "\(b.name) is in the outer half of \(par.name)'s Hill sphere, where orbits are usually unstable over time.")
                    }
                }
                // A planet around one star of a binary
                if par.kind == .star, b.kind != .star, let (p1, p2, aBin, eBin) = binary(containing: par, in: d) {
                    let companion = p1.id == par.id ? p2 : p1
                    let limit = sTypeLimit(aBin: aBin, e: eBin, mu: companion.mass / (par.mass + companion.mass))
                    if apo > limit {
                        warn(b, .problem, "\(b.name) strays too far from \(par.name): beyond about \(SandboxFormat.distance(limit)), \(companion.name) disrupts the orbit.")
                    }
                }
            } else {
                // Orbits the centre of everything before it: circumbinary if that includes a binary.
                let before = d.tree.prefix { $0.body.id != b.id }.map(\.body)
                let stars = before.filter { $0.kind != .planet && $0.kind != .moon }.sorted { $0.mass > $1.mass }
                if stars.count >= 2, let (p1, p2, aBin, eBin) = binary(containing: stars[0], in: d) {
                    let limit = pTypeLimit(aBin: aBin, e: eBin, mu: min(p1.mass, p2.mass) / (p1.mass + p2.mass))
                    if peri < limit {
                        warn(b, .problem, "\(b.name) is too close to orbit both stars: inside about \(SandboxFormat.distance(limit)) the pair's pull throws it out.")
                    }
                }
            }
        }

        // Neighbours around the same parent: crossing orbits and tight packing.
        let groups = Dictionary(grouping: d.bodies.filter { $0.id != firstID && $0.e < 1 }) { $0.parent ?? -1 }
        for (pid, sibs) in groups {
            let sorted = sibs.sorted { $0.a < $1.a }
            guard sorted.count > 1 else { continue }
            let M: Double = pid >= 0 ? (d.body(pid)?.mass ?? 0) : d.centralMass(of: sorted[0])
            for k in 1..<sorted.count {
                let inner = sorted[k - 1], outer = sorted[k]
                if inner.kind == .star || outer.kind == .star { continue }
                if outer.a * (1 - outer.e) < inner.a * (1 + inner.e) {
                    warn(outer, .problem, "\(inner.name) and \(outer.name) have crossing orbits: expect a close encounter, collision or ejection.")
                    continue
                }
                guard M > 0 else { continue }
                let mutualHill = cbrt((inner.mass + outer.mass) / (3 * M)) * (inner.a + outer.a) / 2
                let spacing = (outer.a - inner.a) / mutualHill
                // Gladman (1993): two planets closer than 2√3 mutual Hill radii can't stay apart.
                // Below ~5, systems usually go unstable unless a resonance protects them.
                if spacing < 2 * sqrt(3) {
                    warn(outer, .problem, String(format: "%@ and %@ are only %.1f mutual Hill radii apart: too close for their orbits to stay stable.",
                                                 inner.name, outer.name, spacing))
                } else if spacing < 5 {
                    warn(outer, .caution, String(format: "%@ and %@ are %.1f mutual Hill radii apart; this tight, orbits usually go unstable unless a resonance protects them.",
                                                 inner.name, outer.name, spacing))
                }
            }
        }
        return out.sorted { ($0.severity, $1.bodyID) > ($1.severity, $0.bodyID) }
    }
}
