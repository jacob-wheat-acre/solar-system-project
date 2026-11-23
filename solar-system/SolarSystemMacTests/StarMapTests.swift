import Foundation
import Testing
import simd
@testable import SolarSystemMac

/// The star catalogue and the travel maths.
struct StarMapTests {
    @Test func catalogueLoads() throws {
        let all = StarCatalog.all
        #expect(all.count > 900)
        let proxima = try #require(StarCatalog.star("Proxima Centauri"))
        #expect(abs(proxima.d - 4.24) < 0.03)
        let sirius = try #require(StarCatalog.star("Sirius"))
        #expect(abs(sirius.d - 8.6) < 0.05)
        #expect(StarCatalog.star("TRAPPIST-1")?.sandbox == "trappist")
        #expect(Set(all.map(\.name)).count == all.count, "names must be unique")
        // Positions agree with the listed distances.
        for s in all.prefix(50) { #expect(abs(simd_length(s.galactic) - s.d) < 0.01) }
    }

    @Test func galacticCentreIsPlusX() {
        let ra = 266.405 * Double.pi / 180, dec = -28.936 * Double.pi / 180
        let eq = SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
        let g = StarCatalog.galactic(eq)
        #expect(g.x > 0.9999, "\(g)")
    }

    @Test func oneGToProxima() {
        let t = StarTrip(distance: 4.24, drive: .thrust(g: 1))
        #expect(abs(t.shipYears - 3.53) < 0.03, "\(t.shipYears)")
        #expect(abs(t.earthYears - 5.87) < 0.03, "\(t.earthYears)")
        // The animation reaches the end on both clocks, and the midpoint at half time.
        let end = t.state(earthTime: t.earthYears)
        #expect(abs(end.x - 4.24) < 1e-9 && abs(end.shipTime - t.shipYears) < 1e-9)
        #expect(abs(t.state(earthTime: t.earthYears / 2).x - 2.12) < 1e-9)
    }

    @Test func gentleThrustIsNewtonian() {
        // 0.001 g over 0.01 ly: far below light speed, so t ≈ 2√(d/a) on both clocks.
        let t = StarTrip(distance: 0.01, drive: .thrust(g: 0.001))
        let newton = 2 * sqrt(0.01 / (0.001 * StarTrip.gravity))
        #expect(abs(t.earthYears / newton - 1) < 1e-3)
        #expect(abs(t.shipYears / newton - 1) < 1e-3)
    }

    @Test func cruiseAndWarp() {
        let c = StarTrip(distance: 10, drive: .cruise(beta: 0.5))
        #expect(abs(c.peakGamma - 1.1547) < 1e-4)
        #expect(abs(c.earthYears - 20) < 1e-9 && abs(c.shipYears - 20 / 1.1547) < 1e-3)
        let w = StarTrip(distance: 10, drive: .warp(multiple: 10))
        #expect(w.earthYears == 1 && w.shipYears == 1)
    }
}
