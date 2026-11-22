import Foundation

// Shared date formatting for the simulation clock (iOS + macOS).
// Dates are built with astronomical years (0 = 1 BC, -6 = 7 BC); Calendar hands
// them back as era 0 + a positive year, so read `.era` to tell BC from AD.

private let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
private let utcGregorian: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Astronomical year (…, -1 = 2 BC, 0 = 1 BC, 1 = AD 1, …) of `date`.
private func astronomicalYear(_ date: Date) -> Int? {
    let c = utcGregorian.dateComponents([.era, .year], from: date)
    guard let era = c.era, let yr = c.year else { return nil }
    return era == 0 ? 1 - yr : yr
}

private func yearString(_ yr: Int) -> String {
    if yr > 0 { return yr <= 999 ? "\(yr) AD" : "\(yr)" }
    return "\(1 - yr) BC"
}

/// Full date: "Dec 21, 2020" / "May 27, 7 BC" / "Jun 21, 1405 BC"
func solarDateString(_ date: Date) -> String {
    let c = utcGregorian.dateComponents([.month, .day], from: date)
    guard let yr = astronomicalYear(date), let mo = c.month, let dy = c.day else { return "?" }
    return "\(months[max(0, min(11, mo - 1))]) \(dy), \(yearString(yr))"
}

/// Month + year: "Dec 2020" / "May 7 BC"
func solarDateShort(_ date: Date) -> String {
    let c = utcGregorian.dateComponents([.month], from: date)
    guard let yr = astronomicalYear(date), let mo = c.month else { return "?" }
    return "\(months[max(0, min(11, mo - 1))]) \(yearString(yr))"
}

/// Date label whose precision matches the playback speed, so the readout
/// changes at most a few times per second instead of becoming a blur.
/// Pass `secondsPerSecond: 0` when paused to get the full date.
func solarDateLabel(_ date: Date, secondsPerSecond rate: Double) -> String {
    let day = 86_400.0, year = 365.25 * day
    if rate <= 300 || rate <= 4 * 3600 {                    // minute/hour ticks stay readable
        let c = utcGregorian.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0, m = rate <= 300 ? (c.minute ?? 0) : 0
        return solarDateString(date) + String(format: "  %02d:%02d UTC", h, m)
    }
    if rate < 4 * day   { return solarDateString(date) }   // day ticks ≤ 4×/s
    if rate < 0.35 * year { return solarDateShort(date) }  // month ticks ≤ ~4×/s
    guard let yr = astronomicalYear(date) else { return "?" }
    let yearsPerSecond = rate / year
    if yearsPerSecond < 4 { return yearString(yr) }
    // Round to a power of ten so the label ticks roughly 1–10×/s, e.g. "≈ 2,030"
    let unit = Int(pow(10, floor(log10(yearsPerSecond))))
    let rounded = Int((Double(yr) / Double(unit)).rounded(.down)) * unit
    let n = rounded > 0 ? rounded : 1 - rounded
    return "≈ \(n.formatted(.number.grouping(.automatic))) \(rounded > 0 ? "AD" : "BC")"
}
