# 项目协作规则

- **每改完代码顺手跑 `scripts/sync_drive.sh`**（高优先级）：把工程代码打包到 `gdrive:gba-sync/gba_code_latest.tar.gz`，改完代码、验证通过后立即同步，不要等收尾。
- 默认在电脑端开发和验证，新功能同时适配安卓触屏和布局。用户明确要求导出安卓端时，才构建或更新 APK。
- 改 Rust 后先 `cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target`，再跑 `cargo test` 和 Godot 玩法测试。
- 跑 Godot 测试前把 `user://` 指到工程内可写目录，否则设置文件写不进去，整批设置类用例会连锁失败：

  ```sh
  XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://tests/growth_playtest.gd
  ```

  其余同款：`tests/playtest.gd`、`tests/mode_menu_playtest.gd`、`tests/touch_playtest.gd`，以及启动校验 `godot --headless --path . --quit-after 5`。

## 工作流技能（本项目专属）

- 4 条硬性工作流规范（同口径数据对比 / 软渲染下只用 `--headless` / 截图先看再结论 / 测试通过后同步源码包）写在项目技能 `.dsh/skills/harbor-alert-workflow/SKILL.md`。做 3D 模型或性能对比、汇报渲染截图、交付同步前，先加载 `harbor-alert-workflow`。
- dsh 自动扫描 `<工程根>/.dsh/skills`（rank 100）与 `~/.dsh/skills`（rank 400），新增或修改技能都无需重启，下次会话/下次加载即生效。

## 坐压与设置面板约定（2026-11-25）

- 新增设置项的顺序：先在 `scenes/settings_schema.gd` 声明（页 / 组 / 是否高级 / 生效时机 / 依赖 / 取值格式），再到 `rust/src/settings.rs` 加字段、默认值、校验与序列化，最后才写界面代码。节点名必须等于存档键（`AudioMuted`、`NpcRespawn` 是历史例外）。
- 依赖项一律**隐藏**而不是置灰；需要测试可见性时先调用 `Interface.debug_expand_settings()` 展开全部分组与「高级」。
- 画面/声音类选项放 `PAGE_GRAPHICS`（全局一页，保存时镜像进四个模式）；玩法规则放 `PAGE_GAMEPLAY`（按模式）。
- 坐压相关：被坐压用 `Giant.pinned_by`，不要复用 `grabbed`；坐压期间不要调用 `animate()` 或 `show_motion()`，否则行走姿态会覆盖坐姿。
- 新功能默认可在电脑与安卓触屏两端操作：坐压已有键盘 `X` 与触屏「坐压/起身」按钮。

## 渲染/相机约定（2026-11-26，阶段 1.5）

- 静态资产（道路、地块、树木、路灯、车、系船柱、建筑）**一律全图合批**，不要再按 108 m 分块生成 `MultiMeshInstance3D`；需要距离裁剪的只有 `Scenery` 里的独立小件。新增批次放 `District/Batches`，别放进 `Scenery`（会被分块裁剪误伤）。
- 建筑视觉由 `scenes/district_batches.gd` 三层负责；新增可破坏建筑时用 `_spawn_kit_building()`（会自动 `batched = true`），需要独立 `IntactModel` 节点的只有中心 12 栋与两个地标。
- 相机与视距：`far`/`near`/臂长/焦点都由 `round.rs` 按身高与地图算，**禁止再写死上限**；改相机后跑 `tests/playtest.gd`、`tests/growth_playtest.gd`、`tests/touch_playtest.gd`。
- 性能/面数对比用 `scripts/district_stats.gd`（几何）与 `tests/gpu_probe.gd`（实机 GPU，需要真 GPU 与窗口），两次比较必须同窗口尺寸、同预热逻辑，口径写在汇报里。

## 验证命令

```sh
# Rust：先构建再跑测试
cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target
cargo test --locked --manifest-path rust/Cargo.toml --target-dir rust/target

# 坐压玩法端到端（44 项）
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://tests/sit_crush_gameplay_playtest.gd

# 设置面板相关
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://tests/growth_playtest.gd
XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://tests/touch_playtest.gd
```
