import Foundation
import SwiftUI
import SceneKit
import SpriteKit
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Small SceneKit helpers shared by the Missions and Sandbox scenes.

enum SceneLines {
    static func material(_ color: NSColorLike) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        return m
    }

    static func geometry(_ pts: [SCNVector3], material: SCNMaterial?) -> SCNGeometry {
        var idx: [Int32] = []
        for i in 0..<max(0, pts.count - 1) { idx += [Int32(i), Int32(i + 1)] }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        if let material { g.materials = [material] }
        return g
    }

    /// A circle of `radius` in the scene's XZ plane.
    static func circle(radius: Float, segments: Int = 96, material: SCNMaterial) -> SCNGeometry {
        let pts = (0...segments).map { i -> SCNVector3 in
            let a = Float(i) / Float(segments) * 2 * .pi
            return SCNVector3(SCNFloat(radius * cos(a)), 0, SCNFloat(radius * sin(a)))
        }
        return geometry(pts, material: material)
    }
}

/// Stars, zodiac stick figures and the Milky Way on a sphere of radius 1000.
/// The node is drawn first and without depth testing: it sits near zFar, where depth
/// precision runs out when the camera is zoomed in close. Keep it centred on the
/// camera and scale it to the current far distance.
enum CelestialSky {
    static let radius: Float = 1000

    static func makeNode() -> SCNNode {
        let r = CGFloat(radius)
        let sky = SCNNode()
        func ecl(_ lonDeg: Double, _ latDeg: Double) -> SCNVector3 {
            let lon = lonDeg * .pi / 180, lat = latDeg * .pi / 180
            return SCNVector3(SCNFloat(cos(lat) * cos(lon) * Double(r)), SCNFloat(sin(lat) * Double(r)),
                              SCNFloat(cos(lat) * sin(lon) * Double(r)))
        }
        var stars = CelestialCatalog.labeledStars.map { ecl($0.lon, $0.lat) }
        var rng = SplitMix64(seed: 0x5354_4152)
        for _ in 0..<600 {
            let lon = Double.random(in: 0..<360, using: &rng)
            let lat = asin(Double.random(in: -1...1, using: &rng)) * 180 / .pi
            stars.append(ecl(lon, lat))
        }
        let el = SCNGeometryElement(indices: (0..<Int32(stars.count)).map { $0 }, primitiveType: .point)
        el.pointSize = 2; el.minimumPointScreenSpaceRadius = 0.5; el.maximumPointScreenSpaceRadius = 2.5
        let starGeo = SCNGeometry(sources: [SCNGeometrySource(vertices: stars)], elements: [el])
        starGeo.materials = [SceneLines.material(NSColorLike(white: 1, alpha: 0.7))]
        sky.addChildNode(SCNNode(geometry: starGeo))

        var lines: [SCNVector3] = []
        for c in CelestialCatalog.zodiacConstellations {
            let pts = c.stars.map { ecl($0.lon, $0.lat) }
            for (a, b) in c.lines { lines += [pts[a], pts[b]] }
        }
        let lineGeo = SCNGeometry(sources: [SCNGeometrySource(vertices: lines)],
                                  elements: [SCNGeometryElement(indices: (0..<Int32(lines.count)).map { $0 }, primitiveType: .line)])
        lineGeo.materials = [SceneLines.material(NSColorLike(white: 1, alpha: 0.18))]
        sky.addChildNode(SCNNode(geometry: lineGeo))
        sky.addChildNode(MilkyWay.makeNode(radius: r))

        sky.enumerateHierarchy { node, _ in
            node.renderingOrder = -100
            node.geometry?.materials.forEach { $0.readsFromDepthBuffer = false; $0.writesToDepthBuffer = false }
        }
        return sky
    }

    /// Re-centre the sky on the camera and scale it to sit just inside `farRadius`.
    static func follow(_ sky: SCNNode, camera: SCNVector3, farRadius: Float) {
        sky.position = camera
        let s = SCNFloat(farRadius / radius)
        sky.scale = SCNVector3(s, s, s)
    }
}

/// Text labels that follow SceneKit nodes, drawn in a SpriteKit overlay.
/// Call `layout(_:)` from the main thread (e.g. dispatched from `willRenderScene`).
final class LabelOverlay {
    private weak var view: SCNView?
    private let overlay = SKScene()
    private var labels: [String: SKLabelNode] = [:]

    init(view: SCNView) {
        self.view = view
        overlay.scaleMode = .resizeFill
        overlay.backgroundColor = .clear
        view.overlaySKScene = overlay
    }

    private func label(_ name: String) -> SKLabelNode {
        if let l = labels[name] { return l }
        let l = SKLabelNode(text: name)
        l.fontName = "Menlo-Regular"; l.fontSize = 10
        l.fontColor = SKColor.white.withAlphaComponent(0.75)
        l.horizontalAlignmentMode = .left; l.verticalAlignmentMode = .bottom
        overlay.addChild(l); labels[name] = l
        return l
    }

    func layout(_ anchors: [(name: String, node: SCNNode)]) {
        guard let view else { return }
        let names = Set(anchors.map(\.name))
        for (name, l) in labels where !names.contains(name) { l.isHidden = true }
        for a in anchors {
            let l = label(a.name)
            let p = view.projectPoint(a.node.presentation.worldPosition)
            guard p.z > 0, p.z < 1 else { l.isHidden = true; continue }
            #if os(iOS)
            let y = view.bounds.height - CGFloat(p.y)
            #else
            let y = CGFloat(p.y)
            #endif
            l.isHidden = false
            l.position = CGPoint(x: CGFloat(p.x) + 7, y: y + 4)
        }
    }
}

/// The translucent info card in the corner of the Missions and Sandbox scenes.
/// The header always shows; tapping the card shows or hides the details. On iPhone it
/// starts collapsed so it doesn't cover the action; elsewhere it starts expanded.
struct CollapsibleInfoCard<Header: View, Details: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let details: Details
    @State private var expanded: Bool?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var defaultExpanded: Bool { sizeClass != .compact }
    #else
    private var defaultExpanded: Bool { true }
    #endif

    var body: some View {
        let open = expanded ?? defaultExpanded
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) { header }
                Spacer(minLength: 8)
                Image(systemName: open ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if open { details }
        }
        .padding(open ? 12 : 9)
        .frame(maxWidth: open ? 300 : 240, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded = !open } }
    }
}
