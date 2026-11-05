shader_type canvas_item;
render_mode blend_mix;

// 捕捉网橡皮擦式的碎片溶解效果：0 为完整，1 为被完全擦掉。
// 用 UV 网格噪声做颗粒状咬痕，避免整块碎片一次性消失的生硬感。
uniform float erosion : hint_range(0.0, 1.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec4 base = texture(TEXTURE, UV) * COLOR;
	if (erosion > 0.001) {
		// 两层不同密度的噪声：细颗粒决定缺口边缘，粗颗粒决定整片脱落。
		float grain = hash21(floor(UV * 26.0));
		float chunk = hash21(floor(UV * 7.0));
		float cut = erosion * 1.2 - 0.16 * grain - 0.12 * chunk;
		if (grain < cut) {
			discard;
		}
		// 被啃过的部分整体压暗，让缺口看起来是"缺口"而不是"变透明"。
		base.rgb *= 1.0 - 0.5 * erosion;
	}
	COLOR = base;
}
