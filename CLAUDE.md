# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A SwiftUI + SceneKit solar system simulator with two apps in one Xcode project at `solar-system/solar-system.xcodeproj`:

- **`solar-system`**: iOS app (sources in `solar-system/solar-system/`)
- **`SolarSystemMac`**: macOS app (sources in `solar-system/SolarSystemMac/`) with extra views: Earth–Moon (`EarthMoonView.swift`), Galactic (`GalacticView.swift`), and `TraditionsCatalog.swift`

Deployment targets are iOS/macOS 26.2, with Swift 5 mode and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. There are no third-party dependencies. The project isn't under git.

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

# Single test
xcodebuild -scheme SolarSystemMac -destination 'platform=macOS' test -only-testing:SolarSystemMacTests/SolarSystemMacTests/example
```

The test targets only contain Xcode template stubs. No linter is configured.

## Architecture

### Code shared between targets
The project uses Xcode 16 **file-system synchronized groups**, so any file placed in a target's folder joins that target automatically. The `SolarSystemMac` target *also* compiles these files from the iOS folder, through a membership exception in `project.pbxproj`. To share another file, add it to that `membershipExceptions` list:

- `solar-system/solar-system/SolarSystemScene.swift`: the SceneKit scene, orbital mechanics, and the `BodyCatalog`/`CelestialCatalog` data
- `solar-system/solar-system/SolarSystemSceneView.swift`: the SwiftUI wrapper, info cards, `BodyStatsCatalog`, `NotableDateCatalog`, and `ResonanceSynth` (AVFoundation audio)
- `solar-system/solar-system/PhaseView.swift`: the Lissajous resonance phase diagram
- `solar-system/solar-system/NamedDate.swift`: the type for saved and notable dates

Editing any of these files affects **both** apps, so build both schemes afterward. These files handle platform differences with `#if os(iOS)` / `#if os(macOS)` and with the type aliases `NSColorLike` (UIColor/NSColor), `PlatformViewRepresentable`, and `SceneFloat` (Float on iOS, CGFloat on macOS). Use these aliases instead of platform types.

### Per-target UI
Each target has its own `ContentView.swift` with a different layout, and the macOS one adds the Earth–Moon and Galactic modes. The two copies still duplicate some logic, including `SpeedPreset`, the resonance-pair lists, the simulation clock, and the saved-date persistence. Logic meant for both apps should go in a shared file rather than in both copies.

The iOS `ContentView` has two layouts:
- **iPad/regular width:** `NavigationSplitView` with the controls in the sidebar.
- **iPhone/compact width:** the scene fills the screen, and the controls sit in a bottom sheet that can't be dismissed. Background interaction is on up to the `.medium` detent so the scene stays tappable. The bookmark alert is attached to the sheet in this layout, because a view that is presenting a sheet can't show an alert. Info cards get extra bottom padding (`cardBottomInset`) so the collapsed sheet doesn't cover them.

### Simulation model
- **Time:** `ContentView` owns the simulation clock. While the clock is running, `simulationDate = playAnchorSim + (now − playAnchorReal) × timeScale`; while paused, it is `selectedDate`. A `TimelineView(.animation)` re-evaluates every frame and passes the date down. Each scene's `update(simulationDate:)` then positions bodies analytically from that date, with no incremental integration, so you can jump to any date directly.
- **Orbits:** Body positions are computed from Keplerian elements at the J2000 epoch, solving Kepler's equation for the eccentric anomaly and converting to the true anomaly. Elements live in `BodyCatalog.planetsAndDwarfs`. The scene scale is 1 AU = 10 units, and body radii are deliberately exaggerated (`radiusScale`).
- **Observation modes** (`ObservationMode`): full system, Jovian system, and Saturn system, each with its own node root, speed presets, and slider ranges. `ResonancePair` drives the orbital-resonance guide lines, the conjunction markers, `PhaseView`, and the audio synth.
- **Persistence:** User-saved dates (`[NamedDate]`) are stored as JSON in `UserDefaults` under the key `"savedDates"`.
- **Mac-only scenes:** `EarthMoonScene` and `GalacticScene` follow the same pattern: a scene class with `update(...)`, an `NSViewRepresentable` container whose coordinator holds the scene, and a custom `SCNView` subclass for orbit, zoom, and tap handling.
