extends Node3D
## Single-world 3D desktop-sandbox bedroom mount (Vulkan mobile, 32-bit Reversed-Z).
## Mounts the 1:1 Japanese cream & pale-oak bedroom (scenes/skybox_bedroom.gd, including
## seated Yumeka) directly inside the main 3D world at the active tabletop scale so
## `sandbox_anchor` lands at exact main-world `(0, 0, 0)`. All bedroom/Yumeka meshes and
## lights are isolated onto VisualInstance3D/Light3D Layer 2 while the harbour city uses
## Layer 1, preventing bedroom lights (e.g. night desk lamp) and main-world Sun from
## bleeding into each other while keeping 100% real 3D depth occlusion.

const BedroomShell := preload("res://scenes/skybox_bedroom.gd")
const DistrictExpansion := preload("res://scenes/district_expansion.gd")
const BEDROOM_SCALE := BedroomShell.BEDROOM_SCALE
const DEFAULT_MAP_SIDE := 1418.0
const PALM_TRAY_WIDTH := 0.10
const PALM_TRAY_OFFSET := 0.30

var bedroom: Node3D
var ultra_giant_anchor: Node3D
var _anchor: Node3D


func _ready() -> void:
	bedroom = BedroomShell.new()
	bedroom.name = "Bedroom"
	# Set scale and world offset BEFORE add_child so Bedroom._ready() and Yumeka._ready()
	# see exact main-world transforms immediately during initialization.
	bedroom.scale = Vector3.ONE * BEDROOM_SCALE
	bedroom.position = Vector3(
		0.0,
		-(BedroomShell.DESK_TOP + BedroomShell.SANDBOX_BASE_THICKNESS) * BEDROOM_SCALE,
		0.0,
	)
	add_child(bedroom)
	_anchor = bedroom.sandbox_anchor
	ultra_giant_anchor = bedroom.ultra_giant_anchor
	configure_tabletop(false, DEFAULT_MAP_SIDE)


## Map coordinates stay in harbour metres. The bedroom provides the tabletop scale.
func configure_tabletop(palm_size: bool, map_side: float) -> float:
	var room_scale := DEFAULT_MAP_SIDE / PALM_TRAY_WIDTH if palm_size else BEDROOM_SCALE
	var base_depth := DistrictExpansion.sandbox_frame_depth(map_side * 0.5)
	var tray_offset := PALM_TRAY_OFFSET if palm_size else 0.0
	bedroom.configure_tray(room_scale, map_side, base_depth, tray_offset)
	bedroom.scale = Vector3.ONE * room_scale
	bedroom.position = -_anchor.position * room_scale
	var corner := Vector3(BedroomShell.ROOM.x * 0.5, BedroomShell.ROOM.y - BedroomShell.DESK_TOP,
			BedroomShell.ROOM_Z_MAX - _anchor.position.z) + Vector3.ONE * BedroomShell.WALL
	return maxf(50000.0, corner.length() * room_scale + map_side * 2.0)


func mark_dirty() -> void:
	# Single-world rendering updates natively every frame; kept as a no-op for compatibility.
	pass


func is_yumeka_mounted() -> bool:
	var y := get_yumeka()
	return y != null and y.has_method(&"debug_is_mounted") and bool(y.call(&"debug_is_mounted"))


func get_yumeka() -> Node:
	if ultra_giant_anchor == null:
		return null
	return ultra_giant_anchor.get_node_or_null("Yumeka")


func get_bedroom() -> Node3D:
	return bedroom


## Forward day/dusk/night atmosphere weights to the single-world bedroom lights & props.
func apply_day_night(day_w: float, dusk_w: float, night_w: float, cycle_time: float = 0.0) -> void:
	if bedroom != null and bedroom.has_method(&"apply_day_night"):
		bedroom.call(&"apply_day_night", day_w, dusk_w, night_w, cycle_time)
