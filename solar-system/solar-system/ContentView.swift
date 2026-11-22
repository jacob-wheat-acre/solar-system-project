import SwiftUI

// MARK: - Named Date

struct NamedDate: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let date: Date
    init(name: String, date: Date) { id = UUID(); self.name = name; self.date = date }
}

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
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedDate: Date = Date()
    @State private var isRunning: Bool = true
    @State private var timeScale: Double = SpeedPreset.solarDefaults[2].secondsPerSecond
    @State private var selectedPresetID: String = SpeedPreset.solarDefaults[2].id

    @State private var showOrbits: Bool = true
    @State private var showAxes: Bool = false
    @State private var showLabels: Bool = true
    @State private var showResonance: Bool = true
    @State private var showStars: Bool = true
    @State private var observationMode: ObservationMode = .fullSystem
    @State private var clearCounter: Int = 0
    @State private var selectedBody: String? = nil
    @State private var playTones: Bool = false
    @State private var synth = ResonanceSynth()
    @State private var selectedDateInfo: NamedDate? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Separate pair selection per mode so switching modes doesn't reset each other
    @State private var selectedSolarPair:   ResonancePair = .init(primary: "Earth",     secondary: "Venus",   ratioLabel: "13:8 ★")
    @State private var selectedJovianPair:  ResonancePair = .init(primary: "Io",        secondary: "Europa",  ratioLabel: "2:1")
    @State private var selectedSaturnPair:  ResonancePair = .init(primary: "Enceladus", secondary: "Dione",   ratioLabel: "2:1")

    @State private var playAnchorReal: Date = Date()
    @State private var playAnchorSim: Date = Date()

    // Notable dates
    @State private var savedDates: [NamedDate] = []
    @State private var showingBookmarkAlert = false
    @State private var bookmarkName = ""

    private let presetDates: [NamedDate] = [
        NamedDate(name: "Great Conjunction",      date: makeDate(2020, 12, 21)),
        NamedDate(name: "Planetary Parade",       date: makeDate(2022,  6, 24)),
        NamedDate(name: "Mars Great Opposition",  date: makeDate(2018,  7, 27)),
        NamedDate(name: "Grand Tour Alignment",   date: makeDate(1977,  8, 20)),
        NamedDate(name: "5-Planet Arc",           date: makeDate(2002,  4, 23)),
        NamedDate(name: "Pluto at Perihelion",    date: makeDate(1989,  9,  5)),
        NamedDate(name: "Neptune Discovery",      date: makeDate(1846,  9, 23)),
        NamedDate(name: "Pluto Discovery",        date: makeDate(1930,  2, 18)),
        NamedDate(name: "Next Great Conjunction", date: makeDate(2040, 11,  5)),
        NamedDate(name: "Tycho's Conjunction",     date: makeDate(1563,  8, 24)),
        NamedDate(name: "Black Death Conjunction", date: makeDate(1345,  3, 20)),
        NamedDate(name: "Star of Bethlehem",       date: makeDate(  -6,  5, 27)),
        NamedDate(name: "Jupiter-Venus Beacon",    date: makeDate(  -1,  6, 17)),
        NamedDate(name: "Joshua's Long Day",       date: makeDate(-1404, 6, 21)),
        NamedDate(name: "Hezekiah's Sundial",      date: makeDate( -700, 4,  5)),
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

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ScrollView {
                        controls
                            .padding()
                    }
                    .navigationTitle("Solar System")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
                } detail: {
                    scenePane
                        .ignoresSafeArea()
                }
            } else {
                VStack(spacing: 0) {
                    scenePane
                        .frame(minHeight: 340)
                    Divider()
                    ScrollView {
                        controls
                            .padding()
                    }
                }
            }
        }
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
                    ? simulationDate.formatted(date: .abbreviated, time: .omitted)
                    : bookmarkName
                savedDates.append(NamedDate(name: name, date: simulationDate))
                persistSaved()
            }
            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: isRunning) { _, newValue in
            if newValue {
                playAnchorReal = Date()
                playAnchorSim = selectedDate
            } else {
                selectedDate = simulationDate
            }
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

    // MARK: - Scene Pane

    private var scenePane: some View {
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
                Text(simulationDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(sizeClass == .regular ? .title2 : .body, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 12)
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

    // MARK: - Simulation Time

    private var simulationDate: Date {
        guard isRunning else { return selectedDate }
        let realElapsed = Date().timeIntervalSince(playAnchorReal)
        return playAnchorSim.addingTimeInterval(realElapsed * timeScale)
    }

    private var activeSpeedPresets: [SpeedPreset] {
        switch observationMode {
        case .jovianSystem: SpeedPreset.jovianDefaults
        case .saturnSystem: SpeedPreset.saturnDefaults
        default:            SpeedPreset.solarDefaults
        }
    }

    private var sliderRange: ClosedRange<Double> {
        switch observationMode {
        case .jovianSystem: 1_800...345_600
        case .saturnSystem: 21_600...3_888_000
        default:            86_400...788_940_000
        }
    }

    private var sliderStep: Double {
        switch observationMode {
        case .jovianSystem: 1_800
        case .saturnSystem: 21_600
        default:            86_400
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
        let w = radians.truncatingRemainder(dividingBy: 2.0 * .pi)
        return w < 0 ? w + 2.0 * .pi : w
    }

    private func normalizedAngleSigned(radians: Double) -> Double {
        let w = normalizedAngle(radians: radians)
        return w > .pi ? w - 2.0 * .pi : w
    }

    private func applyPreset(_ preset: SpeedPreset) {
        selectedPresetID = preset.id
        timeScale = preset.secondsPerSecond
    }

    private func applyDefaultPresetForMode(_ mode: ObservationMode) {
        switch mode {
        case .jovianSystem: applyPreset(SpeedPreset.jovianDefaults[1])
        case .saturnSystem: applyPreset(SpeedPreset.saturnDefaults[2])
        default:            applyPreset(SpeedPreset.solarDefaults[2])
        }
    }

    private func timeScaleLabel(_ s: Double) -> String {
        if s >= 86_400 {
            let days = s / 86_400
            return days >= 365
                ? String(format: "%.1f y/s", days / 365)
                : String(format: "%.0f d/s", days)
        }
        return String(format: "%.0f h/s", s / 3600)
    }

    private var selectedPairBinding: Binding<ResonancePair> {
        switch observationMode {
        case .jovianSystem: $selectedJovianPair
        case .saturnSystem: $selectedSaturnPair
        default:            $selectedSolarPair
        }
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

    private func jumpTo(_ d: NamedDate) {
        selectedDate = d.date
    }

    private func dateRow(_ d: NamedDate, deletable: Bool = false) -> some View {
        HStack {
            Button { jumpTo(d) } label: {
                HStack {
                    Text(d.name).lineLimit(1)
                    Spacer()
                    Text(d.date.formatted(.dateTime.year().month(.abbreviated)))
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

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(isRunning ? "Pause" : "Run") { isRunning.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(sizeClass == .regular ? .large : .regular)
                Button("Clear") { clearCounter += 1 }
                    .controlSize(sizeClass == .regular ? .large : .regular)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Observation")
                Picker("Observation Mode", selection: $observationMode) {
                    ForEach(ObservationMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Run Speed")
                Picker("Speed Preset", selection: $selectedPresetID) {
                    ForEach(activeSpeedPresets) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedPresetID) { _, id in
                    if let p = activeSpeedPresets.first(where: { $0.id == id }) { applyPreset(p) }
                }
                HStack {
                    Text("Fine tune").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $timeScale, in: sliderRange, step: sliderStep)
                    Text(timeScaleLabel(timeScale))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 68, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Resonance Pair")
                Picker("Pair", selection: selectedPairBinding) {
                    ForEach(activeResonancePairs) {
                        Text("\($0.primary)–\($0.secondary) (\($0.ratioLabel))").tag($0)
                    }
                }
                if let phase = phaseDegrees(for: activePair) {
                    Text("Phase: \(phase, specifier: "%.1f")°")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if observationMode == .jovianSystem {
                    Text("Laplace (Io–Europa–Ganymede): \(jovianLaplaceAngleDegrees, specifier: "%.2f")°")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                TimelineView(.animation) { _ in
                    PhaseView(pair: activePair, simulationDate: simulationDate)
                }
                .padding(.top, 4)
            }

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

            HStack {
                Toggle("Show Orbits",    isOn: $showOrbits)
                Toggle("Show Axes",      isOn: $showAxes)
            }
            HStack {
                Toggle("Show Labels",    isOn: $showLabels)
                Toggle("Show Resonance", isOn: $showResonance)
            }
            Toggle("Show Stars & Constellations", isOn: $showStars)

            DatePicker("Scrub Date", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                .font(.caption)

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Notable Dates")
                ForEach(presetDates) { dateRow($0) }
                if !savedDates.isEmpty {
                    Text("Bookmarks").font(.footnote).foregroundStyle(.tertiary).padding(.top, 2)
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
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.subheadline).foregroundStyle(.secondary)
    }
}
