#include <metal_stdlib>
using namespace metal;

// The road-trip export's frame renderer (`RoadTripMetalCanvas`). Everything is
// in canvas pixels, y down, colours premultiplied — as the Core Graphics
// frame drew them.

// MARK: - Quads

/// One quad: the unit square mapped onto the canvas by `origin + u·axisX +
/// v·axisY` (any rotation), filled with a texture or a colour, cut by a mask.
struct Quad {
    float2 origin;
    float2 axisX;
    float2 axisY;
    /// The texture's part shown: origin and size, in 0…1.
    float4 uvRect;
    /// Premultiplied; multiplies the texture when there is one.
    float4 color;
    /// The quad's size in pixels (its masks are in pixels).
    float2 size;
    /// Rounded corners' radius (pixels); a circle when `flags & kEllipse`.
    float radius;
    /// > 0: a soft edge this wide (a shadow); else a one-pixel antialiased one.
    float blur;
    /// Pixels the quad is grown by, so its antialiased edge is not cut.
    float margin;
    uint flags;
};

constant uint kTextured = 1;
constant uint kEllipse = 2;
constant uint kVignette = 4;
/// The texture holds a line's coverage per style (red, green, blue: glow,
/// casing, line): the styles' colours (`strokeColors`) laid one over the
/// other, the whole faded by `color.a` — Core Graphics' strokes in a
/// transparency layer.
constant uint kStrokes = 16;

struct QuadOut {
    float4 position [[position]];
    float2 local;
    float2 uv;
    uint index [[flat]];
};

vertex QuadOut quadVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Quad *quads [[buffer(0)]],
    constant float2 &canvas [[buffer(1)]]
) {
    Quad q = quads[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 grow = q.margin / max(q.size, float2(1e-3));
    float2 l = mix(-grow, 1 + grow, corner);
    float2 p = q.origin + l.x * q.axisX + l.y * q.axisY;
    QuadOut out;
    out.position = float4(p.x / canvas.x * 2 - 1, 1 - p.y / canvas.y * 2, 0, 1);
    out.local = l * q.size;
    out.uv = q.uvRect.xy + l * q.uvRect.zw;
    out.index = iid;
    return out;
}

fragment float4 quadFragment(
    QuadOut in [[stage_in]],
    constant Quad *quads [[buffer(0)]],
    constant float2 &canvas [[buffer(1)]],
    constant float4 *strokeColors [[buffer(2)]],
    texture2d<float> image [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    Quad q = quads[in.index];
    if (q.flags & kStrokes) {
        float4 coverage = image.sample(smp, in.uv);
        float4 color = float4(0);
        for (int i = 0; i < 3; i++) {
            float4 style = strokeColors[i] * coverage[i];
            color = style + color * (1 - style.a);
        }
        return color * q.color.a;
    }
    if (q.flags & kVignette) {
        // Clear to 55 % of the radius, then darkening to 45 % black.
        float radius = max(canvas.x, canvas.y) * 0.72;
        float t = clamp((length(in.position.xy - canvas * 0.5) / radius - 0.55) / 0.45, 0.0, 1.0);
        return float4(0, 0, 0, 0.45 * t);
    }
    float2 p = in.local - q.size * 0.5;
    float d;
    if (q.flags & kEllipse) {
        d = length(p) - q.size.x * 0.5;
    } else {
        float r = min(q.radius, min(q.size.x, q.size.y) * 0.5);
        float2 k = abs(p) - (q.size * 0.5 - r);
        d = length(max(k, 0.0)) + min(max(k.x, k.y), 0.0) - r;
    }
    float coverage = q.blur > 0 ? 1 - smoothstep(-q.blur, q.blur, d) : clamp(0.5 - d, 0.0, 1.0);
    float4 color = q.color;
    if (q.flags & kTextured) {
        color *= image.sample(smp, in.uv);
    }
    return color * coverage;
}

// MARK: - Strokes

/// One segment of a stroked line: capsules around a → b, one per style
/// (`halfWidths`: glow, casing, line; 0 for none), their coverages in red,
/// green and blue. Drawn with max blending, so the segments of a line make
/// one shape (round caps and joins, no darker overlap) — as a Core Graphics
/// stroke.
struct Segment {
    float2 a;
    float2 b;
    float4 halfWidths;
};

struct SegmentOut {
    float4 position [[position]];
    float2 point;
    uint index [[flat]];
};

vertex SegmentOut segmentVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Segment *segments [[buffer(0)]],
    constant float2 &canvas [[buffer(1)]]
) {
    Segment s = segments[iid];
    float2 along = s.b - s.a;
    float len = length(along);
    float2 dir = len > 1e-4 ? along / len : float2(1, 0);
    float2 normal = float2(-dir.y, dir.x);
    float reach = max(max(s.halfWidths.x, s.halfWidths.y), s.halfWidths.z) + 1;
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = s.a - dir * reach + dir * (len + 2 * reach) * corner.x + normal * reach * (corner.y * 2 - 1);
    SegmentOut out;
    out.position = float4(p.x / canvas.x * 2 - 1, 1 - p.y / canvas.y * 2, 0, 1);
    out.point = p;
    out.index = iid;
    return out;
}

fragment float4 segmentFragment(
    SegmentOut in [[stage_in]],
    constant Segment *segments [[buffer(0)]]
) {
    Segment s = segments[in.index];
    float2 pa = in.point - s.a;
    float2 ba = s.b - s.a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    float d = length(pa - ba * h);
    float4 coverage = clamp(s.halfWidths - d + 0.5, 0.0, 1.0);
    return select(coverage, float4(0), s.halfWidths <= 0);
}
