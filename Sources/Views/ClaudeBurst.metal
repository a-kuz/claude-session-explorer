// Claude Burst — Metal port of @claude-ds/burst (WebGL2 raymarch).
// Two passes: a one-time bake of the star polygon SDF into an r16Float texture,
// then a per-frame raymarch of the engraved squircle plate (sphere-intersect first).
// The background is transparent (alpha 0) so the view composes over app surfaces;
// MSAA in the render pass gives smooth premultiplied edges.

#include <metal_stdlib>
using namespace metal;

constant float PI  = 3.14159265359;
constant float TAU = 6.28318530718;
constant float SDF_RES  = 1024.0; // bake target is SDF_RES × SDF_RES
constant float SDF_HALF = 1.2;    // world half-range covered by the SDF texture

struct BurstUniforms {
    float4 cream;   // inner-face color (rgb, engraving floor/walls)
    float4 terra;   // face color (rgb)
    float2 res;     // drawable size in pixels
    float2 cam;     // yaw, pitch
    float zoom;     // visible size (bounding sphere scales with it)
    float hf;       // squircle half-width
    float hz;       // plate half-thickness
    float n;        // squircle exponent (corner rounding)
    float bevel;    // edge bevel
    float cut;      // engraving depth
    float glow;     // inner-face glow
    float spec;     // specular amount
    float amb;      // ambient
    float fresnel;  // rim light flag (0/1)
    float irid;     // iridescence flag (0/1)
    float pulse;    // glow pulse flag (0/1)
    float nobox;    // bare star, no plate (0/1)
    float wave;     // time, drives the glow pulse
};

vertex float4 burstVertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle: (-1,-1) (3,-1) (-1,3).
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    return float4(p, 0.0, 1.0);
}

// ── bake pass: exact polygon SDF, evaluated once per texel ──

constant int NP = 112;
constant float2 POLY[NP] = {
    float2(0.672,0.0),float2(0.408,0.057),float2(0.844,0.164),float2(0.881,0.203),
    float2(0.891,0.239),float2(0.87,0.266),float2(0.809,0.295),float2(0.702,0.284),
    float2(0.297,0.185),float2(0.26,0.182),float2(0.286,0.216),float2(0.562,0.472),
    float2(0.653,0.568),float2(0.694,0.625),float2(0.681,0.657),float2(0.658,0.658),
    float2(0.556,0.596),float2(0.262,0.361),float2(0.474,0.73),float2(0.471,0.783),
    float2(0.46,0.797),float2(0.431,0.811),float2(0.396,0.811),float2(0.343,0.77),
    float2(0.308,0.726),float2(0.061,0.345),float2(0.048,0.389),float2(0.013,0.764),
    float2(-0.016,0.919),float2(-0.033,0.937),float2(-0.067,0.951),float2(-0.099,0.944),
    float2(-0.128,0.913),float2(-0.11,0.697),float2(-0.058,0.297),float2(-0.279,0.599),
    float2(-0.387,0.727),float2(-0.462,0.8),float2(-0.49,0.815),float2(-0.523,0.805),
    float2(-0.543,0.775),float2(-0.425,0.586),float2(-0.192,0.246),float2(-0.559,0.486),
    float2(-0.67,0.543),float2(-0.698,0.546),float2(-0.739,0.537),float2(-0.76,0.512),
    float2(-0.761,0.476),float2(-0.723,0.435),float2(-0.547,0.315),float2(-0.226,0.12),
    float2(-0.227,0.11),float2(-0.31,0.101),float2(-0.861,0.075),float2(-0.911,0.064),
    float2(-0.933,0.049),float2(-0.952,0.017),float2(-0.953,0.0),float2(-0.942,-0.017),
    float2(-0.703,-0.025),float2(-0.246,-0.017),float2(-0.707,-0.33),float2(-0.791,-0.403),
    float2(-0.804,-0.427),float2(-0.812,-0.469),float2(-0.805,-0.503),float2(-0.77,-0.539),
    float2(-0.723,-0.545),float2(-0.605,-0.473),float2(-0.236,-0.213),float2(-0.247,-0.247),
    float2(-0.441,-0.585),float2(-0.52,-0.743),float2(-0.526,-0.78),float2(-0.516,-0.826),
    float2(-0.483,-0.871),float2(-0.454,-0.89),float2(-0.375,-0.883),float2(-0.344,-0.85),
    float2(-0.061,-0.289),float2(-0.023,-0.187),float2(-0.014,-0.199),float2(0.037,-0.703),
    float2(0.056,-0.799),float2(0.089,-0.844),float2(0.121,-0.86),float2(0.15,-0.854),
    float2(0.189,-0.818),float2(0.196,-0.787),float2(0.184,-0.641),float2(0.113,-0.242),
    float2(0.124,-0.243),float2(0.148,-0.268),float2(0.361,-0.535),float2(0.475,-0.653),
    float2(0.513,-0.681),float2(0.537,-0.688),float2(0.591,-0.68),float2(0.638,-0.616),
    float2(0.643,-0.6),float2(0.625,-0.524),float2(0.381,-0.194),float2(0.317,-0.079),
    float2(0.602,-0.128),float2(0.781,-0.152),float2(0.853,-0.15),float2(0.882,-0.124),
    float2(0.881,-0.093),float2(0.869,-0.061),float2(0.793,-0.028),float2(0.728,-0.013)
};

static float sdPolyBase(float2 p) {
    float d = dot(p - POLY[0], p - POLY[0]);
    float s = 1.0;
    float2 vj = POLY[NP - 1];
    for (int i = 0; i < NP; i++) {
        float2 vi = POLY[i];
        float2 e = vj - vi, w = p - vi;
        float2 b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        d = min(d, dot(b, b));
        bool3 c = bool3(p.y >= vi.y, p.y < vj.y, e.x * w.y > e.y * w.x);
        if (all(c) || !any(c)) s = -s;
        vj = vi;
    }
    return s * sqrt(d);
}

fragment float4 burstBakeFragment(float4 pos [[position]]) {
    float2 uv = pos.xy / SDF_RES;
    float2 wp = (uv * 2.0 - 1.0) * SDF_HALF;
    return float4(sdPolyBase(wp), 0.0, 0.0, 1.0);
}

// ── main pass: raymarch ──

constant float ANG[12] = {
    0.2619, 0.7678, 1.0647, 1.6580, 2.1468, 2.5309,
    3.1416, 3.7003, 4.2236, 4.8692, 5.4455, 6.1435
};

static float angDist(float a, float b) { float d = abs(a - b); return min(d, TAU - d); }

// Per-ray length wave: cosine-power kernel over the 12 ray angles.
static float scaleAt(float ang, constant float* scales) {
    float num = 0.0, den = 0.0;
    for (int i = 0; i < 12; i++) {
        float dd = angDist(ang, ANG[i]);
        float w = pow(max(0.0, cos(min(dd * 1.6, PI * 0.5))), 6.0) + 0.0005;
        num += w * scales[i]; den += w;
    }
    return num / den;
}

// Star SDF via the baked texture: D(p) = D0(p/sc) * sc, sc = angular scale (the wave).
static float sdPoly(float2 p, constant float* scales, texture2d<float> sdf) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float sc = scaleAt(atan2(p.y, p.x), scales);
    float2 q = p / sc;
    float2 uv = q / (2.0 * SDF_HALF) + 0.5;
    return sdf.sample(smp, uv).r * sc;
}

static float sdSquircle(float2 p, float hf, float n) {
    p = abs(p) / hf;
    float k = pow(pow(p.x, n) + pow(p.y, n), 1.0 / n);
    return (k - 1.0) * hf;
}

static float sdIcon(float3 p, constant BurstUniforms& u) {
    float dxy = sdSquircle(p.xy, u.hf, u.n);
    float2 w = float2(dxy, abs(p.z) - u.hz);
    return min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - u.bevel;
}

static float mapInner(float3 pos, constant BurstUniforms& u,
                      constant float* scales, texture2d<float> sdf) {
    if (u.nobox > 0.5) {
        float ds = sdPoly(pos.xy, scales, sdf);
        float2 we = float2(ds, abs(pos.z) - u.hz * 0.4);
        return min(max(we.x, we.y), 0.0) + length(max(we, 0.0)) - u.bevel;
    }
    float box = sdIcon(pos, u);
    // Engraving: a cut of depth `cut` from the face plane z=hz (floor at hz-cut).
    float top = u.hz, bot = u.hz - u.cut;
    if (pos.z < bot - 0.005) return box; // early out below the cut floor
    float d2 = sdPoly(pos.xy, scales, sdf);
    float cz = (top + u.hz + 0.05) * 0.5, hzCut = (u.hz + 0.05 - bot) * 0.5;
    float2 w = float2(d2, abs(pos.z - cz) - hzCut);
    float prism = min(max(w.x, w.y), 0.0) + length(max(w, 0.0));
    return max(box, -prism);
}

// Object size: scale space by zoom, SDF scales as map(p/z)*z.
static float map(float3 pos, constant BurstUniforms& u,
                 constant float* scales, texture2d<float> sdf) {
    return mapInner(pos / u.zoom, u, scales, sdf) * u.zoom;
}

static float3 calcNormal(float3 p, constant BurstUniforms& u,
                         constant float* scales, texture2d<float> sdf) {
    const float2 k = float2(1.0, -1.0);
    const float e = 0.0016;
    return normalize(
        k.xyy * map(p + k.xyy * e, u, scales, sdf) +
        k.yyx * map(p + k.yyx * e, u, scales, sdf) +
        k.yxy * map(p + k.yxy * e, u, scales, sdf) +
        k.xxx * map(p + k.xxx * e, u, scales, sdf));
}

fragment float4 burstFragment(float4 fragPos [[position]],
                              constant BurstUniforms& u [[buffer(0)]],
                              constant float* scales [[buffer(1)]],
                              texture2d<float> sdf [[texture(0)]]) {
    // Flip y: Metal's fragment origin is top-left, the shader math assumes y-up.
    float2 uv = (float2(fragPos.x, u.res.y - fragPos.y) - 0.5 * u.res) / u.res.y;
    float yaw = u.cam.x, pitch = u.cam.y;
    float cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw);
    float R = 6.0;
    float3 ro = float3(R * cp * sy, R * sp, R * cp * cy);
    float3 fw = normalize(-ro);
    float3 rt = normalize(cross(fw, float3(0.0, 1.0, 0.0)));
    float3 up = cross(rt, fw);
    float3 rd = normalize(uv.x * rt + uv.y * up + 1.6 * fw);

    // Analytic bounding-sphere intersect; the sphere scales with zoom.
    float Rb = 2.6 * u.zoom;
    float t = 0.0; bool hit = false;
    float b = dot(ro, rd);
    float cc = dot(ro, ro) - Rb * Rb;
    float disc = b * b - cc;
    if (disc >= 0.0) {
        t = -b - sqrt(disc); if (t < 0.0) t = 0.0;
        for (int i = 0; i < 110; i++) {
            float3 pos = ro + rd * t;
            float d = map(pos, u, scales, sdf);
            if (d < 0.0006) { hit = true; break; }
            if (t > 8.0) break;
            t += d * 0.8;
        }
    }

    if (!hit) return float4(0.0); // transparent — composes over the app surface

    float3 pos = ro + rd * t;
    float3 n = calcNormal(pos, u, scales, sdf);
    float3 Lk = normalize(float3(0.45, 0.7, 0.7));
    float3 Lf = normalize(float3(-0.5, 0.2, 0.5));
    float difK = clamp(dot(n, Lk), 0.0, 1.0);
    float difF = clamp(dot(n, Lf), 0.0, 1.0);
    float spec = pow(clamp(dot(reflect(-Lk, n), -rd), 0.0, 1.0), 48.0);
    float pz = pos.z / u.zoom; // z in object coordinates (thresholds live there)
    // inset: 0 on the face (z=hz), 1 on the engraving floor (z=hz-cut)
    float inset = u.nobox > 0.5 ? 0.0 : smoothstep(u.hz - 0.005, u.hz - u.cut * 0.6, pz);
    float3 albedo = mix(u.terra.rgb, u.cream.rgb, inset);
    float ao = u.nobox > 0.5 ? 1.0 : mix(0.80, 1.0, smoothstep(u.hz - u.cut, u.hz - 0.005, pz));
    float sheen = pow(clamp(0.5 + 0.5 * n.y, 0.0, 1.0), 3.0);

    float fres = pow(clamp(1.0 - abs(dot(n, -rd)), 0.0, 1.0), 2.5);
    float3 irid = 0.5 + 0.5 * cos(TAU * (fres * 1.6 + float3(0.0, 0.33, 0.67)) + atan2(n.y, n.x));

    float3 c = albedo * u.amb;
    c += albedo * difK * 0.70;
    c += albedo * difF * 0.20;
    c *= ao;
    c += albedo * sheen * 0.10;
    c += spec * float3(1.0) * u.spec * (1.0 - inset);
    c += mix(float3(0.0), irid, u.irid * 0.18 * fres);
    c += u.fresnel * fres * float3(1.0, 0.95, 0.9) * 0.45;
    float pulse = mix(1.0, 0.55 + 0.65 * (0.5 + 0.5 * sin(TAU * u.wave)), u.pulse);
    c += u.cream.rgb * inset * u.glow * pulse;

    float3 col = pow(clamp(c, 0.0, 1.0), float3(0.4545));
    return float4(col, 1.0);
}
