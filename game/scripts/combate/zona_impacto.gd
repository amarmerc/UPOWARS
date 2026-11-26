class_name ZonaImpacto
extends Area3D
## Hitbox de una zona del cuerpo. Vive en la capa de fisica "hitbox" (2): los disparos la ven,
## la capsula de movimiento no.

const CAPA_HITBOX: int = 2

var zona: String = "torso"
var salud: Salud = null
