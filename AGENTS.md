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

- 5 条硬性工作流规范（同口径数据对比 / 软渲染下只用 `--headless` / 截图先看再结论 / 测试通过后同步源码包 / 视觉渲染测试用隔离虚拟显示）写在项目技能 `.dsh/skills/harbor-alert-workflow/SKILL.md`。做 3D 模型或性能对比、汇报渲染截图、交付同步前，先加载 `harbor-alert-workflow`。
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
- 性能/面数对比用 `scripts/district_stats.gd`（几何）与 `tests/gpu_probe.gd`（实机 GPU，需要真 GPU 与窗口，窗口纪律见下方「视觉/渲染测试显示规范」），两次比较必须同窗口尺寸、同预热逻辑，口径写在汇报里。

## 视觉/渲染测试显示规范（永久，2026-11-26）

跑 Godot 渲染截图、探针脚本（含 `tests/gpu_probe.gd`）或任何 GPU 测试时的窗口纪律，**长期生效、每轮遵守**：

- **禁止占用用户的真实桌面窗口**：不要把游戏/渲染窗口弹到用户的真实桌面，不要抢焦点、挤占平铺窗口；一律改用内存里的隔离虚拟显示。
- **先检测本机是否支持带 AMD Renoir 硬件加速的无头虚拟显示**：优先 `xvfb-run` 配 `vglrun -d /dev/dri/renderD128`（本机 `renderD128`＝AMD 核显、`renderD129`＝NVIDIA dGPU，以 `/dev/dri/by-path` 为准），或 `weston --backend=headless --use-gl` / `gamescope` 等虚拟 Wayland 显示；开跑前必须验证 `OpenGL renderer` 仍是 AMD Radeon（测核显需 `MESA_LOADER_DRIVER_OVERRIDE=radeonsi`，否则会落到 zink/NVIDIA dGPU）而非 `llvmpipe`，验证不过一律按纯软件环境处理。
- **本机只剩纯 `Xvfb` 时**（2026-11-26 实测即此：`vglrun`/`weston`/`gamescope`/`xvfb-run` 均未装，只有裸 `Xvfb`）：
  - 允许：**少量帧**的截图与布局验证，命令全部挂 `timeout`；
  - 禁止：在掉回 `llvmpipe` 的纯 `Xvfb` 里硬跑长帧率 ABBA 基准（数据无参考价值还烧 CPU）；需要真实核显 FPS 时明确提示用户在真实桌面自行运行（同口径要求照旧），或仅在验证过硬件加速（renderer＝AMD Radeon）的虚拟显示中运行。

  ```sh
  # 没有 xvfb-run 包装，手动起隔离虚拟显示（:97 被占就换 :98/:99，起前看 /tmp/.X*-lock）
  Xvfb :97 -screen 0 1920x1080x24 & XVPID=$!
  XDG_DATA_HOME="$PWD/build/xdg" DISPLAY=:97 timeout 120 godot --path . --quit-after 5
  kill $XVPID   # 用完关掉；实测 llvmpipe + gl_compatibility 下启动+5 帧 ≈ 23 s
  ```

- **纯逻辑与回归测试继续 `--headless`**，不受本规范影响。

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
