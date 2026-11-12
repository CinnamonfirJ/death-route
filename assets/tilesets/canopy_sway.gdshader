shader_type canvas_item;
render_mode unshaded;

void vertex() {
	vec2 anchor = MODEL_MATRIX[3].xy;
	float seed = fract(sin(dot(anchor, vec2(0.071, 0.037))) * 43758.5453);
	float phase = seed * 6.283185;
	float breeze = sin(TIME * mix(0.65, 1.27, seed) + phase);
	breeze += 0.32 * sin(TIME * 1.68 + phase * 2.0);
	VERTEX.x += max(-VERTEX.y, 0.0) * breeze * mix(0.034, 0.067, seed);
}
