import SwiftUI

// Lissajous phase diagram: plots the primary body's orbital angle (x-axis)
// against the secondary body's orbital angle (y-axis) over one full
// resonance cycle (derived from the ratio label).
//
// A true resonance (2:1, 4:1, 13:8 …) traces a closed figure.
// A near-resonance drifts slowly, making the imperfect locking visible.
struct PhaseView: View {
    let pair: ResonancePair
    let simulationDate: Date

    private static let moonPeriods: [String: Double] = [
        "Io":        1.769  * 86400, "Europa":    3.551  * 86400,
        "Ganymede":  7.155  * 86400, "Callisto": 16.689  * 86400,
        "Mimas":     0.942  * 86400, "Enceladus": 1.370  * 86400,
        "Tethys":    1.888  * 86400, "Dione":     2.737  * 86400,
        "Rhea":      4.518  * 86400, "Titan":    15.945  * 86400,
        "Iapetus":  79.321  * 86400,
    ]

    private func period(_ name: String) -> Double? {
        BodyCatalog.planetsAndDwarfs.first { $0.name == name }?.orbitalPeriodSeconds
            ?? Self.moonPeriods[name]
    }

    var body: some View {
        // Precompute scalars so Canvas captures only value types, no self
        let pPeriod  = period(pair.primary)
        let sPeriod  = period(pair.secondary)
        let t        = simulationDate.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))
        let pLabel   = pair.primary
        let sLabel   = pair.secondary
        let rLabel   = pair.ratioLabel
        let samples  = 900
        let plotSize: CGFloat = 155

        Canvas { ctx, size in
            guard let pP = pPeriod, let sP = sPeriod else { return }

            // Derive the resonance period from the ratio label.
            // "13:8 ★" → min(13,8)=8 → window = 8 × longerPeriod = one full cycle.
            // "2:1"    → min(2,1)=1  → clamped to 2 × longerPeriod = two cycles.
            let rParts = rLabel
                .replacingOccurrences(of: "~", with: "")
                .replacingOccurrences(of: "★", with: "")
                .split(separator: ":")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let multiplier = (rParts.count == 2) ? min(rParts[0], rParts[1]) : 2
            let window = Double(max(multiplier, 2)) * max(pP, sP)
            let tStart = t - window

            // Map time to a canvas coordinate via cosine.
            // cos(2π·t/T) maps the circular orbit to a smooth oscillation,
            // producing proper curved Lissajous figures instead of straight lines.
            func phase(_ τ: Double, _ p: Double) -> CGFloat {
                CGFloat((cos(2.0 * .pi * τ / p) + 1.0) / 2.0)  // → [0, 1]
            }

            // Continuous path — no wrap detection needed since cos is smooth.
            func buildPath(lo: Int, hi: Int) -> Path {
                var path = Path()
                for i in lo..<hi {
                    let τ = tStart + Double(i) / Double(samples - 1) * window
                    let pt = CGPoint(x: phase(τ, pP) * size.width,
                                     y: phase(τ, sP) * size.height)
                    if i == lo { path.move(to: pt) }
                    else       { path.addLine(to: pt) }
                }
                return path
            }

            // ── Background ──────────────────────────────────────────────
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black.opacity(0.80)))

            // ── Grid (quarter marks) ─────────────────────────────────────
            var grid = Path()
            for f: CGFloat in [0.25, 0.5, 0.75] {
                grid.move(to: CGPoint(x: f * size.width, y: 0))
                grid.addLine(to: CGPoint(x: f * size.width, y: size.height))
                grid.move(to: CGPoint(x: 0, y: f * size.height))
                grid.addLine(to: CGPoint(x: size.width, y: f * size.height))
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.10)), lineWidth: 0.5)

            // ── Phase trail — old portion dim, recent portion bright ──────
            let split = samples * 3 / 4
            ctx.stroke(buildPath(lo: 0,     hi: split),
                       with: .color(.cyan.opacity(0.20)), lineWidth: 0.8)
            ctx.stroke(buildPath(lo: split, hi: samples),
                       with: .color(.cyan.opacity(0.70)), lineWidth: 1.1)

            // ── Current position ─────────────────────────────────────────
            let r: CGFloat = 3.5
            let dot = CGRect(
                x: phase(t, pP) * size.width  - r,
                y: phase(t, sP) * size.height - r,
                width: r * 2, height: r * 2
            )
            ctx.fill(Path(ellipseIn: dot), with: .color(.white))
        }
        .frame(width: plotSize, height: plotSize)
        // x-axis label (primary, bottom-left)
        .overlay(alignment: .bottomLeading) {
            Text(pLabel)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .padding(2)
        }
        // y-axis label (secondary, top-right, rotated)
        .overlay(alignment: .topTrailing) {
            Text(sLabel)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .rotationEffect(.degrees(-90))
                .padding(2)
        }
        // Ratio label (top-left, subtle)
        .overlay(alignment: .topLeading) {
            Text(rLabel)
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .padding(3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
