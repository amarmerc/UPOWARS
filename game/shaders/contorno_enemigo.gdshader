shader_type spatial;
render_mode cull_front, unshaded, depth_draw_opaque;
// Contorno de enemigo visible (inverted hull) para usar como `material_overlay` de las mallas del personaje: se dibuja la malla
// por detras, engrosada a lo largo de la normal EN ESPACIO DE VISTA (independiente de la escala del modelo), asi que queda un
// borde de color alrededor de la silueta. Con prueba de profundidad normal: un muro, un prop o un arbol por delante lo tapan
// (el humo lo gestiona ContornoEnemigos con linea_de_vision). El ancho crece con la distancia para que se vea de lejos.

uniform vec4 color : source_color = vec4(1.0, 0.1, 0.45, 1.0);
uniform float ancho_cerca = 0.035;
uniform float ancho_por_metro = 0.008;
uniform float ancho_max = 0.34;

void vertex() {
	vec3 p = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = normalize((MODELVIEW_NORMAL_MATRIX * NORMAL));
	float d = length(p);
	p += n * min(ancho_cerca + ancho_por_metro * d, ancho_max);
	p.z -= 0.05 + 0.004 * d;   // un poco mas lejos que el cuerpo: evita el z-fighting en la silueta
	POSITION = PROJECTION_MATRIX * vec4(p, 1.0);
}

void fragment() {
	ALBEDO = color.rgb;
}
