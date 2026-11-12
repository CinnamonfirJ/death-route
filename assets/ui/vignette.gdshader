shader_type canvas_item;
render_mode unshaded;
uniform float intensity : hint_range(0.0, 1.0) = 0.25;

void fragment() {
	vec2 edge = UV * 2.0 - 1.0;
	float shade = smoothstep(0.50, 1.38, length(edge));
	COLOR = vec4(0.04, 0.045, 0.075, shade * intensity);
}
