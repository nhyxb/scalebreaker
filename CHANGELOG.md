# 变更记录（Changelog）

本文档记录《Scalebreaker》（原名《港区警报》，工程目录 `gba`）项目的关键迭代改动、备份位置、回滚方式与验证结果。

---

## 2026-11-26 — 外围历史街区旧程序化方块楼全部切到 Kenney GLB

备份：`backups/20261126_150831_historic_kenney_kits/{scenes/district_expansion.gd,CHANGELOG.md,MEMORY.md}`（改动前副本）。
回滚：

```sh
cp backups/20261126_150831_historic_kenney_kits/scenes/district_expansion.gd scenes/district_expansion.gd
```

### 一、改动（`scenes/district_expansion.gd::_spawn_historic_building()`）

- 按 `historic_style` 补上与 `scenes/district.tscn` 中央 12 栋完全一致的 `intact_scene` + `kit_scale`：`&"dockpress"` → `commercial/building-e`、`6.16`；`&"tidewater"` → `commercial/building-m`、`5.08`；`&"marineworks"` → `industrial/building-s`、`6.55`（`district.tscn` 的 KenneyDockPress/Tidewater/MarineWorks 同一 GLB 路径）。
- `historic_style`、`ruin_floor`（高度图废墟层不变）、`footprint` 槽位与 `batched = true` 全部保留；未映射的 style 会 `push_error`（杜绝再静默回退 `HistoricBuildings.unit_mesh()` 旧方块楼）。
- 几何语义沿既有机制：`damageable.gd::_fit_kit_intact()` 用传入的 footprint 槽位钳制 kit AABB 并把运行时 `footprint` 重写为 kit 实值（碰撞/瓦砾/寻路一致）；`batch_spec()` 键为 GLB 资源路径且不含 `kit_scale`，外围楼与中央同型楼共享同一 MultiMesh，零批次膨胀。

### 二、验证

- 运行时探针（`build/tmp/historic_kit_probe.gd`，headless 实测）：外围历史楼 **154/154 全部带 `intact_scene`**（`without_kit=[]`）；`BATCH_SPECS` 全部键到三个 GLB 路径（building-m 54 / building-e 54 / building-s 46）与中央共批；样本 `DockPressExt_17` 运行时 footprint `(10.1, 5.50, 6.21)`，与中央 DockPress 实值 (10.1×5.5×6.2) 一致；`batched=true`、`historic_style` 保留。
- 合批账单（`scripts/district_stats.gd`，同口径前后对比）：近层 `building/Near_` 由 50 → 48 批次节点（`historic/dockpress`、`historic/tidewater` 两个专属近层键消失、并入 building-e/building-m kit 键），近层 tris 326,407 → 373,871（kit 细节替换单方块细节，仅 +14.5%）；远层与代理层不变。
- 回归：`cargo build/test` **40/40**；8 套 Godot headless **673 项全绿**（playtest 214 / growth 192 / brawl 43 / mode_menu 45 / touch 42 / audio 36 / sit_crush_gameplay 44 / sit_crush 57）；启动校验 `--quit-after 5` 零错误（无 missing Kenney、无未映射 style 报错）。
- 同前一轮收口：真核显旋转帧率按用户指示**跳过、未测（不估算）**；沙盘悬浮修复经用户目视验收「画面正常」。

---

## 2026-11-26 — 修复实机录屏「沙盘悬空/不在桌子上」投影错位：卧室背景 TextureRect 溢出、相机属性同步、变化驱动刷新与接触影增强

备份：`backups/20261126_140922_skybox_float_fix/{scenes/{harbor_skybox.gd,skybox_bedroom.gd},tests/playtest.gd,CHANGELOG.md,MEMORY.md}`（改动前副本）。
回滚：

```sh
cp backups/20261126_140922_skybox_float_fix/scenes/harbor_skybox.gd scenes/harbor_skybox.gd
cp backups/20261126_140922_skybox_float_fix/scenes/skybox_bedroom.gd scenes/skybox_bedroom.gd
cp backups/20261126_140922_skybox_float_fix/tests/playtest.gd tests/playtest.gd
```

### 一、根因（headless 数值复现）

- `scenes/harbor_skybox.gd` 的 `_rect` 未设 `expand_mode`（Godot 4 默认 `EXPAND_KEEP_SIZE`，用 SubViewport 纹理尺寸当控件最小尺寸）。窗口超过 1506×847 时 `DESKTOP_RES_RATIO=0.85` 使 `_sub.size` 超过 1280×720 基准逻辑画布（1920×1080 → 1632×918），`_rect` 被撑大 1.275× 并从画布左上溢出，卧室背景整体放大且光学中心右下偏约 14%，主世界沙盘与卧室书桌完全错位悬空。headless 复现：强制 `_resize(1920×1080)` 后修复前 `rect.size = rect.get_minimum_size() = 1632×918`；修复后 `rect.size = 1280×720 = root.get_visible_rect().size`、最小尺寸归零。
- `_half_flip` 无条件隔帧刷新 + 未设 `process_priority`：快速旋转时卧室背景滞后主相机 1–2 帧，沙盘在桌面上打滑。

### 二、修复（`scenes/harbor_skybox.gd`、`scenes/skybox_bedroom.gd`）

1. `_rect` 补 `expand_mode = EXPAND_IGNORE_SIZE`、`stretch_mode = STRETCH_SCALE`（保留 `PRESET_FULL_RECT`）：任何窗口分辨率与 RES_RATIO 下背景矩形严格等于主视口可见画布，光学中心与主相机 100% 重合。
2. `_sky_cam` 同步 `keep_aspect = cam.keep_aspect`、`h_offset = cam.h_offset * SKY_SCALE`、`v_offset = cam.v_offset * SKY_SCALE`。
3. `_ready()` 设 `process_priority = 100`（主相机当帧更新完后再同步卧室相机）；删除 `_half_flip`，改**变化驱动刷新**：相机位姿/fov/keep_aspect/h-v offset 任一变化当帧 `UPDATE_ONCE`，静止帧零重渲；新增公共 `mark_dirty()`——阶段 3 卧室内的动画内容（坐姿 Yumeka 等）每帧必须调用。
4. `SandboxContactShadow` 接触影峰透明度 0.18 → 0.42（`scenes/skybox_bedroom.gd`）：沙盘木框底边在书桌上有清晰柔和的落地压暗。

### 三、防回归与验证（本轮全部完成；视觉目视未完成项单独声明）

- `tests/playtest.gd::_bedroom_skybox()` 新增两条断言：`expand_mode == EXPAND_IGNORE_SIZE && stretch_mode == STRETCH_SCALE`；强制 `_resize(1920×1080)` 使 `sub.size = 1632×918 > 1280×720` 时 `rect.size` 仍严格等于 `root.get_visible_rect().size`（旧代码此处即为 1632×918 溢出，必红）。
- Rust：`cargo build --locked` 与 `cargo test --locked` **40/40 通过**；Godot 8 套 headless 回归 **673 项全绿**（playtest 214（含新断言）/ growth 192 / brawl 43 / mode_menu 45 / touch 42 / audio 36 / sit_crush_gameplay 44 / sit_crush 57）。
- 变化驱动刷新机制探针（`build/tmp/backdrop_refresh_probe.gd`，Xvfb + llvmpipe，裸 Skybox）：静止 4 帧纹理字节恒定（跳过渲染成立）；连续 4 帧大幅移动每帧字节都变化（**同帧 `UPDATE_ONCE` 连续重赋值有效**，修复了旋转零帧滞后）；停止移动后 3 帧立即稳定。
- 1920×1080（`--resolution 1920x1080` 建窗，`sub=1632×918`，即 bug 触发口径）Xvfb 截图 6 张存 `build/tmp/float_fix_shots/`（renderer=llvmpipe，光栅化结果与硬件一致，仅速度慢）。首轮 1152×648 对照组（sub 未超基准，不构成 bug 条件）存 `build/tmp/float_fix_shots_1152/`，其卧室直出图 05/06 已目视核验：**框底与桌面接触处无缝隙、无悬浮、无墙色/地板漏出**，阴影均匀无污染周边物件。
- **A/B 同机位对照（`build/tmp/float_fix_ab/`，机器侧量化实证）**：同 500 m 巨人、同相机位姿、同 1632×918 触发口径，仅运行时翻转 `_rect.expand_mode` 一个属性：`fixed_*.png`（EXPAND_IGNORE_SIZE＝现行代码）vs `buggy_*.png`（EXPAND_KEEP_SIZE＝旧默认，即实机录屏悬浮错的来源）。本地像素差分（阈值 16/255）：东南俯瞰对全帧 **28.8%** 像素不同（597,685 / 2,073,600），最差 8×8 区域（100% 差异）集中于右上背景带与沙盘边缘带；东墙仰视对（goal 指定视角）全帧 **35.1%**（728,667），最差区域集中于下半背景带。仅背景合成策略一属性之差即改变全帧近三成像素——根因的量化影證。差分热力图随轮归档至 `build/tmp/float_fix_ab/`。
- **目视核验（视觉后端恢复后完成两批 VLM 判读，综合结论如下）**：
  - **A/B 对照（4 张）**：两张成对图里城市前景**逐格完全一致**（差异全部在卧室背景层）；buggy 图呈现背景放大裁切、光学中心偏移、框外衔接错乱——正是实机录屏的悬浮错位；fixed 图背景比例回正、无拉伸/裁切感（VLM 对远景构图下框底接触细节判读为「不可分辨」，与 500 m 远景下接触带仅数像素的几何事实一致，非异常）。
  - **02 北俯瞰**：托盘呈近宽远窄的对称梯形、左右收缩对称，西/北/东三边外桌面色带大致均匀（近侧被画面下缘裁切）；远处背景为北窗+显示器侧影，与「由南向北」一致——**通过**。
  - **04 大幅摆动当帧即拍**：背景已显示北侧内容（北窗+显示器）、无另一朝向残影/拼接缝、横梁水平滚转回正——**变化驱动刷新零滞后的视觉端证据，通过**。
  - **06 卧室直出（1:1 桌面近景）**：VLM 判读「无托盘本体、桌心一块柔边深棕矩形」——与场景结构吻合：卧室世界**只含家具+接触影贴片**（城市/木框在主世界不进此渲染），该「深 1–2 档、柔边、居中」矩形即 0.42 的 `SandboxContactShadow`（0.18 时代同贴片在 979×551 图判读为「似有似无」，现为清晰可辨的落地压暗）——**接触影增强验收通过**。
  - **01 东墙仰视**：下缘框沿不可见系沙盘内低仰角的正常构图（近缘在视锥外）；VLM 对地标方位的「疑点」经机位几何复核（实际朝 +X 正东、仰 24°、北窗在 45° 侧向不入画）判定为提问措辞预设误差，非画面异常——**无实锤待修项**。
  - 如实声明：VLM 对像素级小目标存在判读波动（同图两次成对判读中框脚位置读数不一），**最终目视验收以用户在呈现图像上的确认为准**；发现异常随时按 skill 列待修。
  - **用户验收（2026-11-26）：「画面正常」——全部呈现截图目视验收通过，本条目视觉核验收口。**
- 动态旋转帧率（真核显）按项目显示规范须由**用户在真实桌面**运行（llvmpipe 下长基准被禁止、数据无意义）：`build/tmp/rotation_bench.gd` 已备好（`ab_probe` 同口径：420 帧预热 + 60 帧采样、vsync 关；1280×720 与 1920×1080 两窗口 ABBA 交叉；headless 冒烟 8 段通过）。命令：
  `MESA_LOADER_DRIVER_OVERRIDE=radeonsi timeout 300 godot --path . --resolution 1916x1077 --script res://build/tmp/rotation_bench.gd`
- **用户裁决（2026-11-26）：跳过旋转帧率测试——该项标记「未测（按用户指示跳过，禁止估算）」；`build/tmp/rotation_bench.gd` 与命令保留，日后可随时实机复测。**
- 顺带勘误 MEMORY：`ab_probe.gd` 为 60 帧采样（非 60 秒）。

---

## 2026-11-26 — 新增永久测试规范：视觉/渲染测试一律用隔离虚拟显示，禁止占用用户真实桌面

备份：`backups/20261126_140608_virtual_display_spec/{AGENTS.md,SKILL.md,MEMORY.md,CHANGELOG.md}`（改动前副本；`SKILL.md` 原路径 `.dsh/skills/harbor-alert-workflow/SKILL.md`）。
回滚：

```sh
cp backups/20261126_140608_virtual_display_spec/AGENTS.md AGENTS.md
cp backups/20261126_140608_virtual_display_spec/SKILL.md .dsh/skills/harbor-alert-workflow/SKILL.md
cp backups/20261126_140608_virtual_display_spec/MEMORY.md MEMORY.md
```

### 一、规范内容（`AGENTS.md` + `.dsh/skills/harbor-alert-workflow/SKILL.md`）

- **禁止占用用户的真实桌面窗口**：跑 Godot 渲染截图、探针脚本（含 `tests/gpu_probe.gd`）或任何 GPU 测试时，不得把窗口弹到用户真实桌面（不抢焦点、不挤占平铺窗口）。
- **改用内存中的隔离虚拟显示，先检测再降级**：
  1. 先检测本机是否支持带 AMD Renoir 硬件加速的无头虚拟显示——优先 `xvfb-run` 配 `vglrun -d /dev/dri/renderD128`，或 `weston --backend=headless --use-gl` / `gamescope` 等虚拟 Wayland 显示；开跑前必须验证 `OpenGL renderer` 仍是 AMD Radeon 而非 `llvmpipe`（测核显需 `MESA_LOADER_DRIVER_OVERRIDE=radeonsi`）。
  2. 本机只有纯 `Xvfb`（如 `xvfb-run -a -s "-screen 0 1920x1080x24"`，本机需手动 `Xvfb :97`）时：仅允许**少量帧**的截图与布局验证（命令挂 `timeout`）；**禁止**在掉回 `llvmpipe` 的纯 `Xvfb` 里硬跑长帧率 ABBA 基准，需要真实核显 FPS 时明确提示用户在真实桌面自行运行。
- **纯逻辑与回归测试继续 `--headless`**。
- 落点：`AGENTS.md` 新增「视觉/渲染测试显示规范（永久）」一节，工作流技能条数 4 → 5、`gpu_probe` 的窗口要求指向该规范；SKILL.md 新增第 5 条硬性规范，第 2 条的禁窗/截图条款改为与第 5 条衔接（不矛盾），交付前自查补显示隔离与 FPS 来源两项；`MEMORY.md` 记录本机隔离显示能力实测（见下）。

### 二、本轮实测依据（检测全程未触碰用户真实桌面）

- 工具链：`vglrun`/`weston`/`gamescope`/`xvfb-run` 均未装；`Xvfb`/`glxinfo`/`eglinfo` 可用。`/dev/dri/by-path` 确认 `renderD128`＝AMD（08:00.0）、`renderD129`＝NVIDIA（01:00.0）。
- `DISPLAY= WAYLAND_DISPLAY= timeout 40 eglinfo -B`（surfaceless，不碰真实桌面）：`AMD Radeon Graphics (radeonsi, renoir, ACO, DRM 3.64)`；另有 llvmpipe 设备（LLVM 23.1.5）。
- 纯 `Xvfb`（`Xvfb :97 -screen 0 1920x1080x24` + `DISPLAY=:97 glxinfo -B`）：`OpenGL renderer string: llvmpipe (LLVM 23.1.5, 256 bits)`。
- 纯 Xvfb 内 Godot 4.7.2 窗口探针：`XDG_DATA_HOME="$PWD/build/xdg" DISPLAY=:97 timeout 90 godot --path . --quit-after 5` → exit=0、约 23 s（渲染后端 `gl_compatibility`，日志 `Using Device: Mesa - llvmpipe`）——「少量帧截图/布局验证」路径可行；按新规范未跑任何 FPS 基准。
- 本轮为纯文档/规范改动，无 Rust 与场景代码变更，无需 `cargo build/test` 与 playtest。

---

## 2026-11-26 — 阶段 2 录屏问题修复：移除外海/船礁、主世界微缩沙盘木框、卧室单灯阴影、桌面疏朗化与启动报错治理

备份：`backups/20261126_130550_phase2_diorama_polish/{scenes,scripts,tests,rust/src,project.godot,CHANGELOG.md,MEMORY.md}`（改动前完整源码副本）。
回滚：

```sh
cp -a backups/20261126_130550_phase2_diorama_polish/scenes/. scenes/
cp -a backups/20261126_130550_phase2_diorama_polish/scripts/. scripts/
cp -a backups/20261126_130550_phase2_diorama_polish/tests/. tests/
cp -a backups/20261126_130550_phase2_diorama_polish/rust/src/. rust/src/
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

### 一、移除外围巨型海面与外海模型，龙门吊内缩防出框（`scenes/district.tscn`、`scenes/district.gd`、`scenes/district_expansion.gd`）

- 移除 `scenes/district.tscn` 中原 `3600 × 3600 m` 的 `Water` 节点与 `WaterMesh`/`WaterMaterial`，同步清理 `scenes/district.gd::_resize_land()` 中的 `$Water` 扩容逻辑。
- 移除 `scenes/district_expansion.gd` 中所有位于城市陆地（`half_land`）之外的停泊货轮、渔船、大小邮轮、航道浮标、4 块远海岩石与旧外挂灰海堤（保留陆地内系船柱与船坞内船体）。
- 岸线龙门吊（`_build_waterfront_quays()`）改为向港内朝向（南岸 `PI`、东岸 `-PI/2`）并内缩至 `half_land - 14.0`，内陆集装箱区龙门吊增加边界保护，实机几何审计确认陆地外（除 `SandboxFrame` 外）零网格越界（`outliers = 0`）。

### 二、主世界浅原木微缩沙盘木框对齐桌面 + 默认白雾清零（`scenes/district_expansion.gd`、`scenes/skybox_bedroom.gd`、`scenes/main.tscn`、`rust/src/game.rs`）

- 新增 `district_expansion.gd::_build_sandbox_frame()`：沿 `1418 × 1418 m` 陆地四周合并生成单个 60 三角面的 `SandboxFrame`（`1 draw call`、无碰撞、不挂进 `Scenery` 以防分块裁剪误伤），浅原木色系（`Color(0.73, 0.59, 0.44)`）与卧室书桌自然衔接；木框底面位于 `y = -32.0 m`（1:6667 下对应 `4.8 mm` 托盘厚），框外 360° 完整露出书桌桌面、键盘、显示器、台灯与转椅。
- `skybox_bedroom.gd::_build_sandbox()` 移除卧室侧重复 CSG 木框，避免双包边与 Z-fighting，将 `sandbox_anchor` 精确对齐至 `DESK_TOP + 32.0 * SKY_SCALE`（`0.7548 m`），仅在桌面铺设柔和边缘渐变接触影贴片（`SandboxContactShadow`），任何视角与身高下沙盘木框底面均严丝合缝贴合桌面。
- `scenes/main.tscn` 与 `rust/src/game.rs::view_fog_density()`：在默认及更宽视距下将 `fog_density` 置 `0.0`（保留 `fog_enabled = true` 与既有起止距离语义），彻底消除沙盘木框边缘发光白边；用户手动调低视距（`< DEFAULT_VIEW_DISTANCE`）时自动恢复 `0.85` 边界雾。

### 三、卧室轻量单灯阴影与明暗层次（`scenes/skybox_bedroom.gd`、`scenes/harbor_skybox.gd`）

- 卧室环境光 `ambient_light_energy` 降至 `0.28`，平衡 `WindowSun` 主光能量（`0.76`）与 AGX 曝光（`0.82`），彻底解决 `BG_CANVAS` 合成后向阳桌面/地板过曝与背光墙发灰的“纸片感”。
- 桌面端仅对 `WindowSun` 开启轻量单级正交阴影（`SHADOW_ORTHOGONAL`、`max_distance = 6.0`、`shadow_bias = 0.02`、`shadow_normal_bias = 1.2`、`shadow_blur = 2.2`、`shadow_opacity = 0.56`），`harbor_skybox.gd` 将子视口 `positional_shadow_atlas_size` 置 `0` 避免无谓图集开销；仅 `Shell` 与主要大件家具投射阴影，小饰品与移动端关闭阴影。
- 顺带修复 `harbor_skybox.gd::_resize()` 在窗口动态缩放/平铺时双轴独立夹紧导致 SubViewport 宽高比偏移的问题，改为单标量等比缩放并在 `_process` 中同步检测主视口尺寸，确保任何分辨率下 1:6667 透视零偏差。

### 四、清理 `BearDesk` 并疏朗化桌面布局（`scenes/skybox_bedroom.gd`）

- 移除桌面棱角过重的低模 `BearDesk`（`bear.glb`）。
- 书桌宽度微调至 `1.63 m`（台面仍精确齐平 `0.75 m`），所有剩余桌面物件相对 `21.27 cm` 沙盘边缘向外退开 15–26 cm：`ComputerScreen` 左移至 `x = -0.46`、`LampRoundTable` 右移至 `x = +0.48`、左右音箱外移至 `x = ±0.74`，沙盘正后方 60+ cm 北窗天光完全敞开无遮挡。

### 五、运行时 `ERROR` 排查与修复（`rust/src/game.rs`）

- 修复两类实机运行时 `ERROR`：
  1. `HarborGame::on_notification()` 在 `show_menu()` / `start_round()` / `pause()` / `present()` 期间触发同步系统或场景树通知时偶发 `Gd<T>::bind_mut() failed, already bound` panic：改用 `self.base_mut()` 作用域包裹 `set_pause`、`MapSlot.add_child/remove_child`、`set_mouse_mode` 与 `Interface.call`，安全释放可重入借用锁。
  2. X11 未获焦窗口下调用 `Input::set_mouse_mode(MouseMode::CAPTURED)` 触发 `ERROR: NO GRAB`：改为仅在 `DisplayServer::window_is_focused()` 为真时捕获鼠标，并在 `NOTIFICATION_APPLICATION_FOCUS_IN` 获焦时自动补捕获。

### 六、AMD Renoir 核显 ABBA 实测与四视角目视核验

- 同口径 ABBA 帧率基准（`build/tmp/diorama_fps_bench.gd`，`MESA_LOADER_DRIVER_OVERRIDE=radeonsi`，`gl_compatibility`，`vsync=0`，全图俯瞰 `(0, 620, 980) -> (0,0,0)`，预热 360 帧、每档正反序各 90 帧）：

  | 配置 | 口径（SubViewport / 阴影） | 数据源 | 正序 FPS | 反序 FPS | ABBA 均帧 | 相对无阴影 Δ | Draw Calls | Primitives |
  |---|---|---|---:|---:|---:|---:|---:|---:|
  | 无 Skybox | 禁用 / 关 | `diorama_fps_bench.gd` | 42.9 | 49.8 | 46.4 | +0.1 | 2,637 | 3,156,916 |
  | `0.85` + 2× MSAA（无阴影） | 1629×938 / 关 | `diorama_fps_bench.gd` | 45.4 | 47.2 | 46.3 | +0.0 | 2,646 | 3,157,625 |
  | **`0.85` + 2× MSAA + 单级正交阴影（最终）** | **1629×938 / 开（隔帧）** | **`diorama_fps_bench.gd`** | **45.5** | **47.3** | **46.4** | **+0.1** | **2,652** | **3,158,281** |

- 沿用 `build/tmp/ab_probe.gd`（`1280×720`、`gl_compatibility`、`vsync=0`）单次复测：**50.0 FPS**（worst 50.0，draws 2,644，因移除外海船礁与旧海堤减少 ~42 draw calls）。单级正交阴影实测几乎零掉帧（远低于 3 FPS 阈值），故桌面端保留开启。
- 实机四视角截屏（`build/tmp/diorama_shots/`）逐张核验通过：500 m 东南向斜下俯瞰（可见木框、桌面、门框、衣帽架）、500 m 北向斜下俯瞰（木框、桌面、显示器、北窗无遮挡、零白雾边）、100 m 南向回望（转椅、衣帽架、地板光影立体）、城内低仰角（无小熊、北窗通透），及卧室全景/桌面近景确认窗格阳光投影细腻、零阴影痤疮、零过曝。

### 七、回归验证

- Rust：`cargo build --locked`（零警告）与 `cargo test --locked` **40/40 通过**（新增默认/低视距 `view_fog_density` 断言）。
- Godot（`--headless --fixed-fps 60`，`XDG_DATA_HOME="$PWD/build/xdg"`）：**playtest 212**（已同步校验无 `BearDesk`/无 `Water`/有 `SandboxFrame`）、**growth 192、brawl 43、mode_menu 45、touch 42、audio 36、sit_crush_gameplay 44、sit_crush 57**，合计 **671 项全绿**；`scripts/district_stats.gd` 确认 `SandboxFrame` 仅 1 节点 60 面；`--quit-after 5` 零错误。

---

## 2026-11-26 — 阶段 2 收尾：Kenney 家具卧室替换灰盒、Skybox 去锯齿/防漏缝、椅上超巨锚点与雾色调和

备份：`backups/20261126_110542_phase2_bedroom_furniture/{scenes,scripts,tests,rust/src,project.godot,CHANGELOG.md,MEMORY.md}`（改动前完整源码副本）。
回滚：

```sh
cp -a backups/20261126_110542_phase2_bedroom_furniture/scenes/. scenes/
cp -a backups/20261126_110542_phase2_bedroom_furniture/scripts/. scripts/
cp -a backups/20261126_110542_phase2_bedroom_furniture/tests/. tests/
cp -a backups/20261126_110542_phase2_bedroom_furniture/rust/src/. rust/src/
rm -rf assets/kenney/furniture
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
godot --headless --path . --editor --import
```

### 一、SubViewport 去锯齿与卧室壳体密封（`scenes/harbor_skybox.gd`、`scenes/skybox_bedroom.gd`）

- **去锯齿**：`harbor_skybox.gd` 将子视口分辨率比例由 `0.4` 提升为桌面端 `DESKTOP_RES_RATIO = 0.85`（移动端保留 `MOBILE_RES_RATIO = 0.55`），显式设置 `_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR`，桌面端开启轻量 `Viewport.MSAA_2X`（移动端保持关闭），保持隔帧 `UPDATE_ONCE` 渲染并在尺寸变化时立即触发一帧刷新；同时收紧卧室相机 `near = 0.005 / far = 20.0` 避免低眼位近裁桌面。
- **壳体接缝修复与建筑细节**：
  - 修复旧版北墙 CSG 减法开窗的局部坐标偏移缺陷（原窗洞误偏至天花板）及左右窗框对称符号错误；改用 4 块相互重叠的实心墙体板围合精确窗洞（宽 1.84 m × 高 1.28 m，窗台高 0.94 m），地板与天花板外延覆盖四面墙底/顶，彻底消除低仰角墙角与家具底部的细白漏缝。
  - 补齐 8 cm 浅原木简约踢脚线（嵌地 5 mm、沿门洞自动分段）、立体淡木窗框/内窗台/双开奶油窗扇与玻璃、东墙奶油色卧室门与门套把手。
  - 房高收敛至 2.60 m，北墙紧靠书桌后沿（`z = -0.54 m`），城内低仰角抬头即可见明窗与桌面巨物轮廓。

### 二、柔和日系奶油 + 浅原木材质与灯光（`scenes/skybox_bedroom.gd`）

- 替换偏灰暗颗粒感的 `wall_plaster` 墙面为干净低饱和浅奶油暖白哑光墙（`Color(0.945, 0.916, 0.862)`）与柔白顶面；地板基于现有 `floor_wood_diff.jpg` 经轻量 `ShaderMaterial` 提亮为柔和浅原木木地板（保留细微木板纹，兼容 `gl_compatibility`）；窗框/踢脚线/沙盘外框统一为低饱和浅原木色。
- 灯光调整为北窗暖日照（`WindowSun`，无阴影）+ 室内柔反光（`InteriorBounce`，无阴影）+ 吊灯柔补光（`CeilingFill`，无阴影）+ AGX 色调映射（`exposure = 1.0`），柔和明亮、立体感清晰且不过曝，与 Kenney 城市及二次元角色风格统一。

### 三、Kenney Furniture Kit 21 件真实 GLB 替换全部灰盒 + 椅上超巨锚点

- 从 `kenney_furniture-kit.zip` 的 `Models/GLTF format/` 仅提取 21 个 `.glb` 至独立目录 `assets/kenney/furniture/`（零 OBJ/FBX/Previews，不触碰其他包的 `colormap.png`），并同步更新 `scripts/fetch_kenney_assets.py`：
  - 书桌与转椅：`desk.glb`（精确缩放使台面齐平 `DESK_TOP = 0.75 m`）、`chairDesk.glb`（`1.95×`，坐面高 `0.4553 m`）。
  - 环绕 `21.27 cm × 21.27 cm` 沙盘外沿的桌面近景地标：`computerScreen.glb`、`computerKeyboard.glb`、`computerMouse.glb`、`lampRoundTable.glb`（柔暖自发光灯罩）、`books.glb`、`bear.glb`、`plantSmall1.glb`、`speakerSmall.glb`（左右立体声成对）。
  - 卧室背景大件：`bedDouble.glb`、`pillow.glb`、`pillowLong.glb`、`cabinetBedDrawer.glb`、`bookcaseOpen.glb`（隔板放书与绿植）、`bookcaseClosedDoors.glb`、`rugRounded.glb`、`pottedPlant.glb`、`lampSquareCeiling.glb`（齐顶贴合 `y = 2.60 m`）、`trashcan.glb`、`coatRackStanding.glb`。
- 全部家具纯视觉实例化（`_prepare_visual_subtree()` 确保零 `CollisionObject3D` 碰撞体、关闭投影开销），通过精确 AABB 对齐落地/贴台面/齐顶，并对偏艳红的 `carpet` 材质做柔和日系奶茶/杏粉/燕麦色调和。
- 在 `chairDesk.glb` 坐垫正上方导出并挂接 `ultra_giant_anchor: Node3D`（世界坐标 `(0.0, 0.4553, 0.5484)`，记录 `ultra_giant_seat_y = 0.4553` 与元数据 `seat_y`，水平正对 `sandbox_anchor` `-Z` 方向），同时透出为 `harbor_skybox.gd::ultra_giant_anchor`，供阶段 3 直接挂接高精细度坐姿 Yumeka。

### 四、海雾色与起止距离调和（`scenes/main.tscn`、`rust/src/game.rs`）

- `scenes/main.tscn` 的海雾与天空地平色由偏冷青灰（`Color(0.66, 0.73, 0.73)`，`fog_density = 1.0`，`fog_aerial_perspective = 0.75`）调和为暖日光柔雾（`fog_light_color = Color(0.89, 0.87, 0.83)`、`fog_density = 0.68`、`fog_aerial_perspective = 0.15`、`fog_depth_curve = 1.45`），消除港区海雾与奶油卧室背景的生硬色差。
- `rust/src/game.rs::view_fog_bounds()` 在默认及以上视距的大地图下将雾起止比例由 `0.30 / 0.55` 调整为 `0.52 / 1.12`（1,418 m 港区约 `737 / 1,588 m`），并增加随相机高度放宽的裕度（`+0.45h / +0.85h`），确保 500 m 巨人俯瞰全图时整座城市清晰锐利不被近距雾糊住；低于默认视距时的原有设置语义与断言完全保留。

### 五、实机 GPU 帧率复测与目视核验（AMD Renoir 核显）

- 同口径 ABBA 交叠基准（`build/tmp/sky_fps_bench.gd`，`MESA_LOADER_DRIVER_OVERRIDE=radeonsi`，窗口 `1916×1104`，`gl_compatibility`，`vsync=0`，全图俯瞰 `(0, 620, 980) -> (0,0,0)`，预热 360 帧、每档正反序各测 90 帧）：

  | 配置 | 子视口分辨率 | MSAA | 正序 FPS | 反序 FPS | ABBA 均帧 | 相对无 Skybox Δ | Draw Calls（均值） | Primitives（均值） |
  |---|---|---|---:|---:|---:|---:|---:|---:|
  | 无 Skybox | — | 关闭 | 46.2 | 46.9 | 46.6 | +0.0 | 2,679 | 3,151,792 |
  | 旧 `0.40` 无 MSAA | 766×442 | 关闭 | 46.3 | 46.2 | 46.3 | -0.3 | 2,689 | 3,152,588 |
  | `0.75` + 2× MSAA | 1437×828 | 2× | 43.3 | 42.1 | 42.7 | -3.9 | 2,690 | 3,152,596 |
  | **`0.85` + 2× MSAA（最终）** | **1629×938** | **2×** | **47.4** | **43.1** | **45.2** | **-1.3** | **2,690** | **3,152,632** |
  | `1.00` 无 MSAA | 1916×1104 | 关闭 | 46.3 | 47.0 | 46.6 | +0.1 | 2,691 | 3,152,665 |
  | `1.00` + 2× MSAA | 1916×1104 | 2× | 45.2 | 44.5 | 44.9 | -1.7 | 2,690 | 3,152,608 |

- 沿用既有 `build/tmp/ab_probe.gd`（同窗口 `1916×1104`、`gl_compatibility`、`vsync=0`）单独复测 `0.85 + 2× MSAA`：首次较冷状态 **48.2 FPS**（worst 48.0，draws 2,686），连续热态 43.7 FPS；最终收敛在 **`DESKTOP_RES_RATIO = 0.85` + `Viewport.MSAA_2X` + 隔帧**，相对无 Skybox 仅约 `-1.3 FPS`（-2.8%）。
- 实机截屏目视核验（`build/tmp/sky_phase2_final/` 与 `build/tmp/sky_phase2/04_giant500_overview.png`）：城内低仰角北向/南向、500 m 巨人俯瞰、全图高空俯瞰及卧室/桌面近景均确认无窗框或家具阶梯锯齿、无墙底/墙角白缝、21 件家具落地贴台面无穿模悬空、雾与卧室背景柔和过渡且 500 m 全图清晰。

### 六、回归验证

- 资源导入：`godot --headless --path . --editor --import` 成功导入全部 21 个家具 GLB。
- Rust：`cargo build --locked` 通过；`cargo test --locked` **40/40**（含新增 500 m 巨人高空雾距断言）。
- Godot（`--headless --fixed-fps 60`，`XDG_DATA_HOME="$PWD/build/xdg"`）：**playtest 212**（新增 4 项卧室 Skybox、零碰撞与 `ultra_giant_anchor` 回归）、**growth 192、brawl 43、mode_menu 45、touch 42、audio 36、sit_crush_gameplay 44、sit_crush 57**，合计 **671 项全绿**；`--quit-after 5` 启动校验零错误。

---

## 2026-11-26 — 踩踏蓄力卡墙缺陷修复 + 阶段 2 第一步：桌面沙盘 3D Skybox 卧室壳体

备份：`backups/20261126_013057_stomp_pivot_bedroom_skybox/{scenes,scripts,tests,rust/src}`（改动前完整源码副本）。
回滚：

```sh
cp -a backups/20261126_013057_stomp_pivot_bedroom_skybox/scenes/. scenes/
cp -a backups/20261126_013057_stomp_pivot_bedroom_skybox/scripts/. scripts/
cp -a backups/20261126_013057_stomp_pivot_bedroom_skybox/tests/. tests/
cp -a backups/20261126_013057_stomp_pivot_bedroom_skybox/rust/src/. rust/src/
rm -f scenes/harbor_skybox.gd scenes/skybox_bedroom.gd
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
godot --headless --path . --import   # 移除 assets/textures/polyhaven/ 亦可
```

### 一、卡墙缺陷：踩踏蓄力/冷却期间按住前进会取消原地转身（`rust/src/round.rs`）

- 修复内容（按 MEMORY 预存缺陷条目的处方"重排 update_giant 的 pivot 判定"）：
  1. **pivot 标志跨蓄力存活**：按下踩踏（pending/Windup）与冷却期间不再每帧清除 `standing_pivot_active`，只有松开方向输入才取消原地转身；蓄力中按前进即登记 pivot，蓄力结束/取消后从剩余角度无缝续演（不再要求 >55° 重新入场）。
  2. **被墙挡住的行走改判为站立（限蓄力/冷却）**：`was_walking` 在解锁阶段保持原"输入意图"语义（AI 漫游完全不变），蓄力/冷却期间改按实际位移判定（`actual_travel < 0.35 × requested` 即站立），贴墙按住前进的巨人恢复原地转身资格。
- 红→绿验证：巨人出生点投放到北边界墙（胶囊贴墙、面墙）→ 蓄力踩墙 → 蓄力中按住前进 → 冷却中甩视角 180°：修复前 `get_turn_telemetry()` 全程 `walk_sharp_turn`（standing_turning 从未出现，只能蟹行）；修复后先进入 `standing_turn` 原地转身再迈步离墙 >15 m。
- **测试规避移除**：`tests/playtest.gd` 的 Tidewater4 塔瞄准段原先直接 `giant.rotation = ...` 设身体朝向（规避本缺陷），改为"视角对齐 + 按住方向自然转身收敛到 |Δyaw| < 0.05"（新断言）；另新增回归测试 `_stomp_charge_pivot()`（面墙蓄力按前进 → 原地转身 → 离墙）。playtest 206 → **208** 项。
- 修复过程返工记录：初版把"被挡＝站立"扩展到所有阶段，曾误伤大乱斗 12 m AI 漫游（贴楼拐小碎步窗口吃掉 90 帧位移断言，brawl 43→42）；收缩回蓄力/冷却范围后全绿。

### 二、桌面沙盘 3D Skybox：1:1 卧室 + 1:6667 双相机（阶段 2 第一步）

- 架构：`scenes/harbor_skybox.gd` 在 `main.tscn` 根挂"Skybox"节点——SubViewport（`own_world_3d`）里放 1:1 卧室（`scenes/skybox_bedroom.gd` 程序化生成），主视口 `Atmosphere` 改 `BG_CANVAS`，用 `CanvasLayer(-64) + TextureRect` 把卧室合成在 3D 之后、UI 之下。**顶层仍是 1:1 港区，玩法零改动**。
- 三行位姿同步（`_process` 内）：`sky_cam.global_transform = anchor.global_transform * Transform3D(camp.basis, camp.origin * (1/6666.67))`，加一行 fov 复制。1,418 m 见方 ↔ 沙盘 21.27 cm（书桌中央托盘内膛精确 0.2127 m，`SANDBOX_SIDE` 常量）；1 m : 0.15 mm。
- 卧室壳体：CSG 搭墙/地板/天花板/窗（CSGBox 减法开洞 + 7 cm 木质窗框/窗台/玻璃/中梃），全部 `CSGCombiner3D` 合并成单 mesh；Poly Haven CC0 贴图（`plastered_wall_02` 墙+天花板、`floor_wood` 地板+木框，均 1k jpg diffuse+roughness，存 `assets/textures/polyhaven/`）；家具为尺寸正确的灰盒占位：书桌 1.4×0.68 m×高 0.75 / 椅 / 床 0.9×2.0 m / 书架 0.9×1.9 m，家具美术风格待后续轮。
- 隔离与光照：卧室自带 WorldEnvironment（AGX、仅环境光+平行光**无阴影**、窗外天色 BG_COLOR）。海雾只作用于主世界几何、canvas 背景不受雾影响（**海雾不能遮住卧室**）；卧室灯光在子视口自己的世界（**卧室光照不能过曝港区**）——两条由架构保证，视觉复核确认：港口无过曝死白、无雾盖卧室、无明显接缝锯齿。
- 性能（交叠 A/B 同口径：本机 AMD Renoir 核显 `MESA_LOADER_DRIVER_OVERRIDE=radeonsi`、窗口 1916×1104、gl_compatibility、vsync off、同一二进制，只换 `main.tscn` 的 Skybox 节点有无，`tests/gpu_probe.gd` 补充的 `build/tmp/ab_probe.gd` 只测全图俯瞰）：
  | 轮次 | 无 Skybox | 有 Skybox | Δ |
  |---|---:|---:|---:|
  | 1（0.66 满帧率） | 54.7 | 50.7 | -4.0 |
  | 2（0.5 + CSG合批） | 52.1~55.8 | 41.9~51.1 | -4.6 |
  | 3（0.5 + 隔帧） | 55.0 | 51.5 | -3.5 |
  | 4（**0.4 + 隔帧**，最终） | **55.9** | **52.2** | **-3.7** |
  - 结论：全图俯瞰 **52.2 vs 同会话基线 55.9（-3.7，约 -7%）**。隔帧渲染（UPDATE_ONCE 每两帧）与子视口 0.4 比例为最终配置，窗光阴影 pass 已删（背景看不出来）。
  - 诚实口径声明：**今晚核显热漂移严重**——同一份无 Skybox 基线代码，逐次复测 50.8 / 52.1 / 54.7 / 55.0 / 55.9 FPS（历史记录的 61 是白天较冷状态，今晚复测基线自身就低约 10%）；故前后对比以同一时段交叠 A/B 为准。
- 视觉复核两轮后的已知问题（满足"最多两轮"约定，不再打磨）：低出生眼位时卧室背景多呈整片浅暖墙面（站在托盘底部的几何事实），室内元素辨识度低；海雾色与墙面色未逐色调和；子视口 0.4 比例远景细节偏糊。后续可做：降房高、加大窗占比、增加可见家具轮廓、雾色微调。

### 三、新增资产

- `assets/textures/polyhaven/`：`wall_plaster_{diff,rough}.jpg`、`floor_wood_{diff,rough}.jpg`、`ceiling_plaster_{diff,rough}.jpg`（Poly Haven，CC0，1k jpg）。天花板贴图未用（改用 wall_plaster 调亮）但保留备用。

### 四、验证

- Rust：`cargo build --locked` 通过；`cargo test --locked` **40/40**。
- Godot（`--headless --fixed-fps 60`，XDG_DATA_HOME 指向工程内）：**playtest 208、growth 192、brawl 43、mode_menu 45、touch 42、audio 36、sit_crush_gameplay 44、sit_crush 57**，合计 667 项全过；`--quit-after 5` 启动校验无脚本错误。

### 五、云盘纯源码包同步与云盘时间口径修正

- `scripts/sync_drive.sh` 已执行：`gdrive:gba-sync/gba_code_latest.tar.gz` 766,310 字节，`rclone lsl` 显示 **2026-11-26 02:39:40**（北京时间；本地时钟 02:39:51 复核吻合）。纯源码，不含 `assets/`、`.godot/`、`rust/target/`、APK、`backups/`。
- **口径修正（回应"上次 21:57 UTC 对不上"）**：`rclone lsl` 输出的时间戳是**本机时区（Asia/Shanghai，北京时间）**，不是 UTC。上次把 rclone 读数标成 "21:57 UTC" 属时区标注错误——正确读法是"北京时间 21:57"。今后报云盘版本时间一律直接报北京时间。

---

## 2026-11-26 — GitHub 公开仓库：nhyxb/scalebreaker（首次 git 化）

- `git init` + `gh repo create scalebreaker --public --source . --push`：**https://github.com/nhyxb/scalebreaker**（main 分支，初始提交 `4f7f0f2`，本地一次推送完成）。提交身份 `nhyxb <nhyxb@users.noreply.github.com>`（仓库本地配置，不动全局）。
- **上传内容口径**（回应"排查哪些没必要上传"）：源码全量（`rust/src`、`scenes`、`tests`、`scripts`、`prototypes`、`project.godot`、`export_presets.cfg`、`default_bus_layout.tres`、文档四件）**加 `assets/` 全量**（238M / 732 文件，最大单文件 <40M；Kenney 与 Poly Haven 均 CC0，VRoid 样例已按新许可重打包）。
- **不上传**（进 `.gitignore`，均已在排除清单验证零泄漏）：`rust/target/`（4.0G）、`build/`（719M，含 APK）、`backups/`（1.8G）、`.godot/`（430M 导入缓存）、`gba_source_20251125.tar.gz`（159M，`*.tar.gz` 通配）、`native/*.so`（桌面 113M + 安卓 6M 二进制，保留 `harbor.gdextension` 清单）、本机工具目录 `.aws/.codex/.agents/.dsh`。
- 安排查：`export_presets.cfg` 无 keystore 口令（签名配置在 Godot 编辑器本机设置）；源码 secret 扫描（token/key/password 模式）只命中 `coins.gd` 的游戏内"token"变量名，无凭据；`.aws/.codex/.agents` 均为空目录。
- 推送后 `gh repo view` 确认：PUBLIC、main 已推、origin 指向 github.com/nhyxb/scalebreaker。

---

## 2026-11-26 — 项目更名为 Scalebreaker（中文名待定）

- 玩家可见名称：`project.godot` 的 `application/config/name`（同时是窗口标题与桌面应用名）、主菜单大标题（`scenes/interface.gd::_menu_title`，原本显示“选择模式”）、首页入口（`HarborEntry` 的标签，原“港区警报”改为“港区模式”）、港区分页标题、`export_presets.cfg` 的 Android `package/name`，全部改为 **Scalebreaker**。
- 主菜单大标题是拉丁文、比原先的中文页名宽得多，新增 `_set_menu_title()` 按 428 px 目标自适应字号（76 → 约 58），实测标题最小宽度 434 px，仍落在 442 px 菜单列内，不再把菜单面板撑宽。
- **刻意不改**（避免引用与旧存档失效）：`org.gba.harboralert` 包名、`assets/harbor-alert-icon.png` 等内部路径、Rust crate 名 `harbor`、GDScript `class_name`、`user://` 存档路径与配置键、`.dsh/skills/harbor-alert-workflow` 技能名、`scripts/build_android.sh` 与 `native/harbor.gdextension`；`README.md` / `PLAN.md` 作为历史文档保留旧名，改名记录以本条为准。
- 验证：`cargo test` 40/40、Godot 8 套共 665 项全过（`playtest` 206、`growth_playtest` 192、`brawl_playtest` 43、`mode_menu_playtest` 45、`touch_playtest` 42、`audio_playtest` 36、`sit_crush_gameplay_playtest` 44、`sit_crush_playtest` 57）；测试只按节点名（`HarborEntry`）取菜单入口，不依赖标题文本。

---

## 2026-11-26 — 阶段 1.5：瓶颈治理、全局合批、全图建筑常驻、中心 12 栋换模、第三人称相机重做

备份：`backups/20261126_000904_phase15_batching_camera/{scenes,scripts,tests,rust/src}`（改动前的完整源码副本，取自云盘 2026-11-25 21:48 的纯源码包，已剔除 `rust/target`）。
回滚：

```sh
cp -a backups/20261126_000904_phase15_batching_camera/scenes/. scenes/
cp -a backups/20261126_000904_phase15_batching_camera/scripts/. scripts/
cp -a backups/20261126_000904_phase15_batching_camera/tests/. tests/
cp -a backups/20261126_000904_phase15_batching_camera/rust/src/. rust/src/
rm -f scenes/district_batches.gd tests/gpu_probe.gd
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

### 一、先出账单：千万面与 2,117 个 MultiMesh 的来源（`scripts/district_stats.gd`）

- 统计脚本扩展为按 `Roads / Lots / Scenery / Targets / Batches / BuildingBatches` 分区输出节点数、`MeshInstance3D` 数、`MultiMeshInstance3D` 数、实例数、表面数、三角面，并输出占用三角面前 12 的资产（MultiMesh 由生成器写入 `asset` 元数据，因此账单能指名到 `road/RoadCross` 这一级），另加 `draw_items` 口径（每个网格表面与每个 MultiMesh 表面各算一次提交）与分片度（`avg_instances_per_multimesh`）。
- 结论：**道路是最大头**——850 个 `MultiMeshInstance3D`（108 m 分块 × 4 种瓦片 × 每种瓦片多个表面），14,882 个瓦片实例，**8,775,522 面**，占全图 12,242,673 面的 72%；其中 1,361 个十字路口 × 4,562 面 = 620 万面。碎片化原因就是 `_batch_mesh()` 按 `RENDER_CHUNK_SIZE = 108 m` 切块。

### 二、道路：878 万面 → 209 万面，850 个节点 → 4 个

- 关键事实：`assets/district/roads/*.glb` 的单块瓦片 353–4,562 面，其中**七成是坡化人行道顶面的碎三角面**（十字路口：人行道 2,752 面里 2,320 面小于 5 cm²）。实测任何"面积/朝下/埋深"裁剪阈值都无法既保形又降面（0.05 m² 阈值会把整条人行道打成筛子），所以最终方案是**换几何、保贴图**：
  - 沥青 → 每块一个 12×12 m 平板（2 三角面），UV 用平面投影 `xz/3`，仍用原 `MAT_Road_Asphalt` 贴图；
  - 人行道 → 按原瓦片**顶面 1 m 栅格重建**（`_append_pavement()`：把朝上三角面栅格化取每格最高点，再发 1×1 m 方块），保留原轮廓（直道带、路口四角），贴图仍用原 `MAT_Formed_Concrete`，UV `xz/3`；
  - 斑马线、车道虚线、路口横实线、转角黄漆、排水沟、井盖**全部沿用原几何**（按面积 ≥ `ROAD_MIN_AREA = 0.002 m²` 与**顶点法线**朝向裁剪）。
- 实现要点：判断"面朝哪边"必须用**作者写入的顶点法线**，不能用几何叉积——这套 GLB 的三角形绕序与叉积方向相反，第一版用叉积判断，结果把可见路面全当背面删掉（道路整片消失，视觉子代理复核抓出）。
- 单块瓦片面数（`_road_tile_mesh` 输出，同口径）：Straight 353 → **148**（5,920 块共 876,160 面）、Cross 4,562 → **436**（1,361 块共 593,396 面）、Tee 3,020 → **350**（156 块共 54,600 面），Bend90 1,440 → **112**。
- `_batch_mesh()` 改为**全图一个 MultiMesh**（节点在 District 原点、实例用绝对变换），道路变成 4 个节点；`micro_ground` 高度压缩上限收紧到 0.0015，仍满足小图"路面低于地面但不相交"的既有断言。
- 结果：道路三角面 **8,775,522 → 1,525,076（-83%）**，`MultiMeshInstance3D` 850 → 4。

### 三、全局合批 + 建筑三态 MultiMesh（全图常驻可见）

- **小件全部全局合批**：树木、路灯、车、系船柱各 1 个 MultiMesh，统一挂在新的 `District/Batches` 节点下（不再被 `district.gd` 的 108 m 分块裁剪误伤）；地块铺装从 443 个分块节点降到 7 个。`MultiMeshInstance3D` 总数 **2,117 → 78**。
- **建筑改由 `scenes/district_batches.gd` 三层渲染**（1,566 栋可破坏建筑）：
  - 近层：每种 kit 型号一个 MultiMesh，只放相机 `NEAR_RADIUS = 280 m` 内的建筑；相机移动超过 `REFILL_STEP = 40 m` 才重排，远层实例变换只写一次、跨界时只做“置零/还原”。
  - 远景层：`commercial/low-detail-building-*`（88–378 面，已补进 `scripts/fetch_kenney_assets.py` 从本地缓存 zip 提取 10 个）+ 一个同主色极简盒代理；每个代理一个 MultiMesh，`cast_shadow` 关闭，用逐实例颜色区分楼体。
  - 废墟层：一个共享低面瓦砾堆 MultiMesh，逐实例按 `footprint` 缩放、用 `ruin_color` 上色。
- `scenes/damageable.gd` 新增 `batched`：受击开裂走逐实例染色（不再叠材质 overlay、不再逐栋抖动）；倒塌时先在两层 MultiMesh 里清零该实例、再建临时 `CollapseModel` 播 3.5 秒动画、倒完切废墟层；`restore_building()` 反向恢复（清废墟、按当前距离放回近/远层）；被抓起时临时实例化模型。离相机很远的建筑倒塌只更新碰撞与废墟层，不建倒塌模型。
- **取消建筑/摩天楼/储罐/货轮/道路的 200 m / 300 m 隐藏**：`district.gd` 只对 `Scenery` 里的独立小件（遮阳篷、花盆、伞、储罐、烟囱、龙门吊等）继续按相机距离裁剪，`Targets` 不再参与分块隐藏，建筑全图常驻可见。

### 四、中心 12 栋旧核心建筑统一换成 Kenney 模型

- `scenes/district.tscn` 的 12 栋 `DockPress / Tidewater / MarineWorks` 加 `intact_scene`：DockPress → `commercial/building-e`（`kit_scale = 6.16`）、Tidewater → `commercial/building-m`（`5.08`）、MarineWorks → `industrial/building-s`（`6.55`）。
- 节点名、位置、`footprint` 语义、`ruin_floor`（仍用 `assets/district/ruin_collision/*.tres` 的可步行高度图）、`historic_style`（废墟外观仍走 `historic_buildings.gd` 的瓦砾网格）与 48 m 小图 `_fit_core()` 的适配逻辑全部保留；`footprint` 由 `_fit_kit_intact()` 按真实模型 AABB 改写（DockPress 10.1×5.5×6.2、Tidewater 6.3×16.0×6.3、MarineWorks 13.9×5.5×6.0），碰撞体、AI 寻路与测试用的是同一份尺寸。
- 外层街区的 166 栋红砖历史楼也并入三层 MultiMesh（仍用 `historic_buildings.gd` 的单位网格按 `footprint` 缩放；废墟仍生成自己的瓦砾节点），`Targets` 下的独立网格节点从 2,040 降到 21（12 栋核心 + 灯塔 + 雷达）。

### 五、海雾外推与巨人远距代码降级

- `scenes/main.tscn` 里写死的 252–435 m 近距海雾改为 1,418 m 地图的外圈值（425/780 m，只作首帧与菜单底图），运行时仍由 `sync_view_fog()` 按当前 `map_side` 与视距重算。
- `rust/src/game.rs` 的 `view_fog_bounds()` 增加地图地板：视距 ≥ 出厂默认（桌面 300 / 安卓 200）时，雾起点/终点取 `map_side × 0.30 / 0.55`；1,418 m 图 = **425 m 起雾、780 m 全雾**（原 252–435 m）。低于默认视距时仍严格按用户设置（原有“视距变小、雾更近”的设置语义不变，旧断言仍成立）。
- `scenes/giant_visual.gd` 新增 `set_detail_tier(0/1/2)`：tier 1 关闭自身实时阴影并跳过头发/狐尾二级弹簧，tier 2 再隐藏眼睛/眼线/睫毛/眉/鼻线等零碎子网格；第一人称的“头部只投影”状态不会被覆盖。阈值在 `round.rs::update_distant_silhouettes()` 里按体型缩放（`max(180, height×1.2)` / `max(240, 上一档×2.2)`），骨骼姿态降频沿用既有 `animation_stride`（2–3 帧）。

### 六、第三人称相机重做（`rust/src/round.rs`）

- 删除 `GIANT_CAMERA_MAX_LENGTH = 76.0`、46 m 焦点上限与 7 m 脚部高度上限：焦点高度 = `0.55 × height`，默认臂长 = `1.30 × height`，**500 m 巨人 → 焦点 275 m、臂长 650 m**（旧值 46 m / 76 m，镜头埋在双腿里）。
- 鼠标滚轮平滑缩放（`0.45×–3.0×`，`camera_zoom_target` 指数趋近），臂长与 `near` 同步跟随。
- `V`（含触屏切换按钮）改为三态循环：**第三人称全身 → 第三人称斜侧跟脚（相机在左脚斜前外侧 45°、`FOOT_VIEW_LENGTH_RATIO = 0.62 × height`）→ 第一人称**；跟脚模式接管朝向（玩家朝向被存下，退出时原样恢复），绝不落在两腿正中间。
- 视锥：`camera.far = max(2500, world_limit × 4.4 + height × 3)`（1,418 m 图约 4,600 m），`camera.near = clamp(arm × 0.005, 0.09, 5.0)`；小体型成长模式仍保留 0.037 m 焦点地板。
- 近身防遮挡：当臂长 < `0.20 × height` 时焦点自动从 `0.55 × height` 抬到 `0.82 × height`，拉近不再糊满大腿。
- 新增 `camera_view_mode()` / `set_camera_view(mode)` 供触屏与测试使用。

### 七、同口径数据对比

1. 几何账单（口径：headless、无渲染器、`srcs/district_stats.gd` 全展开扫描；三角面 = 索引/3，MultiMesh 按 `instance_count` 展开）：

| 指标 | 改动前 | 改动后 |
|---|---:|---:|
| 全图三角面 | 12,242,673 | 3,533,635 |
| `MultiMeshInstance3D` | 2,117 | 78 |
| `MeshInstance3D` | 4,672 | 2,653 |
| 渲染实例 | 26,775 | 19,108 |
| 道路三角面 | 8,775,522 | 2,087,764 |
| 建筑近层/远层/废墟三角面（相机在出生点） | —（逐栋 2,484,705） | 约 33 万 / 约 11 万 / 0（未倒塌） |
| `Targets` 下独立网格节点 | 2,040 | 21（12 核心 + 灯塔 + 雷达） |
| `Targets` 下三角面 | 2,484,705 | 25,544 |
| 构建耗时（`start_mode(true)`） | 291.9–299.7 ms | 289–300 ms |
| 中心 12 栋单栋面数 | 约 100（历史低模） | 1,509 / 3,740 / 876 |

2. 实机 GPU（口径：`tests/gpu_probe.gd`；两台次都用**同一窗口尺寸 1916×1104**（改动前那次数值由旧源码 + 旧 `libharbor.so` 跑同一脚本取得，脚本未改动）、`gl_compatibility`、vsync 关闭、预热到连续 30 帧 ≥ 26 FPS 后每个视角测 48 帧；数据源为 Godot `Performance` 监视器）：

| 视角 | 指标 | 改动前 | 改动后（道路修复后，两次采样） |
|---|---|---:|---:|
| 出生点第三人称 | FPS | 80.9 | 63.7 / 64.6 |
| 出生点第三人称 | Draw Call | 965 | 464 / 467 |
| 出生点第三人称 | 引擎上报 prims | 767,156 | 2,660,379 / 2,662,354 |
| 高空俯瞰全城（全图建筑可见） | FPS | 32.5 | 61.0 / 62.0 |
| 高空俯瞰全城 | Draw Call | 9,077 | 2,673 / 2,675 |
| 高空俯瞰全城 | 引擎上报 prims | 4,152,825 | 2,588,871 / 2,588,871 |
| 出生点 + 强制全 chunk（`district_draw_distance = 4000`） | FPS | 42.1 | 42.0 / 42.0 |
| 出生点 + 强制全 chunk | Draw Call | 2,492 | 1,205 / 1,214 |

- 读法：**全图常驻可见这一最坏情形从 32.5 FPS 提到约 61 FPS（+88%）、Draw Call 从 9,077 降到 2,674（-71%）**；出生点视角 FPS 从 80.9 降到约 64（-20%），代价是把原本 300 m 外被裁掉的道路/远层建筑/小件全部纳入绘制（道路本身从 878 万面降到 209 万面），Draw Call 同时从 965 降到 466（-52%）。`prims` 一列只作相对参考：引擎把 MultiMesh 只按一份实例计入，所以新实现（几乎全是 MultiMesh）在 `prims` 上反而"变大"，真正的三角面口径看上面第 1 张表。
- 两处需要说清的口径限制：① 探针在同一进程内按顺序测多组，越靠后的组越受累积状态影响（同一视角末尾复测会比首测低 20%~25%，本次改动前后都按"首次测量"取值并各自复测一次），因此表中给两次采样；② 本机窗口被 WM 最大化到 1916×1104，早期 956×1158 的采样与本次不可比，故重新采了改动前基线。

### 八、验证

- Rust：`cargo build --locked …` 通过；`cargo test --locked …` **40 项全过**（含新增的雾距单元测试）。
- Godot（全部 `--headless --fixed-fps 60`，`XDG_DATA_HOME=$PWD/build/xdg`）：`playtest` **206**、`growth_playtest` **192**、`brawl_playtest` **43**、`mode_menu_playtest` **45**、`touch_playtest` **42**、`audio_playtest` **36**、`sit_crush_gameplay_playtest` **44**、`sit_crush_playtest` **57**，合计 **665 项全过**；`godot --headless --path . --quit-after 5` 启动校验无脚本报错。
- 随本次改动更新的断言（都是被本次需求直接改变的契约，语义保持）：建筑不再按距离隐藏而改为常驻可见、`camera.far` 改为地图+身高口径、`V` 改为三态、中心 12 栋改为 Kenney 低面模型、雾距改为地图外圈。

### 八点五、安卓 APK（2026-11-26 首次在本机构建）

- 本机原本没有 Android 工具链，本次补齐：cmdline-tools（`~/Android/Sdk/cmdline-tools/latest`）、`platform-tools`、`build-tools;35.0.0`、`platforms;android-35`、`ndk;29.0.14206865`、`rustup 1.29.3` + toolchain `1.94.0` + `aarch64-linux-android` 目标；Godot 编辑器设置里补了 `export/android/java_sdk_path = /usr/lib64/jvm/java-25-openjdk`（`android_sdk_path` 原本就指向 `~/Android/Sdk`）。
- `ANDROID_SDK_ROOT=~/Android/Sdk PATH=~/.cargo/bin:$PATH ./scripts/build_android.sh` 一次通过：重新交叉编译 `libharbor_android.so`（6.1 MB，含 `camera_view_mode`/`set_camera_view` 等本阶段新增接口），产物 `build/harbor-alert-debug.apk`（154 MB，`lib/arm64-v8a/{libgodot_android.so, libharbor_android.so, libc++_shared.so}`，`org.gba.harboralert` 0.1.0，已用 debug keystore 签名）。
- 未做：真机/模拟器安装验证（`adb devices` 无设备）；APK 未打进纯源码包（`scripts/sync_drive.sh` 只同步源码）。

### 九、已知限制

- 巨人在**踩踏蓄力/冷却期间按住前进**时，`standing_pivot_active` 被取消但 `was_walking` 已置真，若同时被墙挡住会停在原地不转身（预存在状态机缺陷，本次换模改变帧时序后才在测试里暴露）；回归测试改为等冷却结束再走、或直接设定身体朝向。修它需要重排 `update_giant` 的 pivot 判定，留待单独一轮。
- 远景低模是 `low-detail-building-*` + 盒代理，没有按每个 kit 型号生成单独低模；远景不投阴影，近远切换在 280 m。
- **道路转角落三件小事（本阶段接受，留后续）**：1 m 栅格重建后人行道**连续性已通过**（带宽 ≈ 基准 46–48 px、颜色 230,236,207 vs 基准 227,235,216），但① 路口四角是 90° 直角（原瓦片有 1–2 m 圆弧）；② 转角 `MAT_Safety_Ochre` 黄漆块几乎不可见（只剩 1–2 px 刻线，基准是 8–10 px 平行四边形）；③ 路缘亮线偏弱（+7~16 亮度，基准 +16~20）且板边有 1 px 暗缝。后续可把栅格降到 0.5 m 并单独补圆弧带、黄漆块与独立亮条。
- 无 GPU 沙盒环境下 `--headless` 的 FPS 不代表实机帧率；本文 GPU 数字均来自本机 AMD Renoir 核显（`glxinfo` 确认为 `radeonsi`，非 llvmpipe）。

---

## 2026-11-25 — Kenney 港区换模：8 大分区建筑、树木、船只与街景全面替换

备份：`backups/20261125_194400_kenney_harbor_reskin/scenes/`（改动前的 `scenes/damageable.gd` 与 `scenes/district_expansion.gd` 副本）。
回滚：`cp backups/20261125_194400_kenney_harbor_reskin/scenes/{damageable.gd,district_expansion.gd} scenes/`，删除 `assets/kenney/`、`scripts/fetch_kenney_assets.py`、`scripts/district_stats.gd`，并重跑 `godot --headless --path . --editor --import`。

### 一、资产提取与防覆盖规范（`assets/kenney/`、`scripts/fetch_kenney_assets.py`）

- 从 Google 云盘 6 个 Kenney zip 包仅提取 `Models/GLB format/` 所需 `.glb` 及同目录贴图，未复制 `OBJ/FBX/Previews`，按包分目录独立存放（防 `colormap` 互相覆盖）：
  - `assets/kenney/commercial/`（24 项）、`industrial/`（23 项）、`suburban/`（14 项）、`roads/`（3 项）、`watercraft/`（17 项）、`car/`（10 项），合计 91 个资产文件。
- 已核对 `export_presets.cfg`：Android ARM64 与 Linux x86_64 预设均为 `export_filter="all_resources"`，且 `exclude_filter` 仅排除 `assets/district/buildings/*,backups/*,build/*,prototypes/*,tests/*`，`assets/kenney/` 会正常打入导出包。

### 二、`damageable.gd` 通用 GLB 建筑适配（`scenes/damageable.gd`）

- 扩展 `damageable.gd` 支持 Kenney GLB 作为 `intact` 完好模型（支持 `intact_scene`、`kit_scale` 及 `kit_layout` 多部件拼接）：依据真实网格 AABB 自动计算水平/高度缩放、底部贴地偏移（对齐 `y = 0`）、`footprint` 与阻挡碰撞体尺寸。
- 完整保留原有受击裂纹表现、3.5 秒倒塌动画、废墟生成与可步行 `HeightMapShape3D` 废墟碰撞（按分区/主色适配 `ruin_color`），以及 `kind`、`historic_style`、成长模式建筑血量与 `restore_building()` 接口。

### 三、8 大分区换模与街景批处理（`scenes/district_expansion.gd`）

- **摩天商务区 (`ZONE_HIGHRISE`)**：`commercial` 的 `building-skyscraper-a..e` 与 `building-l/m/n`（约 12×，地标微调至 14×–15×）。
- **核心老港区 (`ZONE_OLDCORE` / `ZONE_CORE`)**：`commercial` 的 `building-a..i`（11×–12×），点缀 `detail-awning*` / `detail-parasol-*`。
- **集装箱码头 (`ZONE_CONTAINERS`)**：`watercraft` 的 `cargo-container-a/b/c`、`cargo-pile-a/b` 与 `industrial` 矮仓库 `building-h/i/j/k/p/s`；保留既有程序化龙门吊。
- **石化储罐区 (`ZONE_REFINERY`)**：`industrial` 的 `detail-tank-large`、`detail-tank`、`chimney-large/medium/basic`、`water-tower`、`building-a/b/e/f/m`。
- **干船坞造船厂 (`ZONE_SHIPYARD`)**：`industrial` 厂房 `building-c/l/q/r/t`，船坞停放 `watercraft` 的 `boat-tug-a/b`、`boat-tow-a/b`。
- **历史区/外围过渡 (`ZONE_HISTORIC`)**：保留红砖历史仓库，外围混入 `suburban` 的 `building-type-a..j`。
- **公园与广场 (`ZONE_PARK` / `ZONE_PLAZA`)**：树木 `MultiMesh` 改用 `suburban/tree-large`、`tree-small`，广场点缀 `suburban/planter` 与 `commercial/detail-parasol-a/b`。
- **滨水泊位与街景**：泊位改用 `watercraft` 的 `ship-cargo-a/b/c`、`ship-ocean-liner`、`ship-ocean-liner-small`、`boat-fishing-small`、`buoy`（保留灯塔与雷达塔）；路灯 `MultiMesh` 改用 `roads/light-curved`、`light-square`；路边以静态无碰撞 `MultiMesh` 点缀 `car` 包车辆（不放 `-barrier` 路障）。保留 `render_chunk` 分块裁剪、小地图 `_fit_core()` 与 `micro_ground` 逻辑。

### 四、同口径几何与性能数据

1. **全港几何统计（同口径，headless，无渲染器，数据源 `scripts/district_stats.gd`）**：

| 指标 | 口径 | 数据源 | 基准值（换模前） | 当前值（换模后） |
|---|---|---|---|---|
| 港区构建耗时 | `start_mode(true)` 单次耗时（ms） | `scripts/district_stats.gd` | 416.8 ms | 301.5 ms |
| 场景节点数 | `Roads/Lots/Scenery/Targets` 节点总数（含未展开/全展开） | 同左 | 20,598 | 16,663（全展开 16,889） |
| `MeshInstance3D` 数 | 上述 4 组下普通网格节点数 | 同左 | 11,827 | 4,672（全展开 4,785） |
| `MultiMeshInstance3D` 数 | 上述 4 组下合批节点数 | 同左 | 2,070 | 2,117 |
| 渲染实例总数 | 普通网格 + MultiMesh 实例数 | 同左 | 38,681 | 26,775（全展开 26,888） |
| 全港总三角面 | 网格表面索引/顶点换算 tris（含 MultiMesh 展开） | 同左 | 9,809,816 | 12,242,673（全展开 12,249,975） |
| 可破坏目标建筑 | `Targets` 子节点数 | 同左 | 1,718 | 1,586 |
| 场景装饰节点 | `Scenery` 子节点数 | 同左 | 2,364 | 3,369 |

2. **多角色物理帧耗时探针（绝对值，headless `--fixed-fps 60`，Debug `libharbor.so`，数据源 `tests/perf_probe.gd`，未测换模前同口径故不作快慢对比）**：

| 场景 | 角色数 | mean (ms) | p50 (ms) | p95 (ms) | max (ms) |
|---|---:|---:|---:|---:|---:|
| `brawl-mixed-60` | 60 | 26.64 | 29.63 | 39.69 | 47.64 |
| `growth-mixed-60` | 60 | 31.74 | 36.16 | 42.60 | 48.67 |
| `growth-contact-60` | 60 | 28.99 | 33.10 | 40.36 | 44.76 |
| `growth-human-60` | 60 | 13.97 | 13.75 | 15.83 | 17.03 |
| `sandbox-giant-60` | 60 | 27.15 | 27.44 | 35.92 | 41.02 |
| `brawl-mixed-20` | 20 | 9.48 | 10.81 | 15.60 | 23.05 |
| `growth-mixed-20` | 20 | 8.86 | 10.40 | 13.11 | 14.03 |
| `growth-contact-20` | 20 | 9.80 | 10.72 | 13.41 | 14.44 |
| `growth-human-20` | 20 | 5.07 | 4.99 | 6.16 | 7.04 |
| `sandbox-giant-20` | 20 | 11.12 | 10.69 | 14.86 | 18.42 |

3. **实机 GPU 渲染监控绝对值（1280×720，OpenGL 4.6 Compatibility，AMD Radeon Graphics `radeonsi/renoir`，沙盒 1 巨人，热身 30 帧后采样 30 帧均值，数据源 Godot `Performance` Monitor，未测换模前同口径）**：
   - `TIME_FPS` 均值：11.0 FPS；`RENDER_TOTAL_DRAW_CALLS_IN_FRAME` 均值：917.2；`RENDER_TOTAL_PRIMITIVES_IN_FRAME` 均值：674,669；`RENDER_TOTAL_OBJECTS_IN_FRAME` 均值：1,011.2。

### 五、回归验证与实机截图检查

| 项目 | 口径 | 数据源 | 结果 |
|---|---|---|---|
| Rust 单测 | `cargo test` 用例数 | `cargo test --locked --manifest-path rust/Cargo.toml` | 39 通过 / 0 失败 |
| 主玩法回归 | `playtest.gd` 断言数 | `--headless --fixed-fps 60` | 204 通过 / 0 失败 |
| 成长模式回归 | `growth_playtest.gd` 断言数 | 同左 | 190 通过 / 0 失败 |
| 混战回归 | `brawl_playtest.gd` 断言数 | 同左 | 43 通过 / 0 失败 |
| 坐压玩法回归 | `sit_crush_gameplay_playtest.gd` 断言数 | 同左 | 44 通过 / 0 失败 |
| 坐压动画回归 | `sit_crush_playtest.gd` 断言数 | 同左 | 57 通过 / 0 失败 |
| 触屏回归 | `touch_playtest.gd` 断言数 | 同左 | 42 通过 / 0 失败 |
| 模式菜单回归 | `mode_menu_playtest.gd` 断言数 | 同左 | 45 通过 / 0 失败 |
| 音频回归 | `audio_playtest.gd` 断言数 | 同左 | 36 通过 / 0 失败 |
| 启动校验 | `--quit-after 5` 退出码 | 同左 | 0（无新增脚本报错） |

- 实机 GPU 截图检查（AMD Radeon `radeonsi`，1280×720，`build/shots/` 共 11 张：`core_east`、`oldharbor`、`highrise`、`containers`、`refinery`、`shipyard`、`waterfront`、`park` 及补拍 `waterfront_ships`、`waterfront_east`、`plaza_parasols`）：8 大分区建筑、集装箱与货堆、储罐/水塔/烟囱、干船坞拖船、滨水货轮/渔船/浮标/龙门吊、公园树木与广场花池/遮阳伞、路灯与路边静态车辆均贴地、材质与阴影方向正常，未见缺失贴图、悬空或穿模。

---

## 2026-11-25 — AI 坐压群体触发优先级：踩踏冷却期不再挡住人群判定

回滚：`rust/src/round/sit.rs` 把 `stomp_allows_sit()` 的函数体改回 `matches!(stomp, Stomp::Ready)`（即恢复“仅 Ready 开闸”），删掉 `a_crowd_sit_pre_empts_the_stomp_cooldown_but_never_a_telegraphed_stomp` 测试与 `tests/sit_crush_gameplay_playtest.gd` 里新增的三个用例，然后重新 `cargo build`。
本次为增量排查，未单独做改动前快照；旧行为等价于上面这一行替换，可据此精确回滚。

### 一、根因：坐压的人群判定被绑在「踩踏 Ready」这一帧上

- `maybe_start_sit()` 的 AI 分支原先是 `if !matches!(actor.stomp, Stomp::Ready) || !actor.body.is_on_floor() { return false; }`。踩踏循环是 `Windup 0.52 s → Recover 0.48 s → Cooldown 0.72 s → Ready`，也就是**每约 1.72 s 只有 1 帧**能进人群判定；`hand_attack`（抓捏 4.5 s、挥拳 2.4 s）期间整帧跳过 `update_giant`，同样不看人群。
- 冷却期里身体其实完全空闲（只是数值在倒计时），却和“动画已锁定”的蓄力/落地一样被当成忙碌。追击中 AI 反复踩踏/抓捏，人群判定几乎抓不到窗口；一旦这期间有一个小目标被踩死或被抓起（抓起后从 `self.rivals` 摘除，不再计入人数），人数就永久掉到 2 以下，表现为“范围内明明有 2 个却从不坐”。
- 顺带核实（结论是本来就对，无需改）：`maybe_start_sit()` 在 `update_giant()` 里排在 `pursue()`（踩踏/抓捏/挥拳决策）**之前**，决策顺序本身没问题；`seat_targets()` 统计人数**不看** `rival_ignore_ratio` / `human_ignore_ratio`，也不要求存在 `chase_target`；意向圈圆心在身体正前方 `2.85 × 体型`、半径 `4.366 × 体型`，25.2 m 巨人对应覆盖身体中心前 7.22 m（含 7.05 m 处的落脚椭圆），落地区是它的镜像（后方 2.85 m）。

### 二、修复（`rust/src/round/sit.rs`）

- 抽出 `stomp_allows_sit(stomp) -> bool`：只有**动画已锁定**的 `Windup`（预警圈已画出）和 `Recover`（脚已落地）阻止坐压；`Ready` 和 `Cooldown` 都允许。冷却期开闸把可用窗口从“每 1.72 s 一帧”扩大到每个循环约 43/72 帧。
- 配套单测 `a_crowd_sit_pre_empts_the_stomp_cooldown_but_never_a_telegraphed_stomp` 固定这条边界（Ready/Cooldown 放行，Windup/Recover 拒绝）。

### 三、调试接口与回归测试

- `growth_actors()` 每行新增 `stomp_phase`（`ready` / `windup` / `impact` / `cooldown`），与 HUD 快照共用新抽取的 `Giant::stomp_phase()`。
- `tests/sit_crush_gameplay_playtest.gd` 由 34 项增至 44 项，新增：
  - `_ai_crush_wins_over_chase_and_stomp()`：AI 追着 40 m 外的对手，脚边两个 1 m 目标 → 群体坐压自行触发、两人在开坐时都还活着、最后由坐压压死（而非踩踏/抓捏）。
  - `_crush_pre_empts_the_stomp_cooldown()`：先让 AI 踩一脚进入冷却，再把两个 1 m 目标放进意向圈，要求 6 帧内开坐。**旧闸门下该用例失败（-1，即永不触发），新闸门下 1 帧触发**，是本次修复的判别性回归。
  - `_crush_ignores_ignore_ratios()`：把 `rival_ignore_ratio` / `human_ignore_ratio` 都压到 1.01（AI 完全不想追它们），坐压人数仍照常计入。

### 四、验证结果

| 项目 | 口径 | 数据源 | 结果 |
|---|---|---|---|
| Rust 单测 | `cargo test` 用例数 | `cargo test --locked --manifest-path rust/Cargo.toml` | 39 通过 / 0 失败 |
| 坐压玩法端到端 | `sit_crush_gameplay_playtest.gd` 断言数 | 同左 | 44 通过 / 0 失败 |
| 成长模式回归 | `growth_playtest.gd` 断言数 | 同左 | 190 通过 / 0 失败 |
| 主玩法回归 | `playtest.gd` 断言数 | 同左 | 204 通过 / 0 失败 |
| 触屏回归 | `touch_playtest.gd` 断言数 | 同左 | 42 通过 / 0 失败 |
| 启动校验 | `--quit-after 5` 退出码 | 同左 | 0（无脚本报错） |

全部为 `--headless` 逻辑验证，**未做视觉验证**（本机为软渲染环境，按项目约定不开窗口）。

### 五、已知残余

- 抓捏射程是 `0.29 × 身高`，意向圈前沿是 `0.2863 × 身高`（`2.85 + 4.366` 再乘体型比例），两者只差 `0.0037 × 身高`（25.2 m 时约 9 cm）。处在这条窄带里的目标仍可能先被抓起、从而退出人数统计。本次未改动几何，避免“人群在落区外也开坐”导致空坐 4.8 s。

---

## 2026-11-25 — 雪狐材质分档调色 + 第一人称眼位/转头上限/视角转向

备份：`backups/20261125_170432_snowfox_tint_firstperson/`（`scenes/`、`rust/src/`、`tests/` 的改动前副本）。
回滚：`cp -r backups/20261125_170432_snowfox_tint_firstperson/{scenes,rust,tests} .` 后重新 `cargo build`。

### 一、雪狐材质按用途分档（`scenes/snow_fox_skin.gd`）

- `_shade_unlit_materials()` 不再只对 `SKIN`/`HAIR` 乘同一个 `0.86`，改为按材质名分档：皮肤/脸（`SKIN`、`FACE`，含眉/睫/唇线）乘 `Color(0.80, 0.73, 0.70)`；头发与狐尾（`HAIR`、`FOXTAIL`）乘 `Color(0.75, 0.78, 0.84)`；其余（白女仆装 `Tops_CLOTH`、围裙、白丝袜等一切未命中项）乘 `Color(0.70, 0.71, 0.75)`；只有 `_EYE` 眼球/高光保持原色。
- 所有 PBR 副本统一 `roughness = 1.0`、`metallic = 0.0`、`metallic_specular = 0`、`SPECULAR_DISABLED`、`emission_enabled = false`，`diffuse_mode` 仍是 `DIFFUSE_TOON`。
- 实测 albedo：皮肤 `(0.8, 0.73, 0.7)`、白衣 `(0.7, 0.71, 0.75)`、头发/狐尾 `(0.75, 0.78, 0.84)`、眼睛 `(1, 1, 1)`。港区实景白衣保留褶皱明暗，不再死白。

### 二、第一人称：裁掉头皮、保留头影、眼位跟骨骼

- `_configure_visibility(&"J_Bip_C_Head", [&"Face", &"Hair"], [&"Body"])`：雪狐 Body 网格现在和 Kawaii/Hina 一样按 `J_Bip_C_Head` 权重裁切，第一人称俯视不再露出头皮与 `HairBack`（1296→24 三角面），Face/Hair 仍走 `SHADOWS_ONLY`。
- `giant_visual.set_first_person()` 的人类阶段也改用 `_set_head_part_hidden()`：人类模型头部同样只保留投影，不再直接 `visible = false`；`set_stage()` / `show_respawn()` 同步。
- 新增 `giant_visual.first_person_eye_position()`：巨人阶段读当前骨架（`_active_skin.skeleton` 或 `_skeleton`）的 Head 骨骼世界坐标，再按身高前偏 `0.045 h`、上抬 `0.055 h`；人类阶段或缺骨骼时回退 `0.90 h`。另加 `capsule_height()` 供测试与回退使用。
- `round.rs::follow_camera()` 第一人称改用该眼位，只在 `pitch < -0.35` 时叠加 smoothstep 的水平前探（`0.06 h`）；远裁剪面改按整体身高计算，避免切换当帧读到旧轨道高度。

### 三、第一人称 ±75° 转头上限 + 「视角控制转向」开关

- `round.rs` 新增 `FIRST_PERSON_YAW_LIMIT = 1.31`（≈75°）：`rotate_view()` 与每帧 `follow_camera()` 都把 `self.yaw` 夹在身体朝向 ±75° 内，看到后背蝴蝶结/尾巴的问题从机制上杜绝。
- 新增设置键 `first_person_steer`（默认开启，玩法页「巨人」组、立即生效、`gameplay.cfg` 按模式持久化；schema 驱动界面，`interface.gd` 无需改动）。
  - 开启：站立时把视角 yaw 交给 `show_motion(..., turn_target, allow_standing_turn = true)` 的原地小碎步转身；行走时身体目标朝向夹在视角 ±75° 内交给 `turn_giant_smooth`。
  - 关闭：身体完全不随视角转，但仍执行 ±75° 上限。
  - 重踏蓄力、手部动作、坐压期间一律跳过转向，攻击锁定朝向不受影响（有回归断言）。

### 四、验证

- Rust：`cargo build` + `cargo test` 38 项（新增 `first_person_steer_defaults_on_in_every_mode`）。
- Godot（`--headless`，全部通过）：`growth_playtest` 190、`playtest` 204、`sit_crush_gameplay_playtest` 34、`sit_crush_playtest` 57、`touch_playtest` 42、`mode_menu_playtest` 45、`brawl_playtest` 43、`audio_playtest` 36；`godot --headless --path . --quit-after 5` 无报错。
- `growth_playtest` 新增三组断言：眼位贴 Head 骨骼（走路起伏/重踏下压/坐压下沉逐帧 `|camera.y - eye.y| < 1.5 mm`）、±75° 左右对称夹紧与开关持久化、退出第一人称恢复完整网格。
- 截图（`build/tmp/`）：`harbor_fox_body.png`、`harbor_fox_fp_level.png`、`harbor_fox_fp_down.png`、`harbor_fox_fp_left/right.png`（港区实景，少量帧）；`fox_body_sun.png`、`fox_body_close.png`、`fox_fp_down.png`、`fox_fp_sit.png`、`fox_shadow.png`（最小场景，同港区光照参数）。

---

## 2026-11-25 — 巨人坐压接入正式玩法 + 设置面板重构

### 一、坐压（sit-crush）接入对局

- **触发规则（`rust/src/round/sit.rs`）**：坐压意向圈在身体正前方，半径 `4.366 × 体型`（25.2 米时约 4.4 米）。AI 巨人当圈内出现 ≥ `sit_crush_targets`（默认 2）个身高 ≤ 自身 `1/sit_crush_ratio`（默认 5 倍）的活物时自动触发；玩家只要是巨人阶段，按 `X`（触屏「坐压」按钮）随时可坐，**不需要目标、不看冷却**，坐着再按 `X` 起身。
- **落区预警**：坐压的转身/下落阶段，`scenes/round_effects.gd` 会在屁股将要落地的位置画一个琥珀色圆环 + 脉冲内环 + 半透明底盘（`SitWarning`，半径 = 坐压圈），转身时跟着扫过去；落座瞬间清掉，换成原有的冲击扬尘/冲击波。被坐压死亡、重开或起身也会清理，不会残留。
- **先转身再坐**：坐姿动画把骨盆落到身体**后方**（实测 `yaw=0` 时骨盆在 +2.85 米，即 -forward 侧），所以触发后先复用现有分层小碎步原地转身，把背（屁股）对准人群，脚落平后再无缝接坐压；没有目标时直接坐。HUD 新增「转身对准」相位。之前的预览场景就是这么演的，这次接进了正式玩法。
- **停留时长**：AI 的坐压停留随体型 `sit_hold_base + sit_hold_per_scale × (体型 - 1)`，最低 0.45 秒（25.2 米约 1.2 秒，100 米约 4.2 秒）；**玩家坐下后不会自动起身**，一直坐在那，直到按 `X` 才起。坐下后走 `show_sit_idle` 的无缝待机循环，起身回到 `show_sit_crush` 的升段。
- **伤害**：落座瞬间复用踩踏管线（`impact()` → `GiantStrike`，新增 `DefeatMethod::SitCrush`），同一次坐压对建筑、行人、撤离玩家和巨人对手都按既有规则结算；击倒播报新增「坐压压扁」。
- **满级待机坐**：达到成长上限且索敌范围内没有目标时，每秒按 `sit_idle_chance` 概率坐下待机；`sit_idle_timeout` 默认 60 秒自动起身，还可在设置里改。待机期间出现任何目标（含比自己大的巨人）立即起身，坐下与待机都同样结算坐压伤害。
- **玩家主动起身**：`X` 或触屏「起身」；按住其他键不会误起身。
- **被坐压制服**：被 ≥ `sit_pin_ratio`（默认 5 倍）的目标坐压命中时，`pinned_by` 定身（不走 AI、不吃输入），每 `sit_pin_interval`（默认 0.5 秒）损失对方攻击力 1/5 的伤害，直到对方起身或死亡。与「被抓起」（`grabbed`）是两套状态：被坐压者仍在场上、仍被看见。
- **互斥**：坐压期间不调用 `animate()`（否则 `show_motion` 会覆盖坐姿）、不跑 AI 与攻击输入，成长暂停；与踩踏/手部动作共用「同一时间只做一个动作」的约定。
- **输入与 HUD**：新增 `stand_up`（X）与 `tap_sit_down()`；触屏新增「坐压/起身」按钮（在切换视角左侧），HUD 相位显示「坐压落下 / 坐压压实（X 起身）/ 起身 / 被坐压制服」，进度条复用踩踏计量条。

### 二、设置面板重构（`scenes/settings_schema.gd` + `scenes/interface.gd`）

- **两页结构**：「画面与声音」只设一次（音效/环境/静音、渲染视距、震动强度、自身震动），保存时镜像进四个模式的 profile；「玩法」仍按模式独立保存。
- **分组可折叠**：地图与开局 / 巨人 / 人类与行人 / 金币与成长 / 复活；每组常用项直接展开，其余收进末尾「高级」（默认收起）。
- **依赖项隐藏**：随机开局的上下限、成长分档、建筑刷新等待、NPC 刷新间隔关闭时整行隐藏，不再是置灰占位。
- **生效时机**：每项右侧标注「下局 / 立即 / 下次倒下 / 下次复活」，底部只留一行说明。
- **短名 + 提示**：选项名精简，行尾 `?` 点开详细说明（触屏没有 hover，所以用点按展开而不是 tooltip）。
- **恢复本页默认**：`ResetSettings` 只重置当前页（画面页重置音频+画面，玩法页重置当前模式）。
- **声明式 schema**：所有选项的页/组/高级/生效时机/依赖/取值格式集中在 `scenes/settings_schema.gd`，新增选项先在那里归类；Rust `settings.rs` 仍是默认值与校验的唯一来源。
- **兼容**：节点名仍等于存档键（`AudioMuted`/`NpcRespawn` 例外），`GameplaySettings`、四个模式标签、`SaveSettings/CancelSettings/ResetSettings` 全部保留。
- **行为变化**：`own_camera_shake` 现在写入全部模式 profile（原来人类模式不存），渲染视距/震动强度按全局页镜像，`tests/playtest.gd` 相应改成「沙盒沿用人类页保存的视距」。
- 新增 `Interface.debug_expand_settings()` 供回归测试展开全部分组与高级项。

### 三、测试与验证

- 新增 `tests/sit_crush_gameplay_playtest.gd`（20 项）：玩家请求式坐下、点击人群、停留时长随体型、满级待机、目标出现起身、超时起身、主动起身、被坐压定身与持续掉血、松手解除。
- `tests/playtest.gd`、`tests/growth_playtest.gd`、`tests/brawl_playtest.gd`、`tests/touch_playtest.gd`、`tests/audio_playtest.gd`、`tests/mode_menu_playtest.gd` 的设置断言按新面板更新（依赖项隐藏、高级展开、显示项全局）。
- 截图里问过的「把坐压/待机导出成动画文件」做成原型放在 `prototypes/giant_animation_bake/`（烘焙工具 + AnimationLibrary + 预览场景，`prototypes/*` 不进包，正式玩法未引用）。
- 验证：Rust 37 项；Godot 共 634 项断言全过——`playtest` 204、`growth_playtest` 177、`sit_crush_playtest` 57、`mode_menu_playtest` 45、`brawl_playtest` 43、`touch_playtest` 42、`audio_playtest` 36、`sit_crush_gameplay_playtest` 30（含转身、玩家不自动起身、AI 停留随体型）；`godot --headless --path . --quit-after 5` 启动校验无报错；设置页（玩法/画面、分组、高级、徽章）已实机渲染核对。
- 改动前快照：`backups/20261125_121621_giant_sit_gameplay/source_snapshot.tar.gz`。回滚：

```sh
snapshot=backups/20261125_121621_giant_sit_gameplay
mkdir -p build/rollback && tar xzf "$snapshot/source_snapshot.tar.gz" -C build/rollback
cp -a build/rollback/scenes/. scenes/
cp -a build/rollback/tests/. tests/
cp -a build/rollback/rust/src/. rust/src/
cp -a build/rollback/CHANGELOG.md build/rollback/MEMORY.md build/rollback/AGENTS.md .
rm -rf tools prototypes/giant_animation_bake scenes/settings_schema.gd
cd rust && cargo build --locked --target-dir target
```

---

## 2026-11-25 — 巨人坐压前先执行现有 180° 原地转身（未接入正式玩法）

在坐压预览与动作接口中接入「面向前方目标 → 现有 180° 原地小碎步转身 → 无缝衔接坐压」流程，正式玩法与 Rust 代码保持未接入状态：

- **原地转身衔接接口（`scenes/giant_visual.gd`）**：
  - 新增 `step_turn_in_place(target_yaw, delta)`，内部直接调用现有的 `show_motion(0.0, -1.0, delta, target_yaw, true)` 复用原汁原味的 180° 原地小碎步转身动画，并在最后一步脚跟落平、骨盆与双脚对齐目标朝向后返回 `done = true`。
  - 为 `finish_sit_crush(immediate := false)` / `finish_sit_idle(immediate := false)` 增加可选即时复位参数，避免重播瞬间残留上一次坐姿退出混合。
- **独立预览场景更新（`tests/sit_crush_preview.gd`）**：
  - 将橙色落区、小人与木箱布置在巨人初始朝向（`-Z`）的正前方（靶心 `z = -2.85`，恰为转身 180° 坐下时的骨盆落点，并留出清晰原地转身脚步空间）；将攻击判定半径由 `10.5m` 收紧至贴合实测坐地臀部与左右压实范围的 `4.4m`（并在 `scenes/giant_visual.gd` 新增比例常量 `SIT_CRUSH_RADIUS_SCALE := 0.295`），同步收紧冲击波环与扬尘扩散半径，且在圈外放置 2 个参照小人验证边界精准不误伤。
  - 默认开场 / 重播 `[R]`、`[C]`（转身→坐下→待机→起身）、`[W]`（行走→转身→坐压）均先运行 6 步 180° 原地转身背对目标，再无缝切入坐压（交接帧骨盆位移跳变 `0.000m`）；`[I]` 直接查看已转身后坐扁目标的坐姿待机，拖动进度条自动切到已转身朝向逐帧检查坐压。
- **自动化验证扩展（`tests/sit_crush_playtest.gd`）**：
  - 扩充至 57 项断言，校验初始正对前方目标、6 步 180° 原地转身、交接帧零跳变、屁股精准落在初始前方目标区并压扁全部 12 个目标，以及重播 / `[W]` / `[I]` / `[C]` 全模式。

验证：坐压与坐姿待机专项 57 项、菜单与卧室 45 项与无界面启动校验全部通过，并完成 8 帧 OpenGL 实机渲染巡检。

改动前快照在 `backups/20261125_114200_giant_turn_then_sit/`。如需回滚，从工程根目录运行：

```sh
snapshot=backups/20261125_114200_giant_turn_then_sit
cp -a "$snapshot"/scenes/giant_visual.gd scenes/
cp -a "$snapshot"/tests/sit_crush_preview.gd tests/
cp -a "$snapshot"/tests/sit_crush_playtest.gd tests/
cp -a "$snapshot"/CHANGELOG.md .
```

---

## 2026-11-25 — 巨人坐姿待机测试动作（未接入正式玩法）

在保持正式玩法、输入与 Rust 逻辑零改动的前提下，为巨人新增坐下后的自然**坐姿待机**程序化动作，并接入独立预览场景与自动化测试：

- **坐姿待机动作与双向无缝过渡（`scenes/giant_visual.gd`）**：
  - 新增 `show_sit_idle(delta, blend_in)` 与 `finish_sit_idle()`：将坐压与坐姿待机下沉深度校准至 `0.830`（彻底消除低角度平视下臀部悬空缝隙，全三套皮肤均经 `pelvis_height_ratio()` 按比例重定向贴地坐实），保持双脚外八平踩锁定、双膝前张；叠加舒缓深呼吸、双谐波慢速重心微晃、平静环视并周期性低头瞄向脚边压扁区域（含眼动与眨眼），双手手腕与掌心稳稳搭在双膝前上方、肘部松弛下垂、手指微弯贴合，不与膝盖/背包/地面穿插。
  - 支持 `show_sit_crush(0..0.65) -> show_sit_idle(任意时长) -> show_sit_crush(0.65..1.00)` 双向 IK 后快照平滑过渡，手部可从坐压平衡展开平滑收搭到膝盖，再从膝盖顺滑滑落撑地起身（且不会重复触发落地冲击）。
- **独立预览场景升级（`tests/sit_crush_preview.gd`）**：
  - 新增「坐姿待机 `[I]`」直接循环预览模式与「坐下→待机→起身 `[C]`」完整流程演示模式（含 3.2s 坐姿停留与平滑衔接的扬尘消散），支持 `1/2/3` 实时切换三套外观与多机位检查。
- **自动化验证扩展（`tests/sit_crush_playtest.gd`）**：
  - 新增坐姿待机生物力学、暂停冻结、`坐下→待机→起身` 连续性、三套皮肤（Kawaii / Hina / Chibi Catgirl）及预览场景双模式自动化检查（由 33 项扩展至 56 项）。

验证：Rust 34 项、坐压与坐姿待机专项 56 项、常规玩法 204 项、成长玩法 177 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项，共 603 项 Godot 断言与无界面启动校验全部通过，并完成 Kawaii / Hina / Chibi Catgirl OpenGL 实机渲染巡检。

改动前快照在 `backups/20261125_110606_giant_sit_idle/`。如需回滚，从工程根目录运行：

```sh
snapshot=backups/20261125_110606_giant_sit_idle
cp -a "$snapshot"/scenes/giant_visual.gd scenes/
cp -a "$snapshot"/tests/sit_crush_preview.gd tests/
cp -a "$snapshot"/tests/sit_crush_playtest.gd tests/
cp -a "$snapshot"/CHANGELOG.md .
```

---

## 2026-11-25 — 修复 AI 巨人突然转弯与攻击瞬间甩头

全面消除 AI 巨人在高倍速、发动攻击、随机漫游和静止换向时的突兀转向，让 AI 与玩家共用同一套平滑分层转身和小碎步机制：

- **AI 攻击严格受当前朝向约束（`rust/src/round.rs`、`rust/src/round/hands.rs`）**：
  - `pursue()` 中对生物与建筑的 AI 重踏新增前方对齐门槛 `AI_STOMP_ALIGN_COS = 0.965`（约 15° 锥角，覆盖站立转身启动死区 12.6°）；目标在身侧或身后时不再单帧甩头起脚，而是保持 `ai_aim_yaw` 原地小碎步转正后再出脚。
  - `start_ai_hand_move()` 改用 AI 巨人当前实际朝向 `actor.body.get_rotation().y` 校验手部抓捏/挥拳扇区，不再向身后直接瞬转出手。
- **高倍速转向速度亚线性平滑限幅（`rust/src/round.rs`）**：
  - `drive_giant()` 将传入 `turn_giant_smooth()` 的转向倍速由线性 `pace`（4 倍速下约 `780°/s`）改为亚线性 `pace.max(0.1).sqrt().min(1.65)`，大乱斗与成长模式默认 4 倍速时行进过弯依旧自然稳重。
- **AI 静止大角度换向启用小碎步 + 漫游优先前方扇区（`rust/src/round.rs`）**：
  - 放开 `standing_pivot_target` 的 `player &&` 限制，使 AI 巨人站立面对大角度新目标时同样先原地小碎步转正再迈步前行。
  - `wander_goal()` 在空旷未贴墙时优先从当前朝向前方 `±68°` 扇区（`dot >= 0.36`）挑选漫游点，减少平地无故 180° 折返；撞墙时回退全方向选点，并仅在当前漫游点仍指向墙面（`dot > 0.35`）时重选，避免贴墙缓慢转向期间逐帧抖动重抽。
- **回归测试（`tests/playtest.gd`）**：
  - 调整 `_multiple_giants()` 中两只 AI 的初始朝向使其正对人类，并新增 `_ai_smooth_turning()` 专项测试，验证 4 倍速下背对人类的 AI 不会瞬转重踏，而是经过多帧原地小碎步平滑转正后再发起踩踏（单帧最大转角 `0.091 rad`）。

验证：Rust 34 项、常规玩法 204 项、成长玩法 177 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项、坐压专项 33 项、独立转身原型 43 项，共 623 项 Godot 断言与无界面启动校验全部通过。

改动前快照在 `backups/20261125_105000_smooth_ai_turning/`。如需回滚，从工程根目录运行以下命令并重新编译 Rust：

```sh
snapshot=backups/20261125_105000_smooth_ai_turning
cp -a "$snapshot"/rust/src/round.rs rust/src/
cp -a "$snapshot"/rust/src/round/hands.rs rust/src/round/
cp -a "$snapshot"/tests/playtest.gd tests/
cp -a "$snapshot"/{CHANGELOG.md,MEMORY.md} .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-25 — 到达当前上限的 AI 停止主动踩楼改为闲逛 + 修复行进急转步频突增

合并完成两项玩法与动作优化：

- **到达当前上限的 AI 不再主动踩楼（`rust/src/round.rs`）**：
  - 新增 `at_current_growth_cap()` / `ai_attacks_scenery()`，同时识别全局高度上限（`self.max_height`）与成长模式高度分层当前上限（`actor.growth_limit`）。
  - AI 巨人达到任一当前上限后停止选取建筑目标、不再记录 `blocking_target` 主动踩楼；若视野内仍有可交战的人类或对手仍照常追击战斗，无攻击目标时直接通过 `wander_goal()` 在港区自由闲逛（撞墙自动重选漫游点）；在成长模式中，若上方分层让出空位导致 `growth_limit` 抬高，AI 会自动恢复拆楼成长。
- **修复行进中突然按左右键转弯步频突增（`scenes/giant_visual.gd`）**：
  - 移除此前按转向角速度直接拉高至 `2.2 cyc/s`（约 4.4 倍步频）的下限，改为按体型缩放后的基准步频平滑约束急转步频在 `1.24×~1.32×` 区间，保留短步自然转弯节奏并彻底消除突然按左右键时连碎几步的抽搐感。
- **回归测试**：在 `rust/src/round.rs` 新增 `capped_ai_detects_both_round_max_and_band_limit` 单元测试；在 `tests/growth_playtest.gd` 新增 2 项实机断言，分别覆盖 AI 到达全局上限和被高度分层限制时停止主动踩楼并保持闲逛。

验证：Rust 34 项、常规玩法 201 项、成长玩法 177 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项、坐压专项 33 项、独立转身原型 43 项，共 620 项 Godot 断言与无界面启动校验全部通过。

改动前快照在 `backups/20261125_103900_capped_ai_roam/`。如需回滚，从工程根目录运行以下命令并重新编译 Rust：

```sh
snapshot=backups/20261125_103900_capped_ai_roam
cp -a "$snapshot"/rust/src/round.rs rust/src/
cp -a "$snapshot"/scenes/giant_visual.gd scenes/
cp -a "$snapshot"/tests/growth_playtest.gd tests/
cp -a "$snapshot"/{CHANGELOG.md,MEMORY.md} .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-25 — 修复行进转弯横向斜滑与双腿甩偏问题

排查第三人称背后视角发现，行进转弯时“看着发歪”的主要原因并非仅是脊柱侧倾，而是物理速度横向蟹行与急转弯步频滞后导致的双腿甩偏：

- **沿身体实际正前方走弧线（`rust/src/round.rs`）**：巨人阶段行走的 `desired_velocity` 改为沿当前身体朝向 `body_forward` 推进（按朝向与输入夹角平滑调速 `0.25~1.0` 收紧转弯半径），彻底消除急转弯横向滑步和 180° 倒退滑步，使髋部始终沿实际步伐弧线移动。
- **急转步频联动角速度与自然落脚走廊（`scenes/giant_visual.gd`）**：
  - 将急转弯最低步频直接与实际转向角速度 `|_pelvis_yaw_vel|` 联动（每步仅承接约 `35°~45°` 转向即抬脚迈下一步），防止支撑脚被留在旧方向并被车身旋转甩到体侧。
  - 迈步落点预测改沿弯道弧线中点外推，仅在前后接近时做防交叉避让，并将最终落脚横向位置限制在髋部自然走廊 `[0.055 S, 0.135 S]` 内，同时将支撑脚最大水平滞留限幅从 `0.56 S` 收紧到 `0.38 S`。
  - 同步微调行进骨盆反倾与脊柱侧倾上限（实测背后视角躯干倾角 `2.4°~4.0°`，双脚中点横向偏离由 `-0.267~-0.305` 收正到 `-0.010~+0.075`）。

验证：桌面 OpenGL Compatibility 实机第三人称背后视角对比复核了行进左转 90°、连续绕圈、右转 90° 与 180° 掉头四组画面；Rust 33 项、常规玩法 201 项、成长玩法 175 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项、坐压专项 33 项、独立转身原型 43 项，共 618 项 Godot 断言与无界面启动校验全部通过。

改动前快照在 `backups/20261125_103100_forward_arc_walk_turn/`。如需回滚，从工程根目录运行以下命令并重新编译 Rust：

```sh
snapshot=backups/20261125_103100_forward_arc_walk_turn
cp -a "$snapshot"/rust/src/round.rs rust/src/
cp -a "$snapshot"/scenes/giant_visual.gd scenes/
cp -a "$snapshot"/{CHANGELOG.md,MEMORY.md} .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-25 — 收敛巨人转身侧倾幅度与重心横移，消除歪倒感

修复此前转身时骨盆横向偏移（`0.088`）超出支撑脚位置（`0.072`）且叠加过多脊柱侧倾（站立约 `13°`、行进急转 `22°~24°`）导致的“歪倒感”：

- **重心收敛到支撑脚正上方（`scenes/giant_visual.gd`）**：站立转身骨盆横移从 `0.072 + 0.016` 调稳至 `0.048 + 0.010`（落在支撑脚正上方），行进横移上限由 `0.055` 收紧至 `0.034`。
- **稳重内倾与头部水平稳定（`scenes/giant_visual.gd`）**：站立转身目标倾角上限由 `0.20 rad` 降至 `0.09 rad`（躯干实测约 `3.6°~5.0°`），行进急转上限由 `0.34 rad` 降至 `0.19 rad`（正常速度躯干实测 `4.7°~5.3°`，4× 高速上限锁在 `8.5°` 内）；同时降低各节脊柱侧倾增益并提高头部前庭水平回正（`0.56 → 0.72`），保持脊柱 S 弧和双臂不对称摆幅清晰可读且下盘扎实。

验证：桌面 OpenGL Compatibility 实机复核了站立 90°/180° 与行进左右急转四视角；无界面启动校验、`tests/playtest.gd`（201/201）、`tests/growth_playtest.gd`（175/175）、`tests/brawl_playtest.gd`（43/43）、`tests/touch_playtest.gd`（42/42）、`tests/sit_crush_playtest.gd`（33/33）全部通过。

改动前快照在 `backups/20261125_100300_tune_turn_lean/`。如需回滚，从工程根目录运行：

```sh
snapshot=backups/20261125_100300_tune_turn_lean
cp -a "$snapshot"/scenes/giant_visual.gd scenes/
cp -a "$snapshot"/CHANGELOG.md .
```

---

## 2026-11-25 — 巨人朝向与攻击脱离视角控制，攻击严格锁定当前朝向

将巨人角色身体朝向、踩踏与手部攻击彻底与镜头环视（`self.yaw`）解耦，并按第三人称动作逻辑补齐「站立大角度先原地小碎步转身再起步」的衔接体验：

- **视角自由环视不改朝向（`rust/src/round.rs`）**：鼠标、方向键或安卓右侧滑屏环视只转动镜头，不再驱动站立巨人的身体朝向（含第一/第三人称）；玩家可 360° 自由绕巨人观察正侧面而不惊动其站姿或朝向。
- **攻击严格锁定当前身体朝向（`rust/src/round.rs`、`rust/src/round/hands.rs`）**：
  - 玩家踩踏（`Space` / 触屏踩踏）改为只取巨人当前身体朝向 `giant.get_rotation().y`，不再读取镜头朝向 `self.yaw` 或当前按住的反向移动键（按住后退键 + 踩踏不会再原地转圈打到身后，必须先转身面向目标）。
  - 玩家手部动作（`Q` 捡起捏碎、`E` 挥拳及对应触屏按钮）在 `start_player_hand_move()` 中同样改为按巨人当前身体朝向筛选前方扇区目标，拒绝身侧与背后目标，哪怕镜头正对着背后目标也不会强行转身出手。
- **站立大角度先小碎步转身再起步（`rust/src/round.rs`、`scenes/giant_visual.gd`）**：
  - `WASD` / 安卓左摇杆仍按当前画面方向操作；静止状态下输入与当前身体朝向夹角 `> 55°`（如 `A`/`D`/`S`）时，先原地执行分层零滑移小碎步转身，转至 `≤ 32°` 后无缝切入行进；已经在行走中则直接走弧线急转弯。
  - 若在站立小碎步中途松开方向键，`scenes/giant_visual.gd` 会顺滑把当前抬起的一小步脚跟先落稳并停在当前朝向，不会空中瞬移或双脚回弹。
- **回归测试更新（`tests/playtest.gd`）**：新增并完善 5 项实机回归断言，验证自由环视不改朝向、按后退+踩踏只打正前方、手部攻击拒绝身后目标且转身后可命中、站立 90°/180° 先原地小碎步再迈步以及中途松手零滑移落脚。

验证：Rust 33 项、常规玩法 201 项、成长玩法 175 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项、坐压专项 33 项、独立转身原型 43 项，共 618 项 Godot 断言与无界面启动校验全部通过。

改动前快照在 `backups/20261125_095000_decouple_facing_from_view/`。如需回滚，从工程根目录运行以下命令并重新编译 Rust：

```sh
snapshot=backups/20261125_095000_decouple_facing_from_view
cp -a "$snapshot"/rust/src/round.rs rust/src/
cp -a "$snapshot"/rust/src/round/hands.rs rust/src/round/
cp -a "$snapshot"/scenes/giant_visual.gd scenes/
cp -a "$snapshot"/tests/playtest.gd tests/
cp -a "$snapshot"/{CHANGELOG.md,MEMORY.md} .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-25 — 巨人分层转身与零滑动脚部动作正式接入游戏

将原独立原型验证通过的巨人分层转身与世界锁定脚部系统正式接入实时玩法（覆盖人类撤离、巨人沙盒、成长模式、大乱斗，适配键鼠与安卓触屏、第一/第三人称视角、全缩放体型及 `Kawaii`、`Hina`、`Chibi Catgirl` 三套外观），并保留独立测试原型 `prototypes/giant_turn/`（已在 `export_presets.cfg` 导出预设中排除 `prototypes/*`）。

主要改动：
- **由上到下逐层滞后转身（`scenes/giant_visual.gd`）**：转向按 `眼 → 头 → 胸 → 胯 → 脚` 依次启动，眼球与头部最先到达新视线，胸部转至头部约一半角度并与骨盆之间形成脊柱反向 S 弧，双肩相对胸腔扭转略微反拧，不再整块身体僵硬同步旋转。
- **内倾压重心与重量感（`scenes/giant_visual.gd`）**：左转向左倾、右转向右倾，内倾幅度随转向速率和移动速度平滑放大；转身时微屈双膝、骨盆略微下沉并将重心优先压到内侧支撑腿上再抬外侧腿；外侧手臂展开摆幅更大，内侧手臂收紧弯曲，同时保留 `Kawaii` 右侧小熊斜挎包的动态避让净空。
- **世界锁定零滑动脚步（`scenes/giant_visual.gd`）**：
  - 支撑脚以脚跟或前脚掌为支点钉地原地旋转（`0.0000 m` 水平滑移），抬起的迈步脚提前将脚尖对准新方向、脚跟先着地再平滑放平，落脚瞬间消除踝部前后回跳。
  - 行进缓转维持常规步幅步频并轻微偏脚尖；行进急转缩短步幅、加快步频，外侧步更长、内侧步更短，同时加入动态防交叉外摆净空。
  - 站立不动转身采用左右交替小碎步（90° 约 4 步、180° 约 6 步），每步带内倾与落脚轻震且不触发行走踩踏破坏，收尾步自然回正标准站距。
- **玩法目标角接入（`rust/src/round.rs`）**：扩展 `Giant::animate()` 与 `show_motion()` 可选参数 `(turn_target, allow_standing_turn)`（保持 3 参数调用向后兼容）；玩家行走时传入目标移动方向角，站立空闲时传入当前镜头/触屏环视朝向以触发站立小碎步转身；AI 巨人在踩踏冷却等待目标时记录 `ai_aim_yaw` 同步执行分层站立转向。
- **实机回归与导出过滤**：在 `tests/playtest.gd` 新增 `_giant_layered_turn()` 实机回归用例覆盖站立 90°/180° 分层顺序、胸头半比、脊柱反弧、肩部反拧、零滑移小碎步、脚跟先落及行进缓/急转内倾与不对称摆臂；`export_presets.cfg` 两个导出预设均增加 `prototypes/*` 排除项。

验证：桌面 OpenGL Compatibility 实机渲染复核了 `Kawaii`、`Hina` 与 `Chibi Catgirl` 在港口实景中的站立分层转身与行进左右急转；Rust 33 项、常规玩法 196 项（含 6 项新增实机转身断言）、成长玩法 175 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项、坐压专项 33 项、独立转身原型 43 项，共 613 项 Godot 断言和无界面启动校验全部通过。

改动前快照在 `backups/20261125_085900_giant_layered_turn/`。如需回滚，从工程根目录运行以下命令并重新编译 Rust：

```sh
snapshot=backups/20261125_085900_giant_layered_turn
cp -a "$snapshot"/scenes/giant_visual.gd scenes/
cp -a "$snapshot"/rust/src/round.rs rust/src/
cp -a "$snapshot"/tests/playtest.gd tests/
cp -a "$snapshot"/{export_presets.cfg,CHANGELOG.md,MEMORY.md} .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-25 — 新增巨人「坐压」程序化动作与独立测试预览场景（未接入正式玩法）

在 `scenes/giant_visual.gd` 新增独立的巨人「坐压」程序化骨骼动作接口 `show_sit_crush(progress, delta)` 与 `finish_sit_crush()`（默认时长 `4.80 s`，冲击点 `t = 0.375`），**暂未接入正式玩法、输入、AI 或伤害结算**，原有待机、行走、踩踏、抓取与挥拳逻辑保持不变。

动作分四阶段实现并适配 `Kawaii`、`Hina` 与 `Chibi Catgirl` 三套巨人外观：
- **准备下蹲（`0.00..0.30`）**：眼神与头部先低头锁定落点，双脚交替向两侧迈开（零滑步）、脚尖朝外，随后慢速屈膝沉胯、背部挺直、双臂向两侧张开保持平衡，呈现“坐向隐形椅子”的重量感蓄力与停顿预警。
- **快速重落（`0.30..0.44`）**：`0.36 s` 重力加速直坠（`pow(u, 2.35)`），双腿向两侧折叠、膝盖外张且保持在髋部前方，双脚全程平踩地面零滑移；臀部贴地瞬间触发滞后脊柱下压、下巴微收与双层头发上飘回落。
- **坐压停留与晃动压实（`0.44..0.67`）**：坐实停留约 `1.4 s`，骨盆带动重心先左后右缓慢晃压再回中稳住，躯干与双臂自然反向平衡且与膝部零穿模。
- **慢速撑地起身（`0.67..1.00`）**：上身前倾、双掌平贴地面（`min_y ≈ 0`，撑地期低滑移）配合腿部蹬伸缓慢抬胯，离地后双掌顺滑避开膝盖与右侧小熊挎包，膝盖伸直、双脚交替收回，脊柱逐节挺直恢复待机。

`scenes/giant_skin.gd` 新增只用于坐压的可选骨盆位移缩放 `pelvis_height_ratio()` / `follow_pose(pelvis_scale := 1.0)`（原有动作默认 `1.0` 零改动），保证 `Hina` 坐实不浮空、`Chibi Catgirl` 坐压与撑地不沉入地面。`_plant()` 新增可选向上极向量参数 `pole_up := 0.0`（默认 `0.0` 不影响既有动作）。

新增独立测试预览场景 `tests/sit_crush_preview.tscn` / `tests/sit_crush_preview.gd`（导出预设已排除 `tests/*`）：包含地面区域标识、可被压扁的小型目标群、落地震动、360° 向外扩散并在起身阶段才缓缓散开的柔边扬尘圈，支持播放/暂停/调速/逐帧拖动、多机位切换、三套外观切换与「行走 → 坐压」过渡测试；新增专项自动化验证 `tests/sit_crush_playtest.gd`。

验证：桌面 OpenGL Compatibility 实机渲染审查了三套外观的多视角序列帧与完整预览场景（含低角度目标视角、压扁目标、震动与扬尘散开）；Rust 33 项、坐压专项 33 项、常规玩法 190 项、成长玩法 175 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项，共 564 项 Godot 断言和无界面启动校验全部通过。

改动前快照在 `backups/20261124_235801_giant_sit_crush_anim/`。如需回滚，从工程根目录运行以下命令：

```sh
snapshot=backups/20261124_235801_giant_sit_crush_anim
cp -a "$snapshot"/scenes/{giant_visual,giant_skin}.gd scenes/
cp -a "$snapshot"/CHANGELOG.md .
rm -f tests/sit_crush_preview.tscn tests/sit_crush_preview.gd tests/sit_crush_preview.gd.uid \
      tests/sit_crush_playtest.gd tests/sit_crush_playtest.gd.uid
```

---

## 2026-11-24 — 修复巨人皮肤脚部持续踮脚问题

`Hina` 和 `Chibi Catgirl` 皮肤原本把脚踝到脚尖骨骼放进了 3D `ALIGN_TOWARD`，将两套平底靴的默认姿态强行对齐到默认 `Kawaii` 皮肤高跟凉鞋约 `-56.5°` 的踝-趾斜率，造成 `Hina` 脚部永久下压约 `20°~23°`、`Chibi Catgirl` 永久下压 `25°~30°` 并伴随约 `±15°` 侧翻，同时脚尖骨骼未继承偏移而在脚掌处上折，使待机、行走和踩踏全程呈踮脚状。

`scenes/giant_skin.gd` 新增水平偏航对齐参数 `yaw_alignments`（绕驱动骨架上方向旋转，并将同一水平偏航同步到脚尖骨骼），`scenes/hina_skin.gd` 和 `scenes/chibi_catgirl_skin.gd` 将左右脚改为仅水平偏航对齐，保留平底靴的自然接地俯仰。同时清除了 `Chibi Catgirl` 导出 Rigify 姿势中残留的腿部拉伸缩放，并重新校准其 `FIT_SCALE` 与 `FLOOR_OFFSET`，使左右脚平齐贴地且站立身高与另外两套皮肤一致。

验证：桌面 Compatibility 实机渲染检查了三套皮肤的待机、行走和踩踏脚部姿态；常规玩法 190 项、成长玩法 175 项（新增两套皮肤待机脚部水平与左右踝齐平回归断言）、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项，共 531 项 Godot 断言和无界面启动校验通过。

改动前快照在 `backups/20261124_232400_fix_skin_tiptoe_feet/`。如需回滚，从工程根目录运行以下命令：

```sh
snapshot=backups/20261124_232400_fix_skin_tiptoe_feet
cp -a "$snapshot"/scenes/{giant_skin,hina_skin,chibi_catgirl_skin}.gd scenes/
cp -a "$snapshot"/tests/growth_playtest.gd tests/
cp -a "$snapshot"/CHANGELOG.md .
```

---

## 2026-11-24 — AI 踩踏预判与冷却后撤修正

AI 踩踏瞄准会用 `predict_stomp_target` 按目标当前速度外推半个蓄力时间，但外推速度上限对所有目标都使用人类冲刺速度 9.5 m/s。成长模式和大乱斗的巨人整体速度默认 4 倍，25.2 米巨人实际速度约 26 m/s；预判只按 9.5 m/s 计算，落点会落在移动巨人身后，快速巨人对战尤其明显。新增 `stomp_lead_cap`：巨人对手按 `GIANT_WALK × 巨人整体速度 × min(scale,1)` 取上限，人类/行人仍按 `HUMAN_SPRINT × 人类整体速度`。4 倍速度下 25.2 米巨人的上限为 28 m/s，能覆盖实际 26 m/s。

势均力敌的 AI 巨人进入踩踏威胁距离后，只要自己的踩踏还在冷却就会后撤；两名巨人都后撤时就会互相绕圈、迟迟不攻击。现在只在真正处于劣势（`outmatched`，对手有效生命超过自身 1.5 倍）时后撤，同等体型会站住对拼。

没有改变的部分：踩踏仍需先进入左脚脚底椭圆，锁定后约 0.52 秒（按体型和整体速度缩放）不能改向；默认 100 生命 / 10 攻击需要 10 次命中，冷却固定 0.72 秒，所以击倒满血巨人仍需要数秒。玩家自己的踩踏落点在左脚前方约 7×体型 米、左侧约 1.39×体型 米，不在准星中心，以橙色预警椭圆为准。

验证：Rust 33 项、常规玩法 190 项、成长玩法 173 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项，共 529 项 Godot 断言和无界面启动校验通过。

改动前快照在 `backups/20261124_165949_giant_stomp_lead/`。本次只改了 `rust/src/round.rs`：

```sh
snapshot=backups/20261124_165949_giant_stomp_lead
cp -a "$snapshot"/rust/src/round.rs rust/src/
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-24 — 开放地图边长和音量设置

四种玩法的地图边长接受正整数，取消 48～1,800 米的固定范围。小地图根据可用空间收窄边墙、裁剪街区并调整撤离点，放不下的设施会省略。音效和环境音量可设为 100% 以上，实时预览和存档使用相同的增益。

Rust 30 项、Godot 524 项和启动校验通过，覆盖 24 米、1,900 米地图的生成与碰撞、1 米地图的开局、150% 和 225% 音量的预览与重启读档。大乱斗通过全部断言，退出时仍报告资源释放告警。

改动前快照位于 `backups/20261124_122453_open_added_settings/`。从工程根目录可恢复本次涉及的文件。

```sh
snapshot=backups/20261124_122453_open_added_settings
cp -a "$snapshot"/scenes/{audio_manager,district,district_expansion,interface,round_effects}.gd scenes/
cp -a "$snapshot"/rust/src/{round,rules,settings}.rs rust/src/
cp -a "$snapshot"/tests/{audio_playtest,playtest,touch_playtest}.gd tests/
cp -a "$snapshot"/{MEMORY,README}.md .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-24 — 移除地图路障，人类速度与两项忽略倍率独立设置

**地图路障。** 删除 `scenes/district.tscn` 的 3 个场景内路障（`Barrier1–3`）和 `scenes/district_expansion.gd` 沿外围大道生成的 6 个路障。`District/Targets` 现在只包含建筑和地标；`scenes/district.gd` 不再对小路障做特殊裁剪。`scenes/damageable.gd` 的 `barrier` 分支和 `rust/src/route.rs` 的非建筑障碍处理保留，当前没有实例；人类撤离和沙盒测试改为检查地图没有 `kind == "barrier"` 的 Targets 子节点。

**设置。** 玩法设置新增 3 个所有模式独立保存的数值：

- `human_speed`「人类整体速度」默认 1.0 倍，同时乘在撤离玩家的行走/冲刺和成长模式人类阶段的移动速度上；`giant_visual.gd` 的人类走路动画通过 `human_pace` 跟随该倍率。
- `rival_ignore_ratio`「巨人互相忽略的身高倍率」从成长/大乱斗分组移到所有模式的通用项，默认 10 倍，仍沿用原扁平存档键，旧档无需迁移。
- `human_ignore_ratio`「巨人忽略人类/行人的身高倍率」新增，默认 30 倍。AI 的 `combat_target()` 用双方实际身高过滤人类/行人候选；达到倍率后巨人不再主动追击或踩踏该目标，但走路落脚仍按原命中规则结算。25.2 米巨人对 1.8 米玩家约 14 倍，默认仍会追击，人类撤离模式的威胁不变。

三项都保存后立即生效。`GameSettings` 的旧 `growth.rival_ignore_ratio` 字段已移除，`combat_rules()` 只保留成长/大乱斗的生命、攻击和金币参数。设置界面在四个标签页都显示三项，并补充了人类速度、两项忽略倍率的默认值与生效说明。

Rust 32 项、常规玩法 190 项、成长玩法 173 项、大乱斗 43 项、菜单与卧室 45 项、触控 42 项、音效 36 项，共 529 项 Godot 断言和无界面启动校验通过。新增测试覆盖两项忽略倍率的独立保存与行为、人类速度 1x/2x 的行走距离、旧档缺字段回退，以及地图无路障。

改动前快照位于 `backups/20261124_123758_remove_road_barriers/`。该快照在并行的「开放地图边长和音量设置」和镜头震动音效之后取得，恢复它会保留那些改动。只恢复本次涉及的文件：

```sh
snapshot=backups/20261124_123758_remove_road_barriers
cp -a "$snapshot"/scenes/{district,district_expansion,giant_visual,human_visual,interface}.gd scenes/
cp -a "$snapshot"/scenes/district.tscn scenes/
cp -a "$snapshot"/rust/src/{round,settings}.rs rust/src/
cp -a "$snapshot"/rust/src/round/growth.rs rust/src/round/
cp -a "$snapshot"/tests/{playtest,growth_playtest}.gd tests/
cp -a "$snapshot"/{CHANGELOG,MEMORY,README}.md .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-24 — 为镜头震动添加深层地震轰鸣音效（方案 A）

基于试听选定的方案 A（深层地震轰鸣 / Deep Seismic Rumble），在 `scripts/generate_audio.py` 新增 `gen_camera_shake()` 生成立体声轻/重两档低频震动音效（`assets/audio/camera_shake_light.wav` 与 `assets/audio/camera_shake_heavy.wav`），目前音效资产共 44 个 WAV 与 2 个无缝循环 OGG。

`scenes/audio_manager.gd` 新增独立的 2 声道可暂停震动音效池（走 `SFX` 总线），提供 `play_camera_shake(intensity, source_height)` 与 `stop_camera_shake()`：按震动强度自动区分轻/重素材（`>= 0.55` 走重型）并映射音量（`-18.0 ~ -1.5 dB`），按震源巨人身高缩放音高，具备 0.14 秒防刷屏冷却与 1.45 倍强震抢占逻辑，暂停时自动冻结。

`rust/src/round.rs` 让 `CameraShake::add_peak()` 返回是否触发新峰值，在 `flush_camera_impacts()` 中仅当镜头实际产生震动时同步触发 `HarborAudio.play_camera_shake()`，并在 `reset_camera_shake()` 中调用 `stop_camera_shake()`；天然遵循旁观者静默、「镜头震动强度 = 0」静音与关闭「自身震动」静默自身震源的规则。

`tests/audio_playtest.gd` 新增 4 项验证（巨人行走震动、重踏震动、`shake_strength = 0` 静音、`own_camera_shake = false` 静音自身）。全量回归通过：Rust 30 项、无界面启动校验（0 泄漏）、音效 35 项、菜单与卧室 45 项、触控 42 项、大乱斗 43 项、常规玩法 185 项、成长玩法 171 项（共 521 项 Godot 断言全部通过）。

改动前快照位于 `backups/20261124_105600_camera_shake_sfx/`（注意：该快照中的 `round.rs` 早于并行合入的多角色性能优化，仅回滚镜头震动音效时请对照 `diff` 移除 `round.rs` 中的 `play_camera_shake` / `stop_camera_shake` 调用，其余文件可直接恢复）：

```sh
snapshot=backups/20261124_105600_camera_shake_sfx
cp -a "$snapshot/generate_audio.py" scripts/generate_audio.py
cp -a "$snapshot/audio_manager.gd" scenes/audio_manager.gd
cp -a "$snapshot/audio_playtest.gd" tests/audio_playtest.gd
rm -f assets/audio/camera_shake_light.wav assets/audio/camera_shake_light.wav.import \
      assets/audio/camera_shake_heavy.wav assets/audio/camera_shake_heavy.wav.import
# 查看 round.rs 差异以仅移除镜头震动音效调用（保留并行性能优化）
diff -u "$snapshot/round.rs" rust/src/round.rs
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-24 — 多角色成对检查缓存、寻路分桶与远距动画分级

角色数量拉高后，Rust 的接触与碰撞两轮成对检查、AI 寻路和远处程序化骨骼更新是主要开销。本次在不改动伤害与碰撞判定顺序的前提下做了三件事：

- `rust/src/round.rs` 新增每帧 `PairFrame` 快照：一次读取每名角色的位置、碰撞半径/高度、安全边距、步速、体型和存活状态。`update_giant_collision_passes()` 与 `apply_giant_contact_stomps()` 共用该快照；碰撞通过仍在移动前结算，接触踩踏仍在所有移动和手部攻击之后结算，按原 `i < j` 顺序遍历，只对已跟踪或确实可能接触的成对候选做物理查询。
- `rust/src/route.rs` 把障碍的逆变换和水平包围盒预先算好，并按寻路格分桶。每个格点只检查身边障碍，不再对每个格点扫描整窗障碍。新增对照测试，验证分桶结果与全量扫描生成的路线完全一致。
- AI 路线申请进入每帧最多 4 个、2.5 毫秒的队列，按角色序号轮转执行；请求带序号，路径被清空或目标变化后旧计划不会覆盖新状态。`rust/src/round/growth.rs` 的拾荒寻路同样走该队列。
- 额外优化：离镜头 120 米内的角色和玩家每帧更新程序化骨骼，120～240 米隔帧，更远每三帧，累积时间上限 0.05 秒；全速范围随身高增长（`max(120, 身高 × 1.2)`），数百米高的巨人近距离保持全速。

多角色性能探针位于 `tests/perf_probe.gd`。60 角色 headless release 物理帧均值（改动前 → 改动后）：大乱斗混合体型 27.8 → 17.2 ms，成长混合体型 29.5 → 21.5 ms，成长高压成对 27.2 → 18.9 ms，沙盒 23.8 → 19.2 ms；20 角色大乱斗约 9.1 → 5.8 ms。784 个障碍、660 米路线的寻路微基准由 135.09 ms 降到 1.15 ms。60 角色仍会超过 16.7 ms 的帧预算，剩余主要是 60 个 `CharacterBody3D` 的 `move_and_slide` 和完整程序化动画，不是成对检查或 A*。

验证：Rust 30 项、成长 171 项、常规 185 项、大乱斗 43 项、菜单 45 项、触控 42 项、音效 35 项、无界面启动校验通过。

改动前快照在 `backups/20261124_103348_pair_cache_path_stagger/`。**该快照早于并行的镜头震动音效改动**；整文件恢复 `round.rs` 会同时移除 `add_peak` 返回值、`play_camera_shake` 和 `stop_camera_shake` 调用。只回滚性能改动时先对比差异，或恢复后重新补回音效调用：

```sh
snapshot=backups/20261124_103348_pair_cache_path_stagger
diff -u "$snapshot/rust/src/round.rs" rust/src/round.rs
diff -u "$snapshot/rust/src/round/growth.rs" rust/src/round/growth.rs
diff -u "$snapshot/rust/src/route.rs" rust/src/route.rs
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

`tests/perf_probe.gd` 是本次新增的手动探针，只打印均值/P50/P95/最长帧，不在自动通过/失败统计内。

---

## 2026-11-24 — Linux x86_64 发布导出

新增 `Linux x86_64` 导出预设。Godot 使用匹配版本的 Linux 模板和 Rust release 扩展，在 `build/linux/` 生成可执行文件、资源包和 `libharbor.so`。

从项目目录之外运行导出文件，确认无界面启动和 X11 图形启动均通过。导出包中的扩展与 Rust release 构建产物一致。

改动前的快照在 `backups/20261124_094604_linux_export/`。从项目根目录可恢复导出预设和说明。

```sh
snapshot=backups/20261124_094604_linux_export
cp -a "$snapshot"/export_presets.cfg "$snapshot"/README.md .
```

---

## 2026-11-24 — 远距巨人剪影、自身震动与碰撞

身高达到 150 米的其他存活巨人在渲染视距外以低对比度剪影显示。剪影使用当前皮肤和动画，保留建筑遮挡。相机为剪影按需延长远裁剪面，普通角色保持原来的裁剪范围，港区区块和海雾继续使用渲染视距设置。

巨人沙盒、成长模式和大乱斗在「镜头震动强度」下新增「自身震动」，默认开启，各模式独立保存。关闭后马上移除自己的脚步、踩踏和建筑碾压震动，保留其他震动的衰减进度。

身体撞击由较高的生物结算。普通行走落脚仅对同高或更矮的生物结算伤害，适用于行人、撤离玩家和巨人。主动重踏使用战斗命中规则。

有巨人的角色组合达到 3 倍身高差时可以通过，现有忽略倍率低于 3 时使用该较低值。接触踩踏使用双方移动轨迹判断，让较小的角色存活时也不会把较大的角色挡住。分开后恢复可碰撞状态。

Rust 27 项、Godot 517 项玩法断言和启动校验通过。桌面实渲在 120 米渲染视距下检查了 770 米外的三套皮肤，并确认前景遮挡。大乱斗测试退出时出现资源释放告警。

改动前的快照在 `backups/20261124_091318_distant_giant_silhouettes/`。恢复本次改动涉及的源码和测试可用下列命令。

```sh
snapshot=backups/20261124_091318_distant_giant_silhouettes
cp -a "$snapshot"/rust/src/{round,settings}.rs rust/src/
cp -a "$snapshot"/rust/src/round/growth.rs rust/src/round/
cp -a "$snapshot"/scenes/{giant_visual,interface}.gd scenes/
cp -a "$snapshot"/tests/{brawl_playtest,growth_playtest,playtest,touch_playtest}.gd tests/
cp -a "$snapshot"/{README,MEMORY}.md .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-24 — 为港区各模式、微缩卧室与界面添加完整音效系统

新增由 `scripts/generate_audio.py` 合成的 42 个 WAV 音效与 2 个 16 秒无缝循环 OGG 环境声（`assets/audio/`），涵盖巨人脚步与重踏、踩踏预警、挥拳/抓取/捏碎、建筑开裂/倒塌/恢复与路障击碎、人类/成长阶段步行与疾跑、受击与体力耗尽、金币拾取（带连续拾取升调）与大乱斗掉币、成长脉冲与人类变巨人音效、战斗命中/击倒/复活/视角切换、微缩卧室步行与攀爬翻越、界面交互（悬停/点击/返回/报错/暂停/继续/撤离胜负），以及港区海风海浪与卧室室内环境声。

新增四总线音频配置 `default_bus_layout.tres`（`Master`、`SFX` 含限幅器防多巨人叠音爆音、`Ambience`、`UI`）及全局 Autoload `HarborAudio`（`scenes/audio_manager.gd`）。3D 空间音效采用池化声道复用、距离剔除、冷却节流与按巨人身高缩放的音高与衰减范围；暂停时自动冻结对局音效并压低环境声，界面音效不受暂停影响。

「玩法设置」新增全局持久化的「音效音量」「环境音量」（0～100%，实时预览）与「静音」开关，保存到 `user://gameplay.cfg` 的 `[audio]` 段落并兼容旧存档。同步从系统 Noto Sans CJK SC 补齐 `assets/fonts/harbor-ui.otf` 移动端字形子集。

Rust 26 项、Godot 493 项测试与无泄漏启动校验全部通过，其中音效专项 31 项、常规玩法 181 项、成长玩法 162 项、菜单与卧室 45 项、模拟触控 41 项、大乱斗 33 项。

改动前的完整快照位于 `backups/20261124_085500_sound_effects/`（注意：该快照早于并行合入的 48 米紧凑地图改动，如仅需回滚音效请按文件选择性恢复或先保留紧凑地图改动）：

```sh
# 查看本次音效改动相对快照的差异
snapshot=backups/20261124_085500_sound_effects
diff -ru "$snapshot/rust/src" rust/src
diff -ru "$snapshot/scenes" scenes

# 仅移除本次新增的音效资产与脚本（其余源码请对照上方 diff 还原）
rm -rf assets/audio default_bus_layout.tres scenes/audio_manager.gd scripts/generate_audio.py tests/audio_playtest.gd tests/audio_playtest.gd.uid
```

---

## 2026-11-24 — 地图最小边长降至 48 米

四种模式现在都支持 48 米边长。最小地图保留中央十字街和四栋全尺寸厂房，铺装、外围设施和出生点按实际尺寸调整。撤离圈放不下时移到东侧道路，玩家从圈外出生。紧凑地图按比例缩短巨人的开局间距，仍按实际体型保留碰撞净空。

地图专项 23 项和常规玩法 181 项通过，覆盖四种模式的 48 米开局、地面和边界碰撞、金币和撤离。

改动前的快照在 `backups/20261124_085931_compact_maps/`。回滚时，用快照对照恢复 `rust/src/round.rs` 中的开局间距和出生调整，把 `rust/src/settings.rs` 和 `scenes/interface.gd` 的边长下限及提示改回 360 米。地图场景和相关玩法测试可以从快照直接恢复。

```sh
snapshot=backups/20261124_085931_compact_maps
cp -a "$snapshot"/scenes/{district,district_expansion}.gd scenes/
cp -a "$snapshot"/tests/playtest.gd tests/
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-24 — 大乱斗安全复活与各模式地图边长

大乱斗先抽取复活身高，再从所有存活巨人索敌范围之外的安全点加权抽取。接近体型相近的巨人时权重更高。常规候选和细网格都找不到范围外的安全点时，允许在范围内复活，仍需避开建筑和角色碰撞。

人类撤离、巨人沙盒、成长模式和大乱斗可在「玩法设置」分别保存地图边长。默认 1418 米，可填 360～1800 米的整数。下一局重新生成地面、海岸、街区、道路和碰撞边界。旧存档缺少该设置时采用默认尺寸。

Rust 25 项、Godot 455 项测试和启动校验通过。桌面渲染与模拟触屏均检查了地图输入和中文显示。

改动前的快照在 `backups/20261124_084330_brawl_respawn_map_size/`。从项目根目录可恢复本次改动涉及的文件。

```sh
snapshot=backups/20261124_084330_brawl_respawn_map_size
cp -a "$snapshot"/rust/src/{game,settings}.rs rust/src/
cp -a "$snapshot"/rust/src/round/growth.rs rust/src/round/
cp -a "$snapshot"/scenes/{district,district_expansion,interface}.gd scenes/
cp -a "$snapshot"/tests/{brawl_playtest,playtest,touch_playtest}.gd tests/
cp -a "$snapshot"/assets/fonts/harbor-ui.otf assets/fonts/
cp -a "$snapshot"/{README,MEMORY}.md .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-24 — 修复大乱斗随机开局堆积在最低身高

随机开局抽到地图无法安全容纳的体型时，改为排除这次及更高的身高，再从剩余区间均匀抽取。使用 0.01～1,000 米、10 名巨人和同四个随机种子复测，最低身高出现次数从 25/40 降至 0/40。

改动前的文件快照在 `backups/20261124_001357_brawl_spawn_sampling/`。可以从工程根目录恢复这次改动涉及的文件。

```sh
snapshot=backups/20261124_001357_brawl_spawn_sampling
cp -a "$snapshot"/rust_src/round/growth.rs rust/src/round/
cp -a "$snapshot"/tests/brawl_playtest.gd tests/
cp -a "$snapshot"/README.md "$snapshot"/MEMORY.md .
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-24 — 全图金币刷新、拆分金币/拆楼成长幅度与视距边界雾隐

成长模式的金币不再刷在巨人旁边，改为按分层随机网格分布到全图道路、公园、广场、院落与空地，并避开存活角色附近（默认至少 18 米净空）和建筑碰撞范围。全图共享金币默认数量提高到 200 枚、刷新间隔提高到 60 秒；金币改用合并双材质网格并按渲染视距定时剔除与旋转，最近金币指南针取消 35 米上限、支持全图指引，小体型 AI 在金币被建筑遮挡时会寻路绕楼拾取。

成长模式的「每次成长幅度」拆分为独立的「金币成长幅度」（`coin_growth_rate`，默认 10%）与「拆楼成长幅度」（`building_growth_rate`，默认 10%），分别作用于拾取金币和各类拆楼方式（踩踏、触碰碾压、手部捏碎）。旧存档中的 `growth_rate` 读取时自动迁移到两项设置，下次保存后移除旧键。

主场景环境雾切换为深度雾（`FOG_MODE_DEPTH`），`HarborGame` 按当前相机的 `district_draw_distance` 与相机高度动态同步 `fog_depth_begin` / `fog_depth_end`（在视距 50%～92% 区间平滑雾隐，并对高空视角作斜距补偿），同时将天空下半球颜色与雾色对齐，使主菜单总览、街道近/中视距及高空第一人称的视距边界均无断层融入海雾。

Rust 24 项、Godot 427 项测试及启动校验全部通过，其中常规玩法 158 项、成长玩法 162 项、菜单与卧室 45 项、模拟触控 40 项、大乱斗 22 项。桌面 Compatibility 实际渲染检查了主菜单 460 m、街道 120 m / 300 m 与 200 m 第一人称高空俯视的雾隐过渡效果。

本次开始改动前的完整备份在 `backups/20261123_204505_mapwide_coins_split_growth/`（包含 `rust/src`、`scenes`、`tests`、`scripts`、`native`、`assets` 及配置文档）。如需整体还原至该快照（注意会一并回退该快照之后并行合入的改动），从工程根目录运行以下命令：

```sh
snapshot=backups/20261123_204505_mapwide_coins_split_growth
rsync -a --delete --exclude='/backups/' --exclude='/.godot/' --exclude='/build/' \
  --exclude='/rust/target/' --exclude='/native/*.so' --exclude='/CHANGELOG.md' "$snapshot/" ./
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-24 — 新增大乱斗模式

「港区警报」二级菜单新增大乱斗，同局玩家与 AI 全程使用巨人形态。拆楼、战斗、击杀成长、身高排名和触屏操作沿用成长模式的逻辑。拆楼只结算建筑破坏，击杀和捡币结算身高。

达到掉币分界的击杀者在脚下掉落金币，金币记住击杀时身高计算出的奖励米数。默认分界是 50 米，奖励是 1%。倒下后先随机抽取复活身高，默认在 30 米以内，再到身高最接近的存活巨人附近寻找有安全间距的落点。大乱斗设置独立保存，新增数值输入可直接填写。

大乱斗 AI 只主动攻击其他巨人，空闲时持续游走。达到 40 米碾压门槛后，游走、追击和捡币可直接穿过建筑。开启「随机开局身高」后，每名巨人各自从自定义的区间抽取出生身高。开局与复活区间分别保存。

Rust 24 项和 Godot 435 项测试通过，其中大乱斗专项 30 项。Godot 启动校验通过，桌面实渲检查了模式菜单、设置和对局 HUD。

改动前的源码、场景、测试及字体快照在 `backups/20261123_234531_brawl_mode/`。整组文件恢复也会回退快照之后的并行改动。需要查看差异时，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_234531_brawl_mode
diff -ru "$snapshot/rust_src" rust/src
diff -ru "$snapshot/scenes" scenes
diff -ru "$snapshot/tests" tests
```

要把上述文件组整体恢复到该快照，使用以下命令。

```sh
snapshot=backups/20261123_234531_brawl_mode
cp -a "$snapshot"/rust_src/. rust/src/
cp -a "$snapshot"/scenes/. scenes/
cp -a "$snapshot"/tests/. tests/
cp -a "$snapshot"/assets/fonts/harbor-ui.otf assets/fonts/
cp -a "$snapshot"/README.md "$snapshot"/MEMORY.md .
rm -f tests/brawl_playtest.gd tests/brawl_playtest.gd.uid
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 — 玩法设置开放数值输入

设置界面和存档取消预设数值边界。小数保留原有输入精度，数量使用整数，无效值会指出具体字段。初始身高和成长上限独立保存，开局身高可以高于成长上限。金币数量为零时不生成金币。

角色数量超过预设名字池时，额外角色使用七位随机字母和数字，局内保持唯一。桌面展开排行后可以用滚轮查看超出一屏的角色。

Rust 24 项、Godot 424 项测试和启动校验通过。验证了旧区间外的输入和读档、初始身高与成长上限独立生效，以及 60 名角色开局时的 20 个随机名字和排行榜滚动。

改动前的完整源码与资产备份在 `backups/20261123_234153_open_numeric_settings/`。以下命令将工程整体还原到该快照，也会还原快照后并行加入的改动。

```sh
snapshot=backups/20261123_234153_open_numeric_settings
rsync -a --delete --exclude='/backups/' --exclude='/.godot/' --exclude='/build/' \
  --exclude='/rust/target/' --exclude='/native/*.so' --exclude='/CHANGELOG.md' "$snapshot/" ./
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 — 成长模式两阶段：人类长大成巨人，取消行人 NPC

成长模式不再生成行人 NPC。玩家和 AI 都从人类阶段开始：使用 `human_kenney` 人类建模、人类比例的胶囊体，没有加速奔跑，不能踩踏、抓取、挥拳或拆楼。金币成长到「变成巨人的身高」（设置项 `attack_height`，默认 3 米）后自动切换为原本的巨人建模并解锁全部巨人动作。人类和巨人的生命、攻击继续使用「1 厘米基准 × 身高」的同一套数值。

人类之间的伤害改为体型撞击：两名人类都低于巨人门槛时，身高达到对方两倍的一方撞倒另一方，使用攻击者的身高计算伤害，并新增「撞击击倒」的击杀播报。巨人 AI 会把处于人类阶段的玩家和其他 AI 当作过去的行人处理，可以踩踏、抓起捏碎或挥拳；人类 AI 只寻找金币、漫游，并远离两倍以上身高的角色。人类阶段的移动速度按身高缩放，完全不受「巨人整体速度」设置影响。

玩家和 AI 的巨人皮肤在开局抽取一次，复活后不再重抽；再次成长到巨人阶段时仍是同一套皮肤。随机开局身高改为在「初始身高」和「成长身高上限」之间对数采样；低于变成巨人的身高时随机为人类 AI，达到门槛时随机为巨人 AI。

设置中删除了「行人身高」和「免受人类碰撞伤害的身高」，原「拆楼与攻击行人的身高」改名为「变成巨人的身高」。新增 `growth_actors()` 玩法测试接口，用于逐角色检查阶段、身高、生命和解锁状态。

Rust 23 项、Godot 393 项测试通过，其中常规玩法 153 项、成长玩法 159 项、菜单与卧室 41 项、模拟触控 40 项。Godot 启动校验通过。本轮未执行桌面实际渲染截图，模型切换、第一人称头部隐藏和人类/巨人动画由 headless 节点检查覆盖。

修改前的备份在 `backups/20261123_215737_no_npc_two_stage_growth/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_215737_no_npc_two_stage_growth
cp -a "$snapshot"/rust_src/. rust/src/
cp -a "$snapshot"/scenes/. scenes/
cp -a "$snapshot"/tests/. tests/
cp "$snapshot"/README.md README.md
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

## 2026-11-23 — Chibi Catgirl 巨人外观

玩家和 AI 巨人出生或复活时，从 Kawaii、Hina 和 Chibi Catgirl 中独立等概率抽取外观。Chibi Catgirl 复用待机、走路、踩踏、抓取和挥拳，手指沿用原模型姿势。模型已按巨人身高校准，第一人称会隐藏头部和帽尖。贴图导入上限为 2K，使用桌面和安卓平台的显存压缩。

Godot 启动校验和 402 项测试通过，其中常规玩法 153 项、成长玩法 169 项、菜单与卧室 41 项、模拟触控 39 项。桌面 Compatibility 实际渲染检查了站姿、四种动作和第一人称。

修改前的备份在 `backups/20261123_202637_chibi_catgirl_skin/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_202637_chibi_catgirl_skin
cp "$snapshot"/scenes/{giant_visual,hina_skin}.gd scenes/
cp "$snapshot"/tests/growth_playtest.gd tests/
cp "$snapshot"/README.md README.md
rm -f scenes/{giant_skin,chibi_catgirl_skin}.gd scenes/{giant_skin,chibi_catgirl_skin}.gd.uid
rm -f assets/characters/chibi_catgirl.glb assets/characters/chibi_catgirl.glb.import
rm -f assets/characters/chibi_catgirl_[0-9]*.png assets/characters/chibi_catgirl_[0-9]*.png.import
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 — Hina 与巨人随机外观

玩家和 AI 巨人每次出生或复活时独立抽取 Kawaii 或 Hina，两套外观等概率。Hina 从原始 GLB 的蒙皮数据恢复绑定姿势，并跟随现有巨人的行走、踩踏、抓取和挥拳。第一人称隐藏头部，受击闪光应用到当前外观。

Godot 启动校验和 395 项测试通过，其中常规玩法 153 项、成长玩法 162 项、菜单与卧室 41 项、模拟触控 39 项。桌面 Compatibility 渲染检查了 Hina 的待机及四种动作。

修改前的备份在 `backups/20261123_200632_hina_random_giant_skins/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_200632_hina_random_giant_skins
cp "$snapshot"/scenes/giant_visual.gd scenes/
cp "$snapshot"/tests/growth_playtest.gd tests/
cp "$snapshot"/README.md README.md
rm -f scenes/hina_skin.gd scenes/hina_skin.gd.uid
rm -f assets/characters/hina.glb assets/characters/hina.glb.import
rm -f assets/characters/hina_[0-9]*.png assets/characters/hina_[0-9]*.png.import
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 — AI 偶尔主动捡起捏碎

巨人成长和巨人沙盒中，AI 同时可以踩踏和抓取当前目标时，每次出招有 90% 概率踩踏、10% 概率捡起捏碎。抓取仍需通过原有的体型、距离和视线判定。踩踏够不到时，AI 会继续尝试可用的手部攻击。

Rust 20 项、Godot 389 项测试通过。专项测试验证了相同距离下的两种选择，以及 AI 抓起后完成捏碎。

修改前的备份在 `backups/20261123_143258_ai_grab_probability/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_143258_ai_grab_probability
cp "$snapshot"/rust/src/round.rs rust/src/
cp "$snapshot"/rust/src/round/hands.rs rust/src/round/
cp "$snapshot"/tests/growth_playtest.gd tests/
cp "$snapshot"/README.md README.md
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-23 — 移除成长行人的随机身高

成长模式的开局行人与后续刷新行人统一使用「行人身高」的固定值，默认 1.8 米。旧存档里的随机身高字段会在读取时忽略，并在下次保存设置时移除。

Rust 20 项、Godot 385 项测试通过，另验证了启用过随机身高的旧配置按保存的固定身高加载。

修改前的备份在 `backups/20261123_134133_remove_random_civilian_height/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_134133_remove_random_civilian_height
cp "$snapshot"/scenes/interface.gd scenes/
cp "$snapshot"/tests/growth_playtest.gd tests/
cp "$snapshot"/rust/src/{round,settings}.rs rust/src/
cp "$snapshot"/README.md README.md
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-23 — 成长行人血条与随机身高

成长模式的行人 NPC 新增头顶血条，最大生命和碰撞攻击按其实际碰撞体身高同比例缩放。1.8 米时各为 1000，改变体型保留当前生命比例。AI 的碰撞和攻击范围判断使用对应的实际尺寸。

玩法设置新增行人固定身高和随机身高选项，所有身高输入范围为 0.1～10 米，默认固定 1.8 米。随机模式默认范围为 1.5～2.1 米，开局和后续刷新的行人独立抽取身高。设置从下一局生效。

Godot 启动校验通过。Rust 20 项、常规玩法 153 项、成长玩法 152 项、菜单与卧室 41 项、模拟触控 39 项全部通过。

修改前的备份在 `backups/20261123_132828_growth_human_stats/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_132828_growth_human_stats
cp "$snapshot"/scenes/{human_visual,interface}.gd scenes/
cp "$snapshot"/scenes/human.tscn scenes/
cp "$snapshot"/tests/growth_playtest.gd tests/
cp "$snapshot"/rust/src/{round,rules,settings}.rs rust/src/
cp "$snapshot"/rust/src/round/{growth,hands}.rs rust/src/round/
cp "$snapshot"/assets/fonts/harbor-ui.otf assets/fonts/
cp "$snapshot"/README.md README.md
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 — 成长击杀播报与自定义建筑刷新时间

成长模式的三个角色都能看到屏幕上方的击杀播报。播报记录击倒者、被击倒者和致命攻击，也提示巨人因行人碰撞倒下。最多显示最近 3 条，每条约 5 秒。暂停时冻结，重开时清空。

成长设置新增「建筑刷新等待时间」，范围为 1～600 秒，默认 60 秒，从下一局生效。每栋建筑单独计时，原址有角色时延后恢复。短间隔刷新会结束原楼体剩余的倒塌动画和扬尘。

Godot 启动校验通过。Rust 20 项、常规玩法 153 项、成长玩法 142 项、菜单与卧室 41 项、模拟触控 39 项全部通过。

修改前的备份在 `backups/20261123_131709_growth_kill_feed/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_131709_growth_kill_feed
cp "$snapshot"/scenes/{damageable,interface}.gd scenes/
cp "$snapshot"/tests/{growth,touch}_playtest.gd tests/
cp "$snapshot"/rust/src/{game,round,settings}.rs rust/src/
cp "$snapshot"/rust/src/round/{growth,hands}.rs rust/src/round/
cp "$snapshot"/assets/fonts/harbor-ui.otf assets/fonts/
cp "$snapshot"/README.md README.md
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 — 巨人捡起捏碎与挥拳

巨人沙盒和巨人成长接入预览工程的蹲下抓取、抬手捏碎和挥拳骨骼动画。电脑端用 Q 和 E，安卓端使用独立触屏按钮。捡起捏碎要求攻击者至少为目标的 3 倍身高，挥拳要求较高一方最多为较矮一方的 2 倍身高。动作在动画的接触帧判断体型、距离和遮挡。击倒与拆楼沿用原有成长和建筑刷新规则。

Godot 启动校验通过。Rust 20 项、常规玩法 153 项、成长玩法 131 项、菜单与卧室 41 项、模拟触控 37 项全部通过。专项验证覆盖体型临界值、出拳躲避、暂停时的抓取和 AI 挥拳命中。

修改前的备份在 `backups/20261123_130014_giant_hand_attacks/`。如需回滚，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_130014_giant_hand_attacks
cp "$snapshot"/scenes/{damageable,giant_visual,interface,touch_controls}.gd scenes/
cp "$snapshot"/tests/{growth,touch}_playtest.gd tests/
cp "$snapshot"/rust/src/round.rs rust/src/
cp "$snapshot"/rust/src/round/growth.rs rust/src/round/
cp "$snapshot"/assets/fonts/harbor-ui.otf assets/fonts/
cp "$snapshot"/{README.md,project.godot} .
rm -- rust/src/round/hands.rs
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 — 成长模式的旁观角色与建筑刷新

巨人成长菜单新增旁观者模式和人类模式。旁观者可自由飞行，人类可在街道上行走和疾跑。两种玩法由 AI 控制全部巨人，保留身高排名。人类旁观者免伤，进入原撤离点会继续对局。

成长模式的共享设置新增「建筑刷新」，默认关闭，从下一局生效。开启后，每栋建筑被摧毁满 60 秒且原址无角色时恢复。刷新会重置建筑耐久、外观和碰撞，保留巨人已获得的成长与拆楼进度。

Godot 启动校验通过。Rust 19 项、常规玩法 153 项、成长玩法 121 项、菜单与卧室 41 项、模拟触控 33 项全部通过。

修改前的备份在 `backups/20261123_123747_growth_observation/`。如需回滚本次改动，从工程根目录运行以下命令。

```sh
snapshot=backups/20261123_123747_growth_observation
cp "$snapshot"/scenes/{damageable,girl_bedroom,interface,touch_controls}.gd scenes/
cp "$snapshot"/tests/{growth,mode_menu,touch}_playtest.gd tests/
cp "$snapshot"/rust/src/{game,round,rules,settings}.rs rust/src/
cp "$snapshot"/rust/src/round/growth.rs rust/src/round/
cp "$snapshot"/assets/fonts/harbor-ui.otf assets/fonts/
cp "$snapshot"/README.md README.md
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --editor --import
```

---

## 2026-11-23 (11:45) — AI 巨人对战距离随体型缩放 & 无目标时闲逛

### 备份位置
- 本次修改前完整备份：`backups/20261123_112851_ai_engage_wander/`（含 `src/`、`tests/`、`README.md`、`CHANGELOG.md`、`project.godot`）。

### 问题
- AI 挑选对手的可交战距离在 `rust/src/round.rs` 中写死为 `(踩踏射程 + 2.5 秒步程).clamp(10, 75)`。巨人碰撞胶囊半径为 `2.9 × 身高 / 25.2 ≈ 0.115 × 身高`，两个巨人的身体中心最近只能到 `0.115 × (双方身高之和)`。身高之和超过约 652 米时（例如两个 400 米、500 + 300 米），这个最近距离已经大于 75 米，对手连候选目标都进不去：不追、不避让、不重踏，只会各自走开。
- 只有“已锁定的目标”能靠 `chase_target` 的豁免在 150 米内继续交战，所以从小体型打起来的一对长大后还能打，几百米才第一次相遇的一组永远不打，表现为“有时候不打”。
- 视野半径 `SIGHT_RANGE` 同样是绝对的 150 米，几百米巨人在 200 米外互相看不见。
- 体型低于拆楼门槛（默认 3 米）的 AI 在没有可拾取金币时把最近的完好建筑当作目标走过去；走到建筑表面后 `forage()` 返回零向量，AI 会原地站住。

### 主要改动（`rust/src/round.rs`、`rust/src/round/growth.rs`，三种模式共用，改动同时生效）
1. 新增 `rival_engage_range(reach, speed, scale)`：对手的交战距离上限改为 `max(75, 2 × 自身碰撞半径 + 踩踏射程)`。小体型仍是原来的 75 米追击窗口，大体型按一个身位加射程放大。
2. 新增 `sight_range(scale)`：视野取 `max(150, 身高)`，目标丢失判定与候选筛选都用它，保证看得见自己愿意交战的对手。
3. 新增 `wander_goal(...)`：没有目标时按体型与步速取 0.5～320 米的漫游点（优先道路出生点，其次随机方向，最后朝地图中心），走到、被拉远或超过跨度后重选；`pursue()` 的漫游分支改用它，不会再返回自身位置。
4. `forage()` 改为 `&mut self`：没有可达金币、也没有可前往的建筑时，用漫游方向当前进方向，不再返回零向量。
5. 新增 Rust 单元测试覆盖交战距离与视野随身高缩放。

### 验证结果
- Rust 单元测试：`19 passed, 0 failed`
- Godot 无界面启动校验：正常退出，零报错
- 玩法回归测试（`tests/playtest.gd`）：`153 passed, 0 failed`
- 成长模式测试（`tests/growth_playtest.gd`）：`105 passed, 0 failed`
- 菜单与卧室测试：`34 passed`；触控测试：`29 passed`
- 回归有效性：把两份 Rust 源文件换回备份后重跑成长测试，新增的“几百米巨人对战”和“无目标闲逛”两条失败、其余 103 条通过；恢复修改后 105 条全部通过。
- 新增测试需要可写的 `user://` 目录（设置文件写在 `user://`），无写权限时整套设置类用例会连锁失败，可用 `XDG_DATA_HOME` 指到工程内目录运行。

### 回滚方式
```sh
cp backups/20261123_112851_ai_engage_wander/src/round.rs rust/src/round.rs
cp backups/20261123_112851_ai_engage_wander/src/round/growth.rs rust/src/round/growth.rs
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-22 (19:15) — 巨人动画深度优化（踩踏运动学修复、收步并脚、双层头发波浪与眼神生命感）

### 备份位置
- 本次修改前完整备份：`backups/20261122_185400_giant_anim_v2/`（含 `scenes/`、`rust/src/`、`rust/Cargo.toml`、`tests/`、`project.godot`、`README.md`、`PLAN.md`、`CHANGELOG.md`）。

### 主要优化内容（`scenes/giant_visual.gd`、`rust/src/round.rs`）
1. **消除踩踏关键帧跳变并重构重磅踩踏姿态**
   - 修复原版 `_stomp_pose` 在 `t = 0.98` 截断导致冲击前一帧左脚瞬移 1.86 米（500 米尺度下高达 36.9 米）、`t = 1.24` 脚踝俯仰瞬跳 `5.1°` 且脚尖穿地、以及退出踩踏时脚偏航瞬跳 `2.6°` 的问题；现改为连续加速下砸至 `t = 1.00` 精准落地、自 `t = 1.24` 绕脚趾支点先抬脚跟再离地，并完整快照过渡四脚角度，全程零瞬移、零跳变。
   - 重做蓄力与砸地姿态：蓄力阶段小腿在膝下自然微收形成爆发力卷曲轮廓（替代生硬 90° 折角），双臂外展平衡彻底消除右手贴脸/挡下巴与左手压膝问题；砸地冲击改为符合生物力学的**对侧发力**（左脚前砸配右臂前挥、左臂后摆），脊柱由过度折腰 `58°` 收束为挺拔有力的冲击前倾并加入胸肩滞后叠加动作。
2. **自然待机、行走与「身体前移并脚」停步升级**
   - **身体随步态前移至前脚再停稳（零回滑）**：在 `rust/src/round.rs` 与 `scenes/giant_visual.gd` 间加入 `stop_carry_velocity(dt)` 协同制动。松开方向键后，支撑脚与落地后的前脚均严格锁定在世界坐标（实测支撑脚与前脚滑移均为 `0.0000 m`），角色身体通过正常 `move_and_slide()` 沿惯性平滑前移至前脚正上方减速停稳，同时后脚顺势抬起向前迈步并拢；遇实体墙/建筑阻挡时平滑消解残余偏移，按键蓄力踩踏或重新移动时即时打断不拖泥带水。
   - 修正待机与行走时手臂/手腕受原始 A-Pose 外扩影响导致的僵硬外翻，使双臂自然贴身垂落；按 `Shoulder Bag` 实测轮廓精调右臂过髋净空，实测待机/行走/踩踏全程与黄色小熊挎包零穿模（最小净空 `+0.0112`～`+0.0418` 模型单位）。
   - 升级双骨腿部 IK（`_plant`）为带极向量轴向扭转对齐（`_align_limb_twist`）算法，杜绝高抬腿时大腿/小腿轴向歪扭；提早蹬地离跟时机（`u = 0.72` 起步滚动）并保持平地零滑步；在身高超过 88 米（`scale > 3.5`）后平滑缩放步幅与步长同步联动，500 米身高单步周期由 ~20 秒优化至 ~6.8 秒且平地滑移 `< 0.0004 m/帧`。
   - 补齐 25.2 米基础尺度归一化基准（修正原先遗留的 `7.4` 写死缩放系数为 `_model_base_scale = 14.8`），并新增成长膨胀微呼吸反馈与高台落差落地缓冲。
3. **双层波浪头发物理与眼球微表情**
   - 头发次级动力学升级为「发根弹簧 → 发梢滞后波浪弹簧 + 独立转向角惯量弹簧」双层架构，修正左/右转时前后发梢切向惯性方向，并结合低头重力垂坠与分区防穿模限位。
   - 启用 `Eye L` / `Eye R` 骨骼驱动自然待机微扫视（眼神领转、头部柔和跟转）、转弯预注视与踩踏落点锁定，搭配自然偶发双眨眼与踩踏触地瞬间的微眯冲击反射。

### 验证结果
- **Rust 单元测试**：`10 passed, 0 failed`
- **Godot 无界面启动校验**：正常退出，零报错
- **完整玩法回归测试（`tests/playtest.gd`）**：`137 passed, 0 failed`
- **专项实测与渲染审查**：完成待机/行走/脚部特写/停步前移并脚/踩踏全流程多视角 OpenGL 实机截图对比，以及停步零回滑（支撑脚 `0.0000 m`、前脚 `0.0000 m`）、挎包 3D 净空、头发局部系惯性方向、500 米多尺度零滑步与关节帧间连续性核验。

### 回滚方式
```sh
cp backups/20261122_185400_giant_anim_v2/scenes/giant_visual.gd scenes/giant_visual.gd
cp backups/20261122_185400_giant_anim_v2/rust/src/round.rs rust/src/round.rs
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
```

---

## 2026-11-22 (16:33) — 场景扩建 20 倍（448 × 448 m 多风貌临港都市）

### 备份位置
- 本次修改前完整备份：`backups/20261122_161800_district_20x/`。

### 一、20 倍大地图与 9 大差异化风貌分区
- **尺度升级**（`scenes/district.tscn`、`scenes/main.tscn`、`scenes/round.tscn`）：
  - 陆地面积由 `100 × 100 m`（`10,000 m²`）扩建至 **`448 × 448 m`（`200,704 m²`，精确 20.07 倍）**，边界碰撞墙外推至 `±220 m`（高 `120 m`），海面扩展至 `2200 × 2200 m`。
  - 主菜单总览镜头拉升至 `(148, 102, 162)` 俯瞰全城，镜头视距 `far` 提至 `950 m`，海雾密度调优为 `0.00095`，太阳光阴影覆盖距离增至 `340 m`。
- **丰富多变分区与地标**（`scenes/district_expansion.gd`、`scenes/district.gd`）：
  - 完整保留中心 `[-36..+36]²` 核心 4 街块原有 12 栋 Breakwater 建筑、3 处路障、出生点与撤离点；
  - 外围规划 10×10 街块（含合并超级街块打破机械棋盘感）与环岛码头岸线，划分为 **核心老港区、中央公园与喷泉广场、摩天玻璃商务区、重型集装箱货运码头、石化炼油储罐区、干船坞造船厂、历史红砖仓库群、环岛海堤与灯塔/雷达岬角** 等多种风貌；
  - 共有 **135 栋可破坏建筑**（42 栋多色调玻璃幕墙摩天楼/塔楼、34 处五彩波纹集装箱堆、29 栋高精度 Breakwater 历史建筑、18 栋船厂大跨度机库/泵房、11 处石化油罐与冷却塔厂区、1 座 35 米红白发光海港灯塔）与 **9 处路障**；
  - 搭配高耸港口龙门桥吊、3 艘停泊岸外的远洋货轮、环城混凝土海堤、远海礁石防波堤，以及通过 `MultiMeshInstance3D` 批量合批渲染的数百棵树木、港口暖光路灯与岸边系缆桩（零建筑重叠、零占道、全场景加载仅 ~0.55 秒）。

### 二、程序化可破坏建筑倒塌与可步行废墟（`scenes/damageable.gd`）
- 扩充 `damageable.gd`，为新增原创建筑提供受损微震、倾斜下沉与烟尘喷发倒塌动画（暂停自动冻结），以及倒塌后生成的风格匹配残骸与动态可步行 `HeightMapShape3D` 废墟斜面（`RuinBody`）。

### 三、全域寻路、大城成长上限与 HUD 适配
- **全域动态窗口 A* 寻路**（`rust/src/route.rs`）：摆脱原 `±44 m` 网格上限，覆盖完整 `±220 m` 全城与 36m 周期多干道路网，动态按搜索窗口裁剪障碍物并自适应 2m/4m 分辨率，跨城寻路仍保持亚毫秒级耗时。
- **无上限 110% 纯复利成长与自适应相机视距**（`rust/src/rules.rs`、`rust/src/round.rs`）：保持每拆一栋建筑体型与脚底范围严格增加当前数值的十分之一（`1.10^destroyed`，数值持续加速变大），并同步动态扩展巨人相机 `far` / `near` 裁剪面与 HUD 身高单位显示（米 / 公里 / 万公里），确保成长到超巨型尺度时视野与界面始终正常。
- **动态 HUD 计数与阶段提示**（`rust/src/round.rs`、`scenes/interface.gd`）：`snapshot()` 动态输出 `total_buildings` 与 `giant_scale`，HUD 自动显示真实总建筑数（如 `00 / 135`）、自适应 12 段总进度条，以及实时巨人身高与「一击拆楼 / 触碰碾压」解锁状态。

### 四、验证结果
- **Rust 单元测试**：`9 passed, 0 failed`（新增大城成长曲线收敛测试与 320m 跨区寻路测试）
- **Godot 城市几何审计**：`20.07x` 面积、`135` 栋建筑、零建筑重叠、零占道、零残余路缘碰撞
- **Godot 完整玩法回归测试（`tests/playtest.gd`）**：`93 passed, 0 failed`（新增 20 倍面积、多建筑类型、外区探索、灯塔倒塌与可步行废墟结算、重开全图恢复等 8 项测试）

---

## 2026-11-22 (15:21) — 巨人平滑自然转向 & 6 栋解锁零停顿触碰碾压

### 备份位置
- 本次修改前完整备份：`backups/20261122_150800_turn_and_crush/`（含 `scenes/`、`rust/src/`、`rust/Cargo.toml`、`tests/`、`README.md`、`PLAN.md`、`CHANGELOG.md`、`project.godot`）。

### 一、巨人自然平滑转向
1. **二阶临界阻尼角速度控制（`rust/src/round.rs`）**
   - 为巨人独立出 `drive_giant()` 与 `turn_giant_smooth()`，以角加速度起转、受限最大角速度（随成长体型略微增重沉稳）及临界阻尼收尾，替代原先 1 帧猛扯的 `face(..., dt * 6.0)`，彻底消除第一帧突转与过冲抖动。
   - 优化 AI 路径航点跟随（放宽航点切换距离并融合前方航点），避免在 2m 网格上出现直角锯齿抽搐转向。
2. **转身踩踏 S 型缓冲与全身层级转向语言（`scenes/giant_visual.gd`）**
   - 进入踩踏时的任意显著转向（`> 0.03 rad`）均记录起始偏移并在 `stomp_pose ∈ [0.0, 0.84]` 内按 `smoothstep` S 型曲线平滑甩身到位，砸地瞬间（`t = 1.0`）对准误差 `0.0000°`。
   - 行走转向与回身踩踏加入头颈率先领转 → 上胸椎跟转 → 骨盆滞后、转向压弯倾身、脚步引导微旋及头发离心甩动；同步将斜坡射线与头发加速度归一化适配 25m~79m 成长体型。

### 二、摧毁 6 栋建筑后一碰即毁且零停顿
1. **规则与解锁门槛（`rust/src/rules.rs`）**
   - 导出 `ONE_HIT_BUILDING_THRESHOLD = 3` 与 `TOUCH_CRUSH_BUILDING_THRESHOLD = 6`，在 `RoundState` 新增 `one_hit_buildings()` 与 `touch_crush_buildings()`；重开自动重置。
2. **运动前扫掠清除碰撞体，保证零停顿穿过（`rust/src/round.rs`、`scenes/damageable.gd`）**
   - 在每帧 `move_and_slide()` 之前调用 `crush_touched_buildings()`：当 `destroyed >= 6` 时，对巨人当前位置、中点及本帧步进位置检查是否与完好建筑矩形相交（`GIANT_RADIUS * giant_scale + 0.14`）。
   - 一经触碰即同帧摧毁建筑、`BlockingBody` 立刻清除 `collision_layer = 0` 并同步将 `CollisionShape3D.disabled = true`，随后紧接执行的 `move_and_slide()` 零阻力全速穿过（实测撞击前后每帧恒定 `7.000 m/s`），同时正常触发倒塌动画、接触面碎屑特效、微震与 110% 成长；路障规则维持两次命中不变。
   - 人类撤离模式下，AI 巨人拆满 6 栋后寻路不再把建筑视为死墙，也不再为拆建筑停步蓄力，直接全速碾压推进。

### 三、验证与文档
- **Rust 单元测试**：`7 passed, 0 failed`
- **Godot 无界面启动校验**：正常退出，零报错
- **完整玩法回归测试（`tests/playtest.gd`）**：`85 passed, 0 failed`（新增 90° 平滑转向、180° 转身踩踏缓冲、5 栋仍阻挡、6 栋后无停顿撞穿建筑并成长、重开复位触碰摧毁等 7 项测试）
- 已同步更新 `README.md`。

---

## 2026-11-22 — 巨人动画全面优化 & UI 工业防灾风格重塑

### 变更文件总览

| 文件 / 目录 | 变更类型 | 说明 |
| --- | --- | --- |
| `scenes/giant_visual.gd` | 重构优化 | 巨人程序化步态、重磅踩踏、废墟斜坡脚部 IK、头发次级物理与面部微表情（保持 `show_motion(speed, stomp_pose, delta)` 对外接口不变，未改动 Rust 逻辑） |
| `scenes/interface.gd` | 重构美化 | 去除“AI 深青发光圆角卡片”风格，重做为「临港防灾标牌 · 工业印刷风」主菜单、自定义矢量 HUD 与居中弹窗（保持 `show_screen` / `update_hud` 接口不变） |
| `backups/.gdignore` | 新增 | 防止 Godot 资源系统扫描备份目录引发 UID 或脚本冲突 |
| `backups/20261122_134700_giant_anim/` | 新增备份 | 本次会话开始前的完整源码与场景基线备份（`scenes/`、`rust/src/`、`rust/Cargo.toml`、`tests/`、`project.godot`、`README.md`、`PLAN.md`） |
| `backups/20261122_140900_ui_polish/` | 新增备份 | 巨人动画优化完成、UI 修改前的增量备份（`scenes/interface.gd`、`scenes/main.tscn`） |
| `CHANGELOG.md` | 新增 | 记录本会话的全部改动与验证信息 |

---

### 一、巨人动画优化（`scenes/giant_visual.gd`）

针对 `assets/characters/kawaii.glb`（115 根骨骼，7.4 倍缩放后约 12.4 米高）进行了蒙皮权重与运动学分析，并实施以下优化：

1. **待机与巨人步态重做**
   - 修正原待机骨盆写死下压 `-0.048` 导致的“半蹲扎马步”问题，待机恢复自然挺拔站姿（`-0.015`），加入呼吸起伏、轻微重心晃动与低频环视微动。
   - 修正倒立摆垂直起伏相位（触地吸收最低、单腿支撑最高）与横向重心转移相位（单腿支撑中段重心稳压支撑腿上方，骨盆与胸腔呈反向倾斜平衡），补全 `spine.001` 脊柱 S 型波浪传导。
   - 将步幅由 `HALF_STEP = 0.24` 调整为 `0.285`（`CONTACT_FRACTION = 0.60`，`SWING_HEIGHT = 0.165`），更契合 12 米体型的步频与沉重感，并维持平地零滑步（实测支撑脚锁定 `42` 帧，测试要求 `> 18`）。
   - 加入 `foot` + `toe` 脚掌滚动：脚跟着地拍平 → 全脚掌稳固支撑 → 绕 `toe` 支点踮脚蹬地折趾，全程零穿地、零过伸膝盖弹跳（最大腿长比 `0.987`）。
   - 新增急停前倾缓冲惯性与转弯压弯倾身（Banking）。

2. **重磅爆发力踩踏与无缝过渡**
   - 进入与退出踩踏时拍摄核心骨骼姿势快照进行平滑混合，并在行走转踩踏初期保留左脚既有的抬升与前伸动量，消除一帧瞬移/回落抽搐。
   - 当 `begin_stomp` 触发大幅瞬间转向（如 180° 背后踩踏）时，通过 `$Model.rotation.y` 视觉偏航缓冲在蓄力前半段顺滑甩身到位，冲击瞬间对准误差 `0.0000°`。
   - 重构四阶段踩踏节奏：高抬腿蓄力悬停 → `pow(u, 2.55)` 加速雷霆下砸（触地瞬间速度最大）→ 脚底钉地后骨盆/躯干/手臂延迟压深顿挫（峰值 `t ≈ 1.09`）→ 重心回撤、脚跟先离地拔脚收姿回立。
   - 落点前伸对齐预警中心（`reach = 0.455`），并在斜坡踩踏时采样落点表面高度。

3. **上肢、手型、头部与防穿模净空**
   - 启用 `shoulder.L/R` 锁骨联动、解剖学局部 `+X` 轴屈肘与 `hand.L/R` 手腕滞后跟随。
   - 驱动全部 30 根手指骨骼形成自然放松微曲手型，踩踏发力时收紧半握拳。
   - 依据 `Jean shorts` 与右侧 `Shoulder Bag` 网格实际轮廓精调左右臂内收与过髋避让，全程无衣物/挎包穿模。
   - 启用 `Neck` + `Head` 前庭稳定补偿、转弯提前注视与踩踏时低头紧盯目标。
   - 经蒙皮权重审计确认 `Shoulder Bag_2` 与 `breast.L/R` 对牛仔短裤与背带有显著交叉权重，明确保持静止不驱动，避免衣物撕裂变形。

4. **废墟斜坡脚部贴合（Terrain Foot IK）**
   - 对地面与废墟层（`collision_mask = 1`）发射轻量射线，自动贴合废墟斜坡的脚踝高度、骨盆补偿沉降与脚掌俯仰/侧倾法线；平地街道上保持零偏移。

5. **头发物理弹簧与面部表情**
   - 自动发现并驱动 `Head` 下全部 12 条头发链（45 根骨骼，含带末尾空格的 `"Front Hair "` 与 `"Back Hair "`）接入二阶阻尼弹簧，响应头部加速度、转身与踩踏落地冲击脉冲，并按前/侧/后分区限位防止穿进脸部与脖颈。
   - 同步驱动 `Body`（兼容原模型 `"Blinl R"` 拼写）、`Eye Line`、`Eyelashes` 的自然周期眨眼，以及踩踏蓄力/冲击期间 `Eyebrows` 微微皱眉发力表情。
   - 所有动画与弹簧计时均严格依赖 `show_motion` 传入的 `delta`，游戏暂停时彻底冻结。

---

### 二、UI 美化与去“AI 味”重塑（`scenes/interface.gd`）

摒弃原版“深青黑底 + 荧光青/琥珀 1px 细描边圆角卡片 + 文本符号凑字”模板，重构为契合 3D 夕阳海港工业氛围的 **「临港防灾标牌 · 工业印刷风」**：

1. **视觉与字体系统**
   - 配色改为暖炭铁黑（`#111316`）、工业纸白（`#efeae0`）、警报朱红（`#e44d2e`）、避难诱导绿（`#2ec995`）与工程机械黄（`#eba930`）。
   - 使用系统思源黑体（`Source Han Sans CN`）Heavy / Bold / Medium / Regular 多字重层次，搭配 `Source Code Pro` 等宽数字，并保持纯粹克制的中文港务标牌文案。
   - 用 45° 工业切角（`ChamferBox`）、实色边标与局部斜纹警示带（`HazardStripe`）取代通用圆角边框面板。

2. **主菜单重做**
   - 采用电影暗角 + 极细胶片颗粒 Shader，保留右侧开阔通透的 3D 港区实景画面；配四角微细光学取景框线（`ViewfinderFrame`）与右上角带呼吸红点的「港区总览」标牌。
   - 左侧不对称海报式编排：「紧急警报」朱红标徽 + 粗重投影大标题「港区警报」+ 细斜纹分割线 + 带 `01` / `02` 编号的斜切模式条目（`TacticalButton`，悬停/聚焦时平滑右滑并展开高亮色旗），附入场动画。

3. **局内 HUD 自定义矢量仪表**
   - **人类撤离模式**：
     - 左上角自绘 3 格斜切生命块（`HealthMeter`，受击红闪震颤熄灭、1 血濒危呼吸）与 4 段斜切体力条（`StaminaGauge`，疾跑白色耗损拖尾、低体橙红闪烁、满格光泽）。
     - 右上角重做为海事战术撤离罗盘（`EvacCompass`）：12 刻度表盘 + 平滑插值矢量箭头与方位光弧 + 大号等宽米数读数（进入 15 米内绿光提示）。
     - 受击与低血量提示升级为四周径向血红暗角 Shader，不遮挡视野中心。
   - **巨人沙盒模式**：
     - 左上角超大等宽拆楼计数（每次摧毁建筑触发弹性跳动）+ 12 格工业进度矩阵（`BuildingMatrix`，新拆毁格亮白闪动；全拆后切换“街区已夷平 · 自由漫游”）。
     - 下方新增踩踏动态状态指示仪（`StompGauge`）：配 `[SPACE]` 键帽，同步呈现蓄力红橙脉冲条、冲击瞬间白金爆闪与冷却回充进度条（暂停时精准冻结）。
   - **底部操作提示**：移除旧版大黑框与空格拼字，改为无框悬浮的实体键帽条（`KeycapBar`）。

4. **暂停与结算弹窗**
   - 采用全屏 `CenterContainer` 精确居中（`420px` 固定宽，动态高度自动居中），顶部按状态切换对应色斜纹警示带，展示局内简要数据与斜切交互按钮，附弹性淡入动效。

---

### 三、验证结果

- **Rust 单元测试**（`cargo test --locked --manifest-path rust/Cargo.toml --target-dir rust/target`）：`6 passed, 0 failed`
- **Godot 无界面启动校验**（`godot --headless --path . --quit-after 5`）：正常退出，无脚本与 Shader 错误
- **完整玩法回归测试**（`godot --headless --path . --fixed-fps 60 --script res://tests/playtest.gd`）：`55 passed, 0 failed`
- **专项核验**：
  - 巨人步态/踩踏/180° 转身踩踏/废墟斜坡脚掌法线贴合/衣物净空均通过数值核验；
  - 主菜单、人类 HUD、巨人 HUD、暂停与结算弹窗在 `1280×720` 下完成像素级布局矩形核验，无重叠、无截断、无出屏。

---

### 四、回滚指引

如需恢复本次会话前的原始版本，可在项目根目录运行：

```sh
# 仅回滚 UI 至修改前状态
cp backups/20261122_140900_ui_polish/scenes/interface.gd scenes/interface.gd

# 仅回滚巨人动画至修改前状态
cp backups/20261122_134700_giant_anim/scenes/giant_visual.gd scenes/giant_visual.gd

# 同时回滚巨人动画与 UI 至本会话最初基线
cp backups/20261122_134700_giant_anim/scenes/giant_visual.gd scenes/giant_visual.gd
cp backups/20261122_134700_giant_anim/scenes/interface.gd scenes/interface.gd
```
