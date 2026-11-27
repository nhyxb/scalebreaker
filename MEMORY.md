# 项目记忆

## 项目名称（2026-11-26 确认）

- 项目已更名为 **Scalebreaker**（中文名待定）。改名范围：`project.godot` 的 `config/name`（窗口标题同源）、主菜单大标题与首页入口、港区分页标题、`export_presets.cfg` 的 Android `package/name`；**README.md 与 CHANGELOG.md 头部也已改为 Scalebreaker 门面**（README 开头注明原名《港区警报》，2026-11-26 公开 GitHub 仓库时更新）。PLAN.md 仍是历史设计文档、保留旧名不改；CHANGELOG 历史条目里的旧名属历史记录，不改。
- **内部一律不改**：包名 `org.gba.harboralert`（改了旧包无法覆盖升级）、`assets/harbor-alert-icon.png` 等路径、Rust crate `harbor`、GDScript `class_name`、`user://` 存档路径与键、技能 `harbor-alert-workflow`、`native/harbor.gdextension`、`scripts/build_android.sh`。
- 主菜单大标题用 `interface.gd::_set_menu_title()` 自适应字号（目标 428 px、≥44 px）：拉丁文名比中文页名宽，不缩放会把 442 px 菜单列撑宽。

## 巨人重步与鞋印（2026-11-27）

- `giant_visual.gd` 使用四种皮肤各自的左右鞋底凸轮廓，摆脚约到 46% 时锁定横向落点和朝向，后段加速垂落。支撑脚按世界坐标锁定，停步会完成当前摆脚，需要收脚时另一只鞋单独结算。只有着地事件才传给 `round/footfalls.rs`，每次包含 `center / yaw / half_extents / left / profile`。鞋底局部坐标 X 向右、-Z 向前，轮廓以半长宽归一化。
- `HarborRound::resolve_footfall()` 用同一鞋底区域同时提交建筑、行人和对手的命中判定、扬尘、低频空间音效和一次震动。成长模式的 40 米巨人以及任意身高的沙盒、大乱斗巨人可直接穿楼拆毁，鞋底命中也可结算拆楼。手部和坐压沿用各自入口。
- `heavy_step_preview()` 提供预测 `eta / progress / locked / lift`，AI 可用早期预测避让。严格比较最终落点时等 `locked`，以 `growth_actors()` 的 `footfall_count` 和 `last_footfall_*` 确认。市民优先远离即将着地的鞋底，复用原有恐慌状态。
- `round_effects.gd::footprint_debug()` 可以查看鞋印池。每局复用 72 个槽位，12 秒过期，末 4.5 秒淡出。鞋印从场景深度投影到可见表面，避免叠放平面产生 Z-fighting。
- 撤离和成长人类观察视角可向上看约 83°。弹簧臂保留原上仰限位，摄像机本身补足抬头角度，保持街面上方。
- **弧线起步、赛车式限角转弯与严格速度绑定步态（2026-11-27 更新）**：
  - `round.rs::update_giant()` 取消站立按方向键锁定位移的原地旋转，`A`/`D`/斜向（含 `S+A`/`S+D`）立即以当前朝向弧线前进并转向目标；仅纯后退 `S`（`dot(camera_forward) < -0.84`）保持正面向前做 `GIANT_BACKWARD_MULT(0.74)` / `BACKWARD_STEP_RATIO(0.82)` 倒退步。
  - `turn_giant_smooth()` 对非人类巨人施加赛车式转向限速（`0.90 * scale^-0.28`，约 `30–45°/步` 并随体型沉稳），`scenes/giant_visual.gd` 配合 `PIVOT_STEP_MAX_YAW = 0.72 rad` 与 `stance_turn_target()`（单脚撑地期骨盆扭转上限 `±STANCE_PELVIS_TWIST_MAX = 0.52 rad`）保持撑地零打滑与局部防跨中线约束。
  - `_advance_walk()` 严格由真实水平位移速度（`has_real_travel`）驱动重步循环，无水平位移时严禁播放原地踏步；`_step_standing_turn_live()` 仅由坐压 `step_turn_in_place()` 显式开启，常规 `show_motion()` 一律不触发。`STOP_SETTLE` 过渡期间跟随步伐标记 `trail_ft.planted`，确保收步零锚点跳变。
  - `can_crush_buildings()` 解锁后从 `collision_mask` 排除 `BUILDING_LAYER(8)` 与 `RUBBLE_LAYER(16)` 并由 `crush_touched_buildings()` 直接穿楼碾压；未解锁时 `DefeatMethod::Step` 不伤建筑，改用 `E` 挥拳 / `Q` 抓碎 / `X` 坐压（AI 走 `start_ai_scenery_hand_move()`）。`idle_sit` 因重步期间多数帧存在 pending `footfall` 且此时视野无目标，只需检查地面状态而不必等待 `footfall.is_none()`（人群 sit-crush 仍保留等当前落地后再判断）。
  - `giant_size_speed_factor(scale)` 与 `_swing_hover_bounds(body_ratio)` 让高体型移速不发闷、改为抬脚最高点悬停滞空更久；玩家按 `S` 后退用 `GIANT_BACKWARD_MULT(0.74)` / `BACKWARD_STEP_RATIO(0.82)` 保持正面朝前做真实倒退步。

## 全局合批、建筑三态与相机（2026-11-26 确认）

- **静态资产一律全图一个 MultiMesh**：`scenes/district_expansion.gd::_batch_mesh()` 不再按 `RENDER_CHUNK_SIZE(108 m)` 分块，节点放在 District 原点、实例用绝对变换；只有 `Scenery` 里的独立小件仍按 108 m 分块裁剪（`district.gd` 只对 `$Scenery` 注册 chunk，`Roads/Lots/Targets/Batches` 不再参与）。全局小件批次挂在新的 `District/Batches` 下；`scripts/district_stats.gd` 的扫描根已包含 `Batches` 与 `BuildingBatches`，账单才完整。
- **道路是"换几何、保贴图"**：原瓦片 353–4,562 面，七成是坡化人行道顶面的碎面，任何裁剪阈值都保不住形状（0.05 m² 会把人行道打成筛子）。最终 `_road_tile_mesh()` 用**扁平板块**替换沥青（12×12 m 两块三角，y=-0.01 压在标线下，UV `xz/3`），并用 `_append_pavement()` 把原瓦片朝上三角面**按 1 m 栅格重建**人行道（格心在三角内才发格子、取格内最高点，y≈0.15）；贴图仍是原 `MAT_Road_Asphalt` / `MAT_Formed_Concrete`，斑马线/车道虚线/黄漆/排水沟/井盖沿用原几何。878 万面 → **209 万面**、850 个 MultiMesh → 4 个。
- **人行道已知偏差（2026-11-26 接受）**：1 m 栅格重建后连续性/带宽/颜色已与基准持平，剩三件小事：路口四角是 90° 直角（原瓦片 1–2 m 圆弧）、转角黄漆块只剩 1–2 px、路缘亮线偏弱（+7~16，基准 +16~20）并有 1 px 暗缝。后续可降到 0.5 m 栅格 + 单独补圆弧/黄漆/亮条。
- **安卓工具链（2026-11-26 装好）**：`~/Android/Sdk`（cmdline-tools/latest、platform-tools、build-tools;35.0.0、platforms;android-35、ndk/29.0.14206865）、`rustup 1.29.3` + toolchain `1.94.0` + `aarch64-linux-android`、Godot 设置 `export/android/java_sdk_path=/usr/lib64/jvm/java-25-openjdk`。构建 APK：`ANDROID_SDK_ROOT=~/Android/Sdk PATH=~/.cargo/bin:$PATH ./scripts/build_android.sh` → `build/harbor-alert-debug.apk`（约 154 MB，含 lib/arm64-v8a 三个 .so）。改 Rust 后必须重跑该脚本，否则 APK 里还是旧的 `native/libharbor_android.so`。
- **判断面朝向必须用顶点法线，不能用几何叉积**：这套 GLB 的绕序与叉积方向相反，用叉积会把可见路面当背面删掉（曾导致道路整片消失，只有视觉复核能发现——headless 数字反而"更好看"）。任何"按法线裁剪几何"的改动都要在真 GPU 截图上确认。
- **建筑三态渲染**（`scenes/district_batches.gd` + `damageable.gd::batched`）：近层每种 kit 型号一个 MultiMesh（`NEAR_RADIUS = 280 m`，相机移动 `REFILL_STEP = 40 m` 才重排；远层实例只写一次，跨界只做置零/还原）；远景层用 `commercial/low-detail-building-*` 与同主色盒代理（`cast_shadow` 关闭）；废墟层是共享瓦砾堆。实例隐藏靠零变换退化。`damageable` 只在 `batched == false`（中心 12 栋、灯塔、雷达）时才建 `IntactModel` 节点；被抓进手里时临时实例化、松开恢复；远处建筑倒塌只更新碰撞与废墟层（`is_near()`），近处才播 3.5 s 倒塌。
- **`batch_spec()` 不包含 `kit_scale`**：实例变换自带各自 `_kit_fit`，写进 key 会让每个地标放大率都拆出一个新 MultiMesh（曾导致 162 个近层节点）。
- **中心 12 栋换模**（`scenes/district.tscn`）：`intact_scene` + `kit_scale`（DockPress → `commercial/building-e` 6.16、Tidewater → `commercial/building-m` 5.08、MarineWorks → `industrial/building-s` 6.55），同时保留 `historic_style` 与 `ruin_floor`：完好模型是 Kenney，废墟仍是历史高度图瓦砾。**外围历史街区已于 2026-11-26 同步切到同一套 kit**（`district_expansion.gd::_spawn_historic_building()` 按同表映射且未映射 style 会 push_error），全城不再走 `HistoricBuildings.unit_mesh()` 旧方块楼；外围楼与中央同型共享 MultiMesh（`batch_spec()` 键为 GLB 路径，无 kit_scale），运行时 footprint 仍由 `_fit_kit_intact()` 按槽位钳制后重写为 kit 实值。`footprint` 由 `_fit_kit_intact()` 改写（10.1×5.5×6.2 / 6.3×16×6.3 / 13.9×5.5×6.0），测试一律按运行时 `footprint` 计算落点。
- **第三人称相机**（`rust/src/round.rs`）：三态 `view_mode()` 0/1/2 = 第三人称全身 / 斜侧跟脚 / 第一人称，`V` 与触屏按钮循环，`camera_view_mode()`、`set_camera_view()` 供触屏与测试；焦点 `0.55 × height`（成长模式地板 0.037），臂长 `1.30 × height × zoom`（滚轮 0.45–3.0 平滑）；跟脚模式朝向 = `body_yaw + PI + 0.79`、臂长 `0.62 × height`、焦点在左脚，进出该模式要保存/恢复玩家朝向。`far = max(2500, world_limit × 4.4 + height × 3)`、`near = clamp(arm × 0.018, 0.09, 8.0)`（2026-11-26 Z-fighting 加固：24-bit 深度需更高 near 配合 `Ground/Surface` 视觉底板下沉 `-0.07 m` + `subdivide 16×16`，物理地面仍 `y=0`；第一人称与微缩/全景相机的小 near 不变）；臂长 < `0.2 × height` 时焦点抬到 `0.82 × height`。**不要再引入 `GIANT_CAMERA_MAX_LENGTH` 这类写死上限**，500 m 巨人曾因此把镜头埋进双腿。
- **海雾**（`rust/src/game.rs::view_fog_bounds` & `view_fog_density` + `scenes/main.tscn`）：视距 ≥ 出厂默认（桌面 300 / 安卓 200）时将 `fog_density` 置 `0.0`（保留 `fog_enabled=true` 与 `map_side × 0.52 / 1.12 + 0.45h / 0.85h` 起止距离断言语义），消除微缩沙盘木框边缘发光白边；低于默认视距时恢复 `fog_density=0.85` 边界雾，旧设置语义与断言不变。
- **巨人远距降级**：`giant_visual.set_detail_tier()` 由 `round.rs::update_distant_silhouettes()` 按 `max(180, height × 1.2)` / `max(240, 上一档 × 2.2)` 驱动；tier1 关实时阴影并跳过头发/狐尾弹簧，tier2 再隐藏眼睛/眼线/睫毛/眉/鼻线；第一人称的 `SHADOWS_ONLY` 头部不会被 tier 覆盖（tier 逻辑必须跳过 `SHADOWS_ONLY`）。
- **测试落点**：核心街区 4×3 栋楼几乎贴满 24 m 地块，把 23–25 m 巨人放在 `DockPress1/Tidewater1` 南侧会插进 `MarineWorks1` 的碰撞盒，`is_on_floor()` 变假、手部攻击起不来。要放到北侧空街（`-(footprint.z*0.5 + 5)`）并把身体朝向设为 `PI`。
- **贴墙转向**：`update_giant` 在实际位移不足时恢复原地小步转向，等当前转身小步落定后再切入重步。只有建筑和角色碰撞允许贴着接触迈重步，地图边界第 2 层不能触发空踏。回归入口为 `tests/playtest.gd::_blocked_walk_pivot`。

## 大乱斗与成长模式共用的回合逻辑

- `Mode::has_growth()` 同时涵盖成长模式和大乱斗，用于共用体型战斗、建筑耐久、排名和播报。人类阶段、建筑身高奖励和有寿命的地图金币仅在 `Mode::Growth` 启用。
- 大乱斗的金币在共享的 `damage_rival()` 击杀结算里生成，保存击杀时身高计算出的固定米数。随机开局和复活分别读取独立的身高范围。复活先抽身高，再按相对体型和距离加权选择落点，优先避开所有存活巨人的 `sight_range()`。范围外的常规道路和细网格都无安全点时才进入范围内备选，仍需有碰撞净空。相关回归入口为 `tests/brawl_playtest.gd`。
- 大乱斗随机开局遇到放不下的体型时，`random_brawl_start()` 按地图和已占用位置排除该身高及更大的体型，再均匀重抽。把失败抽签直接降为区间最低值会使宽区间大量堆积在同一身高。
- 大乱斗 AI 的主动攻击只针对其他巨人。空闲时用 `wander_goal()` 持续游走，撞墙会重选目标。任意身高都可在游走、追击和捡币时穿过建筑与废墟，步行直接拆楼。沙盒同样默认开启如履平地，成长模式仍以 40 米解锁。

## 成长模式的人类/巨人两阶段（2026-11-28）

- 玩家和 AI 共用 `GiantProgress::coin_value`。开局/复活由 `sync_spawn_stage()` 读取旧设置键 `attack_height` 决定初始形态，落在人类阶段就使用固定 1.8 米胶囊和人类模型。随机开局的抽样上限仍取配置值，回合实际身高上限在出现人类阶段时至少为 40 米。
- 人类阶段没有主动攻击，使用 `HUMAN_WALK × settings.human_speed`。攒满 10 等值后 `advance_giant_growth()` 直接切换到 40 米巨人、更新建筑碰撞掩码和相机、播放变身音效。低档位上限不能把已变身角色压回 40 米以下。倒下后清空本命累计，保留皮肤与本局击倒数。
- `snapshot_growth()` 提供 `coin_value / coin_transform_target / transform_height` 给桌面与触屏共用 HUD；变身时立即清除模糊雷达。近处无雷达读数时仍走原渐隐动画。
- 安卓 HUD 使用 `assets/fonts/harbor-ui.otf` 的 Noto Sans CJK SC 可变字体子集；新增中文文案时应用 `fc-query` 或 `Font.has_char()` 核查。需要补字时从同版本完整字体重建子集，保留旧码点及字重范围。
- 地图金币由 `update_map_coins()` 管理，开局铺满；每币寿命为 `coin_interval × 0.6–1.5`，拾取圈内读条时冻结该币寿命。最后 4 秒由 `coins.gd` 加速闪烁。有人类阶段存活且场上有缺额时，每隔 0.5–1.8 秒补 1–3 枚；最后一个人类阶段结束后，剩余币继续各自到期。大乱斗金币按原击倒掉落逻辑常驻。
- 回归读取 `round.coin_debug()` 的 `id / ttl / expiring / tier / dwell / position`，以及 `growth_actors()` 的 `height / human / coin_value / can_crush_buildings / hand_action`。验证闪烁时把目标币放在相机剔除距离内，按同一个实例 ID 跨帧跟踪。

## AI 交战距离必须随体型缩放（2026-11-23 确认）
- 巨人胶囊半径是 `GIANT_RADIUS(2.9) × scale`，`scale = 身高 / 25.2`，即约 `0.115 × 身高`；两个巨人的身体中心最近只能到 `0.115 ×（双方身高之和）`。
- `rust/src/round.rs` 里 `rival_engage_range()` 用 `max(75, 2 × 自身半径 + 踩踏射程)` 作为对手的交战距离上限，`sight_range()` 用 `max(150, 身高)` 作为视野。以后改动这两个数、或新增“多近才理目标”的常量，都要跟着体型缩放；写死小常量会让几百米的巨人对走到一起也不打。
- 已锁定的目标（`chase_target`）不受 `attack_range` 限制，只要在 `sight_range` 内就一直交战，连续丢失 2 秒才放弃。遇到“有时打有时不打”，先查交战距离和视野这两个门。

- 交战时，`ai::combat_approach()` 让低于自身一半高的目标成为鞋底穿越点。近身可交战的 0.5–2 倍目标仍可挥拳；站稳对齐后会尝试坐压。两项忽略倍率与危险预警仍优先。大乱斗回归以实际扣血验证 0.075、0.4、0.5、1、2 倍目标，以及同级拳击与坐压闭环。

## AI 待机行为
- `pursue()` 的漫游分支和成长模式的 `forage()` 都走 `wander_goal()`：没有对手、建筑或金币时按体型与步速选 0.5～320 米的漫游点，不会停在原地。新增 AI 分支时不要在无目标路径返回 `Vector3::ZERO`。
- 到达当前上限（`self.max_height` 或成长模式分层 `actor.growth_limit`）的 AI 巨人由 `ai_attacks_scenery()` 返回 `false`，不再主动选楼或踩楼，没有攻击目标时直接走 `wander_goal()` 闲逛（撞墙且当前目标仍指向墙面 `dot > 0.35` 时重选漫游点）；分层空出后会自动恢复拆楼。
- `wander_goal()` 在非贴墙状态下优先选择当前朝向前方 `±68°` 扇区内的漫游点，减少无故 180° 突然掉头；贴墙或前方受阻时回退全方向搜索。

## 港区地图尺寸
- 四种模式各自保存正整数 `map_side`，以米为单位，缺字段的旧存档采用 1418 米。新回合在 `District._ready()` 前传入设置，场景据此生成道路、街区、海岸和碰撞。Rust 读取 `District.play_edge` 作为 `world_limit`，出生点、金币、寻路和旁观镜头共用这个边界。
- 48 米地图保留中央十字街和四栋全尺寸厂房。地图更小时按可用空间缩窄边墙、裁剪铺装、移除放不下的设施，并调整撤离圈和出生标记。边长超过 1800 米和低于 48 米的回归在 `tests/playtest.gd`。

## 速度与忽略倍率（2026-11-24 确认）
- `GameSettings.human_speed` 默认 1.0，乘在撤离玩家的 `HUMAN_WALK`/`HUMAN_SPRINT` 和成长人类阶段的 `HUMAN_WALK × 身高/HUMAN_HEIGHT` 上。`HUMAN_WALK` 和 `HUMAN_SPRINT` 仍是基础常量；`giant_visual.gd` 通过 `human_pace` 让人类走路动画跟随该倍率。
- `GameSettings.rival_ignore_ratio` 默认 10，所有模式独立保存，控制 AI 巨人之间不再主动追击，并决定碰撞例外与通行的门槛。它从 `GrowthSettings` 移到 `GameSettings`，但存档键仍是扁平的 `rival_ignore_ratio`，旧档无需迁移。
- `GameSettings.human_ignore_ratio` 默认 30，所有模式独立保存。`combat_target()` 用 `ignores_human(巨人身高, 目标身高, 倍率)` 过滤人类/行人候选；该判定是非对称的，只有更大的巨人一侧能忽略，不会让较矮的巨人忽略更高的人类。达到倍率后 AI 巨人不再主动追击该目标，实际落脚依旧按鞋底范围结算。25.2 米巨人对 1.8 米人类约 14 倍，默认仍会追击。
- 两个倍率都必须用 `settings.*` 读取，不要再从 `combat_rules()`/`GrowthSettings` 取；`combat_rules()` 只保留成长/大乱斗的生命、攻击、金币和建筑参数。

## 地图路障（2026-11-24 确认）
- 地图不再生成路障：`scenes/district.tscn` 的 `Barrier1–3` 和 `district_expansion.gd` 的 6 处外围路障已移除，`District/Targets` 只保留建筑和地标。
- `damageable.gd` 的 `kind == "barrier"` 分支和 `route.rs` 的非建筑障碍处理仍保留，便于兼容旧场景或以后重新加入；当前没有 `barrier` 实例。
- 玩法测试不再依赖 `Barrier1/3`，并在人类撤离和沙盒中检查 `Targets` 没有 `kind == "barrier"` 的子节点。

## 巨人剪影与镜头震动
- 150 米及以上的远处活巨人使用当前皮肤网格的淡色材质叠加，保留深度遮挡。渲染剪影时可以延长相机远裁剪面，`district_draw_distance` 仍决定城市区块和海雾。
- `own_camera_shake` 由巨人沙盒、成长模式和大乱斗各自保存，旧存档默认开启。自身与附近震动各自保持衰减状态，关闭当局的自身震动时只清除自身的状态。
- 重步和坐压使用不同的震动强度与随距离衰减的范围。成长和大乱斗的外来震动按身高差计算，沙盒、撤离和自身震动按体型平方根缩放。

## 被动接触伤害
- 重步使用 `DefeatMethod::Step`。建筑与鞋底凸多边形求交，角色用脚下接地高度与水平碰撞半径和同一轮廓求交，因此敌方巨人可因真正被踩中受伤。
- 巨人之间的碰撞体按成对例外放行，默认身高相差 3 倍起生效，忽略倍率更低时取较低值。倍率变化时等身体分开再恢复。

## 多角色性能：成对检查、寻路与动画（2026-11-24 确认）
- `PairFrame` 缓存角色位置、半径、高度、安全边距和步速。`update_giant_collision_passes()` 在移动前更新例外，`apply_human_bumps()` 在所有移动和手部攻击后结算同场人类的身体撞击。
- `route.rs` 的寻路格使用 CSR 分桶：障碍的逆变换和水平包围盒在每次规划时预处理一次，再分桶到可能覆盖的格点。`bucketed_queries_match_a_full_obstacle_scan` 验证分桶与全量扫描输出完全一致；改分桶边界时必须保留该对照。`Footprint::touches()` 仍每次求逆，只用于非热路径。
- AI 路线不再在 `pursue`/`forage` 内同步规划，而是 `request_route()` 写入每角色一个槽位，`process_path_requests()` 每帧最多 4 个、2.5 毫秒，按 `path_cursor` 轮转。请求带 `serial`，`Giant::clear_path()` 会把 `pending_path` 置 0；应用前必须同时检查存活、未被抓和序号，防止旧计划覆盖清空后的路径。增加角色数或改预算后先跑 `tests/perf_probe.gd` 看路径延迟。
- 巨人脚步每物理帧推进，落脚与预测不随镜头距离降频。巨人仍按剪影级别跳过远处头发和尾巴次级弹簧，人类动画仍可根据距镜头远近降频。
- 60 角色 release headless 基线约：大乱斗 27.8ms、成长混合 29.5ms、沙盒 23.8ms；优化后约 17.2/21.5/19.2ms。20 角色大乱斗约 9.1 → 5.8ms。剩余瓶颈是 60 个 `CharacterBody3D` 的 `move_and_slide` 和完整程序化动画；成对检查约 0.01ms，A* 已由 135ms 降到 1.15ms 量级。
- 性能探针 `tests/perf_probe.gd` 只打印，不进通过/失败统计。用 release 扩展测；把 release `.so` 覆盖到 debug 路径后，测完必须 `touch rust/src/lib.rs && cargo build`，否则 cargo 认为 debug 产物仍是最新，游戏会继续加载 release 扩展。

## 巨人分层转身与脚部跟踪（2026-11-25 确认）
- `giant_visual.gd::show_motion()` 的第二参数是供已有三参数预览调用保留的空参数。巨人接触帧返回鞋底字典，其他帧返回空值。人类阶段仍返回脚步布尔值。
- 手部攻击按身体当前朝向结算。玩家视角与第一人称跟转只引导走路朝向，摆脚完成落点锁定后，继续转视角不会移动鞋印。
- `WASD` / 左摇杆保持画面相对方向；玩家与 AI 巨人在站立不动且目标方向夹角 `> STAND_PIVOT_ENTER_ANGLE (0.96 rad ≈ 55°)` 时都先原地小碎步转身，转到 `≤ STAND_PIVOT_EXIT_ANGLE (0.56 rad ≈ 32°)` 后无缝切入行走，中途松手会把抬起的一小步稳稳落完再停下。
- AI 接近目标时按其速度提前量与鞋底摆动侧对准路线。`start_ai_hand_move()` 继续按身体当前朝向校验手部攻击前方扇区。
- 巨人阶段行进速度沿当前身体正前方 `body_forward` 走弧线（急弯自动微减速 `0.25~1.0`），避免横向蟹行把支撑脚甩偏；`giant_visual.gd` 将急转步频平滑限制在正常步频的 `1.24×~1.32×` 内，并约束迈步落脚在髋部自然横向走廊内。
- 原地小碎步转身只调整朝向和提供轻量骨骼回弹。要检查支撑脚是否滑动，用 `get_turn_telemetry()` 的世界空间跟踪或 `tests/playtest.gd::_giant_layered_turn()`。
- 独立原型 `prototypes/giant_turn/` 保留供交互预览，已在 `export_presets.cfg` 两个预设中通过 `prototypes/*` 排除出打包产物。

## 桌面沙盘 3D Skybox（2026-11-26 阶段 2 完整定稿）

- **卧室背景合成修复（2026-11-26 实机录屏 Bug：沙盘悬空）**：`harbor_skybox.gd` 的 `TextureRect` 原先缺 `expand_mode`（默认 `EXPAND_KEEP_SIZE` 用 SubViewport 纹理当最小尺寸）——窗口 >1506×847 时 `DESKTOP_RES_RATIO=0.85` 使 `_sub.size` 超过 1280×720 基准画布（1920×1080 → 1632×918），`_rect` 被撑到 1.275×、光学中心右下偏 ~14%，沙盘与书桌错位悬空。修复三件套：`EXPAND_IGNORE_SIZE` + `STRETCH_SCALE` + 保留 `PRESET_FULL_RECT`；`_sky_cam` 同步 `keep_aspect` 与 `h/v_offset × SKY_SCALE`；`process_priority=100` + **变化驱动刷新**（相机位姿/fov/纵横比/偏移变化当帧 `UPDATE_ONCE`，静止跳过渲染，替代 `_half_flip` 隔帧）。**阶段 3 起卧室里出现任何动画内容（坐姿 Yumeka 等）时，其每帧动画必须调 `Skybox.mark_dirty()`**，否则相机静止时不会重渲卧室。回归断言在 `tests/playtest.gd::_bedroom_skybox()`（强制 `_resize(1920×1080)` 后断言 expand/stretch 模式与 `rect.size == get_visible_rect().size`）；headless 下 `root.size=(64,64)`、逻辑画布用 `root.get_visible_rect()`（=1280×720），不要拿 `root.size` 当画布尺寸。
- **修复收口（2026-11-26 用户验收）**：用户对呈现的修复后逐项核验截图给出「画面正常」——目视验收通过；真核显动态旋转帧率按用户指示**跳过、未测（不估算）**，`build/tmp/rotation_bench.gd` 与命令保留在 CHANGELOG 顶部条目备日后实机复测。

- 架构：`scenes/harbor_skybox.gd`（挂在 `main.tscn` 根的 `Skybox` 节点）+ `scenes/skybox_bedroom.gd`（1:1 日系奶油 + 浅原木风格化卧室，跑在 SubViewport 的 `own_world_3d`）。主视口 `Atmosphere` 用 `Environment.BG_CANVAS=3`，卧室经 `CanvasLayer(-64)+TextureRect(ViewportTexture)` 合成为 3D 背景（UI 在零层之上不受影响）。**不要改回 dome/sky 方案**，也**不要加回外围大 `Water` 海面**：`scenes/district.tscn` 已移除 `3600 × 3600 m` `Water`，`scenes/district_expansion.gd` 已移除 `half_land` 外的所有停泊船只、邮轮、浮标、远海岩石，岸线龙门吊向港内朝向并内缩 14 m，确保零几何穿出沙盘框、框外 360° 完整露出卧室书桌。
- 主世界沙盘木框与桌面精确对齐：`district_expansion.gd::_build_sandbox_frame()` 沿 `half_land` 生成单 mesh 60 面浅原木外框与底裙（`District/SandboxFrame`，不入 `Scenery` 以防分块裁剪，无碰撞，底面在 `y = -32.0 m`）；`skybox_bedroom.gd::_build_sandbox()` 不再绘制重复 CSG 托盘，仅放柔和接触影贴片（`SandboxContactShadow`），并将 `sandbox_anchor` 精确设在 `DESK_TOP + 32.0 * SKY_SCALE`（`0.7548 m`），从任何角度/身高看木框底面都零视差贴合桌面。
- 位姿与宽高比同步：`_process` 内同步主视口尺寸并用**单标量**等比缩放 `_sub.size`（防止窗口缩放/平铺时 `STRETCH_KEEP_ASPECT_COVERED` 裁切放大导致 1:6667 错位）；`sky_cam.global_transform = anchor.global_transform * Transform3D(active.basis, active.origin * (1/6666.67))` + fov 复制，`near=0.005 / far=20.0`。
- 画质、单灯阴影与性能：桌面端 `DESKTOP_RES_RATIO=0.85` + `Viewport.MSAA_2X` + `TEXTURE_FILTER_LINEAR` + 隔帧 `UPDATE_ONCE` + `positional_shadow_atlas_size=0`；移动端 `MOBILE_RES_RATIO=0.55` + `MSAA_DISABLED` + 无阴影。卧室 `ambient_light_energy=0.28`、`tonemap_exposure=0.82`（抵消 `BG_CANVAS` 合成提亮、无过曝），桌面端仅对 `WindowSun`（`light_energy=0.76`）开启单级正交阴影（`SHADOW_ORTHOGONAL`、`max_distance=6.0`、`shadow_bias=0.02`、`shadow_normal_bias=1.2`、`shadow_blur=2.2`、`shadow_opacity=0.56`），仅 `Shell` 与大件家具投射阴影。AMD Renoir 核显 ABBA 同口径实测：开阴影 46.4 vs 关阴影 46.3 FPS（+0.1 FPS，仅 +6 draw calls）；`ab_probe.gd` 单测 50.0 FPS。
- 卧室家具与阶段 3 锚点：21 个 GLB 位于 `assets/kenney/furniture/`（零碰撞）；桌面已移除低模 `BearDesk`，书桌微宽至 `1.63 m`，其余桌面物件退离 `21.27 cm` 沙盘边缘 15–26 cm（`ComputerScreen` 左移至 `x=-0.46`、`LampRoundTable` 右移至 `x=+0.48`），正后方北窗天光完全敞开。`skybox_bedroom.gd` 在 `chairDesk.glb` 坐垫正上方导出 `ultra_giant_anchor: Node3D`（`UltraGiantAnchor`，`(0.0, 0.4553, 0.5484)`，`ultra_giant_seat_y=0.4553`，水平面朝 `sandbox_anchor` `-Z`），透出至 `harbor_skybox.gd::ultra_giant_anchor` 供阶段 3 挂接坐姿 Yumeka。回归入口：`tests/playtest.gd::_bedroom_skybox()`。
- **Rust `HarborGame` 重入与 X11 鼠标捕获保护（2026-11-26）**：`rust/src/game.rs` 在 `set_pause`、`MapSlot` 增删子节点、`Interface.call` 与 `Input::set_mouse_mode` 外层统一用 `self.base_mut()` 释放可重入借用，防止同步通知触发 `HarborGame::on_notification` `already bound` panic；`MouseMode::CAPTURED` 仅在 `DisplayServer::window_is_focused()` 为真时设置（并在 `APPLICATION_FOCUS_IN` 补捕获），消除 X11 未获焦时的 `ERROR: NO GRAB`。
- **阶段 3A 坐姿 Yumeka（2026-11-26 晚间十公里级压迫感升级定稿）**：授权资产 `~/Downloads/YUMEKA_v1.0.4.zip` → `scripts/export_yumeka_seated.py` 全自动导出 `assets/characters/yumeka/Yumeka_seated.glb`（目录连同 license 副本被 `.gitignore`，**永不入库/不入 sync_drive**）。**坐姿必须走 1 帧 Action（`SeatedPose`，48 骨），严禁 `bpy.ops.pose.armature_apply()`**：Apply-as-Rest 只改 rest 骨，带 Shape Keys 的网格顶点不会烘焙变形，glTF 皮肤绑定退化为恒等→Godot 渲染穿椅 T-pose。导出参数：`export_animations=True`、`export_rest_position_armature=False`、`export_force_sampling=True`、`export_morph_animation=False`；Blender 5.3 算子名 `bpy.ops.export_scene.gltf`（后台先 `addon_enable("io_scene_gltf2")`）。前倾趴桌定稿：`ChairDesk` 前移 4 cm 至 `z=0.60`（`ultra_giant_anchor.z=0.50835`），`BODY_SCALE=1.05` + `CUSHION_COMPRESSION=0.042`；先用 `LEG_POSE_TWISTS`（大腿 −89°、小腿 86°、脚 10°）测未倾坐垫平面，再叠 `UPPER_POSE_TWISTS`（`Spine +4° / Chest +26°` 共 30° 前倾、`Neck +14° / Head -14°`，上臂贴身下垂前收、前臂屈肘呈八字形 `/\` 搭于 21.27 cm 沙盘南侧桌面）与 `LOCAL_POSE_TWISTS`（前臂旋前 +59°、手腕微伸 +10°、五指含拇指绕骨骼真实屈指轴 `local (1,0,0)` 取负角递增微屈——**注意 `local Z` 是横向张指而非握拳，真屈指轴是 `local X` 且左右同为负角**）；终值：眼高 **0.979 m**（`eye_z=0.350`，1.80/25/100 m 平视 0° 即可见巨脸压满天际线）、大腿顶 `0.605 m < 0.690 m`、鞋底 `+0.039 m`、`LowerArm_L/R=(±0.223,0.803,0.369)`、`Hand_L/R=(±0.169,0.796,0.202)`。Godot 侧（`scenes/yumeka_ultra_giant.gd`）：`_ready()` 播 `SeatedPose` → `seek(0,true)` → `pause()` 后缓存 `_posed_bases`/`_local_bases`，按 `Spine → Chest → Neck → Head → Eye_L/Eye_R` 父子顺序叠加呼吸、头颈（±15°/±10°）与**双眼球共轭锁视**（`EYE_YAW_LIMIT=±14°`、`EYE_PITCH_LIMIT=±10°`、`_swing_to()` 返回角度值），18 Hz tick 调 `Skybox.mark_dirty()` 并同步 `CityNightLights.set_giant_shadow_pulse(_breath_lift)`。材质规范：roughness 0.88 / metallic 0 / metallic_specular 0.16 / emission 关、`*Transparent` 用 `TRANSPARENCY_ALPHA_SCISSOR 0.42`+双面。
- **城内巨型遮天阴影与背景微柔焦薄雾（2026-11-26 晚定稿）**：`scenes/city_night_lights.gd` 在全部建筑/路灯着色器与 `shadowed_surface_material()`（覆盖地面/地块/道路/树/沙盘框，道路带 `repeat_enable`）中注入世界空间 `apply_giant_shadow()`（仅压暗 `ALBEDO`、保留 `EMISSION` 万家灯火，零新增 Draw Call/光源/Z-fighting），随 Yumeka 4.2 s 呼吸轻微脉动，由 `day_night_cycle.gd` 按昼 `0.66` / 昏 `0.70` / 夜 `0.26`（未挂载 Yumeka 时 `0.0`）联动；`scenes/harbor_skybox.gd` 的 `_rect` 挂单 pass 2D `ShaderMaterial`（5-tap `0.78 px` 微柔焦 + 昼 `5.8%`/昏 `6.4%`/夜 `4.4%` 空气薄雾）。回归入口 `tests/playtest.gd::_bedroom_skybox`（含眼高 `0.95–1.08`、手部/大腿/脚部区间、眼球左右追踪与限幅、背景空气透视材质与昼/昏/夜遮天阴影断言）。
- **易踩坑备忘**：headless 回归里出现的 `Parameter "material" is null` ×45 为**存量**现象（移除 Yumeka GLB 照样出现，来源未定位），别归因给新增资产/皮肤改动；Blender 里按「平面区域过滤器」找身体最低顶点会被裙摆/鞋底骗（裙摆能悬在真接触面下方 20 cm），测量要经骨位置+顶点归属打印确认。GDScript lambda **按值捕获局部变量**：从 `_walk`/回调里给外层局部赋值静默失败（本项目连踩两次：探针与 `_land_seated_pose`），收集一律走成员变量或 `Array.append`；Xvfb 里卧室镜像相机别放到 x≈±1.9 m 取景（会陷进床/床头柜区渲成纯色墙），x≈1.55 m 已验证可用。
- **画面质感与昼夜氛围精装（2026-11-26 晚定稿）**：
  - **卧室精装**（`scenes/skybox_bedroom.gd`）：`BedroomEnvironment` 改用 `BG_SKY` 动态天空 Shader（上层视角地平线下移 `+0.16`，含云层/日晕/夕阳/星夜，室内环境光仍走 `AMBIENT_SOURCE_COLOR`）；北窗两侧为 `DIFFUSE_LAMBERT_WRAP` 褶皱半透纱帘 + 原木杆/绑带（留出中央 1.38 m 无遮挡视野）；`Decor` 节点放 6 幅程序生成木框挂画、西北墙软木板、南墙搁板（含粉彩书/多肉/相框）、桌垫（键鼠抬高 `2.4 mm` 坐于垫上）与右侧马克杯，全部零碰撞；`ComputerScreen/MonitorDisplay` 按实测倾斜法线贴合 256×154 程序桌面壁纸+双窗口+任务栏纹理（带昼夜自发光）。
  - **主世界 AGX 与 4 皮肤统一防过曝**：`scenes/main.tscn` 切 `tonemap_mode = 4`（AGX、`exposure = 0.96`）+ 天空半球冷阴影环境光；`GiantSkin.shade_anime_materials()` 统一将 `snow_fox`/`hina`/`chibi_catgirl`/`kawaii` 的 `KHR_materials_unlit` 转为 `PER_PIXEL + DIFFUSE_BURLEY`（`roughness = 0.89`、`specular = 0.16`、`emission = false`，白衣/白发/肤色反照率压至 `0.84–0.90`），彻底消除 `DIFFUSE_TOON` 阳光惨白洗平并使 4 皮肤均响应黄昏/夜景光照。
  - **昼夜循环与零新增动态灯夜景**：`time_of_day`（`auto/day/dusk/night`，默认 `day`，`settings_schema.gd` `PAGE_GRAPHICS` `kind = "choice"` + `rust/src/settings.rs` `TimeOfDay` 持久化，局内 `F7` 兼容 `keycode`/`physical_keycode` 轮切）；`scenes/day_night_cycle.gd` 同步主世界 `Sun`/`Atmosphere`/`CityNightLights` 与 `Skybox.apply_day_night()`；`scenes/city_night_lights.gd` 对 `commercial(5,1)`/`industrial(4,3)`/`suburban(5,1)` 玻璃色块及 `roads(4,2)` 路灯灯头做像素分析并生成 `filter_nearest` 掩码（零 mipmap 串色），近景 48 批次+核心 12 栋走掩码+世界坐标房间哈希、远景 5 批次走严格垂直立面（`|n.y|<0.22`）网格窗着光，路灯 2 批次走 `material_override`；**0 新增城内动态灯、MultiMesh 维持 76 个**；夜晚卧室 `DeskLampLight`（`LampRoundTable` 内单盏无阴影 `OmniLight3D`，白天关闭）自动亮起暖金光柔和照亮 Yumeka 脸部与桌面。回归入口 `tests/playtest.gd::_day_night_and_settings()`。

## 阶段 4：金币风险分级 + 全场 Utility AI（2026-11-27 确认）

- **金币 3 档**（`growth.rs::CoinTier`）：Normal/High/Extreme = 1×/2.5×/5× 奖励、0/2.0/3.75 s 读条；分级来源＝巨人脚边踩踏射程(Extreme)、活动区 `max(视距×1.4, 身高×2.2)`(High)、交战热区（重步落脚/拆迁/击杀喂入 `note_hotspot`，12 s TTL，容量 24）；热区与巨人位置每 0.5 s 对存量币重估（`update_hotspots_and_coin_tiers`，热区衰减在 `physics_process` 里无条件跑——`coin_count=0` 时金币更新提前返回）。**离开拾取圈按 ~27 %/s 缓退不清零**（`advance_dwell`，纯函数有单测）；成长为巨人后全部瞬拾；brawl 击杀掉落币恒 Normal。读条状态在 `Giant.coin_dwell: Option<CoinDwell>`（按币 InstanceId 跟踪），玩家有地面进度环（`coins.gd::show_dwell`）与递增音效（`coin_dwell_tick`，复用 coin_pickup wav 的独立冷却别名），AI 无视觉但共用同一时序代码。
- **模糊雷达**：`snapshot_growth` 仅在成长模式人类阶段发 `coin_radar`（angle/span≈40°/tier/proximity 3 档，110 m 内不发=淡出）；HUD 是 `interface.gd` 的 `CoinRadar` 类（顶部居中弧形扇区，tier 三色，脉冲速率 5.2/9.0/14.5 Hz）。成长模式**不再发** `coin_distance/coin_angle`（精确罗盘只保留给 brawl 小巨人）；`growth_playtest._mapwide_coins` 的旧精确断言已改为雷达断言。
- **AI 模块 `rust/src/round/ai.rs`**：`Personality`（6 维 0–100，`roll()` 走 godot 随机流→测试 `seed()` 可复现，跨复活保留；**不要改回 wall-clock 随机**，会让回归按掷骰结果漂移）、`SizeTier`（7 档 +10 %/−10 % 滞回，`from_ratio_with_hysteresis`）、`CombatMemory`（目击 6 s/受击 2.5 s/仇恨 25 s/失败逃跑拉黑 4 s/危险区 13 s，全部 tick 衰减）、`escape_direction`（16 射线按"探针-威胁距离增量"给分 + 边界侵入斥力，**任何情况不返回零向量**，有单测）。
- **pursue 重构要点**：预警圈内每帧直接 Evade（100+，绕过 0.25 s 重评），utility 重评带 +13 惯性；**逃避期间豁免站立小碎步转身**（`update_giant` 里 `intent == Evade` 清 pivot，否则 4× giant_speed 下 0.13 s 预警窗会被 180° 转身耗光——回归 `_ai_evades_warning_circles`）；Search 分数按目击点距离 60/(60+d) 衰减（远处逃兵让位给拆楼，否则 playtest 的拆楼回归会因 6 s 搜索超窗）；**击杀清空进攻方 last_seen/hit_from/grudge**（搜尸体无意义）；撤离/沙盒 AI 对人类/市民目标 attack 恒 100 分且 `chases()` 不拦（掠食者设计，性格不得让撤离巨人对人类摆烂）。
- **挑高楼倾向**：`choose_building(actor, position, prefer_tall)` 只在**距最近楼 6 m 窗口内**取最高楼（destructiveness>0.6 触发）；窗口放宽会抢走明确最近楼、打破 playtest 的拆楼断言（该断言已改为"最近簇 ±7 m 内被拆"）。
- **市民三态**（`update_civilians` + `CivilianState::{Calm,Panic,Cover}`）：0.28 s 节流感威胁（巨人活动范围/鞋底落点预测/落地震动都算），panic 速度 ×2.4、动画传 sprint=true，撞墙沿墙滑行；`round.civilian_debug()` 暴露 state/position。**测试市民恐慌时先等开局恐慌平息**（出生在巨人旁的市民开局就在 panic，最多 ~14 s 才回 calm，中途瞬移会因 cover 目标点在旧位置而拉长回程）。
- **测试/调试接口**：`round.coin_debug()`（id/ttl/expiring/tier/dwell/position）、`round.civilian_debug()`、`growth_actors()` 新增 `intent/size_tier/evading/dwell/dwell_tier`。
- **易踩坑**：`coins.gd` 的 dwell ring 挂在 Coins 根下，`_refresh_visible` 必须跳过无子节点的孩子（否则每帧 Index error 刷屏）；测试成长模式地图币补刷时保留存活人类阶段角色；重步预测回归可临时设 `giant_speed=1×` 留出可测的避让窗口。

## 阶段 3B-1 & 单世界 Vulkan `mobile` 渲染升级（2026-11-27 确认）

- **渲染后端与单世界挂载**：`project.godot` 已切换为 `renderer/rendering_method="mobile"` 与 `renderer/rendering_method.mobile="mobile"`。`scenes/harbor_skybox.gd` 已彻底移除 `SubViewport`、`BedroomCamera`、`CanvasLayer -64`、`TextureRect` 与 2D 薄雾合成层，改为把 `Bedroom`（含 `Yumeka_seated.glb`）直接挂在主 3D 场景 `Skybox/Bedroom` 下，`scale = Vector3.ONE * 6666.67`，`sandbox_anchor.global_position == (0, 0, 0)`，零碰撞体；主世界 `Atmosphere` 唯一 `WorldEnvironment` 切为 `BG_SKY`，由 `day_night_cycle.gd` 驱动含云层/夕阳/繁星的动态天空 Shader（卧室不再创建第二 `WorldEnvironment`）；`Overview`、`Round/Orbit/Arm/Camera` 与 `round.rs::apply_camera_distance()` 的 `far` 下限抬至 `50000.0`，第一人称与旁观相机 `near` 下限收敛至 `0.05 m`（保证 `far/near <= 1,000,000`，避免 `RenderingLightCuller::create_frustum_points()` 浮点退化报错）。
- **Layer 1 / Layer 2 原生光照隔离**：Layer 1 为城市（`District`/建筑/道路/沙盘木框/巨人/人类/金币/特效 + 主世界 `Sun.light_cull_mask = 1`）；Layer 2 为卧室与 Yumeka（递归所有 `VisualInstance3D.layers = 2` + `Bedroom/Lights` 反向缩放 `1/6666.67` 使 4 盏卧室灯以 `1.0` 全局缩放运行且 `light_cull_mask = 2`、`WindowSun` `SHADOW_PARALLEL_2_SPLITS` `max_distance = 40000 m`、`DeskLampLight` `omni_range = 29333 m`）。**Vulkan `Forward Mobile` 易踩坑**：① 点光源有显式 `pow(distance, -omni_attenuation)` 距离衰减且将 `linear_color * energy * PI` 打包进 FP16（上限 `65,504`），`energy > 20,850` 会导致红通道溢出变青绿——因此 `DeskLampLight` / 夜间 `CeilingFill` 使用 `omni_attenuation = 0.75` + `energy = 1118 / 320`（UBO 峰值 `3,512 << 65,504`）；② NVIDIA/Android 移动 GPU 在 `Forward Mobile` 下常选 `D24_UNORM_S8_UINT`，22 km 远墙处 1 bit ≈ 300–590 m，因此卧室 7 处远墙挂画/软木板在 `Shell` 内挖有 `10 cm`（`667 m`）浅凹槽且无重叠衬板，避免远墙 Z-fighting。
- **废除 `Yumeka_hand_relay.glb`，直接驱动真身骨架「单指点戳」**：`scripts/export_yumeka_hand_relay.py` 与断手资产已删除。`scenes/yumeka_ultra_giant.gd` 直接在 `Yumeka_seated.glb` 317 骨骨架上实现 `apply_right_arm_ik()` / `clear_right_arm_ik()`（动态量取 `L1=1090.28 m / L2=1171.96 m` 与指腹偏移；`Yumeka_seated.glb` 已将 `REST_RELAXED` 烘焙进 `SeatedPose` rest，手势混合用 `q_rest_relaxed^-1 * q_target` 绕验证过的 `local (1,0,0)` 屈指轴插值，保留 `REST_RELAXED`/`FINGER_POKE`/`OPEN_PALM`/`PINCH_GRIP`；叠加 `Chest` `+3°` 前探/`±2.5°` 转向与 `Shoulder_R` `+4.5°`/`-3°` 随动，每帧同步重算 `Neck`/`Head`/`Eye_L`/`Eye_R` 与 `LowerArm_twist_R` 45% 旋前；所有网格设 `extra_cull_margin = 2.0` 防伸臂时视锥裁剪）。`scenes/desk_hazards.gd` 保留 `desk_hazards` 开关、`45–90 s` 自动周期、`F8` 快捷键、不可攻击合约、AI 预警圈躲避与 `110 m` 破坏结算，直接驱动真身完成 `RAISE(0.65s) → WINDUP(1.75s) → HOLD(0.50s) → RETRACT(0.65s) → RETURN(0.75s)` 五段连贯动画（实测首帧误差 `0.00012 m`、触地水平误差 `0.0008 m`、卷指净空 `+233.0 m`）；缺失 `Yumeka_seated.glb` 时回退无碰撞关节占位臂。回归入口：`tests/playtest.gd::_bedroom_skybox()`、`_day_night_and_settings()`、`_desk_hazards_finger_poke()`。

## 本机开发注意
- bash 工具的 `/tmp` 不跨命令保留。临时源码副本放工程内的 `build/tmp/`，不要依赖 `/tmp`。
- **GPU 测量口径（2026-11-26 教训）**：本机默认 OpenGL 会落在 zink/NVIDIA dGPU（本会话探测 `Using Device: Mesa - zink Vulkan(NVIDIA...)`）；测核显必须 `MESA_LOADER_DRIVER_OVERRIDE=radeonsi`（`glxinfo -B` 同理）。iGPU 连续满载热降频极明显（同一基线代码逐次 50.8→55.9 不等），前后对比必须做**交叠 A/B**（`build/tmp/ab_probe.gd`：只测全图俯瞰 `(0,620,980)`、1280×720、vsync 关、420 帧预热 + 60 帧采样），并报同会话成对差值；绝对值（如 61 FPS 历史基线）跨天/跨热状态不可比。ABBA 在哪跑按 AGENTS.md「视觉/渲染测试显示规范」：真 FPS 只能来自用户真实桌面（由用户自行运行）或验证过 radeonsi 的隔离虚拟显示；llvmpipe（纯 Xvfb）里的数字一律不进性能结论。
- `rclone lsl` 输出的是**本机时区（Asia/Shanghai=北京时间）**，不是 UTC；报云盘时间一律写"北京时间 XX:XX"。
- **隔离虚拟显示能力（2026-11-26 实测，永久显示规范的技术前提）**：`vglrun`/`weston`/`gamescope`/`xvfb-run` 均未装，只有裸 `/usr/bin/Xvfb`（手动 `Xvfb :97 -screen 0 1920x1080x24` 起、用完 kill）。`renderD128`＝AMD Renoir 核显、`renderD129`＝NVIDIA dGPU（查 `/dev/dri/by-path`）；不碰真实桌面的 renderer 检测用 `DISPLAY= WAYLAND_DISPLAY= timeout 30 eglinfo -B`（surfaceless 报 radeonsi/renoir）。纯 Xvfb 内 glxinfo＝llvmpipe（LLVM 23.1.5），Godot 4.7.2 + gl_compatibility `--quit-after 5` 实测约 23 s 退出——少量帧截图/布局验证可行，长 FPS 基准禁止。以后要无窗口硬件加速需装 VirtualGL/Weston/gamescope 并重测 renderer，装好后更新本条与 AGENTS.md。**Xvfb 里 `DisplayServer.window_set_size()` 不生效**（实测设了 1920×1080 后 `root.size` 仍是 1152×648）：要指定截图/测试窗口尺寸必须用 CLI `godot --resolution WxH` 在建窗时给定；否则探针跑在默认窗口上，`_sub.size` 可能根本没超过 1280×720、测不到想测的口径。

## 备份约定
- 改动前的完整备份放在 `backups/<YYYYMMDD_HHMMSS>_<主题>/`，`CHANGELOG.md` 顶部记录本次备份路径、改动和回滚命令。

## 巨人坐压（2026-11-25 确认）

- 坐压状态机在 `rust/src/round/sit.rs`：`SitPhase::{Drop, Hold, Rise}`，Drop/Rise 换算成 `giant_visual.gd` 的 0..0.67 / 0.67..1 进度，Hold 走 `show_sit_idle` 无缝循环。坐压期间**禁止调用 `animate()`**（`show_motion` 会覆盖坐姿），也不跑 AI/输入/成长。
- 触发：AI 自动（条件 = 前方意向圈内 ≥ `sit_crush_targets` 个身高 ≤ 自身 `1/sit_crush_ratio` 的活物；半径 `4.366 × 体型`，圆心在身体正前方 `2.85 × 体型`）。玩家**只要是巨人阶段**按 `stand_up`（X）随时可坐，不需要目标、不看坐压冷却；`sit_crush_enabled` 只关 AI 的自动坐压。
- AI 坐压在地面检查，没有重步预告时才启动。人群检查在下一次追击与迈步之前执行。玩家按 X 继续可主动坐下或起身。
- 人群判定在 `update_giant()` 里排在 `pursue()` **之前**，所以群体坐压本来就优先于单点踩踏/抓捏；`seat_targets()` 统计人数**不看** `rival_ignore_ratio` / `human_ignore_ratio`，也不要求存在 `chase_target`，统计范围＝`rivals`（含人类阶段巨人）+ `civilians` + 撤离玩家。抓起的目标会从 `rivals` 摘除、不计入人数——抓捏射程 `0.29 × 身高` 比意向圈前沿 `0.2863 × 身高` 略大，这条约 `0.0037 × 身高`（25.2 m 时 9 cm）的窄带是唯一还能让单点攻击抢先的路径。
- 落区预警：`round_effects.gd` 的 `sit_warn(center, radius, index)` / `sit_warn_end(index)` 画琥珀色落区圈（节点名 `SitWarning` / `SitWarning2`），`drive_sit` 在 Turn/Drop 阶段每帧更新、落座/起身/死亡时清除；不要在 Hold 阶段还留着圈。
- 坐姿的骨盆落在身体**后方**：`sit_center = 位置 - forward × 2.85 × 体型`（实测 yaw=0 时骨盆在 +2.85 米），所以坐压前要先原地转身把背对准人群——`SitPhase::Turn` 调用 `giant_visual.gd` 的 `step_turn_in_place(aim, dt)`，`done` 或 7 秒超时后再进 Drop；没有目标就直接坐。**判定圈在前方、落地区在后方**，两者不要写反。
- 停留：AI 用 `sit_hold_base + sit_hold_per_scale × (体型-1)`，最低 0.45 秒；玩家的坐压 `timed = false`，**不会自动起身**，必须按 X（`SitAction.timed` 控制是否计时）。满级待机坐由 `sit_idle_chance` 每秒概率触发，`sit_idle_timeout`（默认 60 秒）自动起身，出现目标（含更大巨人）立即起身。
- 伤害：落座瞬间走既有 `impact()` → `GiantStrike`，`DefeatMethod::SitCrush`，建筑/行人/对手同一套结算；击倒播报键 `sit_crush`。坐下与待机都会结算一次落座伤害。
- 被坐压：`Giant.pinned_by` 定身并每 `sit_pin_interval`（0.5 秒）掉 `攻击力/5` 的血，直到对方起身/死亡。**不要复用 `grabbed`**：被抓起会从 `rivals` 摘除、HUD 显示「被抓住」、手部逻辑当作持有目标，语义完全不同。
- 设置键（`GameSettings.sit`）：`sit_crush_enabled / sit_crush_ratio / sit_crush_targets / sit_hold_base / sit_hold_per_scale / sit_idle_enabled / sit_idle_chance / sit_idle_timeout / sit_pin_ratio / sit_pin_interval`，四个模式共用。
- 回归入口：`tests/sit_crush_gameplay_playtest.gd`（44 项）。测试里玩家巨人要按 X 才坐；AI 待机坐用 `debug_resize_giant` 造体型、把玩家挪远制造「无目标」。
- 调试接口 `round.debug_resize_giant(index, height)` 改体型。`growth_actors()` 提供 `sit / sit_idle / pinned`，`snapshot()` 提供 `sit_action / sit_progress / sit_idle / giant_pinned / sit_ready`。

## 设置面板（2026-11-25 重构）

- 选项元数据唯一来源是 `scenes/settings_schema.gd` 的 `OPTIONS`：每项声明 `key`（＝节点名＝存档键＝`invalid_setting()` 返回值）、短名、`hint`、`kind/step/suffix/integer/percent`、`page`、`group`、`advanced`、`apply`（下局/立即/下次倒下/下次复活）、`modes`、`requires`。新增选项先在这里归类，再改 Rust 校验与界面。
- 两页：`graphics`（画面与声音，全局只设一次，保存时把 `view_distance / shake_strength / own_camera_shake` 镜像进四个模式 profile）与 `gameplay`（按模式保存）。`own_camera_shake` 已改为所有模式都写入。
- 玩法页按 `GROUPS` 分组、每组末尾「高级」默认收起；`requires` 不满足时整行隐藏（不再置灰）。`Interface.debug_expand_settings()` 供测试展开。
- 节点名兼容契约：`GameplaySettings`、`SaveSettings/CancelSettings/ResetSettings`、`HumanSettingsTab/GiantSettingsTab/GrowthSettingsTab/BrawlSettingsTab`、`SettingsPageGraphics/SettingsPageGameplay`、`NpcRespawn/AudioMuted`，数字项节点名＝存档键。
- `_save_settings()` 会同时抓取玩法页、音频与显示项（即使用户停在玩法页），避免隐藏页的改动丢失；`_capture_settings_fields()` 只收当前模式适用的键，其余从 `default_mode_settings()` 兜底。

## 雪狐巨人皮肤（2026-11-25 正式接入）

- Godot 4.7 仍不认 `.vrm`（`PackedScene` 只认 tscn/res/scn，`.vrm` 在 `--import` 时被静默忽略）；VRM 1.0 就是 glTF 2.0 容器，正式资产是 `~/Documents/AvatarSample_D.vrm`（VRoid 2.16，已按新许可重新打包）复制成的 `assets/characters/snow_fox.glb`。旧的 `assets/characters/_vrm_probe/` 与 `tests/vrm_avatar_skin.gd` 已删除。
- 皮肤 `scenes/snow_fox_skin.gd`，注册为 `giant_visual.gd` 的 `SKINS` 键 `&"Snow Fox"`（随机皮肤池 4 选 1；`tests/sit_crush_preview.gd` 按 4 切换）。`J_Bip_*` → Kawaii 驱动骨，T-pose 用 `ALIGN_TOWARD` 拉成 A-pose，`FIT_SCALE=1.184`（模型 1.4398 m → Kawaii 1.7047 m）；`FLOOR_OFFSET=0`，实测站立脚底 0.03–0.04 m；`pelvis_height_ratio()` 自动约 1.073，坐压 0.55 进度骨盆落在地面（hips_y≈0.37 m）、不悬空。
- 材质：MToon 到达时是 `KHR_materials_unlit`；`_shade_unlit_materials()` 复制成 PBR：`DIFFUSE_TOON`、`roughness=1.0`、`metallic=0`、`metallic_specular=0`、`SPECULAR_DISABLED`、`emission_enabled=false`。**按材质名分档 tint**（`material_tint()`）：`SKIN`/`FACE`（含眉睫唇线）`Color(0.80,0.73,0.70)`；`HAIR`/`FoxTail` `Color(0.75,0.78,0.84)`；其余（白女仆装 `Tops_CLOTH`、围裙、白丝袜等未命中项）`Color(0.70,0.71,0.75)`；只有材质名含 `_EYE` 的眼球/高光保持 1.0。旧实现只压暗 SKIN/HAIR 的 0.86，白衣和丝袜完全不压，强光下死白。
- 二次动态：`giant_skin.gd` 新增可选 `apply_secondary_motion(sway, tip_sway, bounce, tip_bounce, rot_lag, tip_rot, head_down_tilt, dt)`；`giant_visual._update_hair()` 在 `_active_skin != null` 时不再写隐藏的 Kawaii 发骨，改为在 `_distant_clipped`/剪影之外把弹簧值转发给皮肤。雪狐只驱动 `J_Sec_Hair*`（11 条锁，每条 2–5 节）和 `J_Opt_C_FoxTail*`（5 节）；裙骨未动（裙摆靠 `SkirtFront*` 继承大腿、`SkirtSide/Back` 继承髋）。
- 第一人称：`set_first_person()` 用 `cast_shadow = SHADOWS_ONLY` 取代 `visible=false`（雪狐的 Face/Hair、Kawaii 的 7 个 HEAD_ATTACHMENTS，人类阶段的头也一样），地面影子仍有头/发/兽耳。雪狐 `_configure_visibility()` 的第三个参数要传 `[&"Body"]`：Body 网格里既有头皮 SKIN（1018 三角面）也有整块 `HairBack`（1296→24 面），不裁就会在第一人称低头时露出蓝灰网格。
- 同口径面数：Kawaii 58.1k 面/15 网格、Hina 35.4k 面/14 材质、Chibi Catgirl 84.3k 面/22 网格、雪狐 61.0k 面/15 个 surface（Godot 合并后 44,709 顶点/29 贴图），属于同一量级。
- 仍未做：不解析 `VRMC_springBone`（只是把现有弹簧值转发）；表情是 morph target，骨骼眼/眉/眨眼对雪狐无效。

## 第一人称相机（2026-11-25 确认）

- 眼位唯一来源是 `giant_visual.first_person_eye_position()`：巨人阶段 = 当前骨架 Head 骨骼世界坐标 + 前偏 `0.045 × 身高` + 上抬 `0.055 × 身高`；人类阶段或缺 Head 骨骼回退 `0.90 × 胶囊身高`。`round.rs::follow_camera()` 直接拿它当基准，只在 `pitch < -0.35` 时再最多叠 `0.105 × 身高` 的 smoothstep 前探（`FIRST_PERSON_LOOK_DOWN_PITCH/LEAN`），**不要再在 Rust 侧重复加基础前偏**。实测雪狐眼高 0.8916 h（Head 骨骼 0.8365 h），Kawaii 0.899 h，Hina 0.890 h，Chibi 0.820 h。
- 第一人称转头夹紧：`self.yaw` 相对 `giants[0].body.get_rotation().y` 最多 ±`FIRST_PERSON_YAW_LIMIT (1.31 rad ≈ 75°)`，由 `clamp_first_person_view()` 在 `rotate_view()` 和每帧 `follow_camera()` 里执行；这是「看不到后背蝴蝶结和尾巴」的硬保证。
- 设置键 `first_person_steer`（默认开，玩法页「巨人」组，立即生效）：开启时站立用 `show_motion(..., turn_target=视角 yaw, allow_standing_turn=true)` 原地小碎步带身体、行走用夹在 ±75° 的 `turn_giant_smooth`；关闭时身体不随视角。手部动作和坐压期间跳过（`steer_view` 条件），攻击锁定朝向不变。
- 注意 `giant_visual` 的原地转身自身死区是 `STAND_START_DEADZONE (0.22 rad)` 起步、`STAND_DONE_DEADZONE (0.06)` 收尾；`FIRST_PERSON_STEER_DEADZONE (0.05)` 只是「不再请求」的门槛，所以 12.6° 以内只转头不挪脚。
- 测试：`tests/growth_playtest.gd` 的 `_first_person_eye_tracks_head()`、`_first_person_view_limits()`；`_first_person_camera_active()` 现在用 `first_person_eye_position()` 取期望高度（旧的 `0.90 × 身高` 已不适用）。

## dsh 技能环境（2026-11-25 配置）

- dsh 原生 `@deepseek-ai/dsh-skill-filesystem` 已支持多目录技能根，**不需要**另装 `dsh-skills-manager`：`<工程根>/.dsh/skills`（项目，rank 100）、`<工程根>/.agents/skills`（200）、`customSkillDirs`（300）、`~/.dsh/skills`（400）、`~/.agents/skills`（500）。放在 `<name>/SKILL.md` 或顶层 `<name>.md` 即被识别，**目录监听会自动刷新、无需重启 dsh**；frontmatter 只强制 `name` + `description`（`name` 必须 `^[a-z0-9]+(-[a-z0-9]+)*$`），多余字段（如 `license`/`compatibility`）被忽略。
- 已装 6 个引擎/Rust 技能（用户级 `~/.dsh/skills/`，来源 commit 见下）：`godot-3d-essentials`、`godot-gdscript` 来自 gamedev-skills/awesome-gamedev-agent-skills @ `c6ca6c4`（各含 `references/` + `assets/*.gd` 检查脚本）；`godot-4-api-pitfalls`、`godot-control-layout`、`godot-scene-organization` 来自 ziva-sh/godot-skills @ `f3199da`；`rust` 来自 joshuadavidthomas/agent-skills @ `516dee7`（整目录 73 个 md，`references/` 之间互相引用紧密，按需读取，内部链接 0 断链）。
- 项目专属技能 `harbor-alert-workflow` 在 `.dsh/skills/`（5 条硬性规范：同口径对比 / 软渲染只用 `--headless` / 截图先看再结论 / 测试通过后同步源码包 / 视觉渲染测试用隔离虚拟显示）。`.git` 原是空目录（只占位让 dsh 识别 projectRoot）；**2026-11-26 起 `git init` 成真仓库**，origin = https://github.com/nhyxb/scalebreaker（公开、main 分支、初始提交 4f7f0f2）。`.dsh/skills/` **公开进仓库**（`AGENTS.md` 引用它；`.gitignore` 用 `/.dsh/*` + `!/.dsh/skills` 只白名单技能目录，`.dsh/` 下的其他本机数据仍排除）。GitHub 仓库内容口径：源码 + `assets/` 全量（Kenney/Poly Haven CC0、VRoid 样例按其许可重打包）都上传；**不上传**（在 `.gitignore`）：`rust/target/`、`build/`、`backups/`、`.godot/`、`*.tar.gz`、`native/*.so`（113M 桌面 .so）、`.aws/.codex/.agents/` 及 `.dsh/` 其他内容。**别把 `.git` 删掉**的规则照旧生效。
- 更新：`git -C ~/.cache/dsh-skill-src/<repo> pull` 后 `cp -a` 覆盖对应目录；卸载直接删目录；克隆缓存留在 `~/.cache/dsh-skill-src/`（gamedev / ziva / jdt 三个稀疏克隆）。
- 本机 `glxinfo` 是 `AMD Radeon (radeonsi)` 且另有 RTX 3050 Ti，**不是** llvmpipe；软渲染判定要在实际执行环境里跑一次再决定能不能开窗口。
