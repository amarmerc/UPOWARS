shader_type spatial;
// Losas de techo (marquesinas y pasillo central): cara inferior blanca, cara superior gris claro, cantos blancos.
// La normal sale de las derivadas (el glb no trae normales utiles) y se pasa a mundo para decidir arriba/abajo.

uniform vec3 color_inferior : source_color = vec3(0.925, 0.918, 0.894);
uniform vec3 color_superior : source_color = vec3(0.72, 0.72, 0.71);

varying vec3 wpos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 nv = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (dot(nv, -VERTEX) < 0.0) {
		nv = -nv;
	}
	NORMAL = nv;
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(nv, 0.0)).xyz);
	vec3 c = color_inferior;
	if (n.y > 0.5) {
		vec2 pg = wpos.xz * 6.0;
		float fino = 1.0 - smoothstep(0.25, 0.8, max(fwidth(pg.x), fwidth(pg.y)));
		c = color_superior * (0.94 + 0.08 * mix(0.5, hash21(floor(pg)), fino));
	}
	ALBEDO = c;
	ROUGHNESS = 0.9;
}
