import Foundation
import simd

// Mission data for the Missions view. The JSON files in MissionData/ are generated
// by tools/fetch_missions.py (NASA/JPL Horizons trajectories; Apollo 11 reconstructed
// from its flight timeline). Positions are in the file's `unitKm` units in the
// ecliptic J2000 frame; velocities in units per day.

// MARK: - UI metadata

nonisolated struct MissionSpeed: Identifiable, Hashable, Sendable {
    let label: String
    let secondsPerSecond: Double
    var id: String { label }
}

nonisolated struct MissionInfo: Identifiable, Hashable, Sendable {
    let id: String            // JSON file name
    let name: String
    let subtitle: String
    let speeds: [MissionSpeed]
    let defaultSpeed: Int
    /// How far before an event "jump to" lands, so you can watch it happen.
    let eventLead: TimeInterval
    /// Default thing the camera follows, and how far away (scene units).
    let defaultFollow: String
    let defaultDistance: Float
}

nonisolated enum MissionCatalog {
    private static let min = 60.0, hour = 3600.0, day = 86_400.0, year = 365.25 * 86_400.0

    static let all: [MissionInfo] = [
        MissionInfo(id: "apollo11", name: "Apollo 11", subtitle: "First Moon landing · 1969",
                    speeds: [.init(label: "1 min/s", secondsPerSecond: min),
                             .init(label: "10 min/s", secondsPerSecond: 10 * min),
                             .init(label: "1 h/s", secondsPerSecond: hour),
                             .init(label: "6 h/s", secondsPerSecond: 6 * hour)],
                    defaultSpeed: 2, eventLead: 20 * min, defaultFollow: "Columbia", defaultDistance: 40),
        MissionInfo(id: "voyager", name: "Voyager 1 & 2", subtitle: "Grand Tour of the giant planets · 1977–",
                    speeds: [.init(label: "10 d/s", secondsPerSecond: 10 * day),
                             .init(label: "60 d/s", secondsPerSecond: 60 * day),
                             .init(label: "1 y/s", secondsPerSecond: year),
                             .init(label: "5 y/s", secondsPerSecond: 5 * year)],
                    defaultSpeed: 1, eventLead: 40 * day, defaultFollow: "Voyager 2", defaultDistance: 70),
        MissionInfo(id: "cassini", name: "Cassini–Huygens", subtitle: "Saturn orbiter · 1997–2017",
                    speeds: [.init(label: "1 d/s", secondsPerSecond: day),
                             .init(label: "10 d/s", secondsPerSecond: 10 * day),
                             .init(label: "60 d/s", secondsPerSecond: 60 * day),
                             .init(label: "1 y/s", secondsPerSecond: year)],
                    defaultSpeed: 2, eventLead: 20 * day, defaultFollow: "Cassini", defaultDistance: 40),
        MissionInfo(id: "newhorizons", name: "New Horizons", subtitle: "Pluto and beyond · 2006–",
                    speeds: [.init(label: "10 d/s", secondsPerSecond: 10 * day),
                             .init(label: "60 d/s", secondsPerSecond: 60 * day),
                             .init(label: "1 y/s", secondsPerSecond: year)],
                    defaultSpeed: 1, eventLead: 30 * day, defaultFollow: "New Horizons", defaultDistance: 70),
    ]

    static func info(_ id: String) -> MissionInfo { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Loaded mission

nonisolated enum MissionFrame: String, Decodable, Sendable { case heliocentric, geocentric }

nonisolated struct MissionEvent: Decodable, Identifiable, Hashable, Sendable {
    let t: Double
    let title: String
    let detail: String
    let craft: String?
    let body: String?
    var id: String { "\(Int(t))-\(title)" }
    var date: Date { Date(timeIntervalSince1970: t) }
}

/// A sampled trajectory with cubic Hermite interpolation (uses the stored velocities).
nonisolated final class MissionTrack: Sendable {
    let name: String
    let label: String?
    let radiusKm: Double
    let times: [Double]                 // unix seconds
    let positions: [SIMD3<Double>]      // data units
    let velocities: [SIMD3<Double>]     // data units per second

    init(name: String, label: String?, radiusKm: Double, t: [Double], s: [Double]) {
        self.name = name; self.label = label; self.radiusKm = radiusKm; self.times = t
        var p: [SIMD3<Double>] = [], v: [SIMD3<Double>] = []
        p.reserveCapacity(t.count); v.reserveCapacity(t.count)
        for i in 0..<t.count {
            let o = i * 6
            p.append(SIMD3(s[o], s[o + 1], s[o + 2]))
            v.append(SIMD3(s[o + 3], s[o + 4], s[o + 5]) / 86_400)
        }
        positions = p; velocities = v
    }

    var start: Double { times.first ?? 0 }
    var end: Double { times.last ?? 0 }

    /// Index of the last sample at or before `t` (clamped to a valid segment start).
    func segmentIndex(at t: Double) -> Int {
        var lo = 0, hi = times.count - 1
        if t <= times[0] { return 0 }
        if t >= times[hi] { return max(0, hi - 1) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Position at `t`, clamped to the track's time span.
    func position(at t: Double) -> SIMD3<Double> {
        if times.count == 1 { return positions[0] }
        let tc = Swift.min(Swift.max(t, start), end)
        let i = segmentIndex(at: tc)
        let t0 = times[i], t1 = times[i + 1], h = t1 - t0
        guard h > 0 else { return positions[i] }
        let s = (tc - t0) / h, s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2,    h11 = s3 - s2
        return h00 * positions[i] + (h10 * h) * velocities[i]
             + h01 * positions[i + 1] + (h11 * h) * velocities[i + 1]
    }

    /// Velocity (data units per second) at `t`.
    func velocity(at t: Double) -> SIMD3<Double> {
        let dt = 30.0
        return (position(at: t + dt) - position(at: t - dt)) / (2 * dt)
    }
}

nonisolated final class Mission: Sendable {
    let info: MissionInfo
    let frame: MissionFrame
    let unitKm: Double
    let start: Date
    let end: Date
    let bodies: [MissionTrack]
    let craft: [MissionTrack]
    let events: [MissionEvent]
    /// Geocentric missions only: unit vector toward the Sun (for lighting).
    let sunDirection: SIMD3<Double>?

    fileprivate init(info: MissionInfo, file: MissionFile) {
        self.info = info
        frame = file.frame; unitKm = file.unitKm
        start = Date(timeIntervalSince1970: file.start)
        end = Date(timeIntervalSince1970: file.end)
        bodies = file.bodies.map { MissionTrack(name: $0.name, label: $0.label, radiusKm: $0.radiusKm, t: $0.t, s: $0.s) }
        craft = file.craft.map { MissionTrack(name: $0.name, label: $0.label, radiusKm: $0.radiusKm, t: $0.t, s: $0.s) }
        events = file.events.sorted { $0.t < $1.t }
        sunDirection = file.sunDirection.map { SIMD3($0[0], $0[1], $0[2]) }
    }

    func body(_ name: String) -> MissionTrack? { bodies.first { $0.name == name } }
    func track(_ name: String) -> MissionTrack? { craft.first { $0.name == name } ?? body(name) }

    /// Most recent event at or before `date`, and the next one after it.
    func events(around date: Date) -> (last: MissionEvent?, next: MissionEvent?) {
        let t = date.timeIntervalSince1970
        return (events.last { $0.t <= t }, events.first { $0.t > t })
    }
}

/// Approximate sphere-of-influence radii (km): inside one, a spacecraft's motion is
/// best seen relative to that body.
nonisolated enum SphereOfInfluence {
    static let km: [String: Double] = [
        "Moon": 66_100, "Venus": 616_000, "Earth": 925_000, "Jupiter": 48_200_000,
        "Saturn": 54_800_000, "Uranus": 51_800_000, "Neptune": 86_800_000, "Pluto": 3_100_000,
    ]
}

extension Mission {
    /// Body to draw paths relative to when the camera follows `name` at time `t`:
    /// a followed body itself, or whichever body's sphere of influence holds the
    /// followed spacecraft. nil = the mission's own frame (Sun / Earth).
    func referenceBody(follow name: String, at t: Double) -> String? {
        let center = frame == .heliocentric ? "Sun" : "Earth"
        if body(name) != nil { return name == center ? nil : name }
        guard let craft = track(name) else { return nil }
        let p = craft.position(at: t)
        for b in bodies where b.name != center {
            if let soi = SphereOfInfluence.km[b.name], simd_length(p - b.position(at: t)) * unitKm < soi {
                return b.name
            }
        }
        return nil
    }
}

nonisolated private struct MissionFile: Decodable {
    struct Track: Decodable {
        let name: String
        let label: String?
        let radiusKm: Double
        let t: [Double]
        let s: [Double]
    }
    let id: String
    let name: String
    let frame: MissionFrame
    let unitKm: Double
    let start: Double
    let end: Double
    let sunDirection: [Double]?
    let bodies: [Track]
    let craft: [Track]
    let events: [MissionEvent]
}

nonisolated enum MissionLoadError: LocalizedError {
    case missingFile(String)
    var errorDescription: String? {
        switch self { case .missingFile(let id): "Mission data “\(id).json” is missing from the app bundle." }
    }
}

/// Loads and caches missions off the main thread.
actor MissionStore {
    static let shared = MissionStore()
    private var cache: [String: Mission] = [:]

    func load(_ id: String, bundle: Bundle = .main) throws -> Mission {
        if let m = cache[id] { return m }
        guard let url = bundle.url(forResource: id, withExtension: "json")
                ?? bundle.url(forResource: id, withExtension: "json", subdirectory: "MissionData") else {
            throw MissionLoadError.missingFile(id)
        }
        let file = try JSONDecoder().decode(MissionFile.self, from: Data(contentsOf: url))
        let mission = Mission(info: MissionCatalog.info(id), file: file)
        cache[id] = mission
        return mission
    }
}
