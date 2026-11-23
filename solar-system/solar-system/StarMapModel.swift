import Foundation
import simd

/// A real star within 50 light-years, from `StarData/nearby_stars.json` (built by
/// tools/fetch_stars.py from the HYG database v4.1, CC BY-SA 4.0).
nonisolated struct NearbyStar: Codable, Identifiable, Hashable, Sendable {
    let name: String
    /// Catalogue id: Gliese number, HIP number, or the name for hand-added stars.
    let cat: String
    /// Distance from the Sun, light-years.
    let d: Double
    /// Equatorial J2000 position, light-years (x toward RA 0h, z toward the north celestial pole).
    let eq: [Double]
    let sp: String
    let absmag: Double?
    /// Luminosity in L☉ (visual).
    let lum: Double?
    /// B−V colour index.
    let bv: Double
    /// Shared by the members of a multiple-star system.
    let group: String
    let planets: String?
    /// A Sandbox preset id for this system.
    let sandbox: String?

    var id: String { name }
    var isSun: Bool { name == "Sol" }
    var displayName: String { isSun ? "Sun" : name }

    /// Galactic position, light-years: x toward the galactic centre, y toward galactic
    /// rotation (l = 90°), z toward the north galactic pole.
    var galactic: SIMD3<Double> { StarCatalog.galactic(SIMD3(eq[0], eq[1], eq[2])) }

    /// Effective temperature from B−V (Ballesteros 2012).
    var temperature: Double { 4600 * (1 / (0.92 * bv + 1.7) + 1 / (0.92 * bv + 0.62)) }

    /// Spectral class in words.
    var kindDescription: String {
        let s = sp.uppercased()
        if s.hasPrefix("D") { return "White dwarf" }
        if s.hasPrefix("SD") { return "Subdwarf" }
        let cls: [Character: String] = ["O": "Blue", "B": "Blue-white", "A": "White", "F": "Yellow-white",
                                        "G": "Yellow", "K": "Orange", "M": "Red", "L": "Brown", "T": "Brown"]
        guard let c = s.first, let colour = cls[c] else { return sp.isEmpty ? "Star" : sp }
        if c == "L" || c == "T" { return "Brown dwarf" }
        if s.contains("III") { return "\(colour) giant" }
        if s.contains("IV") { return "\(colour) subgiant" }
        return c == "M" ? "Red dwarf" : "\(colour) main-sequence star"
    }
}

nonisolated enum StarCatalog {
    static let all: [NearbyStar] = load()

    static var sun: NearbyStar { all.first { $0.isSun } ?? all[0] }

    static func star(_ name: String) -> NearbyStar? { all.first { $0.name == name } }

    /// Stars worth listing in pickers: named ones, planet hosts and Sandbox systems.
    static let notable: [NearbyStar] = all.filter { s in
        s.isSun || s.planets != nil || s.sandbox != nil
            || !(s.name.hasPrefix("Gliese ") || s.name.hasPrefix("GJ ") || s.name.hasPrefix("HIP ") || s.name.hasPrefix("HYG "))
    }

    static func load(bundle: Bundle = .main) -> [NearbyStar] {
        struct File: Decodable { let stars: [NearbyStar] }
        guard let url = bundle.url(forResource: "nearby_stars", withExtension: "json")
                ?? bundle.url(forResource: "nearby_stars", withExtension: "json", subdirectory: "StarData"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.stars
    }

    /// Equatorial (J2000) → galactic rotation (Hipparcos, ESA 1997, vol. 1 §1.5.3).
    static func galactic(_ e: SIMD3<Double>) -> SIMD3<Double> {
        let m = simd_double3x3(rows: [
            SIMD3(-0.054_875_5604, -0.873_437_0902, -0.483_835_0155),
            SIMD3( 0.494_109_4279, -0.444_829_6300,  0.746_982_2445),
            SIMD3(-0.867_666_1490, -0.198_076_3734,  0.455_983_7762),
        ])
        return m * e
    }

    /// Approximate colour of a blackbody at `t` kelvin (Tanner Helland's fit, as in BlackHoleLens.metal).
    static func blackbody(_ temperature: Double) -> SIMD3<Float> {
        let t = min(max(temperature, 1000), 40000) / 100
        let r = t <= 66 ? 1 : min(max(1.293 * pow(t - 60, -0.1332), 0), 1)
        let g = t <= 66 ? min(max(0.390 * log(t) - 0.632, 0), 1) : min(max(1.130 * pow(t - 60, -0.0755), 0), 1)
        let b = t >= 66 ? 1 : (t <= 19 ? 0 : min(max(0.543 * log(t - 10) - 1.196, 0), 1))
        return SIMD3(Float(r), Float(g), Float(b))
    }
}
