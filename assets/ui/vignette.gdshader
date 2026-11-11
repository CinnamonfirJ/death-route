shader_type canvas_item;
render_mode unshaded;

void fragment() {
	vec2 edge = UV * 2.0 - 1.0;
	float shade = smoothstep(0.50, 1.38, length(edge));
	COLOR = vec4(0.04, 0.025, 0.02, shade * 0.62);
}
