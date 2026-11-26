# 巨人程序化动作烘焙（原型，未接入正式玩法）

把 `scenes/giant_visual.gd` 里实时程序化的「坐压 / 坐姿待机 / 180° 原地转身」采样成
`giant_actions.res`（AnimationLibrary），可直接给 `AnimationPlayer` 播放，用于过场、
预览或以后的自定义动作系统。

- 重新烘焙：`XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://prototypes/giant_animation_bake/bake_giant_animations.gd`
- 预览：`godot --path . res://prototypes/giant_animation_bake/giant_animation_preview.tscn`
  （`-- --shots` 会写 `build/tmp/shots/*.png`）
- 产物：`giant_actions.res`，四段剪辑 `turn_180 / sit_crush / sit_idle / turn_then_sit`。

注意：
- 烘焙按 Kawaii 默认骨架采样；Hina / Chibi Catgirl 皮肤仍走程序化路径（坐姿贴地依赖各自
  `pelvis_height_ratio`）。
- 只驱动 `Model` 与骨骼，不碰 `CharacterBody3D` 的 transform；转身被折进 `Model` 旋转，
  所以播放时角色碰撞体朝向不变。
- 正式玩法目前仍直接调用 `giant_visual.gd` 的程序化接口，没有引用这个资源；改动作时间轴
  后需要重新烘焙。
- `prototypes/*` 已在两个导出预设中排除，不会进包。
