#include <metal_stdlib>
using namespace metal;

// The chart's marks: triangles in pixels, each with its color and, for
// shapes the fragment shader rounds (bars' data ends, dots), where it is in
// its shape. Kept as `ChartVertex` in ChartView.swift (the same layout).
struct ChartVertex {
    float2 position;   // pixels, from the top left
    float4 color;      // not premultiplied
    float2 local;      // pixels from the shape's center
    float2 halfSize;   // the shape's half size (a dot: x is its radius)
    float radius;      // a bar's corner radius
    uint kind;         // 0 plain, 1 a bar rounded at its data end (local y < 0), 2 a dot
};

struct ChartUniforms {
    float2 viewport;   // pixels
};

struct ChartFragment {
    float4 position [[position]];
    float4 color;
    float2 local;
    float2 halfSize;
    float radius;
    uint kind [[flat]];
};

vertex ChartFragment chartVertex(const device ChartVertex *vertices [[buffer(0)]],
                                 constant ChartUniforms &uniforms [[buffer(1)]],
                                 uint id [[vertex_id]]) {
    ChartVertex in = vertices[id];
    float2 clip = in.position / uniforms.viewport * 2.0 - 1.0;
    ChartFragment out;
    out.position = float4(clip.x, -clip.y, 0, 1);
    out.color = in.color;
    out.local = in.local;
    out.halfSize = in.halfSize;
    out.radius = in.radius;
    out.kind = in.kind;
    return out;
}

/// The distance to a box of `halfSize` whose corners are rounded by `radius`.
static float roundedBoxDistance(float2 point, float2 halfSize, float radius) {
    float2 q = abs(point) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

fragment float4 chartFragment(ChartFragment in [[stage_in]]) {
    float coverage = 1.0;
    if (in.kind == 1) {
        // Rounded at the data end (above the middle), square at the baseline.
        float rounded = roundedBoxDistance(in.local, in.halfSize, in.radius);
        float square = max(abs(in.local.x) - in.halfSize.x, abs(in.local.y) - in.halfSize.y);
        float distance = in.local.y < 0 ? rounded : square;
        coverage = clamp(0.5 - distance, 0.0, 1.0);
    } else if (in.kind == 2) {
        coverage = clamp(0.5 - (length(in.local) - in.halfSize.x), 0.0, 1.0);
    }
    float alpha = in.color.a * coverage;
    return float4(in.color.rgb * alpha, alpha);
}
