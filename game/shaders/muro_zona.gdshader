shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, unshaded, shadows_disabled;
// Muro translucido de una zona competitiva (limite de la zona y barreras de spawn). Hexagonos tenues en coordenadas de la
// propia pared (UV.x = metros a lo largo del muro, UV.y = metros sobre el terreno, los pone zona_activa.gd): el relleno es
// casi transparente (se ve a traves) y las aristas se hacen mas visibles cuando la camara esta cerca. El alfa nunca supera
// `alpha_max` (< 1), asi que el muro se ve pero no tapa nada.

uniform vec4 color : source_color = vec4(0.45, 0.86, 1.0, 1.0);
uniform float celda = 1.5;              // tamano del hexagono (m)
uniform float grosor = 0.04;            // grosor relativo de la arista (0-0.5 de la celda) a poca distancia
uniform float alpha_relleno = 0.035;    // alfa del interior de las celdas
uniform float alpha_linea = 0.34;       // alfa de las aristas lejos del jugador
uniform float alpha_cerca = 0.6;        // alfa de las aristas junto al jugador
uniform float radio_cerca = 10.0;       // a esta distancia (m) las aristas ya estan a media intensidad
uniform float alpha_max = 0.75;         // tope absoluto del alfa
uniform float altura_fundido = 3.0;     // el borde superior se vuelve algo mas transparente en estos metros
uniform float altura_total = 8.0;
uniform float brillo_borde = 0.5;       // intensidad de la franja de la base (a ras de terreno) y de la corona

varying vec3 wpos;

float dist_hex(vec2 p) {
	p = abs(p);
	return max(dot(p, normalize(vec2(1.0, 1.7320508))), p.x);
}

// devuelve la distancia (0 = en la arista) normalizada de la celda hexagonal que contiene p
float arista_hex(vec2 p) {
	vec2 r = vec2(1.0, 1.7320508);
	vec2 h = r * 0.5;
	vec2 a = mod(p, r) - h;
	vec2 b = mod(p - h, r) - h;
	vec2 gv = dot(a, a) < dot(b, b) ? a : b;
	return 0.5 - dist_hex(gv);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = UV / celda;
	float e = arista_hex(p);                         // 0 en la arista, 0.5 en el centro de la celda
	float d = distance(wpos, CAMERA_POSITION_WORLD);
	float aa = max(fwidth(e), 0.002) * 1.5;
	float gr = min(grosor * (1.0 + d / 25.0), 0.22);     // las aristas engrosan con la distancia para no desaparecer
	float linea = 1.0 - smoothstep(gr, gr + aa, e);
	float cerca = 1.0 - smoothstep(radio_cerca * 0.3, radio_cerca * 2.2, d);
	float alpha_l = mix(alpha_linea, alpha_cerca, cerca);
	float a = alpha_relleno * (0.6 + 0.4 * cerca) + linea * alpha_l;
	// pulso muy suave para que se note que es un campo de fuerza
	a *= 0.9 + 0.1 * sin(TIME * 1.6 + UV.x * 0.15 + UV.y * 0.4);
	// base y corona un poco mas marcadas
	float base = 1.0 - smoothstep(0.0, 0.3, abs(UV.y));
	float corona = altura_total > 0.0 ? 1.0 - smoothstep(0.0, 0.3, abs(UV.y - altura_total)) : 0.0;
	a += (base + corona) * brillo_borde * 0.25 * (0.4 + 0.6 * cerca);
	if (altura_total > 0.0) {
		a *= mix(1.0, 0.55, smoothstep(altura_total - altura_fundido, altura_total, UV.y));
	}
	ALBEDO = color.rgb * (0.85 + 0.6 * linea);
	ALPHA = clamp(a, 0.0, alpha_max);
}
