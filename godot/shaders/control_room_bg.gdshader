shader_type canvas_item;
render_mode blend_mix, unshaded;

// Dark industrial backdrop for the control room. Everything is procedural
// so the project ships with no image assets and stays crisp at any export
// resolution: brushed-steel bays, a riveted seam every panel width, a warm
// glow that leans toward red as the core gets away from the operator, and
// a vignette to keep the eye on the instruments.

uniform vec3 base_color : source_color = vec3(0.058, 0.066, 0.082);
uniform vec3 panel_color : source_color = vec3(0.086, 0.098, 0.118);
uniform vec3 glow_color : source_color = vec3(0.95, 0.42, 0.16);
uniform float alarm : hint_range(0.0, 1.0) = 0.0;   // 0 calm .. 1 emergency
uniform float time_scale = 1.0;
uniform vec2 resolution = vec2(1440.0, 900.0);

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Cheap value noise -- enough to break up the flat steel without a texture.
float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
    vec2 uv = UV;
    vec2 px = uv * resolution;
    float t = TIME * time_scale;

    // Vertical bays, 180 px apart, with a darker seam between them.
    float bay = abs(fract(px.x / 180.0) - 0.5) * 2.0;
    float seam = smoothstep(0.86, 1.0, bay);

    // Brushed-metal streaks: strongly anisotropic noise.
    float brush = noise(vec2(px.x * 0.9, px.y * 0.045)) * 0.055;
    float grain = noise(px * 1.7) * 0.022;

    vec3 col = mix(base_color, panel_color, 0.35 + brush * 3.0);
    col -= seam * 0.030;
    col += grain;

    // Rivet rows along each seam.
    vec2 rivet_cell = vec2(180.0, 96.0);
    vec2 rp = mod(px + vec2(90.0, 48.0), rivet_cell) - rivet_cell * 0.5;
    float rivet = 1.0 - smoothstep(1.6, 3.2, length(rp));
    float near_seam = smoothstep(0.90, 1.0, bay);
    col += rivet * near_seam * 0.05;

    // Horizontal scan line, very faint -- CRT instrumentation.
    col *= 1.0 - 0.020 * step(0.5, fract(px.y * 0.5));

    // Warm glow from the core, breathing faster the worse things get.
    float pulse = 0.5 + 0.5 * sin(t * mix(1.1, 6.5, alarm));
    float dist = distance(uv, vec2(0.5, 0.44));
    float halo = exp(-dist * dist * 9.0);
    col += glow_color * halo * (0.030 + 0.115 * alarm * pulse);

    // Vignette.
    float v = distance(uv, vec2(0.5)) * 1.28;
    col *= 1.0 - clamp(v * v * 0.85, 0.0, 0.72);

    COLOR = vec4(col, 1.0);
}
