// Single-pass political map. One quad, one draw call for the whole world.
// Province borders are derived per-pixel from the ID texture, so there is no
// border geometry to build or update. Per-province state (owner colour,
// selection, hover) lives in a tiny lookup texture updated on change only.
shader_type canvas_item;

uniform sampler2D terrain_tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D id_tex : filter_nearest, repeat_disable;
// Row 2: occupier colour (a = province is occupied). Row 0: owner colour (a = owned). Row 1: r = owner index+1 /255, g = selected
// province, b = hovered province, a = belongs to selected country.
uniform sampler2D lookup_tex : filter_nearest, repeat_disable;
uniform vec2 map_size = vec2(2048.0, 1024.0);
uniform float zoom = 1.0;
uniform int map_mode = 0; // 0 political, 1 terrain, 2 provinces
uniform bool country_selected = false;
uniform bool whole_country = false;
uniform bool has_occupation = false; // true only while some province is occupied (skips the extra fetch otherwise)
uniform float detail = 1.0; // 0 disables ocean animation / vignette (low quality)

int pid(vec2 uv) {
	vec3 c = texture(id_tex, uv).rgb;
	return int(c.r * 255.0 + 0.5) + int(c.g * 255.0 + 0.5) * 256;
}

vec4 lk(int id, int row) {
	return texelFetch(lookup_tex, ivec2(id, row), 0);
}

// True when neighbour n is land owned by someone other than `me` (sea and same province ignored).
bool foreign(int n, int id, float me) {
	return n != id && n != 0 && lk(n, 1).r != me;
}

vec3 hash_color(int id) {
	float h = fract(sin(float(id) * 12.9898) * 43758.5453);
	float s = fract(sin(float(id) * 78.233) * 12345.678);
	return mix(vec3(0.35, 0.45, 0.30), vec3(0.85, 0.75, 0.55), vec3(h, s, fract(h + s)));
}

void fragment() {
	vec2 uv = UV;
	vec2 px = 1.0 / map_size;
	vec3 terrain = texture(terrain_tex, uv).rgb;
	int id = pid(uv);

	// Border sample distances in texels: roughly constant on screen.
	float inv_z = 1.0 / zoom;
	float w1 = max(0.6, 0.9 * inv_z);
	vec2 a = px * w1;
	int n0 = pid(uv + vec2(a.x, 0.0));
	int n1 = pid(uv - vec2(a.x, 0.0));
	int n2 = pid(uv + vec2(0.0, a.y));
	int n3 = pid(uv - vec2(0.0, a.y));
	bool p_edge = n0 != id || n1 != id || n2 != id || n3 != id;

	vec3 col;
	if (id == 0) {
		col = terrain;
		if (p_edge) {
			col *= 0.58 * mix(vec3(1.0), vec3(0.62, 0.72, 0.70), 0.22);
		}
	} else {
		vec4 own = lk(id, 0);
		vec4 meta = lk(id, 1);
		float luma = dot(terrain, vec3(0.299, 0.587, 0.114));
		if (map_mode == 0 || map_mode >= 3) {
			vec3 pol = own.rgb * (0.38 + 1.05 * luma);
			col = mix(terrain, pol, own.a * 0.78);
		} else if (map_mode == 2) {
			col = mix(terrain, hash_color(id) * (0.45 + 0.9 * luma), 0.7);
		} else {
			col = terrain;
		}
		if (country_selected) {
			col = meta.a > 0.5 ? col * (whole_country ? 1.14 : 1.08) : mix(col, vec3(luma * 0.9), 0.35) * 0.85;
		}
		if (meta.b > 0.5) col = col * 1.12 + 0.04;
		if (has_occupation && map_mode != 1) {
			vec4 occ = lk(id, 2);
			if (occ.a > 0.5) {
				// Occupied: diagonal stripes in the occupier's colour (screen-space, constant width).
				float stripe = step(0.5, fract((FRAGCOORD.x + FRAGCOORD.y) * 0.1111111));
				col = mix(col, occ.rgb * (0.55 + 0.9 * luma), stripe * 0.85);
			}
		}

		// Country borders: dark outer line + coast highlight (only evaluated on province edges).
		if (p_edge) {
			float me = meta.r;
			bool coast = n0 == 0 || n1 == 0 || n2 == 0 || n3 == 0;
			bool c_outer = foreign(n0, id, me) || foreign(n1, id, me) || foreign(n2, id, me) || foreign(n3, id, me);
			float fade = map_mode == 2 ? 1.0 : smoothstep(0.55, 1.1, zoom);
			col = mix(col, col * 0.62, 0.8 * fade);
			if (c_outer) {
				if (whole_country && meta.a > 0.5) {
					col = vec3(0.98, 0.86, 0.45);
				} else {
					col = mix(col, own.rgb * 0.45, 0.35);
					col = mix(col, vec3(0.10, 0.08, 0.07), 0.85);
				}
			}
			if (coast) col = (whole_country && meta.a > 0.5) ? mix(col, vec3(0.98, 0.86, 0.45), 0.75) : mix(col, vec3(0.16, 0.20, 0.22), 0.7);
		}
		if (meta.g > 0.5) {
			col *= 1.15;
			if (p_edge) col = vec3(0.98, 0.86, 0.45);
		}
	}

	if (detail > 0.5) {
		float v = length(SCREEN_UV - 0.5);
		col *= mix(1.0, 0.78, smoothstep(0.45, 0.85, v));
	}
	COLOR = vec4(col, 1.0);
}
