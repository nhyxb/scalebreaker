extends "res://scenes/giant_skin.gd"
## Transfers the procedural giant rig's rotations to Hina's differently oriented bones.

const MODEL := preload("res://assets/characters/hina.glb")

const DRIVER_BONES := {
	"Hips_108": "spine",
	"Spine_99": "spine.001",
	"Chest_98": "spine.003",
	"Neck_59": "Neck",
	"Head_58": "Head",
	"Eye_L_4": "Eye L",
	"Eye_R_5": "Eye R",
	"Left shoulder_78": "shoulder.L",
	"Left arm_77": "upper_arm.L",
	"Left elbow_76": "forearm.L",
	"Left wrist_75": "hand.L",
	"Right shoulder_97": "shoulder.R",
	"Right arm_96": "upper_arm.R",
	"Right elbow_95": "forearm.R",
	"Right wrist_94": "hand.R",
	"Left leg_103": "thigh.L",
	"Left knee_102": "shin.L",
	"Left ankle_101": "foot.L",
	"Left toe_100": "toe.L",
	"Right leg_107": "thigh.R",
	"Right knee_106": "shin.R",
	"Right ankle_105": "foot.R",
	"Right toe_104": "toe.R",
}
# The source has one bent arm in its bind pose. Align the main limb segments
# to the driver's rest directions so that bend is not added to every motion.
const ALIGN_TOWARD := {
	"Left arm_77": "Left elbow_76",
	"Left elbow_76": "Left wrist_75",
	"Right arm_96": "Right elbow_95",
	"Right elbow_95": "Right wrist_94",
	"Left leg_103": "Left knee_102",
	"Left knee_102": "Left ankle_101",
	"Right leg_107": "Right knee_106",
	"Right knee_106": "Right ankle_105",
}
# Align feet on the ground plane only so flat boots do not inherit Kawaii's heeled ankle pitch.
const ALIGN_YAW := {
	"Left ankle_101": "Left toe_100",
	"Right ankle_105": "Right toe_104",
}
const FINGERS := {
	"Thumb": "thumb",
	"Index": "f_index",
	"Middle": "f_middle",
	"Ring": "f_ring",
	"Little": "f_pinky",
}
const FIT_SCALE := 1.034

func configure(driver: Skeleton3D) -> void:
	_load_model(MODEL)
	_restore_bind_pose()
	_configure_visibility(&"Head_58",
		[&"Object_6", &"Object_7", &"Object_8", &"Object_9", &"Object_10", &"Object_11",
		&"Object_12", &"Object_13", &"Object_14", &"Object_18", &"Object_19"], [&"Object_15"])
	scale = Vector3.ONE * FIT_SCALE
	position.y = 0.0048 * FIT_SCALE

	var mapping := DRIVER_BONES.duplicate()
	var alignments := ALIGN_TOWARD.duplicate()
	for bone in skeleton.get_bone_count():
		var target_name := skeleton.get_bone_name(bone)
		var parts := target_name.split("_")
		for prefix in FINGERS:
			if not parts[0].begins_with(prefix):
				continue
			var segment := int(parts[0].right(1))
			if prefix == "Thumb":
				segment += 1
			mapping[target_name] = "%s.%02d.%s" % [FINGERS[prefix], segment, parts[1]]
			if prefix == "Middle" and segment == 1:
				var wrist := "Left wrist_75" if parts[1] == "L" else "Right wrist_94"
				alignments[wrist] = target_name
			break

	_configure_pose(driver, mapping, alignments, ALIGN_YAW)


func _restore_bind_pose() -> void:
	# This Fab conversion retains inverse binds but drops the joint transforms.
	var global_rest := {}
	for mesh in meshes:
		for bind in mesh.skin.get_bind_count():
			var bone := skeleton.find_bone(mesh.skin.get_bind_name(bind))
			global_rest[bone] = mesh.skin.get_bind_pose(bind).affine_inverse()

	for bone in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(bone)
		var parent_rest: Transform3D = global_rest.get(parent, Transform3D.IDENTITY)
		var rest: Transform3D = global_rest[bone]
		skeleton.set_bone_rest(bone, parent_rest.affine_inverse() * rest)
	skeleton.reset_bone_poses()

