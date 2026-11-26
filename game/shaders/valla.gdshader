shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, shadows_disabled;
// Malla metalica de la valla perimetral: rombos de `paso` m dibujados en coordenadas de mundo (sin UVs); el alfa solo
// es alto en los alambres. Con la distancia el alfa tiende a su media (sin moire).

uniform vec3 color : source_color = vec3(0.55, 0.58, 0.6);
uniform float paso = 0.12;
uniform float hilo = 0.012;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 nv = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(nv, 0.0)).xyz);
	vec2 t = normalize(vec2(-n.z, n.x));
	float u = dot(wpos.xz, t);
	float v = wpos.y;
	float a = (u + v) / paso;
	float b = (u - v) / paso;
	float aa = max(fwidth(a), fwidth(b)) + 0.001;
	float w = hilo / paso;
	// distancia al alambre mas cercano (en fraccion de paso)
	float d1 = min(fract(a), 1.0 - fract(a));
	float d2 = min(fract(b), 1.0 - fract(b));
	float linea = 1.0 - smoothstep(w, w + aa, min(d1, d2));
	float media = 2.0 * w * 2.0;
	float k = mix(linea, media, clamp(aa * 2.0, 0.0, 1.0));
	ALBEDO = color;
	ALPHA = clamp(k * 0.9 + 0.04, 0.0, 1.0);
	METALLIC = 0.6;
	ROUGHNESS = 0.45;
}
