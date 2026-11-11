shader_type canvas_item;

uniform sampler2D decals : source_color, filter_nearest, repeat_disable;
uniform bool road_surface = false;
varying vec2 world_position;

float hash_cell(vec2 cell) {
	vec3 p = fract(vec3(cell.xyx) * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float dirt_noise(vec2 position) {
	vec2 cell = floor(position);
	vec2 weight = smoothstep(vec2(0.0), vec2(1.0), fract(position));
	float top = mix(hash_cell(cell), hash_cell(cell + vec2(1.0, 0.0)), weight.x);
	float bottom = mix(hash_cell(cell + vec2(0.0, 1.0)), hash_cell(cell + 1.0), weight.x);
	return mix(top, bottom, weight.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 pixel = floor(world_position);
	float patch = dirt_noise(pixel / 96.0) * 0.72 + dirt_noise(pixel / 26.0) * 0.28;
	float grit = hash_cell(floor(pixel / 2.0));
	float tint = floor(patch * 9.0 + grit * 0.8) / 9.0 - 0.5;
	float patch_strength = road_surface ? 0.18 : 0.46;
	vec3 dirt = COLOR.rgb * (1.0 + tint * patch_strength + (grit - 0.5) * 0.05);

	vec2 cell = floor(pixel / 68.0);
	float variant = floor(hash_cell(cell + vec2(47.0, 12.0)) * 12.0);
	if (variant < 8.0 && (!road_surface || variant < 2.0 || variant >= 6.0)) {
		vec2 local = fract(pixel / 68.0);
		if (hash_cell(cell + 61.0) < 0.5) {
			local.x = 1.0 - local.x;
		}
		if (hash_cell(cell - 41.0) < 0.5) {
			local = local.yx;
		}
		vec2 slot = vec2(mod(variant, 4.0), floor(variant / 4.0));
		vec2 texel = floor(local * 63.0) + 0.5;
		vec4 decal = texture(decals, (slot * 64.0 + texel) / vec2(256.0, 128.0));
		dirt = mix(dirt, decal.rgb, decal.a * (road_surface ? 0.7 : 1.0));
	}
	COLOR.rgb = dirt;
}
