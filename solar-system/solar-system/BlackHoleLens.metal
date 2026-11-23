// Ray-traced black holes for the Sandbox: a full-screen SCNTechnique pass.
//
// For each pixel near a black hole, the camera ray is followed through Schwarzschild
// spacetime with the photon orbit equation u'' + u = 3/2 u² (u = r_s / r, φ the angle
// in the ray's orbital plane). Captured rays are black: that gives the shadow (radius
// √27/2 r_s) and the photon ring. Escaping rays pick up whatever lies in their new
// direction: the rendered scene if it's on screen and behind the hole, otherwise the
// sky texture. Far from the hole the analytic weak-field deflection 2 r_s / b is used.
// An optional thin accretion disk is added where a ray crosses the disk plane.
// SchwarzschildRay (SandboxLens.swift) is the same integration in Swift, for tests.

#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

// Bound by SceneKit from the technique's vec4 symbols: field names match the pass's inputs.
// Everything is in camera space (looking down −z), computed on the CPU each frame:
// SceneKit doesn't provide its frame matrices to technique quad passes.
struct LensUniforms {
    float4 params;      // x: hole count, y: disk on (0/1), z: disk outer radius (r_s), w: disk brightness
    float4 camera;      // x: tan(½ fov) horizontal, y: vertical, z: zNear, w: zFar
    float4 view;        // x: viewport height (px), y: depth buffer is reverse-Z (0/1)
    float4 diskNormal;  // camera space
    float4 rot0, rot1, rot2;  // camera-to-world rotation, columns
    float4 h0, h1, h2, h3;    // camera-space position xyz, w = r_s (scene units)
};

static float4 holeAt(constant LensUniforms& lens, int i) {
    return i == 0 ? lens.h0 : i == 1 ? lens.h1 : i == 2 ? lens.h2 : lens.h3;
}

struct QuadIn { float4 position [[attribute(SCNVertexSemanticPosition)]]; };
struct QuadOut { float4 position [[position]]; float2 uv; };

vertex QuadOut bh_lens_vertex(QuadIn in [[stage_in]]) {
    QuadOut o;
    o.position = in.position;
    o.uv = float2(in.position.x * 0.5 + 0.5, 0.5 - in.position.y * 0.5);
    return o;
}

/// Approximate colour of a blackbody at `t` kelvin (normalised so white ≈ 6500 K).
static float3 blackbody(float t) {
    t = clamp(t, 1000.0, 40000.0) / 100.0;   // Tanner Helland's fit
    float r = t <= 66 ? 1.0 : clamp(1.293 * pow(t - 60, -0.1332), 0.0, 1.0);
    float g = t <= 66 ? clamp(0.390 * log(t) - 0.632, 0.0, 1.0) : clamp(1.130 * pow(t - 60, -0.0755), 0.0, 1.0);
    float b = t >= 66 ? 1.0 : (t <= 19 ? 0.0 : clamp(0.543 * log(t - 10) - 1.196, 0.0, 1.0));
    return float3(r, g, b);
}

/// Direction of travel at angle φ in the orbital plane (basis e1, e2), from u and du/dφ.
static float3 travelDirection(float phi, float u, float du, float3 e1, float3 e2) {
    float3 er = cos(phi) * e1 + sin(phi) * e2;
    float3 ep = -sin(phi) * e1 + cos(phi) * e2;
    return normalize(-du / u * er + ep);
}

fragment half4 bh_lens_fragment(QuadOut in [[stage_in]],
                                texture2d<float, access::sample> colorSampler [[texture(0)]],
                                depth2d<float, access::sample> depthSampler [[texture(1)]],
                                texture2d<float, access::sample> skySampler [[texture(2)]],
                                constant LensUniforms& lens [[buffer(0)]]) {
    constexpr sampler screenS(filter::linear, address::clamp_to_edge);
    constexpr sampler skyS(filter::linear, address::repeat);
    float4 original = colorSampler.sample(screenS, in.uv);
    int count = int(lens.params.x);
    if (count == 0) { return half4(original); }

    float2 tanHalf = lens.camera.xy;
    float2 ndc = float2(in.uv.x * 2 - 1, 1 - in.uv.y * 2);
    float3 d = normalize(float3(ndc * tanHalf, -1));
    float focalPx = lens.view.x * 0.5 / tanHalf.y;
    float zn = lens.camera.z, zf = lens.camera.w;
    bool reverseZ = lens.view.y > 0.5;

    // The hole with the strongest effect on this ray (smallest impact parameter in r_s).
    int best = -1; float bestB = 1e30;
    for (int i = 0; i < count && i < 4; i++) {
        float3 h = holeAt(lens, i).xyz;
        float rs = holeAt(lens, i).w;
        float ahead = dot(h, d);
        float b = length(cross(h, d)) / rs;
        if (ahead < 0 && length(h) > 50 * rs) { continue; }   // behind us and far: no bending ahead
        if (b < bestB) { bestB = b; best = i; }
    }
    if (best < 0) { return half4(original); }

    float rs = holeAt(lens, best).w;
    float3 hole = holeAt(lens, best).xyz;
    // Depth-buffer value at the hole's distance; larger values are farther unless reverse-Z.
    float dist = max(-hole.z, zn);
    float zHole = reverseZ ? zn * (zf - dist) / (dist * (zf - zn)) : zf * (dist - zn) / (dist * (zf - zn));
    float farSign = reverseZ ? -1.0 : 1.0;
    bool diskOn = lens.params.y > 0.5;
    float diskOuter = lens.params.z;

    // Things in front of the hole aren't lensed.
    float ownDepth = depthSampler.sample(screenS, in.uv);
    if ((ownDepth - zHole) * farSign < 0) { return half4(original); }

    float3 outDir = d;
    float3 col = float3(0);
    float trans = 1;
    bool captured = false;

    float r0 = length(hole) / rs;
    if (bestB > 25 && r0 > 2 * bestB && !(diskOn && bestB < diskOuter * 1.2)) {
        // Weak field: rotate the ray toward the hole. From far away the total bending is 2/b;
        // for a camera at finite distance only the part still ahead counts: (1 + cos θ)/b,
        // θ the angle between the ray and the direction to the hole.
        float cosT = dot(d, normalize(hole));
        float alpha = (1 + cosT) / bestB + 0.368 * (1 + cosT) / (bestB * bestB);
        if (alpha * focalPx < 0.3) { return half4(original); }
        float3 toward = normalize(hole - dot(hole, d) * d);
        outDir = normalize(cos(alpha) * d + sin(alpha) * toward);
    } else {
        // Strong field: integrate the photon orbit in its plane (units of r_s).
        float3 p0 = -hole / rs;
        float3 e1 = p0 / r0;
        float3 t = d - dot(d, e1) * e1;
        float tl = length(t);
        if (tl < 1e-5) {
            captured = dot(d, e1) < 0;
        } else {
            float3 e2 = t / tl;
            float3 nd = normalize(lens.diskNormal.xyz);
            float u = 1 / r0;
            float du = -dot(d, e1) / tl * u;
            // Steps are in angle, so following the ray far out costs nothing extra.
            float uEscape = min(u, 0.001);
            float phi = 0;
            float prevSide = dot(e1 / u, nd);
            float prevR = 1 / u;
            for (int k = 0; k < 2400; k++) {
                // Smaller steps near the hole, where the path bends fastest.
                float h = clamp(0.02 / (1 + 6 * u), 0.003, 0.016);   // coarser steps show as rings
                float k1u = du,               k1v = -u + 1.5 * u * u;
                float u2 = u + 0.5 * h * k1u, v2 = du + 0.5 * h * k1v;
                float k2u = v2,               k2v = -u2 + 1.5 * u2 * u2;
                float u3 = u + 0.5 * h * k2u, v3 = du + 0.5 * h * k2v;
                float k3u = v3,               k3v = -u3 + 1.5 * u3 * u3;
                float u4 = u + h * k3u,       v4 = du + h * k3v;
                float k4u = v4,               k4v = -u4 + 1.5 * u4 * u4;
                u  += h / 6 * (k1u + 2 * k2u + 2 * k3u + k4u);
                du += h / 6 * (k1v + 2 * k2v + 2 * k3v + k4v);
                phi += h;
                if (u >= 1) { captured = true; break; }
                if (u <= 0) { u = 1e-6; }
                float r = 1 / u;
                if (diskOn) {
                    float3 pos = r * (cos(phi) * e1 + sin(phi) * e2);
                    float side = dot(pos, nd);
                    if (side * prevSide < 0) {
                        float f = prevSide / (prevSide - side);
                        float rc = mix(prevR, r, f);
                        if (rc > 3 && rc < diskOuter) {
                            // Thin disk: T ∝ r^-¾ (1 − √(3/r))^¼, shifted by gravity and the gas's orbital motion.
                            float prof = pow(rc, -0.75) * pow(1 - sqrt(3 / rc), 0.25) / 0.214;
                            float3 travel = travelDirection(phi, u, du, e1, e2);
                            float3 gasDir = normalize(cross(nd, pos));
                            float beta = sqrt(1 / (2 * (rc - 1)));
                            float gamma = 1 / sqrt(1 - beta * beta);
                            float g = sqrt(1 - 1 / rc) / (gamma * (1 - beta * dot(gasDir, -travel)));
                            float temp = 4800 * prof * g;
                            float bright = lens.params.w * pow(g, 4) * pow(prof, 4);
                            float edge = smoothstep(diskOuter, diskOuter * 0.7, rc);
                            float a = 0.92 * edge;
                            col += trans * a * blackbody(temp) * bright;
                            trans *= 1 - a;
                            if (trans < 0.02) { break; }
                        }
                    }
                    prevSide = side; prevR = r;
                }
                if (du < 0 && u < uEscape) {
                    // Nearly straight from here: extrapolate to where u reaches 0, the
                    // direction it heads off to infinity.
                    float phiInf = phi + u / -du;
                    outDir = cos(phiInf) * e1 + sin(phiInf) * e2;
                    break;
                }
            }
        }
    }

    float3 bg = float3(0);
    if (!captured && trans >= 0.02) {
        // What lies in the bent direction: the rendered scene if it's on screen and behind the hole, else the sky.
        bool fromScreen = false;
        if (outDir.z < -1e-4) {
            float2 n2 = (outDir.xy / -outDir.z) / tanHalf;
            float2 uv2 = float2(n2.x * 0.5 + 0.5, 0.5 - n2.y * 0.5);
            if (all(uv2 > 0.002) && all(uv2 < 0.998)) {
                float dz = depthSampler.sample(screenS, uv2);
                if ((dz - zHole) * farSign >= 0) {
                    bg = colorSampler.sample(screenS, uv2).rgb;
                    fromScreen = true;
                }
            }
        }
        if (!fromScreen) {
            float3 w = normalize(outDir.x * lens.rot0.xyz + outDir.y * lens.rot1.xyz + outDir.z * lens.rot2.xyz);
            float2 suv = float2(atan2(w.z, w.x) / (2 * M_PI_F) + 0.5, 0.5 - asin(clamp(w.y, -1.0, 1.0)) / M_PI_F);
            bg = skySampler.sample(skyS, suv).rgb;
        }
    }
    col += trans * bg;
    return half4(half3(col), 1);
}
