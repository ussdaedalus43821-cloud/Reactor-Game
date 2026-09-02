shader_type canvas_item;
render_mode blend_mix, unshaded;

// GPU core map. The whole 10x10 fuel-channel grid is rasterised in one
// draw call from five scalars, so the bridge never has to ship 100 cell
// temperatures per frame -- reactor_server.py sends a peaking tilt and an
// amplitude and the GPU reconstructs the distribution.
//
// The cell temperature law here is the same one the CPU uses:
//     T(i,j) = T_ref + (T_fuel - T_ref) * (1 - amp + amp * cos(r * PI/2))
// with r the normalised radius from the (tilted) flux centroid.

uniform float fuel_temp_c = 270.0;
uniform float t_ref_c = 300.0;         // TF_REF_C
uniform vec2 tilt = vec2(0.0, 0.0);    // flux centroid offset, -1..1
uniform float amp : hint_range(0.0, 1.0) = 0.65;
uniform float grid_n = 10.0;
uniform float cell_gap : hint_range(0.0, 0.4) = 0.10;
uniform float meltdown : hint_range(0.0, 1.0) = 0.0;
uniform float alarm : hint_range(0.0, 1.0) = 0.0;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.35;

const vec3 C_COLD = vec3(0.059, 0.118, 0.549);   //  300 C  deep blue
const vec3 C_WARM = vec3(1.000, 0.843, 0.157);   //  800 C  amber
const vec3 C_HOT  = vec3(1.000, 1.000, 1.000);   // 1800 C  white
const vec3 C_MELT = vec3(1.000, 0.098, 0.098);   // 2800 C  red

const float T_COLD = 300.0;
const float T_WARM = 800.0;
const float T_HOT  = 1800.0;
const float T_MELT = 2800.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(41.7, 289.3))) * 24634.6345);
}

vec3 temp_to_color(float t) {
    if (t <= T_COLD) {
        // Below the reference the channel is simply dark and cold.
        float f = clamp(t / T_COLD, 0.0, 1.0);
        return C_COLD * (0.25 + 0.75 * f);
    }
    if (t < T_WARM) {
        return mix(C_COLD, C_WARM, (t - T_COLD) / (T_WARM - T_COLD));
    }
    if (t < T_HOT) {
        return mix(C_WARM, C_HOT, (t - T_WARM) / (T_HOT - T_WARM));
    }
    return mix(C_HOT, C_MELT, clamp((t - T_HOT) / (T_MELT - T_HOT), 0.0, 1.0));
}

void fragment() {
    vec2 uv = UV;

    // Which fuel channel is this fragment in, and where inside it.
    vec2 cell = floor(uv * grid_n);
    vec2 f = fract(uv * grid_n);

    // Cell centre in -1..1 core coordinates, offset by the flux tilt.
    vec2 centre = ((cell + 0.5) / grid_n) * 2.0 - 1.0;
    vec2 rel = centre - tilt;
    float r = clamp(length(rel) / 1.41421356, 0.0, 1.0);

    float weight = cos(r * 1.5707963);
    float t_cell = t_ref_c + (fuel_temp_c - t_ref_c) * ((1.0 - amp) + amp * weight);

    // Per-channel jitter: real cores are not perfectly symmetric.
    t_cell += (hash(cell) - 0.5) * 26.0 * clamp((fuel_temp_c - t_ref_c) / 600.0, 0.0, 1.0);

    // A core in disassembly boils and flickers.
    if (meltdown > 0.0) {
        float boil = sin(TIME * 11.0 + hash(cell) * 30.0) * 0.5 + 0.5;
        t_cell += meltdown * boil * 420.0;
    }

    vec3 col = temp_to_color(t_cell);

    // Hot channels bloom.
    float heat = clamp((t_cell - T_WARM) / (T_MELT - T_WARM), 0.0, 1.0);
    col += col * heat * 0.65;

    // Cell borders: a dark gap plus a lit top-left bevel.
    vec2 edge = min(f, 1.0 - f);
    float gap = smoothstep(0.0, cell_gap, min(edge.x, edge.y));
    float bevel = smoothstep(cell_gap, cell_gap * 2.4, min(f.x, f.y));
    col *= gap;
    col += (1.0 - bevel) * gap * 0.06;

    // CRT scan lines over the whole map.
    float scan = 1.0 - scanline_strength * 0.14 * step(0.5, fract(uv.y * grid_n * 6.0));
    col *= scan;

    // Alarm wash.
    col = mix(col, col * vec3(1.25, 0.72, 0.66), alarm * 0.35);

    COLOR = vec4(col, 1.0);
}
