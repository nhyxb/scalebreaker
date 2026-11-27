shader_type spatial;
render_mode unshaded, blend_mul, cull_front, depth_test_disabled, depth_draw_never, fog_disabled;

uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D sole_mask : filter_linear_mipmap, repeat_disable;
uniform float opacity = 1.0;
uniform float side = 1.0;

// Project from the visible scene depth. The box bounds the pass without putting a
// second coplanar surface on the ground, including where pavement meets asphalt.
void fragment() {
	float depth = texture(scene_depth, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 point = world.xyz / world.w;
	vec3 area_normal = cross(dFdx(point), dFdy(point));
	if (depth <= 0.0 || abs(area_normal.y) < length(area_normal) * 0.72) {
		discard;
	}
	vec3 offset = point - MODEL_MATRIX[3].xyz;
	vec3 x_axis = MODEL_MATRIX[0].xyz;
	vec3 z_axis = MODEL_MATRIX[2].xyz;
	vec2 sole = vec2(dot(offset, x_axis) / dot(x_axis, x_axis),
			dot(offset, z_axis) / dot(z_axis, z_axis));
	float projection_height = length(MODEL_MATRIX[1].xyz);
	if (abs(offset.y) >= projection_height || max(abs(sole.x), abs(sole.y)) >= 1.0) {
		discard;
	}
	float silhouette = texture(sole_mask, sole * 0.5 + 0.5).r;
	vec2 tread = vec2(sole.x * side, sole.y);
	float blocks = smoothstep(0.1, 0.25, abs(fract(tread.y * 3.5 + abs(tread.x) * 0.24) - 0.5));
	float seam = smoothstep(0.05, 0.13, abs(tread.x + 0.14));
	float midsole = smoothstep(0.03, 0.16, abs(tread.y - 0.24));
	float contrast = (0.43 + 0.57 * blocks) * mix(0.50, 1.0, seam * midsole);
	float reach = max(130.0, max(length(x_axis), length(z_axis)) * 125.0);
	float distance_fade = 1.0 - smoothstep(reach, reach * 1.85, distance(point, CAMERA_POSITION_WORLD));
	float amount = silhouette * contrast * opacity * distance_fade;
	ALBEDO = mix(vec3(1.0), vec3(0.36, 0.33, 0.29), amount);
	ALPHA = 1.0;
}
