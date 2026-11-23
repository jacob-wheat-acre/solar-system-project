import Foundation

/// How the ship gets there.
nonisolated enum ShipDrive: Hashable, Sendable {
    /// Coasting at a fixed fraction of light speed (the speed-up and slow-down are ignored).
    case cruise(beta: Double)
    /// Constant proper acceleration `g` (in Earth gravities): speed up to the midpoint,
    /// flip, slow down. Real special relativity.
    case thrust(g: Double)
    /// A speculative warp bubble moving at `multiple` × c (Alcubierre).
    case warp(multiple: Double)
}

/// A trip between two stars. Units: light-years and years, so c = 1.
nonisolated struct StarTrip: Hashable, Sendable {
    let distance: Double
    let drive: ShipDrive

    /// 1 g = 9.806 65 m/s² in light-years per year².
    static let gravity = 9.806_65 * pow(365.25 * 86_400, 2) / 9.460_730_472_580_8e15

    private var a: Double { if case .thrust(let g) = drive { g * Self.gravity } else { 0 } }

    /// Time that passes on Earth (and at the destination, which shares its frame).
    var earthYears: Double {
        switch drive {
        case .cruise(let beta): distance / beta
        case .thrust: sqrt(distance * distance + 4 * distance / a)
        case .warp(let n): distance / n
        }
    }

    /// Time on the ship's clock.
    var shipYears: Double {
        switch drive {
        case .cruise(let beta): distance / beta * sqrt(1 - beta * beta)
        case .thrust: 2 / a * acosh(1 + a * distance / 2)
        case .warp(let n): distance / n   // free fall inside the bubble: no time dilation
        }
    }

    /// Top speed as a multiple of c (above 1 only for warp, where it's the bubble's speed).
    var peakSpeed: Double {
        switch drive {
        case .cruise(let beta): beta
        case .thrust: sqrt(1 - 1 / pow(peakGamma, 2))
        case .warp(let n): n
        }
    }

    /// Largest Lorentz factor along the way (1 for warp: the ship itself isn't moving locally).
    var peakGamma: Double {
        switch drive {
        case .cruise(let beta): 1 / sqrt(1 - beta * beta)
        case .thrust: 1 + a * distance / 2
        case .warp: 1
        }
    }

    /// Where the ship is (light-years from the start), its clock, and its speed, when
    /// `t` years have passed on Earth.
    func state(earthTime t: Double) -> (x: Double, shipTime: Double, speed: Double) {
        let T = earthYears
        let t = min(max(t, 0), T)
        switch drive {
        case .cruise(let beta):
            return (beta * t, t * sqrt(1 - beta * beta), beta)
        case .warp(let n):
            return (n * t, t, n)
        case .thrust:
            // Hyperbolic motion from rest: x = (√(1 + (at)²) − 1)/a, τ = asinh(at)/a.
            // The second half mirrors the first.
            let a = self.a
            func half(_ t: Double) -> (x: Double, tau: Double, v: Double) {
                let at = a * t
                return ((sqrt(1 + at * at) - 1) / a, asinh(at) / a, at / sqrt(1 + at * at))
            }
            if t <= T / 2 {
                let h = half(t)
                return (h.x, h.tau, h.v)
            }
            let h = half(T - t)
            return (distance - h.x, shipYears - h.tau, h.v)
        }
    }

    /// Ship time to reach `beta` at 1 g, for the cruise note.
    static func shipTimeToReach(_ beta: Double, g: Double = 1) -> Double { atanh(beta) / (g * gravity) }
}

nonisolated enum TravelFormat {
    static func years(_ y: Double) -> String {
        let days = y * 365.25
        if days < 1 { return String(format: "%.1f hours", days * 24) }
        if days < 60 { return String(format: "%.1f days", days) }
        if y < 2 { return String(format: "%.1f months", y * 12) }
        if y < 100 { return String(format: "%.1f years", y) }
        return "\(Int(y.rounded()).formatted()) years"
    }

    static func speed(_ s: Double) -> String {
        if s >= 1 { return s >= 10 ? "\(Int(s.rounded()))× c" : String(format: "%.1f× c", s) }
        if s > 0.99 {
            // Enough nines to tell them apart.
            let nines = max(3, Int(ceil(-log10(1 - s))) + 1)
            return String(format: "%.\(nines)fc", s)
        }
        return String(format: "%.2fc", s)
    }

    /// The date back home when you'd arrive, leaving now.
    static func arrival(after years: Double, from now: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: now)
        if years > 2 { return "the year \(year + Int(years.rounded()))" }
        let date = now.addingTimeInterval(years * 365.25 * 86_400)
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
