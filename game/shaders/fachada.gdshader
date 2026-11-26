shader_type spatial;
// Fachada procedural en coordenadas de mundo (sin UVs). Caras verticales: plantas de `planta` m y ventanas de
// `vent_w` x `vent_h` m cada `modulo` m a lo largo de la fachada. La coordenada horizontal es la proyeccion de la
// posicion de mundo sobre la tangente horizontal de la normal, asi el patron se alinea en cualquier orientacion.
// Caras horizontales (cubiertas, vuelos): gris de grava.

uniform vec3 color_pared : source_color = vec3(0.78, 0.78, 0.8);
uniform vec3 color_grava : source_color = vec3(0.4, 0.4, 0.41);
uniform vec3 color_cristal : source_color = vec3(0.04, 0.09, 0.2);
uniform float planta = 3.5;
uniform float modulo = 3.0;
uniform float vent_w = 1.5;
uniform float vent_h = 1.4;
uniform float alfeizar = 1.0;   // altura del borde inferior de la ventana sobre el suelo de la planta

varying vec3 wpos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x), mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}

float caja(float x, float a, float b, float aa) {
	return smoothstep(a - aa, a + aa, x) * (1.0 - smoothstep(b - aa, b + aa, x));
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// normal plana de la cara por derivadas (el glb no trae normales y Godot las suaviza entre cara superior y paredes,
	// porque comparten vertices); se orienta hacia la camara
	// (en espacio de vista: cerca de la camara los valores son pequenos y las derivadas no pierden precision)
	vec3 nv = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (dot(nv, -VERTEX) < 0.0) {
		nv = -nv;
	}
	NORMAL = nv;
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(nv, 0.0)).xyz);
	if (abs(n.y) > 0.6) {
		// cubierta de grava (o cara inferior de un vuelo, mas oscura)
		vec2 pg = wpos.xz * 14.0;
		float fino = 1.0 - smoothstep(0.25, 0.8, max(fwidth(pg.x), fwidth(pg.y)));   // sin grano fino a distancia (moire)
		float g = mix(0.5, hash21(floor(pg)), fino);
		float m = vnoise(wpos.xz * 0.7);
		float k = (0.8 + 0.3 * g) * (0.9 + 0.2 * m) * (n.y > 0.0 ? 1.0 : 0.7);
		ALBEDO = color_grava * k;
		ROUGHNESS = 0.97;
		METALLIC = 0.0;
	} else {
		vec2 t = normalize(vec2(-n.z, n.x));
		float u = dot(wpos.xz, t);
		float v = wpos.y;
		float aa = max(fwidth(u), fwidth(v)) * 0.75 + 0.0005;
		vec2 celda = vec2(floor(u / modulo), floor(v / planta));
		float lu = u - celda.x * modulo;
		float lv = v - celda.y * planta;
		float x0 = (modulo - vent_w) * 0.5;
		float vent = caja(lu, x0, x0 + vent_w, aa) * caja(lv, alfeizar, alfeizar + vent_h, aa);
		float marco = caja(lu, x0 - 0.1, x0 + vent_w + 0.1, aa) * caja(lv, alfeizar - 0.1, alfeizar + vent_h + 0.1, aa);
		// pared con ruido y una cornisa a nivel de forjado
		vec2 pf = vec2(u, v) * 18.0;
		float fino = 1.0 - smoothstep(0.25, 0.8, max(fwidth(pf.x), fwidth(pf.y)));
		float ruido = vnoise(vec2(u, v) * 1.3) * 0.12 + mix(0.5, hash21(floor(pf)), fino) * 0.05;
		vec3 pared = color_pared * (0.92 + ruido);
		pared *= 1.0 - 0.10 * caja(lv, planta - 0.22, planta, aa);
		pared = mix(pared, pared * 0.55, marco);
		float tono = hash21(celda + vec2(7.0, 3.0));
		vec3 cristal = color_cristal * (0.7 + 0.9 * tono);
		ALBEDO = mix(pared, cristal, vent);
		ROUGHNESS = mix(0.9, 0.08, vent);
		METALLIC = mix(0.0, 0.5, vent);
		SPECULAR = mix(0.5, 0.9, vent);
	}
}
