import SwiftUI

private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
    Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date()
}

private struct SpeedPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let secondsPerSecond: Double

    static let solarDefaults: [SpeedPreset] = [
        .init(id: "solar-30d",  label: "30 d/s",  secondsPerSecond: 2_592_000),
        .init(id: "solar-120d", label: "120 d/s", secondsPerSecond: 10_368_000),
        .init(id: "solar-1y",   label: "1 y/s",   secondsPerSecond: 31_557_600),
        .init(id: "solar-5y",   label: "5 y/s",   secondsPerSecond: 157_788_000),
        .init(id: "solar-20y",  label: "20 y/s",  secondsPerSecond: 631_152_000)
    ]

    static let jovianDefaults: [SpeedPreset] = [
        .init(id: "jovian-2h",  label: "2 h/s",  secondsPerSecond: 7_200),
        .init(id: "jovian-6h",  label: "6 h/s",  secondsPerSecond: 21_600),
        .init(id: "jovian-12h", label: "12 h/s", secondsPerSecond: 43_200),
        .init(id: "jovian-1d",  label: "1 d/s",  secondsPerSecond: 86_400),
        .init(id: "jovian-3d",  label: "3 d/s",  secondsPerSecond: 259_200)
    ]

    static let saturnDefaults: [SpeedPreset] = [
        .init(id: "saturn-6h",  label: "6 h/s",  secondsPerSecond: 21_600),
        .init(id: "saturn-1d",  label: "1 d/s",  secondsPerSecond: 86_400),
        .init(id: "saturn-4d",  label: "4 d/s",  secondsPerSecond: 345_600),
        .init(id: "saturn-15d", label: "15 d/s", secondsPerSecond: 1_296_000),
        .init(id: "saturn-45d", label: "45 d/s", secondsPerSecond: 3_888_000)
    ]

    static let earthMoonDefaults: [SpeedPreset] = [
        .init(id: "em-12h", label: "12 h/s", secondsPerSecond: 43_200),
        .init(id: "em-1d",  label: "1 d/s",  secondsPerSecond: 86_400),
        .init(id: "em-3d",  label: "3 d/s",  secondsPerSecond: 259_200),
        .init(id: "em-7d",  label: "7 d/s",  secondsPerSecond: 604_800),
        .init(id: "em-30d", label: "30 d/s", secondsPerSecond: 2_592_000),
    ]

    // 1 Myr = 31,557,600,000,000 s  (365.25 × 86,400 × 1,000,000)
    private static let kyrSec: Double = 365.25 * 86_400 * 1_000
    private static let myrSec: Double = 365.25 * 86_400 * 1_000_000
    static let galacticDefaults: [SpeedPreset] = [
        .init(id: "gal-1yr", label: "1 yr",   secondsPerSecond: 365.25 * 86_400),
        .init(id: "gal-1k",  label: "1 kyr",  secondsPerSecond: kyrSec),
        .init(id: "gal-1m",  label: "1 Myr",  secondsPerSecond: myrSec),
        .init(id: "gal-50m", label: "50 Myr", secondsPerSecond: 50 * myrSec),
        .init(id: "gal-1g",  label: "1 Gyr",  secondsPerSecond: 1000 * myrSec),
    ]
}

struct ContentView: View {
    @State private var selectedDate: Date = Date()
    @State private var isRunning: Bool = true
    @State private var timeScale: Double = SpeedPreset.solarDefaults[2].secondsPerSecond
    @State private var selectedPresetID: String = SpeedPreset.solarDefaults[2].id

    @State private var showOrbits: Bool = true
    @State private var showAxes: Bool = false
    @State private var showLabels: Bool = true
    @State private var showResonance: Bool = false
    @State private var showStars: Bool = true
    @State private var observationMode: ObservationMode = .fullSystem
    @State private var clearCounter: Int = 0
    @State private var selectedBody: String? = nil
    @State private var playTones: Bool = false
    @State private var synth = ResonanceSynth()
    @State private var selectedDateInfo: NamedDate? = nil
    @State private var showTraditions: Bool = true
    @State private var missionState = MissionState()
    @State private var sandboxState = SandboxState()

    // Separate pair selection per mode so switching modes doesn't reset each other
    @State private var selectedSolarPair:  ResonancePair = .init(primary: "Earth",     secondary: "Venus",  ratioLabel: "13:8 ★")
    @State private var selectedJovianPair: ResonancePair = .init(primary: "Io",        secondary: "Europa", ratioLabel: "2:1")
    @State private var selectedSaturnPair: ResonancePair = .init(primary: "Enceladus", secondary: "Dione",  ratioLabel: "2:1")

    @State private var playAnchorReal: Date = Date()
    @State private var playAnchorSim: Date = Date()

    // Notable dates
    @State private var savedDates: [NamedDate] = []
    @State private var showingBookmarkAlert = false
    @State private var bookmarkName = ""

    private let presetDates: [NamedDate] = [
        NamedDate(name: "Great Conjunction",      date: makeDate(2020, 12, 21)), // Jupiter & Saturn 0.1° apart
        NamedDate(name: "Planetary Parade",       date: makeDate(2022,  6, 24)), // Saturn-Mars-Jupiter-Venus
        NamedDate(name: "Mars Great Opposition",  date: makeDate(2018,  7, 27)), // closest in 15 years
        NamedDate(name: "Grand Tour Alignment",   date: makeDate(1977,  8, 20)), // Voyager 2 launch window
        NamedDate(name: "5-Planet Arc",           date: makeDate(2002,  4, 23)), // 5 naked-eye planets in 35°
        NamedDate(name: "Pluto at Perihelion",    date: makeDate(1989,  9,  5)), // Pluto inside Neptune
        NamedDate(name: "Neptune Discovery",      date: makeDate(1846,  9, 23)),
        NamedDate(name: "Pluto Discovery",        date: makeDate(1930,  2, 18)),
        NamedDate(name: "Next Great Conjunction", date: makeDate(2040, 11,  5)), // Jupiter & Saturn again
        NamedDate(name: "Tycho's Conjunction",     date: makeDate(1563,  8, 24)), // inspired Tycho Brahe
        NamedDate(name: "Black Death Conjunction", date: makeDate(1345,  3, 20)), // Jupiter-Saturn-Mars in Aquarius
        // Biblical / ancient events — rough scholarly estimates; exact dates unknown
        NamedDate(name: "Star of Bethlehem",       date: makeDate(  -6,  5, 27)), // 7 BC Jupiter-Saturn triple conjunction
        NamedDate(name: "Jupiter-Venus Beacon",    date: makeDate(  -1,  6, 17)), // 2 BC near-merger in Leo
        NamedDate(name: "Joshua's Long Day",       date: makeDate(-1404, 6, 21)), // ~1405 BC, Battle of Gibeon (Josh 10)
        NamedDate(name: "Hezekiah's Sundial",      date: makeDate( -700, 4,  5)), // ~701 BC, shadow retreats (Isa 38)
    ]

    private let solarResonancePairs: [ResonancePair] = [
        .init(primary: "Earth",   secondary: "Venus",   ratioLabel: "13:8 ★"),
        .init(primary: "Jupiter", secondary: "Saturn",  ratioLabel: "~5:2"),
        .init(primary: "Jupiter", secondary: "Uranus",  ratioLabel: "~7:1"),
        .init(primary: "Neptune", secondary: "Pluto",   ratioLabel: "3:2"),
        .init(primary: "Uranus",  secondary: "Neptune", ratioLabel: "~2:1"),
        .init(primary: "Saturn",  secondary: "Uranus",  ratioLabel: "~3:1"),
        .init(primary: "Earth",   secondary: "Mars",    ratioLabel: "~2:1"),
        .init(primary: "Mars",    secondary: "Jupiter", ratioLabel: "~1:6"),
    ]

    private let jovianResonancePairs: [ResonancePair] = [
        .init(primary: "Io",       secondary: "Europa",   ratioLabel: "2:1"),
        .init(primary: "Europa",   secondary: "Ganymede", ratioLabel: "2:1"),
        .init(primary: "Io",       secondary: "Ganymede", ratioLabel: "4:1"),
        .init(primary: "Ganymede", secondary: "Callisto", ratioLabel: "~7:3"),
    ]

    private let saturnResonancePairs: [ResonancePair] = [
        .init(primary: "Enceladus", secondary: "Dione",   ratioLabel: "2:1"),
        .init(primary: "Mimas",     secondary: "Tethys",  ratioLabel: "2:1"),
        .init(primary: "Mimas",     secondary: "Dione",   ratioLabel: "~3:1"),
        .init(primary: "Titan",     secondary: "Iapetus", ratioLabel: "~5:1"),
    ]

    private var activePair: ResonancePair {
        switch observationMode {
        case .jovianSystem: selectedJovianPair
        case .saturnSystem: selectedSaturnPair
        default:            selectedSolarPair
        }
    }


    private var activeResonancePairs: [ResonancePair] {
        switch observationMode {
        case .jovianSystem: jovianResonancePairs
        case .saturnSystem: saturnResonancePairs
        default:            solarResonancePairs
        }
    }

    private var selectedPairBinding: Binding<ResonancePair> {
        switch observationMode {
        case .jovianSystem: $selectedJovianPair
        case .saturnSystem: $selectedSaturnPair
        default:            $selectedSolarPair
        }
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                controls.padding()
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            if observationMode == .missions {
                missionPane
            } else if observationMode == .sandbox {
                SandboxSceneView(state: sandboxState)
            } else if observationMode == .earthMoonSystem {
                TimelineView(.animation) { _ in
                    EarthMoonView(simulationDate: simulationDate,
                                  secondsPerSecond: isRunning ? timeScale : 0)
                }
            } else if observationMode == .galactic {
                TimelineView(.animation) { _ in
                    GalacticView(simulationDate: simulationDate)
                }
            } else {
                TimelineView(.animation) { _ in
                    SolarSystemSceneView(
                        simulationDate: simulationDate,
                        showOrbits: showOrbits,
                        showAxes: showAxes,
                        observationMode: observationMode,
                        resonancePair: showResonance ? activePair : nil,
                        clearCounter: clearCounter,
                        showLabels: showLabels,
                        showStars: showStars,
                        selectedBody: $selectedBody
                    )
                    .overlay(alignment: .top) {
                        Text(solarDateLabel(simulationDate, secondsPerSecond: isRunning ? timeScale : 0))
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.top, 10)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let body = selectedBody {
                        BodyInfoCard(name: body) { selectedBody = nil }
                            .id(body)
                            .padding(12)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let d = selectedDateInfo {
                        DateInfoCard(entry: d) { selectedDateInfo = nil }
                            .id(d.id)
                            .padding(12)
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            playAnchorReal = Date()
            playAnchorSim = selectedDate
            loadSaved()
        }
        .onChange(of: observationMode) { _, _ in selectedBody = nil }
        .alert("Name this bookmark", isPresented: $showingBookmarkAlert) {
            TextField("Name", text: $bookmarkName)
            Button("Save") {
                let name = bookmarkName.isEmpty
                    ? solarDateString(simulationDate)
                    : bookmarkName
                savedDates.append(NamedDate(name: name, date: simulationDate))
                persistSaved()
            }
            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: selectedDate) { _, newValue in
            if isRunning {
                playAnchorReal = Date()
                playAnchorSim = newValue
            }
        }
        .onChange(of: timeScale) { _, _ in
            if isRunning {
                selectedDate = simulationDate
                playAnchorReal = Date()
                playAnchorSim = selectedDate
            }
        }
        .onChange(of: observationMode) { _, newMode in
            applyDefaultPresetForMode(newMode)
        }
    }

    /// Start or stop the clock. Always go through this (or `runBinding`): it re-anchors on
    /// play and saves the reached date on pause *synchronously*, so a date set right after
    /// (e.g. a mission parking at launch) isn't overwritten by a later onChange.
    private func setRunning(_ on: Bool) {
        guard on != isRunning else { return }
        if on {
            playAnchorReal = Date()
            playAnchorSim = selectedDate
        } else {
            selectedDate = runningDate
        }
        isRunning = on
    }

    private var runBinding: Binding<Bool> { Binding(get: { isRunning }, set: { setRunning($0) }) }

    /// Where the running clock has reached, clamped to the end of the current mission.
    private var runningDate: Date {
        let d = playAnchorSim.addingTimeInterval(Date().timeIntervalSince(playAnchorReal) * timeScale)
        if let end = missionEnd, d > end { return end }
        return d
    }

    private var simulationDate: Date { isRunning ? runningDate : selectedDate }

    /// End of the mission being shown (missions mode only); the clock stops there.
    private var missionEnd: Date? { observationMode == .missions ? missionState.current?.end : nil }
    private var missionEnded: Bool { isRunning && (missionEnd.map { runningDate >= $0 } ?? false) }

    private var activeSpeedPresets: [SpeedPreset] {
        switch observationMode {
        case .jovianSystem:    SpeedPreset.jovianDefaults
        case .saturnSystem:    SpeedPreset.saturnDefaults
        case .earthMoonSystem: SpeedPreset.earthMoonDefaults
        case .galactic:        SpeedPreset.galacticDefaults
        default:               SpeedPreset.solarDefaults
        }
    }

    private let kyrSec: Double = 365.25 * 86_400 * 1_000
    private let myrSec: Double = 365.25 * 86_400 * 1_000_000

    private var sliderRange: ClosedRange<Double> {
        switch observationMode {
        case .jovianSystem:    1_800...345_600
        case .saturnSystem:    21_600...3_888_000
        case .earthMoonSystem: 21_600...5_184_000
        case .galactic:        (365.25 * 86_400)...(1000 * myrSec)
        default:               86_400...788_940_000
        }
    }

    private var sliderStep: Double {
        switch observationMode {
        case .jovianSystem:    1_800
        case .saturnSystem:    21_600
        case .earthMoonSystem: 21_600
        case .galactic:        100 * kyrSec
        default:               86_400
        }
    }

    private var jovianLaplaceAngleDegrees: Double {
        let t   = simulationDate.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))
        let day = 86_400.0
        let io       = 2.0 * Double.pi * (t / (1.769 * day))
        let europa   = 2.0 * Double.pi * (t / (3.551 * day))
        let ganymede = 2.0 * Double.pi * (t / (7.155 * day))
        return normalizedAngleSigned(radians: io - 3 * europa + 2 * ganymede) * 180 / .pi
    }

    // Universal phase angle — looks up period from planet catalog, then moon table
    private func phaseDegrees(for pair: ResonancePair) -> Double? {
        let day = 86_400.0
        let moonPeriods: [String: Double] = [
            "Io": 1.769 * day,  "Europa": 3.551 * day,
            "Ganymede": 7.155 * day,  "Callisto": 16.689 * day,
            "Mimas": 0.942 * day,  "Enceladus": 1.370 * day,
            "Tethys": 1.888 * day,  "Dione": 2.737 * day,
            "Rhea": 4.518 * day,  "Titan": 15.945 * day, "Iapetus": 79.321 * day,
        ]
        let pPeriod = BodyCatalog.planetsAndDwarfs.first(where: { $0.name == pair.primary })?.orbitalPeriodSeconds
                      ?? moonPeriods[pair.primary]
        let sPeriod = BodyCatalog.planetsAndDwarfs.first(where: { $0.name == pair.secondary })?.orbitalPeriodSeconds
                      ?? moonPeriods[pair.secondary]
        guard let p = pPeriod, let s = sPeriod else { return nil }
        let t  = simulationDate.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))
        let pA = normalizedAngle(radians: 2.0 * .pi * (t / p))
        let sA = normalizedAngle(radians: 2.0 * .pi * (t / s))
        return normalizedAngle(radians: sA - pA) * 180.0 / .pi
    }

    private func normalizedAngle(radians: Double) -> Double {
        let w = radians.truncatingRemainder(dividingBy: 2 * .pi)
        return w < 0 ? w + 2 * .pi : w
    }

    private func normalizedAngleSigned(radians: Double) -> Double {
        let w = normalizedAngle(radians: radians)
        return w > .pi ? w - 2 * .pi : w
    }

    private func applyPreset(_ preset: SpeedPreset) {
        selectedPresetID = preset.id
        timeScale = preset.secondsPerSecond
    }

    private func applyDefaultPresetForMode(_ mode: ObservationMode) {
        switch mode {
        case .jovianSystem:    applyPreset(SpeedPreset.jovianDefaults[1])
        case .saturnSystem:    applyPreset(SpeedPreset.saturnDefaults[2])
        case .earthMoonSystem: applyPreset(SpeedPreset.earthMoonDefaults[2])
        case .galactic:        applyPreset(SpeedPreset.galacticDefaults[2])
        default:               applyPreset(SpeedPreset.solarDefaults[2])
        }
    }

    private func timeScaleLabel(_ s: Double) -> String {
        let kyr = 365.25 * 86_400 * 1_000
        let myr = 365.25 * 86_400 * 1_000_000
        if s >= myr {
            let myrRate = s / myr
            return myrRate >= 1000
                ? String(format: "%.1f Gyr/s", myrRate / 1000)
                : String(format: "%.0f Myr/s", myrRate)
        }
        if s >= kyr {
            return String(format: "%.0f kyr/s", s / kyr)
        }
        if s >= 86_400 {
            let days = s / 86_400
            return days >= 365
                ? String(format: "%.1f y/s", days / 365)
                : String(format: "%.0f d/s", days)
        }
        return String(format: "%.0f h/s", s / 3600)
    }

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: "savedDates"),
              let decoded = try? JSONDecoder().decode([NamedDate].self, from: data) else { return }
        savedDates = decoded
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(savedDates) {
            UserDefaults.standard.set(data, forKey: "savedDates")
        }
    }

    private func removeSaved(_ d: NamedDate) {
        savedDates.removeAll { $0.id == d.id }
        persistSaved()
    }

    private func jumpTo(_ d: NamedDate) { selectedDate = d.date }

    private func dateRow(_ d: NamedDate, deletable: Bool = false) -> some View {
        HStack {
            Button { jumpTo(d) } label: {
                HStack {
                    Text(d.name).lineLimit(1)
                    Spacer()
                    Text(solarDateShort(d.date))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            if NotableDateCatalog.explanation(for: d.name) != nil {
                Button {
                    selectedDateInfo = (selectedDateInfo?.id == d.id) ? nil : d
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if deletable {
                Button { removeSaved(d) } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }


    // MARK: - Sandbox

    private var sandboxControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            SandboxPlayButtons(state: sandboxState)
            observationPicker
            SandboxControls(state: sandboxState)
        }
    }

    // MARK: - Missions

    private var missionPane: some View {
        TimelineView(.animation) { _ in
            MissionSceneView(state: missionState, simulationDate: simulationDate,
                             secondsPerSecond: isRunning ? timeScale : 0, cardBottomInset: 0)
                .onChange(of: missionEnded) { _, ended in if ended { setRunning(false) } }
        }
    }

    private var missionControls: some View {
        TimelineView(.animation) { _ in
            VStack(alignment: .leading, spacing: 14) {
                MissionPlayButton(state: missionState, simulationDate: simulationDate,
                                  isRunning: runBinding, onJump: { selectedDate = $0 })
                observationPicker
                MissionControls(state: missionState, simulationDate: simulationDate, isRunning: runBinding,
                                onJump: { selectedDate = $0 }, onSpeed: { timeScale = $0 })
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch observationMode {
        case .missions: missionControls
        case .sandbox: sandboxControls
        default: standardControls
        }
    }

    private var observationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Observation")
            Picker("", selection: $observationMode) {
                ForEach(ObservationMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
    }

    private var standardControls: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Playback
            HStack {
                Button(isRunning ? "Pause" : "Run") { setRunning(!isRunning) }
                    .buttonStyle(.borderedProminent)
                if observationMode != .galactic {
                    Button("Clear") { clearCounter += 1 }
                }
                Spacer()
                Text(solarDateString(simulationDate))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            observationPicker

            Divider()

            sectionLabel("Speed")
            Picker("", selection: $selectedPresetID) {
                ForEach(activeSpeedPresets) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedPresetID) { _, id in
                if let p = activeSpeedPresets.first(where: { $0.id == id }) { applyPreset(p) }
            }

            HStack(spacing: 6) {
                Slider(value: $timeScale, in: sliderRange, step: sliderStep)
                Text(timeScaleLabel(timeScale))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 58, alignment: .trailing)
            }

            Divider()

            if observationMode == .earthMoonSystem {
                earthMoonControls
            } else if observationMode == .galactic {
                TimelineView(.animation) { _ in galacticControls }
            } else {
                sectionLabel("Resonance Pair")
                Picker("", selection: selectedPairBinding) {
                    ForEach(activeResonancePairs) {
                        Text("\($0.primary)–\($0.secondary) (\($0.ratioLabel))").tag($0)
                    }
                }
                .labelsHidden()

                if let phase = phaseDegrees(for: activePair) {
                    Text(String(format: "Phase: %.1f°", phase))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if observationMode == .jovianSystem {
                    Text(String(format: "Laplace (Io–Europa–Ganymede): %.2f°", jovianLaplaceAngleDegrees))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                TimelineView(.animation) { _ in
                    PhaseView(pair: activePair, simulationDate: simulationDate)
                }
                .padding(.top, 4)
            }

            if observationMode != .galactic {
                Divider()

                HStack {
                    Text("Focus").font(.subheadline).foregroundStyle(.secondary)
                    Picker("Focus", selection: $selectedBody) {
                        Text("–").tag(String?.none)
                        Section("Star") {
                            Text("Sun").tag(String?.some("Sun"))
                        }
                        Section("Planets") {
                            ForEach(["Mercury","Venus","Earth","Mars","Jupiter","Saturn","Uranus","Neptune"], id: \.self) {
                                Text($0).tag(String?.some($0))
                            }
                        }
                        Section("Dwarf Planets") {
                            ForEach(["Ceres","Pluto","Haumea","Makemake","Eris"], id: \.self) {
                                Text($0).tag(String?.some($0))
                            }
                        }
                        Section("Jovian Moons") {
                            ForEach(["Io","Europa","Ganymede","Callisto"], id: \.self) {
                                Text($0).tag(String?.some($0))
                            }
                        }
                        Section("Saturnian Moons") {
                            ForEach(["Mimas","Enceladus","Tethys","Dione","Rhea","Titan","Iapetus"], id: \.self) {
                                Text($0).tag(String?.some($0))
                            }
                        }
                        Section("Named Stars") {
                            ForEach(["Sirius","Canopus","Arcturus","Vega","Capella","Rigel","Procyon",
                                     "Betelgeuse","Altair","Aldebaran","Antares","Spica","Polaris",
                                     "Deneb","Fomalhaut","Regulus","Pollux"], id: \.self) {
                                Text($0).tag(String?.some($0))
                            }
                        }
                        Section("Constellations") {
                            ForEach(["Aries","Taurus","Gemini","Cancer","Leo","Virgo","Libra",
                                     "Scorpius","Sagittarius","Capricornus","Aquarius","Pisces",
                                     "Orion","Ursa Major","Ursa Minor","Cassiopeia","Cygnus"], id: \.self) {
                                Text($0).tag(String?.some($0))
                            }
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .font(.body)
                }

                Toggle("♪ Resonance Tones", isOn: $playTones)
                    .onChange(of: playTones) { _, on in
                        if on {
                            let (f1, f2) = BodyStatsCatalog.resonanceTones(for: activePair)
                            synth.setFrequencies(f1, f2); synth.start()
                        } else { synth.stop() }
                    }
                    .onChange(of: activePair) { _, pair in
                        guard playTones else { return }
                        let (f1, f2) = BodyStatsCatalog.resonanceTones(for: pair)
                        synth.setFrequencies(f1, f2)
                    }
                if playTones, let label = BodyStatsCatalog.intervalName(for: activePair) {
                    let (fLow, fHigh) = BodyStatsCatalog.resonanceTones(for: activePair)
                    Text("\(label)  ·  \(Int(fLow.rounded()))/\(Int(fHigh.rounded())) Hz")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show Orbits",                 isOn: $showOrbits)
                Toggle("Show Axes",                   isOn: $showAxes)
                Toggle("Show Labels",                 isOn: $showLabels)
                Toggle("Show Resonance",              isOn: $showResonance)
                Toggle("Show Stars & Constellations", isOn: $showStars)

                Divider()

                DatePicker("Date", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                    .font(.caption)

                Divider()

                sectionLabel("Notable Dates")
                ForEach(presetDates) { dateRow($0) }

                if !savedDates.isEmpty {
                    Text("Bookmarks")
                        .font(.footnote).foregroundStyle(.tertiary).padding(.top, 2)
                    ForEach(savedDates) { dateRow($0, deletable: true) }
                }

                Button {
                    bookmarkName = simulationDate.formatted(date: .abbreviated, time: .omitted)
                    showingBookmarkAlert = true
                } label: {
                    Label("Bookmark current date", systemImage: "bookmark")
                        .font(.system(size: 15))
                }
                .padding(.top, 2)
            }

            Spacer()
        }
    }

    private var earthMoonControls: some View {
        let data = EarthMoonData.compute(for: simulationDate)
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Season")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(data.northSeason) (N)  ·  \(data.southSeason) (S)")
                    .font(.system(size: 14, weight: .medium))
                Text(String(format: "%.0f d until %@", data.daysUntilNextEvent, data.nextEventName))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            sectionLabel("Moon")
            HStack(spacing: 8) {
                MoonPhaseView(phaseAngle: data.phaseAngle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(data.moonPhaseName).font(.system(size: 13, weight: .medium))
                    Text(String(format: "%.0f%% lit · Age %.1f d",
                                data.moonIllumination * 100, data.moonAgeInDays))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(format: "Full in %.1f d · New in %.1f d",
                                data.daysUntilFull, data.daysUntilNew))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            sectionLabel("Jump To")
            let events: [(name: String, targetAng: Double)] = [
                ("Vernal Equinox (Mar ~20)",    .pi),
                ("Summer Solstice (Jun ~21)",   3 * .pi / 2),
                ("Autumnal Equinox (Sep ~23)",  0),
                ("Winter Solstice (Dec ~21)",   .pi / 2),
            ]
            ForEach(events, id: \.name) { ev in
                Button {
                    jumpToNextAngle(ev.targetAng)
                } label: {
                    HStack {
                        Text(ev.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            let eventKey = currentEventForSeason(data)
            let traditions = traditionsByEvent[eventKey] ?? []
            DisclosureGroup(isExpanded: $showTraditions) {
                ForEach(traditions) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(t.name)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(t.culture)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        Text(t.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            } label: {
                HStack {
                    Text("TRADITIONS")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("· \(eventKey)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var galacticControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Galactic Orbit")

            let t        = simulationDate.timeIntervalSince(Date(timeIntervalSinceReferenceDate: -978_307_200))
            let omG      = 2.0 * .pi / (225_000_000 * 365.25 * 86_400)
            let omO      = 2.0 * .pi / (64_000_000 * 365.25 * 86_400)
            let frac     = (omG * t).truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)
            let normFrac = frac < 0 ? frac + 1 : frac
            let heightLY = 100.0 * sin(omO * t)                  // real ~±100 ly amplitude
            let galYrs   = t / (225_000_000 * 365.25 * 86_400)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Orbit")
                        .font(.system(size: 13))
                    Spacer()
                    Text(String(format: "%.2f%%", normFrac * 100))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Height")
                        .font(.system(size: 13))
                    Spacer()
                    Text(String(format: "%+.0f ly", heightLY))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Galactic years")
                        .font(.system(size: 13))
                    Spacer()
                    Text(String(format: "%.3f", abs(galYrs)))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Scale notes")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text("Galactic orbit radius ≈ 26,000 ly\nVertical bob ≈ ±100 ly / 64 Myr\nPlanetary orbits at 2 AU/unit")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func currentEventForSeason(_ data: EarthMoonData) -> String {
        switch data.northSeason {
        case "Spring": return "Vernal Equinox"
        case "Summer": return "Summer Solstice"
        case "Autumn": return "Autumnal Equinox"
        default:       return "Winter Solstice"
        }
    }

    private func jumpToNextAngle(_ targetAng: Double) {
        let data = EarthMoonData.compute(for: simulationDate)
        var delta = targetAng - data.ang
        if delta <= 0.001 { delta += 2 * .pi }
        let days = delta / (2 * .pi) * 365.25
        let newDate = simulationDate.addingTimeInterval(days * 86_400)
        selectedDate = newDate
        if isRunning {
            playAnchorReal = Date()
            playAnchorSim  = newDate
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

#Preview {
    ContentView()
}
