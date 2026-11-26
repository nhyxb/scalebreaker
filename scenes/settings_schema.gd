extends RefCounted
## Declarative metadata for the gameplay settings panel.
##
## One entry per option. `key` doubles as the save key, the control node name and the
## value returned by `invalid_setting()`, so tests and the Rust bridge keep working.
##
## Adding a new option means answering, in this order:
##   1. Which page? Graphics/sound go to PAGE_GRAPHICS and are set once for every mode;
##      anything that changes rules belongs to PAGE_GAMEPLAY and is stored per mode.
##   2. Which group? map / giant / humans / growth / revive.
##   3. Is it common enough to sit in the open, or does it belong behind 「高级」?
##   4. When does it apply? LIVE for values the round re-reads every frame,
##      NEXT for values snapshotted when the round starts, DEATH/RESPAWN for revives.
##   5. Does it depend on another toggle? Then give it `requires` so it hides when unused.

const PAGE_GRAPHICS := "graphics"
const PAGE_GRAPHIC_TITLE := "画面与声音"
const PAGE_GAMEPLAY := "gameplay"
const PAGE_GAMEPLAY_TITLE := "玩法"

const APPLY_LIVE := "立即"
const APPLY_NEXT := "下局"
const APPLY_DEATH := "下次倒下"
const APPLY_RESPAWN := "下次复活"

const GROUPS := [
	{"id": "map", "title": "地图与开局"},
	{"id": "giant", "title": "巨人"},
	{"id": "humans", "title": "人类与行人"},
	{"id": "growth", "title": "金币与成长"},
	{"id": "revive", "title": "复活"},
]

const ALL_MODES := [0, 1, 2, 3]

const OPTIONS := [
	# --- 画面与声音（全局只设一次） -----------------------------------------
	{
		"key": "sfx_volume", "label": "音效音量", "hint": "界面、脚步和战斗音效的音量。",
		"kind": "number", "step": 5.0, "suffix": " %", "percent": true,
		"page": PAGE_GRAPHICS, "scope": "audio", "apply": APPLY_LIVE,
	},
	{
		"key": "ambience_volume", "label": "环境音量", "hint": "城市底噪、海风与远处环境声。",
		"kind": "number", "step": 5.0, "suffix": " %", "percent": true,
		"page": PAGE_GRAPHICS, "scope": "audio", "apply": APPLY_LIVE,
	},
	{
		"key": "audio_muted", "node": "AudioMuted", "label": "静音", "hint": "一键关闭全部声音，音量设置会保留。",
		"kind": "toggle", "page": PAGE_GRAPHICS, "scope": "audio", "apply": APPLY_LIVE,
	},
	{
		"key": "view_distance", "label": "渲染视距", "hint": "能看见多远；越大越 fog 少，也越吃性能。",
		"kind": "number", "step": 10.0, "suffix": " 米",
		"page": PAGE_GRAPHICS, "scope": "display", "apply": APPLY_LIVE,
	},
	{
		"key": "shake_strength", "label": "震动强度", "hint": "巨人踩踏和坐压时的镜头震动幅度。",
		"kind": "number", "step": 5.0, "suffix": " %", "percent": true,
		"page": PAGE_GRAPHICS, "scope": "display", "apply": APPLY_LIVE,
	},
	{
		"key": "own_camera_shake", "label": "自身震动", "hint": "自己踩踏时镜头是否跟着震。",
		"kind": "toggle", "page": PAGE_GRAPHICS, "scope": "display", "apply": APPLY_LIVE,
	},

	# --- 地图与开局 ---------------------------------------------------------
	{
		"key": "map_side", "label": "地图边长", "hint": "正方形港区的边长，下一局重新生成道路、街区和边界。",
		"kind": "number", "step": 12.0, "suffix": " 米", "integer": true,
		"page": PAGE_GAMEPLAY, "group": "map", "apply": APPLY_NEXT,
	},
	{
		"key": "giant_count", "label": "巨人数量", "hint": "场上同时出现的巨人数（含你自己）。",
		"kind": "number", "step": 1.0, "suffix": " 名", "integer": true,
		"page": PAGE_GAMEPLAY, "group": "map", "apply": APPLY_NEXT,
	},
	{
		"key": "random_start", "label": "随机开局", "hint": "开局身高在范围内随机，不然全员用初始身高。",
		"kind": "toggle", "modes": [2, 3],
		"page": PAGE_GAMEPLAY, "group": "map", "apply": APPLY_NEXT,
	},
	{
		"key": "giant_height", "label": "初始身高",
		"hint": "开局时每个巨人的身高。",
		"kind": "number", "step": 0.1, "suffix": " 米",
		"page": PAGE_GAMEPLAY, "group": "map", "apply": APPLY_NEXT,
		"requires": {"key": "random_start", "equals": false, "modes": [3]},
	},
	{
		"key": "start_min_height", "label": "开局最低身高", "hint": "大乱斗随机开局的下限。",
		"kind": "number", "step": 0.1, "suffix": " 米", "modes": [3], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "map", "apply": APPLY_NEXT,
		"requires": {"key": "random_start", "equals": true},
	},
	{
		"key": "start_max_height", "label": "开局最高身高", "hint": "大乱斗随机开局的上限。",
		"kind": "number", "step": 0.1, "suffix": " 米", "modes": [3], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "map", "apply": APPLY_NEXT,
		"requires": {"key": "random_start", "equals": true},
	},
	{
		"key": "giant_max_height", "label": "身高上限", "hint": "本局巨人能长到多高，也是坐压停留时长换算的基准。",
		"kind": "number", "step": 0.1, "suffix": " 米",
		"page": PAGE_GAMEPLAY, "group": "map", "apply": APPLY_NEXT,
	},

	# --- 巨人 ---------------------------------------------------------------
	{
		"key": "giant_speed", "label": "巨人速度", "hint": "巨人的移动与转身倍率，含 AI。",
		"kind": "number", "step": 0.1, "suffix": " 倍",
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_crush_enabled", "label": "AI 自动坐压",
		"hint": "AI 巨人在坐压范围内有两个比自己小很多的活物时自动坐下压扁；玩家只要是巨人，按 X 随时可坐。",
		"kind": "toggle", "page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_hold_base", "label": "坐压停留", "hint": "坐下后最少坐多久再起身。体型越大坐得越久。",
		"kind": "number", "step": 0.1, "suffix": " 秒",
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_idle_timeout", "label": "待机起身", "hint": "没事干时坐下待机，最多坐多久自动起身。",
		"kind": "number", "step": 1.0, "suffix": " 秒",
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "first_person_steer", "label": "视角控制转向",
		"hint": "第一人称左右看时身体跟着转；关掉后只有视线转，身体仍不跟着走。两种都限制在左右 75° 内，看不到后背和尾巴。",
		"kind": "toggle", "page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "rival_ignore_ratio", "label": "互相忽略倍率",
		"hint": "体型差达到这个倍数后，巨人之间不再主动追击。",
		"kind": "number", "step": 0.1, "suffix": " 倍", "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "base_health", "label": "基础生命", "hint": "1 厘米高时的生命值，随身高等比放大。",
		"kind": "number", "step": 1.0, "modes": [2, 3], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_NEXT,
	},
	{
		"key": "base_attack", "label": "基础攻击", "hint": "1 厘米高时的攻击力，随身高等比放大。",
		"kind": "number", "step": 1.0, "modes": [2, 3], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_NEXT,
	},
	{
		"key": "attack_height", "label": "成巨身高", "hint": "长到这个身高就从人类变成巨人。",
		"kind": "number", "step": 0.01, "suffix": " 米", "modes": [2], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_NEXT,
	},
	{
		"key": "sit_crush_ratio", "label": "坐压体型差",
		"hint": "目标要比自己小多少倍才算「小目标」，默认 5 倍。",
		"kind": "number", "step": 0.5, "suffix": " 倍", "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_crush_targets", "label": "坐压目标数", "hint": "坐压范围内至少要有几个小目标才触发。",
		"kind": "number", "step": 1.0, "suffix": " 个", "integer": true, "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_hold_per_scale", "label": "体型停留加成",
		"hint": "每多一倍体型，多坐几秒。",
		"kind": "number", "step": 0.1, "suffix": " 秒", "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_idle_enabled", "label": "满级待机坐",
		"hint": "长到上限又没目标时，有一定概率坐下待机。",
		"kind": "toggle", "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_idle_chance", "label": "待机概率", "hint": "每秒有多大概率坐下待机。",
		"kind": "number", "step": 0.05, "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_pin_ratio", "label": "压制体型差",
		"hint": "被大多少倍的巨坐压会定身并持续掉血。",
		"kind": "number", "step": 0.5, "suffix": " 倍", "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},
	{
		"key": "sit_pin_interval", "label": "压制伤害间隔",
		"hint": "被坐压时每隔多久掉一次血。",
		"kind": "number", "step": 0.1, "suffix": " 秒", "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "giant", "apply": APPLY_LIVE,
	},

	# --- 人类与行人 ---------------------------------------------------------
	{
		"key": "human_speed", "label": "人类速度", "hint": "人类与行人整体的移动倍率。",
		"kind": "number", "step": 0.1, "suffix": " 倍",
		"page": PAGE_GAMEPLAY, "group": "humans", "apply": APPLY_LIVE,
	},
	{
		"key": "npc_initial", "label": "开局行人", "hint": "开局刷出多少普通行人。",
		"kind": "number", "step": 1.0, "suffix": " 名", "integer": true, "modes": [0, 1, 2],
		"page": PAGE_GAMEPLAY, "group": "humans", "apply": APPLY_NEXT,
	},
	{
		"key": "npc_respawn", "node": "NpcRespawn", "label": "持续刷新", "hint": "行人会不会持续补充。",
		"kind": "toggle", "modes": [0, 1, 2],
		"page": PAGE_GAMEPLAY, "group": "humans", "apply": APPLY_LIVE,
	},
	{
		"key": "npc_interval", "label": "刷新间隔", "hint": "平均多久补一个行人。",
		"kind": "number", "step": 0.5, "suffix": " 秒", "modes": [0, 1, 2],
		"page": PAGE_GAMEPLAY, "group": "humans", "apply": APPLY_LIVE,
		"requires": {"key": "npc_respawn", "equals": true},
	},
	{
		"key": "human_ignore_ratio", "label": "忽略人类倍率",
		"hint": "体型差达到这个倍数后，巨人不再追小人类。",
		"kind": "number", "step": 0.1, "suffix": " 倍", "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "humans", "apply": APPLY_LIVE,
	},

	# --- 金币与成长 ---------------------------------------------------------
	{
		"key": "coin_height", "label": "金币分界", "hint": "高过这个身高的巨人击倒对手掉落金币。",
		"kind": "number", "step": 1.0, "suffix": " 米", "modes": [3],
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_LIVE,
	},
	{
		"key": "coin_reward_rate", "label": "掉落比例", "hint": "掉落金币折算成身高的比例。",
		"kind": "number", "step": 0.1, "suffix": " %", "percent": true, "modes": [3],
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_LIVE,
	},
	{
		"key": "coin_count", "label": "场上金币", "hint": "一局分布多少枚金币。",
		"kind": "number", "step": 1.0, "suffix": " 枚", "integer": true, "modes": [2],
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
	},
	{
		"key": "coin_interval", "label": "金币刷新", "hint": "多久补一波金币。",
		"kind": "number", "step": 0.5, "suffix": " 秒", "modes": [2], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
	},
	{
		"key": "coin_growth_rate", "label": "金币成长", "hint": "吃一枚金币能长多少。",
		"kind": "number", "step": 1.0, "suffix": " %", "percent": true, "modes": [2], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
	},
	{
		"key": "building_growth_rate", "label": "拆楼成长", "hint": "拆一栋楼能长多少。",
		"kind": "number", "step": 1.0, "suffix": " %", "percent": true, "modes": [2], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
	},
	{
		"key": "height_bands", "label": "身高分档", "hint": "按档位限制同时段最高身高。",
		"kind": "toggle", "modes": [2], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
	},
	{
		"key": "band_start", "label": "分档起始", "hint": "第一档的身高。",
		"kind": "number", "step": 1.0, "suffix": " 米", "integer": true, "modes": [2], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
		"requires": {"key": "height_bands", "equals": true},
	},
	{
		"key": "band_step", "label": "分档间隔", "hint": "每档之间差多少。",
		"kind": "number", "step": 1.0, "suffix": " 米", "integer": true, "modes": [2], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
		"requires": {"key": "height_bands", "equals": true},
	},
	{
		"key": "building_respawn", "label": "建筑刷新", "hint": "被拆的楼会不会重新长回来。",
		"kind": "toggle", "modes": [2, 3], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
	},
	{
		"key": "building_respawn_delay", "label": "刷新等待", "hint": "楼被拆后等多久重建。",
		"kind": "number", "step": 1.0, "suffix": " 秒", "modes": [2, 3], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "growth", "apply": APPLY_NEXT,
		"requires": {"key": "building_respawn", "equals": true},
	},

	# --- 复活 ---------------------------------------------------------------
	{
		"key": "respawn_delay", "label": "复活等待", "hint": "巨人倒下后多久复活。",
		"kind": "number", "step": 0.5, "suffix": " 秒", "modes": [2, 3],
		"page": PAGE_GAMEPLAY, "group": "revive", "apply": APPLY_DEATH,
	},
	{
		"key": "respawn_max_height", "label": "复活身高上限", "hint": "复活时随机身高的上限。",
		"kind": "number", "step": 1.0, "suffix": " 米", "modes": [3], "advanced": true,
		"page": PAGE_GAMEPLAY, "group": "revive", "apply": APPLY_RESPAWN,
	},
]


static func page_options(page: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for option in OPTIONS:
		if String(option.get("page", PAGE_GAMEPLAY)) == page:
			result.append(option)
	return result


static func options_for(page: String, mode: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for option in OPTIONS:
		if String(option.get("page", PAGE_GAMEPLAY)) != page:
			continue
		var modes: Array = option.get("modes", ALL_MODES)
		if not modes.has(mode):
			continue
		result.append(option)
	return result


static func find(key: String) -> Dictionary:
	for option in OPTIONS:
		if String(option["key"]) == key:
			return option
	return {}


static func group_title(group: String) -> String:
	for entry in GROUPS:
		if String(entry["id"]) == group:
			return String(entry["title"])
	return group


static func node_name(option: Dictionary) -> String:
	return String(option.get("node", option["key"]))


static func is_percent(key: String) -> bool:
	return bool(find(key).get("percent", false))


static func is_integer(key: String) -> bool:
	return bool(find(key).get("integer", false))
