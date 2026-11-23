import Foundation
import SceneKit
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Light bending around a Schwarzschild black hole, in units of r_s. The Metal lens
/// shader (BlackHoleLens.metal) runs the same photon-orbit integration per pixel; this
/// copy documents it and lets tests check it against known results.
nonisolated enum SchwarzschildRay {
    /// Rays passing closer than this fall in: the edge of the shadow, √27/2 r_s ≈ 2.6 r_s.
    static let criticalImpactParameter = sqrt(27.0) / 2

    /// Total bending (radians) of a ray arriving from far away with impact parameter `b`
    /// (in r_s), or nil if the hole captures it. Integrates u'' + u = 3/2 u², u = r_s / r.
    static func deflection(b: Double, step: Double = 0.001) -> Double? {
        // Start and stop 1000 b away; the straight-line angle outside that is added back.
        let uFar = 1e-3 / b
        var u = uFar
        var du = sqrt(max(0, 1 / (b * b) - u * u * (1 - u)))
        var phi = 0.0
        func acc(_ u: Double) -> Double { -u + 1.5 * u * u }
        while phi < 100 {
            let k1u = du, k1v = acc(u)
            let k2u = du + step / 2 * k1v, k2v = acc(u + step / 2 * k1u)
            let k3u = du + step / 2 * k2v, k3v = acc(u + step / 2 * k2u)
            let k4u = du + step * k3v, k4v = acc(u + step * k3u)
            let nu = u + step / 6 * (k1u + 2 * k2u + 2 * k3u + k4u)
            let ndu = du + step / 6 * (k1v + 2 * k2v + 2 * k3v + k4v)
            if nu >= 1 { return nil }
            if ndu < 0 && nu <= uFar {
                // Interpolate the exact crossing of u = uFar.
                let f = (u - uFar) / (u - nu)
                phi += f * step
                break
            }
            u = nu; du = ndu; phi += step
        }
        return phi + 2 * asin(b * uFar) - .pi
    }
}

/// The SCNTechnique that draws black holes by ray tracing (see BlackHoleLens.metal).
enum BlackHoleLens {
    static let maxHoles = 4
    private static let skySymbol = "bh_sky"

    struct Hole {
        var position: SIMD3<Float>     // world (scene) coordinates
        var rs: Float                  // Schwarzschild radius in scene units
    }

    private static func technique(_ t: SCNTechnique, count: Int) {
        t.setObject(NSValue(scnVector4: SCNVector4(SCNFloat(count), 0, 0, 0)), forKeyedSubscript: "bh_params" as NSString)
    }

    static func makeTechnique() -> SCNTechnique? {
        let dict: [String: Any] = [
            "passes": [
                "bh_scene": [
                    "draw": "DRAW_SCENE",
                    "outputs": ["color": "bh_color", "depth": "bh_depth"],
                ],
                "bh_lens": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "bh_lens_vertex",
                    "metalFragmentShader": "bh_lens_fragment",
                    "inputs": ["colorSampler": "bh_color", "depthSampler": "bh_depth", "skySampler": skySymbol,
                               "params": "bh_params", "camera": "bh_camera", "view": "bh_view", "diskNormal": "bh_disk",
                               "rot0": "bh_rot0", "rot1": "bh_rot1", "rot2": "bh_rot2",
                               "h0": "bh_h0", "h1": "bh_h1", "h2": "bh_h2", "h3": "bh_h3"],
                    "outputs": ["color": "COLOR"],
                ],
            ],
            "sequence": ["bh_scene", "bh_lens"],
            "targets": [
                "bh_color": ["type": "color"],
                "bh_depth": ["type": "depth"],
            ],
            "symbols": [skySymbol: ["type": "sampler2D"]].merging(vectorSymbols.map { ($0, ["type": "vec4"]) }) { a, _ in a },
        ]
        guard let t = SCNTechnique(dictionary: dict) else { return nil }
        if let sky = skyTexture { t.setObject(SCNMaterialProperty(contents: sky), forKeyedSubscript: skySymbol as NSString) }
        technique(t, count: 0)
        return t
    }

    private static let vectorSymbols = ["bh_params", "bh_camera", "bh_view", "bh_disk", "bh_rot0", "bh_rot1", "bh_rot2",
                                        "bh_h0", "bh_h1", "bh_h2", "bh_h3"]

    /// Per-frame values. Everything goes to the shader in camera space; `holes` are in world space.
    static func set(_ technique: SCNTechnique, camera: SCNNode, viewport: CGSize, reverseZ: Bool,
                    holes: [Hole], disk: Bool, diskOuter: Float = 15, brightness: Float = 1.6) {
        guard let cam = camera.camera, viewport.width > 0, viewport.height > 0 else { return }
        let toWorld = camera.simdWorldTransform
        let toCamera = toWorld.inverse
        let aspect = Float(viewport.width / viewport.height)
        let fov = Float(cam.fieldOfView) * .pi / 180
        var tanX: Float, tanY: Float
        if cam.projectionDirection == .horizontal { tanX = tan(fov / 2); tanY = tanX / aspect }
        else { tanY = tan(fov / 2); tanX = tanY * aspect }
        let hs = holes.prefix(maxHoles).map { h -> SIMD4<Float> in
            let p = toCamera * SIMD4(h.position, 1)
            return SIMD4(p.x, p.y, p.z, h.rs)
        }
        let up = toCamera * SIMD4<Float>(0, 1, 0, 0)
        var values: [SIMD4<Float>] = [
            SIMD4(Float(hs.count), disk ? 1 : 0, diskOuter, brightness),
            SIMD4(tanX, tanY, Float(cam.zNear), Float(cam.zFar)),
            SIMD4(Float(viewport.height), reverseZ ? 1 : 0, 0, 0),
            SIMD4(up.x, up.y, up.z, 0),
            toWorld.columns.0, toWorld.columns.1, toWorld.columns.2,
        ]
        for k in 0..<maxHoles { values.append(k < hs.count ? hs[k] : .zero) }
        for (name, v) in zip(vectorSymbols, values) {
            let vec = SCNVector4(SCNFloat(v.x), SCNFloat(v.y), SCNFloat(v.z), SCNFloat(v.w))
            technique.setObject(NSValue(scnVector4: vec), forKeyedSubscript: name as NSString)
        }
    }

    // MARK: Sky texture

    /// The star sphere (`CelestialSky`) unwrapped to an equirectangular image, so lensed
    /// rays that leave the screen still find the same stars. Built once.
    static let skyTexture: CGImage? = renderSky(face: 512, width: 2048)

    private static func renderSky(face: Int, width: Int) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.background.contents = NSColorLike.black
        let sky = CelestialSky.makeNode()
        scene.rootNode.addChildNode(sky)
        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera!.fieldOfView = 90
        cam.camera!.zNear = 1; cam.camera!.zFar = 3000
        scene.rootNode.addChildNode(cam)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cam

        // Six 90° views: forward and up for each cube face.
        let faces: [(f: SIMD3<Float>, u: SIMD3<Float>)] = [
            ([1, 0, 0], [0, 1, 0]), ([-1, 0, 0], [0, 1, 0]),
            ([0, 1, 0], [0, 0, 1]), ([0, -1, 0], [0, 0, -1]),
            ([0, 0, 1], [0, 1, 0]), ([0, 0, -1], [0, 1, 0]),
        ]
        var pixels: [[UInt8]] = []
        for (f, u) in faces {
            // Camera axes: right, up, back (it looks down its local −z).
            cam.simdOrientation = simd_quatf(simd_float3x3(columns: (simd_cross(f, u), u, -f)))
            let img = renderer.snapshot(atTime: 0, with: CGSize(width: face, height: face), antialiasingMode: .multisampling4X)
            #if os(iOS)
            guard let cg = img.cgImage else { return nil }
            #else
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            #endif
            var buf = [UInt8](repeating: 0, count: face * face * 4)
            guard let ctx = CGContext(data: &buf, width: face, height: face, bitsPerComponent: 8, bytesPerRow: face * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: face, height: face))
            pixels.append(buf)
        }

        let height = width / 2
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let lat = Float.pi / 2 - (Float(y) + 0.5) / Float(height) * .pi
            for x in 0..<width {
                let lon = ((Float(x) + 0.5) / Float(width) - 0.5) * 2 * .pi
                let d = SIMD3<Float>(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
                // The face this direction falls on, and where on it.
                var bestFace = 0, bestDot: Float = -2
                for (i, fu) in faces.enumerated() where simd_dot(d, fu.f) > bestDot { bestDot = simd_dot(d, fu.f); bestFace = i }
                let (f, u) = faces[bestFace]
                let r = simd_cross(f, u)
                let px = simd_dot(d, r) / bestDot, py = simd_dot(d, u) / bestDot
                let col = min(face - 1, max(0, Int((px + 1) / 2 * Float(face))))
                let row = min(face - 1, max(0, Int((1 - py) / 2 * Float(face))))
                let si = (row * face + col) * 4, di = (y * width + x) * 4
                out[di] = pixels[bestFace][si]; out[di + 1] = pixels[bestFace][si + 1]
                out[di + 2] = pixels[bestFace][si + 2]; out[di + 3] = 255
            }
        }
        guard let ctx = CGContext(data: &out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
