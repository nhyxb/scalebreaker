shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float health : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec3 border = vec3(0.04, 0.05, 0.06);
	vec3 empty = vec3(0.18, 0.19, 0.21);
	vec3 fill = mix(vec3(0.92, 0.24, 0.12), vec3(0.48, 0.83, 0.39), smoothstep(0.18, 0.65, health));
	bool inside = UV.x >= 0.025 && UV.x <= 0.975 && UV.y >= 0.18 && UV.y <= 0.82;
	ALBEDO = inside ? (UV.x < 0.025 + 0.95 * health ? fill : empty) : border;
}
