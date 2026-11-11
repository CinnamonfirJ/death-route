shader_type canvas_item;
render_mode unshaded;

uniform vec4 outline_color : source_color = vec4(1.0);

void fragment() {
	COLOR = vec4(outline_color.rgb, COLOR.a);
}
