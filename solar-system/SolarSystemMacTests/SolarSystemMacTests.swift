//
//  SolarSystemMacTests.swift
//  SolarSystemMacTests
//
//  Created by Jacob Whitaker on 1/25/26.
//

import Foundation
import Testing
import simd
@testable import SolarSystemMac

struct MissionDataTests {

    @Test(arguments: MissionCatalog.all.map(\.id))
    func missionLoads(id: String) async throws {
        let m = try await MissionStore.shared.load(id)
        #expect(m.start < m.end)
        #expect(!m.craft.isEmpty)
        #expect(!m.events.isEmpty)
        #expect(m.events.map(\.t) == m.events.map(\.t).sorted())
        for e in m.events {
            #expect(e.date >= m.start.addingTimeInterval(-86_400), "\(e.title) before mission start")
            #expect(e.date <= m.end.addingTimeInterval(86_400), "\(e.title) after mission end")
        }
        for c in m.craft { #expect(c.times == c.times.sorted(), "\(c.name) samples out of order") }
    }

    @Test(arguments: MissionCatalog.all.map(\.id))
    func interpolationHitsSamples(id: String) async throws {
        let m = try await MissionStore.shared.load(id)
        for track in m.craft + m.bodies {
            for i in Swift.stride(from: 0, to: track.times.count, by: max(1, track.times.count / 50)) {
                let err = simd_length(track.position(at: track.times[i]) - track.positions[i])
                #expect(err < 1e-9 * max(1, simd_length(track.positions[i])), "\(track.name) sample \(i)")
            }
        }
    }

    @Test func eagleStaysOnTheMoonWhileLanded() async throws {
        let m = try await MissionStore.shared.load("apollo11")
        let eagle = try #require(m.track("Eagle")), moon = try #require(m.body("Moon"))
        let landing = try #require(m.events.first { $0.title.contains("Eagle has landed") })
        let liftoff = try #require(m.events.first { $0.title == "Lunar liftoff" })
        var t = landing.t + 60
        while t < liftoff.t - 60 {
            let alt = simd_length(eagle.position(at: t) - moon.position(at: t)) - 1737.4
            #expect(abs(alt) < 1, "Eagle \(alt) km off the surface at \(t)")
            t += 1800
        }
    }

    @Test func voyager1PassesJupiterAtTheRightDistance() async throws {
        let m = try await MissionStore.shared.load("voyager")
        let v1 = try #require(m.track("Voyager 1")), jup = try #require(m.body("Jupiter"))
        let flyby = try #require(m.events.first { $0.title == "Voyager 1 · Jupiter" })
        let km = simd_length(v1.position(at: flyby.t) - jup.position(at: flyby.t)) * m.unitKm
        #expect(abs(km - 349_000) < 10_000, "closest approach \(km) km")
    }
}

struct DateLabelTests {
    private let date = Date(timeIntervalSince1970: -14_182_940)   // 1969-07-20 20:17:40 UTC

    @Test func precisionFollowsSpeed() {
        #expect(solarDateLabel(date, secondsPerSecond: 60) == "Jul 20, 1969  20:17 UTC")
        #expect(solarDateLabel(date, secondsPerSecond: 3600) == "Jul 20, 1969  20:00 UTC")
        #expect(solarDateLabel(date, secondsPerSecond: 86_400) == "Jul 20, 1969")
        #expect(solarDateLabel(date, secondsPerSecond: 30 * 86_400) == "Jul 1969")
        #expect(solarDateLabel(date, secondsPerSecond: 365.25 * 86_400) == "1969")
    }

    @Test func bcYears() {
        let c = Calendar(identifier: .gregorian)
        var comps = DateComponents(year: -6, month: 5, day: 27, hour: 12); comps.timeZone = TimeZone(identifier: "UTC")
        let d = try! #require(c.date(from: comps))
        #expect(solarDateString(d) == "May 27, 7 BC")
    }
}
