extends "res://scenes/giant_skin.gd"

const MODEL := preload("res://assets/characters/chibi_catgirl.glb")

const DRIVER_BONES := {
	"DEF-spine_013": "spine",
	"DEF-spine.001_014": "spine.001",
	"DEF-spine.002_015": "spine.002",
	"DEF-spine.003_016": "spine.003",
	"DEF-spine.004_017": "spine.004",
	"DEF-spine.005_018": "Neck",
	"DEF-spine.006_019": "Head",
	"DEF-eye.L_0148": "Eye L",
	"DEF-eye.R_0153": "Eye R",
	"ORG-shoulder.L_0192": "shoulder.L",
	"DEF-upper_arm.L_0217": "upper_arm.L",
	"DEF-forearm.L_0219": "forearm.L",
	"DEF-hand.L_0221": "hand.L",
	"ORG-shoulder.R_00": "shoulder.R",
	"DEF-upper_arm.R_06": "upper_arm.R",
	"DEF-forearm.R_0336": "forearm.R",
	"DEF-hand.R_0338": "hand.R",
	"DEF-thigh.L_089": "thigh.L",
	"DEF-shin.L_091": "shin.L",
	"DEF-foot.L_093": "foot.L",
	"DEF-toe.L_094": "toe.L",
	"DEF-thigh.R_0114": "thigh.R",
	"DEF-shin.R_0116": "shin.R",
	"DEF-foot.R_0118": "foot.R",
	"DEF-toe.R_0119": "toe.R",
}
const ALIGN_TOWARD := {
	"DEF-spine_013": "DEF-spine.001_014",
	"DEF-spine.001_014": "DEF-spine.002_015",
	"DEF-spine.002_015": "DEF-spine.003_016",
	"DEF-spine.003_016": "DEF-spine.004_017",
	"DEF-upper_arm.L_0217": "DEF-forearm.L_0219",
	"DEF-forearm.L_0219": "DEF-hand.L_0221",
	"DEF-upper_arm.R_06": "DEF-forearm.R_0336",
	"DEF-forearm.R_0336": "DEF-hand.R_0338",
	"DEF-thigh.L_089": "DEF-shin.L_091",
	"DEF-shin.L_091": "DEF-foot.L_093",
	"DEF-thigh.R_0114": "DEF-shin.R_0116",
	"DEF-shin.R_0116": "DEF-foot.R_0118",
}
# Align feet horizontally only so flat boots stay level instead of matching Kawaii's heeled ankle pitch.
const ALIGN_YAW := {
	"DEF-foot.L_093": "DEF-toe.L_094",
	"DEF-foot.R_0118": "DEF-toe.R_0119",
}
# The exported Rigify pose includes IK stretch on the legs; clear it so both boots sit level without shear.
const UNSTRETCH_BONES := [
	&"DEF-thigh.L_089",
	&"DEF-shin.L_091",
	&"DEF-foot.L_093",
	&"DEF-thigh.R_0114",
	&"DEF-shin.R_0116",
	&"DEF-foot.R_0118",
]
const DEFORM_PARENTS := {
	"DEF-thigh.L_089": "DEF-spine_013",
	"DEF-thigh.R_0114": "DEF-spine_013",
	"ORG-shoulder.L_0192": "DEF-spine.003_016",
	"ORG-shoulder.R_00": "DEF-spine.003_016",
	"master_eye.L_0145": "DEF-spine.006_019",
	"master_eye.R_0129": "DEF-spine.006_019",
}
const FIT_SCALE := 0.404
const FLOOR_OFFSET := -0.071


func configure(driver: Skeleton3D) -> void:
	_load_model(MODEL)
	# The exported Rigify limbs hang off control chains without any constraints.
	# Connect them to the moving deformation bones while keeping their bind locations.
	for bone_name in DEFORM_PARENTS:
		var bone := skeleton.find_bone(bone_name)
		var parent := skeleton.find_bone(DEFORM_PARENTS[bone_name])
		var rest := skeleton.get_bone_global_rest(bone)
		var parent_rest := skeleton.get_bone_global_rest(parent)
		skeleton.set_bone_parent(bone, parent)
		skeleton.set_bone_rest(bone, parent_rest.affine_inverse() * rest)
		skeleton.reset_bone_pose(bone)
	for bone_name in UNSTRETCH_BONES:
		skeleton.set_bone_pose_scale(skeleton.find_bone(bone_name), Vector3.ONE)

	_configure_visibility(&"DEF-spine.006_019",
		[&"Object_22", &"Object_35", &"Object_37", &"Object_39", &"Object_41", &"Object_42",
		&"Object_43", &"Object_45", &"Object_721", &"Object_723", &"Object_725",
		&"Object_727", &"Object_731"],
		[&"Object_24", &"Object_28", &"Object_29", &"Object_30", &"Object_31", &"Object_719"])
	for mesh in meshes:
		# The source vertex bounds are in centimeters but the skin binds use meters.
		mesh.custom_aabb = AABB(Vector3(-3.6, -4.4, -1.0), Vector3(7.2, 8.8, 6.4))

	rotation.y = -PI * 0.5
	scale = Vector3.ONE * FIT_SCALE
	position = -(basis * skeleton.position) + Vector3.UP * FLOOR_OFFSET
	_configure_pose(driver, DRIVER_BONES, ALIGN_TOWARD, ALIGN_YAW)
