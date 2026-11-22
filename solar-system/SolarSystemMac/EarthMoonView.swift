import SwiftUI
import SceneKit
import AppKit

// MARK: - Data Model

struct EarthMoonData {
    let ang: Double        // Earth heliocentric angle, normalised [0, 2π)
    let phaseAngle: Double // Moon synodic angle, normalised [0, 2π); 0=new, π=full
    let earthSunDistanceKm: Double
    let earthMoonDistanceKm: Double
    let nextSolarEclipse: Date?
    let nextLunarEclipse: Date?

    // MARK: Season (Northern Hemisphere)

    var northSeason: String {
        if ang < .pi / 2  { return "Autumn" }
        if ang < .pi      { return "Winter" }
        if ang < 3 * .pi / 2  { return "Spring" }
        return "Summer"
    }

    var southSeason: String {
        switch northSeason {
        case "Spring": return "Autumn"
        case "Summer": return "Winter"
        case "Autumn": return "Spring"
        default:       return "Summer"
        }
    }

    var nextEventName: String {
        if ang < .pi / 2  { return "Winter Solstice"   }
        if ang < .pi      { return "Vernal Equinox"    }
        if ang < 3 * .pi / 2  { return "Summer Solstice"   }
        return "Autumnal Equinox"
    }

    private var nextEventAngle: Double {
        if ang < .pi / 2  { return .pi / 2  }
        if ang < .pi      { return .pi      }
        if ang < 3 * .pi / 2  { return 3 * .pi / 2  }
        return 2 * .pi
    }

    var daysUntilNextEvent: Double {
        (nextEventAngle - ang) / (2 * .pi) * 365.25
    }

    var seasonProgress: Double {
        let (lo, hi): (Double, Double)
        if ang < .pi/2  { (lo, hi) = (0,       .pi/2)   }
        else if ang < .pi   { (lo, hi) = (.pi/2,   .pi)     }
        else if ang < 3 * .pi / 2 { (lo, hi) = (.pi,   3 * .pi / 2) }
        else                { (lo, hi) = (3 * .pi / 2, 2 * .pi)   }
        return max(0, min(1, (ang - lo) / (hi - lo)))
    }

    // MARK: Moon

    var moonIllumination: Double { (1 - cos(phaseAngle)) / 2 }

    var moonAgeInDays: Double { phaseAngle / (2 * .pi) * 29.53059 }

    var moonPhaseName: String {
        let d = phaseAngle * 180 / .pi
        switch d {
        case 0..<22.5:     return "New Moon"
        case 22.5..<67.5:  return "Waxing Crescent"
        case 67.5..<112.5: return "First Quarter"
        case 112.5..<157.5:return "Waxing Gibbous"
        case 157.5..<202.5:return "Full Moon"
        case 202.5..<247.5:return "Waning Gibbous"
        case 247.5..<292.5:return "Last Quarter"
        case 292.5..<337.5:return "Waning Crescent"
        default:           return "New Moon"
        }
    }

    var daysUntilFull: Double {
        var a = (.pi - phaseAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return a / (2 * .pi) * 29.53059
    }

    var daysUntilNew: Double {
        var a = (2 * .pi - phaseAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if a <= 0 { a += 2 * .pi }
        return a / (2 * .pi) * 29.53059
    }

    // MARK: Factory

    static func compute(for date: Date) -> EarthMoonData {
        let epoch = Date(timeIntervalSinceReferenceDate: -31_579_200)
        let t = date.timeIntervalSince(epoch)
        let body = BodyCatalog.planetsAndDwarfs.first { $0.name == "Earth" }!

        let ecc: Double = body.eccentricity
        let M: Double = body.meanAnomalyAtEpoch + 2.0 * .pi * (t / body.orbitalPeriodSeconds)
        var E: Double = M
        for _ in 0..<8 { E -= (E - ecc * sin(E) - M) / (1.0 - ecc * cos(E)) }
        let sinHalf: Double = sin(E / 2)
        let cosHalf: Double = cos(E / 2)
        let nu: Double = 2.0 * atan2(sqrt(1 + ecc) * sinHalf, sqrt(1 - ecc) * cosHalf)
        var ang = (nu + body.argOfPerihelionRad).truncatingRemainder(dividingBy: 2 * .pi)
        if ang < 0 { ang += 2 * .pi }

        // Known new moon: 6 Jan 2000 18:14 UTC (497640 s after Apple reference date)
        let newMoonRef = Date(timeIntervalSinceReferenceDate: 497_640)
        var phase = (date.timeIntervalSince(newMoonRef) / (29.53059 * 86_400))
            .truncatingRemainder(dividingBy: 1) * 2 * .pi
        if phase < 0 { phase += 2 * .pi }

        // Earth-Sun distance
        let earthSunKm = (1.0 - ecc * cos(E)) * 149_597_870.7

        // Moon distance (Keplerian, anomalistic period ~27.55 days)
        let moonAnom   = 134.963 * .pi / 180 + 2.0 * .pi * (t / (27.55455 * 86400.0))
        let moonDistKm = 384_400.0 * (1.0 - 0.0549 * cos(moonAnom))

        let eclipses = EarthMoonData.nextEclipses(from: date)

        return EarthMoonData(
            ang: ang, phaseAngle: phase,
            earthSunDistanceKm: earthSunKm,
            earthMoonDistanceKm: moonDistKm,
            nextSolarEclipse: eclipses.solar,
            nextLunarEclipse: eclipses.lunar
        )
    }

    // MARK: Eclipse Prediction

    static func moonEclipticLatitudeDeg(daysSinceJ2000: Double) -> Double {
        let omega = 125.044 - 0.05295 * daysSinceJ2000   // ascending node regression
        let L     = 218.316 + 13.176396 * daysSinceJ2000  // Moon mean longitude
        return 5.128 * sin((L - omega) * .pi / 180)
    }

    private static var eclipseCache: (computedFor: Date, solar: Date?, lunar: Date?)? = nil

    static func nextEclipses(from date: Date) -> (solar: Date?, lunar: Date?) {
        if let c = eclipseCache, abs(c.computedFor.timeIntervalSince(date)) < 7 * 86400 {
            return (c.solar, c.lunar)
        }
        let j2000      = Date(timeIntervalSinceReferenceDate: -31_579_200)
        let newMoonRef = Date(timeIntervalSinceReferenceDate: 497_640)
        let step       = 12.0 * 3600.0
        let maxTime    = 2.0 * 365.25 * 86400.0
        var foundSolar: Date? = nil
        var foundLunar: Date? = nil
        var t = step
        while t < maxTime, foundSolar == nil || foundLunar == nil {
            let d   = date.addingTimeInterval(t)
            let lat = moonEclipticLatitudeDeg(daysSinceJ2000: d.timeIntervalSince(j2000) / 86400)
            if abs(lat) < 1.5 {
                var ph = (d.timeIntervalSince(newMoonRef) / (29.53059 * 86_400))
                    .truncatingRemainder(dividingBy: 1) * 2 * .pi
                if ph < 0 { ph += 2 * .pi }
                if foundSolar == nil && (ph < 0.45 || ph > 2 * .pi - 0.45) { foundSolar = d }
                if foundLunar == nil && abs(ph - .pi) < 0.45                { foundLunar = d }
            }
            t += step
        }
        eclipseCache = (computedFor: date, solar: foundSolar, lunar: foundLunar)
        return (foundSolar, foundLunar)
    }
}

// MARK: - Earth-Moon Scene

final class EarthMoonScene {
    let scene      = SCNScene()
    let cameraNode = SCNNode()

    private let root          = SCNNode()
    private var earthNode:     SCNNode!
    private var earthSpinNode: SCNNode!
    private var moonNode:      SCNNode!
    private var moonOrbitRing: SCNNode!
    private var shadowCone:    SCNNode!

    private let earthOrbitR: CGFloat = 28.0
    private let moonOrbitR:  CGFloat =  5.5
    private let obliquity:   Double  = BodyCatalog.deg(23.44)

    private let epoch      = Date(timeIntervalSinceReferenceDate: -31_579_200)
    private let earthDef:  BodyDef
    private let newMoonRef = Date(timeIntervalSinceReferenceDate: 497_640)
    private let synodicPeriod = 29.53059 * 86_400.0

    init() {
        earthDef = BodyCatalog.planetsAndDwarfs.first { $0.name == "Earth" }!
        scene.rootNode.addChildNode(root)
        build()
    }

    // MARK: Update

    func update(date: Date) {
        let t   = date.timeIntervalSince(epoch)
        let ang = earthAngle(t: t)

        // Earth position (Kepler)
        let ecc: Double = earthDef.eccentricity
        let M: Double = earthDef.meanAnomalyAtEpoch + 2.0 * .pi * (t / earthDef.orbitalPeriodSeconds)
        var E: Double = M
        for _ in 0..<8 { E -= (E - ecc * sin(E) - M) / (1.0 - ecc * cos(E)) }
        let r: Double = Double(earthOrbitR) * (1.0 - ecc * cos(E))
        earthNode.position = SCNVector3(x: CGFloat(r * cos(ang)), y: 0, z: CGFloat(r * sin(ang)))

        // Tilt on parent (pole stays fixed in space); spin on child (synced to simulation time)
        earthNode.eulerAngles = SCNVector3(x: CGFloat(obliquity), y: 0, z: 0)
        let spin = (2.0 * .pi * (t / earthDef.rotationPeriodSeconds))
            .truncatingRemainder(dividingBy: 2.0 * .pi)
        earthSpinNode.eulerAngles = SCNVector3(0, CGFloat(spin), 0)

        // Moon position aligned with synodic phase
        var phaseAngle = (date.timeIntervalSince(newMoonRef) / synodicPeriod)
            .truncatingRemainder(dividingBy: 1) * 2 * .pi
        if phaseAngle < 0 { phaseAngle += 2 * .pi }
        let moonAngle = ang + .pi - phaseAngle
        let mr = Double(moonOrbitR)
        moonNode.position = SCNVector3(
            x: earthNode.position.x + CGFloat(mr * cos(moonAngle)),
            y: 0,
            z: earthNode.position.z + CGFloat(mr * sin(moonAngle))
        )
        moonOrbitRing.position = earthNode.position

        // Shadow cone — update each frame to track Earth-Sun direction
        let ep  = earthNode.position
        let epf = simd_float3(Float(ep.x), Float(ep.y), Float(ep.z))
        let len = simd_length(epf)
        if len > 0.001 {
            let awayFromSun = epf / len
            let toSun       = -awayFromSun

            // Cone tip (topRadius = 0, at local +Y) points toward sun; center offset away from sun
            let coneHeight: Float = 20.0
            shadowCone.simdPosition = epf + awayFromSun * (coneHeight / 2)
            let axis   = simd_cross(simd_float3(0, 1, 0), toSun)
            let cosAng = simd_dot(simd_float3(0, 1, 0), toSun)
            if simd_length(axis) > 1e-6 {
                shadowCone.simdOrientation = simd_quatf(
                    angle: acos(max(-1, min(1, cosAng))),
                    axis:  simd_normalize(axis)
                )
            } else if cosAng < 0 {
                shadowCone.simdOrientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
            }
        }
    }

    // MARK: Scene Construction

    private func earthAngle(t: Double) -> Double {
        let ecc: Double = earthDef.eccentricity
        let M: Double = earthDef.meanAnomalyAtEpoch + 2.0 * .pi * (t / earthDef.orbitalPeriodSeconds)
        var E: Double = M
        for _ in 0..<8 { E -= (E - ecc * sin(E) - M) / (1.0 - ecc * cos(E)) }
        let sinH = sin(E / 2); let cosH = cos(E / 2)
        let nu: Double = 2.0 * atan2(sqrt(1.0 + ecc) * sinH, sqrt(1.0 - ecc) * cosH)
        return nu + earthDef.argOfPerihelionRad
    }

    private func build() {
        // Ambient fill — kept low so the PBR terminator on Earth is visible
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 80
        let ambNode = SCNNode(); ambNode.light = amb; root.addChildNode(ambNode)

        // Sun point light at origin
        let sl = SCNLight(); sl.type = .omni; sl.intensity = 2600
        let slNode = SCNNode(); slNode.light = sl; root.addChildNode(slNode)

        // Sun sphere
        let sunGeo = SCNSphere(radius: 3.5); sunGeo.segmentCount = 48
        let sunMat = SCNMaterial()
        sunMat.diffuse.contents  = NSColor.systemYellow
        sunMat.emission.contents = NSColor.systemYellow
        sunMat.emission.intensity = 1.5
        sunMat.lightingModel = .constant
        sunGeo.materials = [sunMat]
        root.addChildNode(SCNNode(geometry: sunGeo))

        // Earth orbit ring — true ellipse with sun at focus
        root.addChildNode(makeEllipticOrbitRing())

        // Season markers: colored radial spokes from sun to orbit + billboard labels beyond
        let markers: [(ang: Double, color: NSColor, top: String, sub: String)] = [
            (0,           NSColor(white: 0.78, alpha: 1),                      "Autumnal Equinox", "~Sep 23"),
            (.pi / 2,     .cyan,                                                "Winter Solstice",  "~Dec 21"),
            (.pi,         NSColor(red: 0.45, green: 0.95, blue: 0.45, alpha: 1), "Vernal Equinox",   "~Mar 20"),
            (3 * .pi / 2, NSColor(red: 1.0,  green: 0.65, blue: 0.2,  alpha: 1), "Summer Solstice",  "~Jun 21"),
        ]
        let orbitR  = Double(earthOrbitR)
        let labelR  = orbitR + 4.2
        for m in markers {
            root.addChildNode(makeRadialSpoke(angle: m.ang, length: CGFloat(orbitR), color: m.color))
            let label = makeLabelNode(top: m.top, sub: m.sub, color: m.color)
            label.position = SCNVector3(
                x: CGFloat(labelR * cos(m.ang)),
                y: 1.2,
                z: CGFloat(labelR * sin(m.ang))
            )
            root.addChildNode(label)
        }

        // Earth — tilt-only parent; spinning child carries all geometry
        earthNode = SCNNode()
        root.addChildNode(earthNode)

        let eGeo = SCNSphere(radius: 1.2); eGeo.segmentCount = 48
        let eMat = SCNMaterial()
        eMat.diffuse.contents   = makeEarthTexture()
        eMat.lightingModel      = .physicallyBased
        eMat.roughness.contents = 0.7
        eMat.metalness.contents = 0.0
        eGeo.materials = [eMat]
        earthSpinNode = SCNNode(geometry: eGeo)
        earthNode.addChildNode(earthSpinNode)

        // Atmospheric haze
        let atmGeo = SCNSphere(radius: 1.30); atmGeo.segmentCount = 48
        let atmMat = SCNMaterial()
        atmMat.diffuse.contents    = NSColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 0.10)
        atmMat.isDoubleSided       = true
        atmMat.lightingModel       = .constant
        atmMat.writesToDepthBuffer = false
        atmGeo.materials = [atmMat]
        earthSpinNode.addChildNode(SCNNode(geometry: atmGeo))

        // Equatorial ring (child of spin node — stays in Earth's equatorial plane)
        let eqTorus = SCNTorus(ringRadius: 1.25, pipeRadius: 0.028)
        let eqMat = SCNMaterial()
        eqMat.diffuse.contents = NSColor(white: 0.9, alpha: 0.55)
        eqMat.lightingModel    = .constant
        eqTorus.materials = [eqMat]
        earthSpinNode.addChildNode(SCNNode(geometry: eqTorus))

        // Spin driven in update(date:) — no SCNAction here

        // Moon orbit ring (position tracked to Earth each frame)
        moonOrbitRing = makeOrbitRing(radius: moonOrbitR)
        root.addChildNode(moonOrbitRing)

        // Umbra shadow cone extending away from Sun
        buildShadowCone()
        // Perihelion & aphelion markers
        buildPerihelionAphelion()
        // Stars, zodiac constellations, Milky Way
        buildCelestialSphere()

        // Moon
        let mGeo = SCNSphere(radius: 0.32); mGeo.segmentCount = 32
        let mMat = SCNMaterial()
        mMat.diffuse.contents   = NSColor.lightGray
        mMat.lightingModel      = .physicallyBased
        mMat.roughness.contents = 0.85
        mGeo.materials = [mMat]
        moonNode = SCNNode(geometry: mGeo)
        root.addChildNode(moonNode)

        // Camera
        let cam = SCNCamera(); cam.zFar = 500; cam.zNear = 0.1; cam.fieldOfView = 50
        cameraNode.camera   = cam
        cameraNode.position = SCNVector3(8, 50, 85)
        cameraNode.look(at: SCNVector3Zero)
        root.addChildNode(cameraNode)
    }

    private func makeOrbitRing(radius: CGFloat) -> SCNNode {
        let t   = SCNTorus(ringRadius: radius, pipeRadius: 0.05)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(white: 1, alpha: 0.22)
        mat.lightingModel    = .constant
        t.materials = [mat]
        return SCNNode(geometry: t)
    }

    // Thin cylinder radiating from the sun (origin) to the orbit at the given angle in the XZ plane.
    private func makeRadialSpoke(angle: Double, length: CGFloat, color: NSColor) -> SCNNode {
        let cyl = SCNCylinder(radius: 0.032, height: length)
        let mat = SCNMaterial()
        mat.diffuse.contents  = color
        mat.emission.contents = color
        mat.emission.intensity = 0.55
        mat.lightingModel     = .constant
        cyl.materials = [mat]
        let node = SCNNode(geometry: cyl)
        // Place cylinder at midpoint of spoke
        node.position = SCNVector3(
            x: CGFloat(cos(angle)) * length / 2,
            y: 0,
            z: CGFloat(sin(angle)) * length / 2
        )
        // Rotate cylinder axis (Y) to lie along the radial direction in XZ plane
        node.rotation = SCNVector4(CGFloat(sin(angle)), 0, CGFloat(-cos(angle)), CGFloat.pi / 2)
        return node
    }

    // Billboard text label: renders two lines of text into an NSImage → SCNPlane that always faces the camera.
    private func makeLabelNode(top: String, sub: String, color: NSColor) -> SCNNode {
        let imgW = 420, imgH = 130
        let img = NSImage(size: NSSize(width: imgW, height: imgH))
        img.lockFocus()
        let topAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: color,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .regular),
            .foregroundColor: color.withAlphaComponent(0.65),
        ]
        let topNS = top as NSString
        let subNS = sub as NSString
        let topSz = topNS.size(withAttributes: topAttrs)
        let subSz = subNS.size(withAttributes: subAttrs)
        topNS.draw(at: CGPoint(x: (CGFloat(imgW) - topSz.width) / 2, y: 72), withAttributes: topAttrs)
        subNS.draw(at: CGPoint(x: (CGFloat(imgW) - subSz.width) / 2, y: 30), withAttributes: subAttrs)
        img.unlockFocus()

        let plane = SCNPlane(width: 13.0, height: 4.0)
        let mat = SCNMaterial()
        mat.diffuse.contents = img
        mat.lightingModel    = .constant
        mat.isDoubleSided    = true
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        node.constraints = [SCNBillboardConstraint()]  // always faces camera, stays upright
        return node
    }

    // Elliptical orbit ring with sun at one focus.
    // Parametric form: xl = –ae + a·cos(θ), zl = b·sin(θ), rotated by argOfPerihelion.
    private func makeEllipticOrbitRing(segments: Int = 256) -> SCNNode {
        let a    = earthOrbitR
        let e    = CGFloat(earthDef.eccentricity)
        let b    = a * CGFloat(sqrt(1.0 - Double(e) * Double(e)))
        let ae   = a * e
        let omega = earthDef.argOfPerihelionRad
        let cosO = CGFloat(cos(omega)), sinO = CGFloat(sin(omega))

        var verts = [SCNVector3]()
        for i in 0..<segments {
            let theta = 2.0 * CGFloat.pi * CGFloat(i) / CGFloat(segments)
            let xl = -ae + a * cos(theta)
            let zl = b * sin(theta)
            verts.append(SCNVector3(
                x: xl * cosO - zl * sinO,
                y: 0,
                z: xl * sinO + zl * cosO
            ))
        }
        var indices = [Int32]()
        for i in 0..<segments {
            indices.append(Int32(i))
            indices.append(Int32((i + 1) % segments))
        }
        let src = SCNGeometrySource(vertices: verts)
        let elm = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geo = SCNGeometry(sources: [src], elements: [elm])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(white: 1, alpha: 0.22)
        mat.lightingModel    = .constant
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    // Procedural Earth texture: latitude-based ocean/land/ice with sin-function continents.
    private func makeEarthTexture() -> NSImage {
        let w = 512, h = 512
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: w * 3, bitsPerPixel: 24
        ), let ptr = rep.bitmapData else {
            return NSImage(size: NSSize(width: w, height: h))
        }

        for py in 0..<h {
            // Row 0 = top of bitmap → north pole.
            let lat    = (0.5 - Double(py) / Double(h)) * .pi
            let absLat = abs(lat * 180 / .pi)
            for px in 0..<w {
                let lon = (Double(px) / Double(w)) * 2.0 * .pi - .pi
                var r, g, b: Double

                if absLat > 70 {
                    // Polar ice cap: fade in over 10°
                    let t = min(1.0, (absLat - 70) / 10.0)
                    r = 0.80 + t * 0.15; g = 0.85 + t * 0.11; b = 0.90 + t * 0.08
                } else {
                    // Sin-based pseudo-continent noise
                    let n1 = sin(lon * 1.8 + 0.3) * cos(lat * 2.2)
                    let n2 = sin(lon * 3.1 - 1.1) * cos(lat * 1.7 + 0.5)
                    let n3 = sin(lon * 0.9 + 2.0) * cos(lat * 3.0)
                    let land = n1 * 0.5 + n2 * 0.3 + n3 * 0.2

                    if land > 0.30 {
                        // Land: green tropics → olive temperate → brown boreal
                        if absLat < 25      { r=0.18; g=0.48; b=0.18 }
                        else if absLat < 55 { r=0.38; g=0.42; b=0.22 }
                        else                { r=0.42; g=0.38; b=0.28 }
                    } else {
                        // Ocean: bright tropical → deep temperate/polar
                        if absLat < 25      { r=0.07; g=0.28; b=0.70 }
                        else if absLat < 55 { r=0.08; g=0.20; b=0.58 }
                        else                { r=0.06; g=0.15; b=0.44 }
                    }
                }
                let off = (py * w + px) * 3
                ptr[off]   = UInt8(r * 255)
                ptr[off+1] = UInt8(g * 255)
                ptr[off+2] = UInt8(b * 255)
            }
        }

        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return img
    }

    // MARK: Shadow Cone

    private func buildShadowCone() {
        let coneH: CGFloat = 20.0
        let cone = SCNCone(topRadius: 0, bottomRadius: 2.2, height: coneH)
        cone.radialSegmentCount = 32
        let mat = SCNMaterial()
        mat.diffuse.contents    = NSColor(white: 0, alpha: 0.20)
        mat.isDoubleSided       = true
        mat.lightingModel       = .constant
        mat.writesToDepthBuffer = false
        cone.materials = [mat]
        shadowCone = SCNNode(geometry: cone)
        shadowCone.renderingOrder = -1
        root.addChildNode(shadowCone)
    }

    // MARK: Perihelion & Aphelion Markers

    private func buildPerihelionAphelion() {
        let a     = Double(earthOrbitR)
        let e     = earthDef.eccentricity
        let omega = earthDef.argOfPerihelionRad
        let cosO  = cos(omega), sinO = sin(omega)

        // Perihelion: ellipse θ=0 → xl = a(1−e), zl = 0, rotated by ω
        let pDist = a * (1 - e)
        let pX    = pDist * cosO, pZ = pDist * sinO

        // Aphelion: ellipse θ=π → xl = −a(1+e), zl = 0, rotated by ω
        let aDist = a * (1 + e)
        let aX    = -aDist * cosO, aZ = -aDist * sinO

        let off: Double = 4.5
        let entries: [(ox: Double, oz: Double, lx: Double, lz: Double, top: String, sub: String, color: NSColor)] = [
            (ox: pX, oz: pZ,
             lx: pX / pDist * (pDist + off), lz: pZ / pDist * (pDist + off),
             top: "Perihelion", sub: "~Jan 3 · closest",
             color: NSColor(red: 1.0, green: 0.72, blue: 0.3, alpha: 1)),
            (ox: aX, oz: aZ,
             lx: aX / aDist * (aDist + off), lz: aZ / aDist * (aDist + off),
             top: "Aphelion", sub: "~Jul 4 · farthest",
             color: NSColor(red: 0.5, green: 0.82, blue: 1.0, alpha: 1)),
        ]

        for entry in entries {
            let dot = SCNSphere(radius: 0.28)
            let dm  = SCNMaterial()
            dm.diffuse.contents  = entry.color
            dm.emission.contents = entry.color
            dm.emission.intensity = 0.6
            dm.lightingModel     = .constant
            dot.materials = [dm]
            let dotNode = SCNNode(geometry: dot)
            dotNode.position = SCNVector3(x: CGFloat(entry.ox), y: 0, z: CGFloat(entry.oz))
            root.addChildNode(dotNode)

            let lbl = makeLabelNode(top: entry.top, sub: entry.sub, color: entry.color)
            lbl.position = SCNVector3(x: CGFloat(entry.lx), y: 1.5, z: CGFloat(entry.lz))
            root.addChildNode(lbl)
        }
    }

    // MARK: Celestial Sphere (stars, zodiac, Milky Way)

    private func eclipticToScene(lonDeg: Double, latDeg: Double, radius: CGFloat) -> SCNVector3 {
        let lon = lonDeg * .pi / 180, lat = latDeg * .pi / 180
        return SCNVector3(
            CGFloat(cos(lat) * cos(lon)) * radius,
            CGFloat(sin(lat)) * radius,
            CGFloat(cos(lat) * sin(lon)) * radius
        )
    }

    private func buildCelestialSphere() {
        let R: CGFloat = 400
        buildStarField(radius: R)
        buildZodiacConstellations(radius: R)
        buildMilkyWayBand(radius: R)
    }

    private func buildStarField(radius: CGFloat) {
        var verts: [SCNVector3] = []
        for star in CelestialCatalog.labeledStars {
            verts.append(eclipticToScene(lonDeg: star.lon, latDeg: star.lat, radius: radius))
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let lon = Double.random(in: 0..<360, using: &rng)
            let lat = asin(Double.random(in: -1.0...1.0, using: &rng)) * 180 / .pi
            verts.append(eclipticToScene(lonDeg: lon, latDeg: lat,
                                         radius: radius * CGFloat.random(in: 0.97...1.0, using: &rng)))
        }
        let src = SCNGeometrySource(vertices: verts)
        let idx = (0..<verts.count).map { Int32($0) }
        let el  = SCNGeometryElement(indices: idx, primitiveType: .point)
        el.pointSize = 2.0
        el.minimumPointScreenSpaceRadius = 0.4
        el.maximumPointScreenSpaceRadius = 3.0
        let geo = SCNGeometry(sources: [src], elements: [el])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(white: 1.0, alpha: 0.70)
        mat.lightingModel    = .constant
        geo.materials = [mat]
        root.addChildNode(SCNNode(geometry: geo))
    }

    private func buildZodiacConstellations(radius: CGFloat) {
        for cst in CelestialCatalog.zodiacConstellations {
            let pts = cst.stars.map { eclipticToScene(lonDeg: $0.lon, latDeg: $0.lat, radius: radius) }
            var lineVerts: [SCNVector3] = []
            for (a, b) in cst.lines { lineVerts.append(pts[a]); lineVerts.append(pts[b]) }
            if !lineVerts.isEmpty {
                let lSrc = SCNGeometrySource(vertices: lineVerts)
                let lIdx = (0..<lineVerts.count).map { Int32($0) }
                let lEl  = SCNGeometryElement(indices: lIdx, primitiveType: .line)
                let lGeo = SCNGeometry(sources: [lSrc], elements: [lEl])
                let lMat = SCNMaterial()
                lMat.diffuse.contents = NSColor(white: 1.0, alpha: 0.28)
                lMat.lightingModel    = .constant
                lGeo.materials = [lMat]
                root.addChildNode(SCNNode(geometry: lGeo))
            }
            let dSrc = SCNGeometrySource(vertices: pts)
            let dIdx = (0..<pts.count).map { Int32($0) }
            let dEl  = SCNGeometryElement(indices: dIdx, primitiveType: .point)
            dEl.pointSize = 2.5
            dEl.minimumPointScreenSpaceRadius = 1.0
            dEl.maximumPointScreenSpaceRadius = 4.0
            let dGeo = SCNGeometry(sources: [dSrc], elements: [dEl])
            let dMat = SCNMaterial()
            dMat.diffuse.contents = NSColor(white: 1.0, alpha: 0.85)
            dMat.lightingModel    = .constant
            dGeo.materials = [dMat]
            root.addChildNode(SCNNode(geometry: dGeo))
        }
    }

    private func buildMilkyWayBand(radius: CGFloat) {
        for (pipe, alpha): (CGFloat, CGFloat) in [(radius * 0.055, 0.08), (radius * 0.018, 0.15)] {
            let torus = SCNTorus(ringRadius: radius * 0.998, pipeRadius: pipe)
            let mat   = SCNMaterial()
            mat.diffuse.contents = NSColor(white: 1.0, alpha: alpha)
            mat.isDoubleSided    = true
            mat.lightingModel    = .constant
            torus.materials = [mat]
            let node = SCNNode(geometry: torus)
            node.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 3)
            root.addChildNode(node)
        }
    }
}

// MARK: - macOS SCNView with orbit + zoom

private class EarthMoonSCNView: SCNView {
    weak var cameraNode: SCNNode?
    private var azimuth:   Float = 0
    private var elevation: Float = -0.53
    private var distance:  Float = 98

    func setup(camera: SCNNode) {
        cameraNode = camera
        syncOrbit()
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        pan.buttonMask = 0x1
        addGestureRecognizer(pan)
    }

    func syncOrbit() {
        guard let cam = cameraNode else { return }
        let p = cam.position
        let px = Float(p.x), py = Float(p.y), pz = Float(p.z)
        let d  = sqrt(px*px + py*py + pz*pz)
        distance  = max(5, d)
        elevation = d > 0.001 ? asin(max(-1, min(1, py / d))) : 0
        azimuth   = atan2(px, pz)
    }

    @objc private func handleOrbit(_ r: NSPanGestureRecognizer) {
        let t = r.translation(in: self)
        r.setTranslation(.zero, in: self)
        azimuth   += Float(t.x) * 0.005
        elevation += Float(t.y) * 0.005
        elevation  = max(-Float.pi/2 + 0.02, min(Float.pi/2 - 0.02, elevation))
        applyOrbit()
    }

    override func scrollWheel(with event: NSEvent) {
        let f = event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaY) * 0.008
            : Double(event.deltaY) * 0.18
        distance = Float(max(5, min(600, Double(distance) * exp(-f))))
        applyOrbit()
    }

    override func magnify(with event: NSEvent) {
        distance = Float(max(5, min(600, Double(distance) * exp(-event.magnification * 2.0))))
        applyOrbit()
    }

    private func applyOrbit() {
        guard let cam = cameraNode else { return }
        let x = distance * cos(elevation) * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * cos(azimuth)
        cam.position = SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
        cam.look(at: SCNVector3Zero)
    }
}

// MARK: - NSViewRepresentable

struct EarthMoonContainer: NSViewRepresentable {
    let simulationDate: Date

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = EarthMoonSCNView()
        let em   = EarthMoonScene()
        view.scene                = em.scene
        view.backgroundColor      = .black
        view.antialiasingMode     = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.pointOfView          = em.cameraNode
        view.allowsCameraControl  = false
        view.setup(camera: em.cameraNode)
        context.coordinator.scene = em
        em.update(date: simulationDate)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.scene?.update(date: simulationDate)
    }

    final class Coordinator { var scene: EarthMoonScene? }
}

// MARK: - Moon Phase Diagram

struct MoonPhaseView: View {
    let phaseAngle: Double   // 0 = new, π = full, 2π = new

    var body: some View {
        Canvas { ctx, size in
            let r      = min(size.width, size.height) / 2 - 1
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let disk   = CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)

            // Dark-side disk
            ctx.fill(Path(ellipseIn: disk), with: .color(.white.opacity(0.12)))
            // Lit portion
            ctx.fill(litPath(center: center, r: r), with: .color(.white.opacity(0.90)))
            // Rim
            ctx.stroke(Path(ellipseIn: disk), with: .color(.white.opacity(0.35)), lineWidth: 0.8)
        }
        .frame(width: 64, height: 64)
    }

    // Builds the lit region of the moon for any phase.
    //
    // Convention (northern hemisphere, Sun to the right):
    //   Waxing (0→π):  right semicircle is always lit; terminator sweeps from +r to −r.
    //   Waning (π→2π): left  semicircle is always lit; terminator sweeps from +r to −r.
    //
    // At new moon the terminator coincides with the semicircle → zero area.
    // At full moon the terminator is the opposite semicircle → full circle.
    private func litPath(center: CGPoint, r: CGFloat) -> Path {
        let k: CGFloat = 0.5523   // Bezier quarter-circle constant
        let top    = CGPoint(x: center.x, y: center.y - r)
        let waxing = phaseAngle < .pi
        let cosΦ    = CGFloat(cos(phaseAngle))
        let ex      = abs(cosΦ) * r    // half-width of terminator ellipse

        var p = Path()
        p.move(to: top)

        // Primary lit semicircle (top → bot)
        if waxing {
            p.addArc(center: center, radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        } else {
            p.addArc(center: center, radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        }

        // Terminator arc (bot → top via ellipse)
        // curveRight logic ensures zero area at new/waning-new, full circle at full.
        let curveRight = waxing ? (cosΦ > 0) : (cosΦ < 0)
        let d: CGFloat = curveRight ? 1 : -1
        let mx = center.x + d * ex

        p.addCurve(to: CGPoint(x: mx, y: center.y),
                   control1: CGPoint(x: center.x + d * ex * k, y: center.y + r),
                   control2: CGPoint(x: mx,                    y: center.y + r * k))
        p.addCurve(to: top,
                   control1: CGPoint(x: mx,                    y: center.y - r * k),
                   control2: CGPoint(x: center.x + d * ex * k, y: center.y - r))
        p.closeSubpath()
        return p
    }
}

// MARK: - Info Overlays

private struct SeasonCard: View {
    let data: EarthMoonData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SEASON")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(data.northSeason)
                .font(.system(size: 18, weight: .semibold))
            Text("N   ·   \(data.southSeason) S")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 4)
                    Capsule()
                        .fill(seasonColor)
                        .frame(width: geo.size.width * CGFloat(data.seasonProgress), height: 4)
                }
            }
            .frame(height: 4)
            Text(String(format: "%.0f d until %@", data.daysUntilNextEvent, data.nextEventName))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(String(format: "☀  %.4f AU", data.earthSunDistanceKm / 149_597_870.7))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 175)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var seasonColor: Color {
        switch data.northSeason {
        case "Spring": return .green
        case "Summer": return .orange
        case "Autumn": return Color(red: 0.75, green: 0.45, blue: 0.1)
        default:       return .cyan
        }
    }
}

private struct MoonCard: View {
    let data: EarthMoonData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MOON")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                MoonPhaseView(phaseAngle: data.phaseAngle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(data.moonPhaseName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(String(format: "%.0f%% lit", data.moonIllumination * 100))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(String(format: "Age %.1f d", data.moonAgeInDays))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Divider().background(Color.white.opacity(0.15))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full moon in").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(String(format: "%.1f d", data.daysUntilFull))
                        .font(.system(size: 12, weight: .medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("New moon in").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(String(format: "%.1f d", data.daysUntilNew))
                        .font(.system(size: 12, weight: .medium))
                }
            }
            Divider().background(Color.white.opacity(0.15))
            Text(String(format: "⟷  %.0f km", data.earthMoonDistanceKm))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if let solar = data.nextSolarEclipse {
                HStack {
                    Text("Solar eclipse").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(solar.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if let lunar = data.nextLunarEclipse {
                HStack {
                    Text("Lunar eclipse").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(lunar.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 210)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Top-level View

struct EarthMoonView: View {
    let simulationDate: Date

    var body: some View {
        let data = EarthMoonData.compute(for: simulationDate)
        EarthMoonContainer(simulationDate: simulationDate)
            .overlay(alignment: .top) {
                Text(simulationDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 10)
            }
            .overlay(alignment: .bottomLeading) {
                SeasonCard(data: data).padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                MoonCard(data: data).padding(12)
            }
    }
}
