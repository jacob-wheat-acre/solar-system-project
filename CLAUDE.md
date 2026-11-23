# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A SwiftUI + SceneKit solar system simulator with two apps in one Xcode project at `solar-system/solar-system.xcodeproj`:

- **`solar-system`**: iOS app (sources in `solar-system/solar-system/`)
- **`SolarSystemMac`**: macOS app (sources in `solar-system/SolarSystemMac/`) with extra views: Earth–Moon (`EarthMoonView.swift`), Galactic (`GalacticView.swift`), and `TraditionsCatalog.swift`

Deployment targets are iOS/macOS 26.2, with Swift 5 mode and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. There are no third-party dependencies. The repo is on GitHub at `jacob-wheat-acre/solar-system-project` (branch `main`).

## Commands

Run these from `solar-system/`:

```sh
# Build iOS
xcodebuild -scheme solar-system -destination 'generic/platform=iOS' -configuration Debug build

# Build macOS
xcodebuild -scheme SolarSystemMac -destination 'platform=macOS' build

# Test (Swift Testing for unit tests, XCTest for UI tests)
xcodebuild -scheme SolarSystemMac -destination 'platform=macOS' test
xcodebuild -scheme solar-system -destination 'platform=iOS Simulator,name=<device>' test

# Single test (or a whole suite: drop the last component)
xcodebuild -scheme SolarSystemMac -destination 'platform=macOS' test -only-testing:SolarSystemMacTests/MissionDataTests/missionLoads
```

Real tests live in `SolarSystemMacTests/SolarSystemMacTests.swift` (mission data, interpolation, date labels), `SolarSystemMacTests/SandboxPhysicsTests.swift` (physics against measured values) and `SandboxDesignTests.swift` (system builder). The sandbox tests are slow in Debug, so add `-configuration Release ENABLE_TESTABILITY=YES` for a fast run. The iOS test targets and the UI tests are still template stubs. No linter is configured.

Run these from the repo root:

```sh
python3 tools/fetch_missions.py [apollo11 voyager cassini newhorizons]   # regenerate mission data (needs network)
python3 tools/make_icon.py <out-dir>                                       # regenerate app icon PNGs
```

## Architecture

### Code shared between targets
The project uses Xcode 16 **file-system synchronized groups**, so any file placed in a target's folder joins that target automatically. The `SolarSystemMac` target *also* compiles these files from the iOS folder, through a membership exception in `project.pbxproj`. To share another file, add it to that `membershipExceptions` list:

- `solar-system/solar-system/SolarSystemScene.swift`: the SceneKit scene, orbital mechanics, and the `BodyCatalog`/`CelestialCatalog` data
- `solar-system/solar-system/SolarSystemSceneView.swift`: the SwiftUI wrapper, info cards, `BodyStatsCatalog`, `NotableDateCatalog`, and `ResonanceSynth` (AVFoundation audio)
- `solar-system/solar-system/PhaseView.swift`: the Lissajous resonance phase diagram
- `solar-system/solar-system/NamedDate.swift`: the type for saved and notable dates
- `solar-system/solar-system/DateDisplay.swift`: `solarDateString` / `solarDateShort` / `solarDateLabel` (BC-aware; the label's precision drops as playback speeds up)
- `solar-system/solar-system/Mission*.swift` and `MissionData/*.json`: the Missions view (see below). Each JSON file is listed in `membershipExceptions` individually.
- `solar-system/solar-system/Sandbox*.swift`: the Sandbox mode (see below)
- `solar-system/solar-system/BlackHoleLens.metal`: the black-hole lens shader (listed in `membershipExceptions` like the Swift files)
- `solar-system/solar-system/SharedSceneUI.swift`: `SceneLines` (line geometry), `CelestialSky` (camera-following star sphere) and `LabelOverlay` (SpriteKit name labels), used by Missions and Sandbox

Editing any of these files affects **both** apps, so build both schemes afterward. These files handle platform differences with `#if os(iOS)` / `#if os(macOS)` and with the type aliases `NSColorLike` (UIColor/NSColor), `PlatformViewRepresentable`, `SceneFloat` (file-private to `SolarSystemScene.swift`) and `SCNFloat` (Float on iOS, CGFloat on macOS; defined in `SolarSystemSceneView.swift`). Use these aliases instead of platform types. `ZoomableSCNView` (also in `SolarSystemSceneView.swift`) is the shared orbit/zoom camera view; set `orbitCenter` each frame to follow a moving target.

### Per-target UI
Each target has its own `ContentView.swift` with a different layout, and the macOS one adds the Earth–Moon and Galactic modes. The two copies still duplicate some logic, including `SpeedPreset`, the resonance-pair lists, the simulation clock, and the saved-date persistence. Logic meant for both apps should go in a shared file rather than in both copies.

The iOS `ContentView` has two layouts:
- **iPad/regular width:** `NavigationSplitView` with the controls in the sidebar.
- **iPhone/compact width:** the scene fills the screen, and the controls sit in a bottom sheet that can't be dismissed. Background interaction is on up to the `.medium` detent so the scene stays tappable. The bookmark alert is attached to the sheet in this layout, because a view that is presenting a sheet can't show an alert. Info cards get extra bottom padding (`cardBottomInset`) so the collapsed sheet doesn't cover them.

### Simulation model
- **Time:** `ContentView` owns the simulation clock. While the clock is running, `simulationDate = runningDate = playAnchorSim + (now − playAnchorReal) × timeScale` (clamped to the mission end in Missions mode); while paused, it is `selectedDate`. Always start and stop it with `setRunning(_:)` / `runBinding`, which re-anchor or save the date synchronously. Don't toggle `isRunning` directly or snapshot the date in an `onChange`, because handlers run after later writes in the same update. A `TimelineView(.animation)` re-evaluates every frame and passes the date down. Each scene's `update(simulationDate:)` then positions bodies analytically from that date, with no incremental integration, so you can jump to any date directly.
- **Orbits:** Body positions are computed from Keplerian elements at the J2000 epoch, solving Kepler's equation for the eccentric anomaly and converting to the true anomaly. Elements live in `BodyCatalog.planetsAndDwarfs`. The scene scale is 1 AU = 10 units, and body radii are deliberately exaggerated (`radiusScale`).
- **Observation modes** (`ObservationMode`): full system, Jovian system, and Saturn system, each with its own node root, speed presets, and slider ranges. `ResonancePair` drives the orbital-resonance guide lines, the conjunction markers, `PhaseView`, and the audio synth.
- **Persistence:** User-saved dates (`[NamedDate]`) are stored as JSON in `UserDefaults` under the key `"savedDates"`.
- **Missions mode** (`ObservationMode.missions`, both apps): `MissionModel.swift` holds the data types, the cubic-Hermite interpolation using stored velocities, `MissionCatalog` (UI metadata and speed presets) and the `MissionStore` loader actor. `MissionScene.swift` is the SceneKit scene. `MissionView.swift` holds `MissionState`, `MissionSceneView`, `MissionPlayButton` and `MissionControls`.
  - Data comes from `tools/fetch_missions.py`. Voyager, Cassini and New Horizons, plus the planets they visit, are real JPL Horizons vectors, heliocentric ecliptic J2000 in AU. Apollo 11 is reconstructed from its flight timeline (event times exact, path shapes approximate), geocentric, in km.
  - Mission events are defined only in the script. It checks each flyby date against the data's closest approach.
  - Bodies are drawn at true size, with a minimum on-screen size. Trails are drawn relative to a body when following it, or when the followed craft is inside that body's sphere of influence (`Mission.referenceBody`).
  - The sky follows the camera and is drawn first without depth testing, because it sits near `zFar`.
  - Data types are `nonisolated` so the actor can build them off the main thread.
- **Sandbox mode** (`ObservationMode.sandbox`, both apps): a real N-body simulation instead of on-rails orbits. Unlike the other modes it does **not** use ContentView's date clock: `SandboxState` (in `SandboxView.swift`) keeps its own clock in simulated years and advances the sim from the `TimelineView` via `tick(_:)`, which only touches `@ObservationIgnored` state.
  - `SandboxPhysics.swift`: units are AU, years and M☉ (G = 4π²). Newtonian gravity plus optional 1PN (Einstein–Infeld–Hoffmann) and 2.5PN radiation reaction, with an adjustable speed of light (`cScale`). Adaptive Dormand–Prince RK45, because the forces depend on velocity. Also handles collisions/mergers, black-hole absorption, collapse, proper-time clocks, the `PrecessionTracker`, and trails sampled inside the integrator.
  - `SandboxScenarios.swift`: the presets. Several are real systems with measured relativistic effects, and the tests check against them (Mercury 43″/century, S2 12′/orbit, Hulse–Taylor 4.23°/yr and its Peters–Mathews orbital decay).
  - `SandboxScene.swift`: the scene plus `GravityGrid`, the potential "rubber sheet" with depth linear in potential and drop lines from each body.
  - **System builder:** every system is a `SandboxDesign` (in `SandboxDesign.swift`), including the presets.
    - Each body has a parent and orbital elements; `parent == nil` means it orbits the centre of mass of everything before it in tree order.
    - `build()` turns a design into barycentric starting states.
    - Saved designs are stored as JSON in `UserDefaults` under `"sandboxDesigns"`.
    - `SandboxEditor.swift` edits the starting setup: the sim stays paused at t = 0 and is rebuilt on every change. `finishEditing()` refits the view via `SandboxAutoView`.
    - `SandboxAnalysis.swift` holds the physics checks (habitable zone, Hill sphere, Roche limit, Gladman spacing, Holman–Wiegert binary limits, ISCO). They're pure functions, tested in `SandboxDesignTests`.
  - **Ray-traced black holes:** `BlackHoleLens.metal` is a full-screen `SCNTechnique` pass, set on the Sandbox view only while the system has a black hole (`SandboxLens.swift` builds it and the sky texture).
    - Per pixel it integrates the photon orbit u'' + u = 3/2 u², then samples the rendered scene or an equirectangular copy of `CelestialSky`. That gives the shadow, Einstein rings and the optional accretion disk.
    - `SchwarzschildRay` is the same maths in Swift, for tests.
    - SceneKit doesn't give technique quad passes its frame matrices (`scn_frame` reads as zeros), so camera values are computed on the CPU. Each is passed as a `vec4` symbol, bound to a same-named field of the shader's struct.
    - Passing an `NSData` for a `vec4` symbol throws inside SceneKit and deadlocks the app.
    - Building needs the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
  - The physics is roughly 80× slower in Debug, so install a Release build on a device.
- **Galactic view (Mac):** `GalacticModel` (in `GalacticView.swift`) holds the measured numbers, with sources in comments: the Sun's orbit and bob, Reid et al. 2019 arm positions (trailing, 12° pitch), and the bar's length, angle and pattern speed. The bob is drawn 4× taller.
- **Mac-only scenes:** `EarthMoonScene` and `GalacticScene` follow the same pattern: a scene class with `update(...)`, an `NSViewRepresentable` container whose coordinator holds the scene, and a custom `SCNView` subclass for orbit, zoom, and tap handling.
