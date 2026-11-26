shader_type spatial;
// Fachada procedural en coordenadas de mundo (sin UVs), parametrizable por estilo (ver materiales.gd).
//
// Instance uniforms (los rellena materiales.gd por edificio):
//   eje_principal  vec2 normalizado en XZ: eje largo del edificio (rectangulo minimo de los vertices)
//   y_cubierta     y maxima del AABB global del edificio
//   ext_eje        (a_min, a_max, b_min, b_max): extension de la huella a lo largo del eje (a = dot(xz, eje)) y del
//                  perpendicular (b = dot(xz, perp)); sirve para centrar la rejilla de ventanas y dejar margen en las esquinas
//
// Caras verticales: la normal da el tipo. Normal perpendicular al eje = cara larga (color_muro, ventanas);
// normal paralela al eje = testero (color_testero). Las plantas se cuentan hacia abajo desde la cubierta, asi la planta
// superior queda siempre completa. De arriba abajo: mirador / remate (pretil) y luego plantas con bandas entre ellas,
// ventanas (aisladas o corridas), panel bajo la ventana, lama sobre la ventana, nervios verticales y ladrillo.
// Caras horizontales (cubiertas, vuelos): gris de grava (la cara inferior algo mas oscura).

instance uniform vec2 eje_principal = vec2(1.0, 0.0);
instance uniform float y_cubierta = 1000.0;
instance uniform vec4 ext_eje = vec4(0.0);

uniform vec3 color_muro : source_color = vec3(0.78, 0.78, 0.8);
uniform vec3 color_testero : source_color = vec3(0.78, 0.78, 0.8);
uniform vec3 color_grava : source_color = vec3(0.4, 0.4, 0.41);
uniform vec3 color_cristal : source_color = vec3(0.04, 0.09, 0.2);
uniform vec3 color_marco : source_color = vec3(0.9, 0.9, 0.9);
uniform float rugosidad = 0.9;
uniform float brillo = 1.0;        // factor sobre el albedo de muro (evita quemar los blancos)

uniform float planta = 3.5;
// ventanas: 0 aisladas (rejilla), 1 corridas (banda continua), 2 sin ventanas
uniform int modo_vent = 0;
uniform float modulo = 3.0;        // separacion entre ventanas (aisladas) o entre montantes (corridas)
uniform float vent_w = 1.5;        // ancho de la ventana aislada
uniform float vent_h = 1.4;
uniform float alfeizar = 1.0;      // altura del borde inferior de la ventana sobre el forjado de su planta
uniform float marco_w = 0.1;       // grosor del marco / montante
uniform float margen_esq = 1.0;    // sin ventanas a menos de esta distancia de las esquinas (caras con extension conocida)
uniform float vent_testero = 0.0;  // 1 = tambien hay ventanas en los testeros
uniform float sin_vent_arriba = 0.0; // sin ventanas en los primeros m bajo la cubierta (ademas del remate)

uniform float panel_h = 0.0;       // panel de color propio bajo la ventana (0 = no)
uniform vec3 color_panel : source_color = vec3(0.85, 0.65, 0.25);

uniform float banda_h = 0.0;       // banda horizontal entre plantas (0 = no)
uniform vec3 color_banda : source_color = vec3(0.95, 0.95, 0.95);

uniform float remate_h = 0.0;      // pretil bajo la cubierta (0 = no)
uniform vec3 color_remate : source_color = vec3(0.89, 0.75, 0.47);
uniform float remate_borde_h = 0.0; // borde superior del pretil
uniform vec3 color_remate_borde : source_color = vec3(0.95, 0.95, 0.95);

uniform float mirador_h = 0.0;     // tramo superior liso de otro color (torre)
uniform vec3 color_mirador : source_color = vec3(0.93, 0.92, 0.9);

uniform float lama_h = 0.0;        // lama / voladizo sobre la ventana (0 = no)
uniform vec3 color_lama : source_color = vec3(0.6, 0.6, 0.59);

uniform float nervio_sep = 0.0;    // nervios verticales cada X m (0 = no)
uniform float nervio_w = 0.05;
uniform float nervio_oscuro = 0.85;

uniform float ladrillo = 0.0;      // intensidad de la textura de ladrillo (0 = no)

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
		// ---- ejes y tipo de cara
		vec2 e = eje_principal;
		e = length(e) > 0.01 ? normalize(e) : vec2(1.0, 0.0);
		vec2 pe = vec2(-e.y, e.x);
		vec2 nh = normalize(n.xz + vec2(1e-6));
		float along = abs(dot(nh, e));              // 1 = testero, 0 = cara larga
		bool es_testero = along > 0.7;
		bool alineada = along > 0.9 || along < 0.1; // si no, cara oblicua: patron sin anclar
		// coordenada horizontal u (de 0 a largo si se conoce la extension de la cara; si no, proyeccion cruda)
		float largo = 0.0;
		float u;
		if (alineada && ext_eje.y > ext_eje.x) {
			if (es_testero) {
				u = dot(wpos.xz, pe) - ext_eje.z;
				largo = ext_eje.w - ext_eje.z;
			} else {
				u = dot(wpos.xz, e) - ext_eje.x;
				largo = ext_eje.y - ext_eje.x;
			}
		} else {
			u = dot(wpos.xz, normalize(vec2(-nh.y, nh.x)));
		}
		// profundidad bajo la cubierta
		float d = y_cubierta - wpos.y;
		float aa = max(fwidth(u), fwidth(d)) * 0.75 + 0.0005;

		bool ventanas_ok = modo_vent != 2 && (!es_testero || vent_testero > 0.5);
		float zona_sup = max(max(remate_h, mirador_h), sin_vent_arriba);
		float s = max(d - max(remate_h, mirador_h), 0.0);
		float k = floor(s / planta);
		float sm = s - k * planta;                  // distancia al forjado superior de esta planta
		float lv = planta - sm;                     // altura sobre el forjado inferior

		// ---- muro base
		vec3 base = es_testero ? color_testero : color_muro;
		float ruido = vnoise(vec2(u, wpos.y) * 1.3) * 0.08;
		vec3 col = base * (0.95 + ruido);

		// ladrillo (hiladas de 0,075 m x 0,25 m, juntas mas claras), a por mundo
		if (ladrillo > 0.0) {
			float fila = floor(wpos.y / 0.075);
			float xb = u / 0.25 + 0.5 * mod(fila, 2.0);
			vec2 fb = vec2(fract(xb), fract(wpos.y / 0.075));
			vec2 aab = vec2(fwidth(xb), fwidth(wpos.y / 0.075));
			float fade = (1.0 - smoothstep(0.2, 0.6, max(aab.x, aab.y))) * ladrillo;
			float junta = max(1.0 - smoothstep(0.04 - aab.x, 0.04 + aab.x, fb.x), 1.0 - smoothstep(0.12 - aab.y, 0.12 + aab.y, fb.y));
			float tono_l = 0.86 + 0.22 * hash21(vec2(floor(xb), fila));
			col *= mix(1.0, tono_l, fade);
			col = mix(col, col * 1.25 + vec3(0.06), junta * fade);
		}

		// ---- nervios verticales
		if (nervio_sep > 0.0) {
			float dm = abs(mod(u, nervio_sep) - nervio_sep * 0.5);   // 0 en el centro de la banda entre nervios
			float dn = nervio_sep * 0.5 - dm;                        // distancia al nervio mas cercano
			float lin = 1.0 - smoothstep(nervio_w * 0.5 - aa, nervio_w * 0.5 + aa, dn);
			float f = 1.0 - smoothstep(0.2, 0.5, fwidth(u) / nervio_sep);
			float medio = 1.0 - (1.0 - nervio_oscuro) * nervio_w / nervio_sep;
			col *= mix(medio, mix(1.0, nervio_oscuro, lin), f);
		}

		float vent = 0.0;
		float rug = rugosidad;
		float met = 0.0;
		float spec = 0.5;
		if (ventanas_ok && d > zona_sup + 0.01 && s > 0.0) {
			// ---- ventanas
			// rejilla centrada en la cara: n modulos, con margen en las esquinas
			float n_mod = 1.0e6;
			float inicio = 0.0;
			if (largo > 1.0) {
				n_mod = floor((largo - 2.0 * margen_esq) / modulo + 0.001);
				inicio = (largo - n_mod * modulo) * 0.5;
			}
			float celda = floor((u - inicio) / modulo);
			bool en_rejilla = n_mod >= 1.0 && celda >= 0.0 && celda < n_mod;
			float lu = u - inicio - celda * modulo;
			float x0 = (modulo - vent_w) * 0.5;
			float hx;       // mascara horizontal de la ventana
			float hxm;      // mascara horizontal con marco
			float hxl;      // mascara horizontal de la lama / panel
			if (modo_vent == 1) {
				float a0 = largo > 1.0 ? margen_esq : -1.0e5;
				float a1 = largo > 1.0 ? largo - margen_esq : 1.0e5;
				hx = caja(u, a0, a1, aa);
				hxm = hx;
				hxl = hx;
				// montantes cada `modulo`
				if (largo > 1.0) {
					float dmo = abs(mod(u - inicio + modulo * 0.5, modulo) - modulo * 0.5);
					float mont = (1.0 - smoothstep(marco_w * 0.5 - aa, marco_w * 0.5 + aa, dmo)) * float(celda >= -0.5 && celda < n_mod + 0.5);
					hx *= 1.0 - mont;
				}
				en_rejilla = largo <= 1.0 || (u > a0 && u < a1);
			} else {
				hx = caja(lu, x0, x0 + vent_w, aa);
				hxm = caja(lu, x0 - marco_w, x0 + vent_w + marco_w, aa);
				hxl = caja(lu, x0 - marco_w, x0 + vent_w + marco_w, aa);
			}
			if (!en_rejilla) {
				hx = 0.0;
				hxm = 0.0;
				hxl = 0.0;
			}
			float y_top = alfeizar + vent_h;
			float vy = caja(lv, alfeizar, y_top, aa);
			float vym = caja(lv, alfeizar - marco_w, y_top + marco_w, aa);
			// panel bajo la ventana
			if (panel_h > 0.0) {
				float pan = hxl * caja(lv, alfeizar - panel_h, alfeizar - marco_w * 0.5, aa);
				col = mix(col, color_panel, pan);
			}
			// lama / voladizo sobre la ventana, sombreada abajo
			float sombra = 1.0;
			if (lama_h > 0.0) {
				float lt = lv - y_top;                    // altura sobre el dintel
				float lam = hxl * caja(lv, y_top, y_top + lama_h, aa);
				float shade = mix(0.5, 1.0, smoothstep(0.0, lama_h * 0.8, lt));
				shade *= 1.0 - 0.3 * (1.0 - smoothstep(0.0, 0.05, lama_h - lt));  // arista superior un poco mas oscura
				col = mix(col, color_lama * shade, lam);
				// sombra arrojada de la lama sobre el cristal
				sombra = mix(0.45, 1.0, smoothstep(0.0, 0.5, y_top - lv));
			}
			// marco y cristal
			float marco = hxm * vym;
			col = mix(col, color_marco, marco);
			vent = hx * vy;
			float tono = hash21(vec2(celda, k) + vec2(7.0, 3.0));
			float refl = mix(1.25, 0.7, clamp((lv - alfeizar) / max(vent_h, 0.01), 0.0, 1.0));   // reflejo del cielo arriba
			vec3 cristal = color_cristal * (0.7 + 0.9 * tono) * refl * sombra;
			col = mix(col, cristal, vent);
		}

		// ---- bandas horizontales entre plantas
		if (banda_h > 0.0) {
			float db = min(sm, planta - sm);
			float ban = 1.0 - smoothstep(banda_h * 0.5 - aa, banda_h * 0.5 + aa, db);
			col = mix(col, color_banda, ban * (1.0 - vent));
		}

		// ---- remate (pretil) y mirador en lo alto
		if (remate_h > 0.0) {
			float r = 1.0 - smoothstep(remate_h - aa, remate_h + aa, d);
			col = mix(col, color_remate, r);
			if (remate_borde_h > 0.0) {
				float rb = 1.0 - smoothstep(remate_borde_h - aa, remate_borde_h + aa, d);
				col = mix(col, color_remate_borde, rb);
			}
			vent *= 1.0 - r;
		}
		if (mirador_h > 0.0) {
			float mi = 1.0 - smoothstep(mirador_h - aa, mirador_h + aa, d);
			col = mix(col, color_mirador, mi);
			vent *= 1.0 - mi;
		}

		ALBEDO = col * mix(brillo, 1.0, vent);
		ROUGHNESS = mix(rug, 0.08, vent);
		METALLIC = mix(met, 0.5, vent);
		SPECULAR = mix(spec, 0.9, vent);
	}
}
