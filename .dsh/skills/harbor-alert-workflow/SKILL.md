---
name: harbor-alert-workflow
description: >-
  harbor-alert（gba 工程）专属工作流硬性规范，共 5 条：同口径数据对比、无 GPU 沙盒下只用 --headless 以免
  llvmpipe 软渲染卡死超时、汇报截图前先逐张客观描述再下结论、测试通过后同步纯源码包到 Google 云盘、
  视觉/渲染测试一律在隔离虚拟显示中跑（禁止占用用户真实桌面窗口）。
  在本工程里改代码、跑测试、对比模型/场景/性能数据、汇报渲染截图或交付同步时使用。
---

# harbor-alert 工作流硬性规范

本工程 = Godot 4.7 前端 + Rust GDExtension（`rust/` 编译给 `native/harbor.gdextension`）。
下面 5 条是**硬性**规则，与根目录 `AGENTS.md` 并行生效；与 `AGENTS.md` 既有约定冲突时以 `AGENTS.md` 为准，并先向用户确认再行动。

---

## 1. 同口径数据对比

对比 3D 模型、场景或性能指标时，**必须严格同口径**；口径不同则一律先换算或换算不了就明确写"不可比"。

必须对齐的维度：

| 维度 | 正确做法 | 常见错法（禁止） |
|---|---|---|
| 面数 | 三角面对三角面（tris） | Blender 四边面数 直接对着引擎 tris 数说"少了 60%" |
| 顶点数 | 声明口径：是否含 UV/法线接缝拆分 | 引擎拆分后顶点数（常翻倍）与 DCC 原始顶点数直接比 |
| 材质 / Draw Call | 分别报：材质槽数、Draw Call 数、是否含阴影与后处理 pass | 拿"材质数量"当"Draw Call 数量"下结论 |
| 性能 | 固定分辨率、渲染后端（forward+ / mobile / compatibility）、是否限帧/vsync、是否 headless | 拿 `--headless` 的帧时间当实机 GPU 帧时间 |
| 内存 | 峰值 vs 常驻分开写；进程 RSS 与显存分开写 | 混用"内存占用"一个数字 |

硬性做法：

- 每个数字都要标**口径 + 数据源**（Godot 调试器 Monitor、`tests/perf_probe.gd`、`glxinfo`、`cargo bench`、Blender 统计面板等）。
- 对比结果用表格给：`指标 | 口径 | 数据源 | 基准值 | 当前值`。
- 拿不到的指标写"未测"，**禁止估算或按经验填数**。
- 只有一个口径的样本时，不要得出"更快/更省"的结论，只能报绝对值。

---

## 2. 避免 llvmpipe 软渲染超时

**先判定，再决定能不能开窗口。** 判定命令：

```sh
glxinfo -B 2>/dev/null | grep -i "OpenGL renderer"   # 或 glxinfo | grep "OpenGL renderer string"
```

- 输出含 `llvmpipe`、`softpipe`、`swrast` → **软渲染环境**（沙盒/无 GPU 权限）。
- 软渲染下**只允许 `--headless`**：逻辑测试、回归脚本、资源导入、启动校验。
  - 禁止软渲染下硬跑带窗口的全城 3D 渲染（会卡死或超时、FPS 无参考价值）；唯一例外是第 5 条允许的纯 Xvfb 少量帧截图与布局验证（必须挂 `timeout`）。
- 软渲染下可以跑的（本工程常用）：

  ```sh
  XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --fixed-fps 60 --script res://tests/growth_playtest.gd
  XDG_DATA_HOME="$PWD/build/xdg" godot --headless --path . --quit-after 5     # 启动校验
  godot --headless --path . --import                                          # 新检出先导入
  ```

- 需要"全城截图"时：窗口一律按第 5 条开在隔离虚拟显示里自己截少量帧验布局；要看实机 GPU 效果/FPS 则提示用户本机按 F5 运行并截图（说明要看哪个场景/视角/部位），或明确写出"视觉未验证"。
- 长命令加 `timeout`（如 `timeout 180 ...`），避免无 GPU 时无限等待。

---

## 3. 截图先看再结论

每次汇报渲染截图或视觉改动结果前，**必须先逐张客观描述图中实际看到的部位状态**，再给结论。

每张截图按以下要点逐条写（没看到的就写"未见"）：

1. 材质：亮度、色偏、粗糙度/金属度观感是否合理；
2. 几何：是否穿模、悬空、埋入地面、法线发黑；
3. 阴影与 AO：有无漏光、阴影方向是否与光源一致、有无阴影痤疮；
4. 视角与遮挡：相机是否能看清目标部位、有无树/建筑/UI 挡住；
5. 性能相关可见项：锯齿、闪烁、LOD 跳变。

然后才给结论：**通过** / **待修**，待修要写清具体部位（节点名、场景路径、坐标）。

禁止：

- 只说"看起来没问题""渲染正常"这类空话；
- 没看图就按代码逻辑脑补画面；
- 本轮只跑了 headless、没有截图时，仍暗示画面已验证——必须明确写"视觉未验证（仅 headless 逻辑通过）"。

---

## 4. 测试通过后同步纯源码包

触发条件（三者都要满足）：

1. 一轮功能改动完成；
2. `cargo build --locked --manifest-path rust/Cargo.toml --target-dir rust/target` 与 `cargo test --locked --manifest-path rust/Cargo.toml --target-dir rust/target` 通过；
3. 对应的 Godot 回归测试通过（`tests/*playtest.gd` 中与改动相关的那几个）。

满足后**询问一次**是否同步；用户已明示"以后直接同步"则直接执行：

```sh
./scripts/sync_drive.sh
# 校验
ls -lh /tmp/gba_code_latest.tar.gz
rclone lsl gdrive:gba-sync/gba_code_latest.tar.gz
```

脚本行为：打包到 `/tmp/gba_code_latest.tar.gz` → `rclone copyto` 到 `gdrive:gba-sync/gba_code_latest.tar.gz`。
包内容为**纯源码**：`project.godot`、`export_presets.cfg`、`default_bus_layout.tres`、`README.md`、`PLAN.md`、`MEMORY.md`、`CHANGELOG.md`、`AGENTS.md`、`native/harbor.gdextension`、`rust/Cargo.toml`、`rust/Cargo.lock`、`rust/src`、`scenes`、`tests`、`scripts`、`prototypes`。

硬性边界：

- **不含** `assets/`（大文件）、`.godot/`、`rust/target/`、APK、`backups/`；不要为了"全量"把二进制塞进纯源码包。
- 任何随包文件都不得写入密钥、token、`.credentials`、云盘凭据。
- `rclone` 失败 / 无网络时：贴出报错并说明"未同步"，**不要假装已同步**。

---

## 5. 视觉/渲染测试用隔离虚拟显示（禁止占用用户真实桌面）

跑 Godot 渲染截图、探针脚本（含 `tests/gpu_probe.gd`）或 GPU 测试时，**禁止把窗口弹到用户的真实桌面**——不抢焦点、不挤占平铺窗口。改用内存虚拟显示，按顺序降级：

1. **先检测硬件加速虚拟显示可用性**（每轮开窗口前实测，不要按经验假设）：

   ```sh
   for c in xvfb-run Xvfb vglrun weston gamescope; do command -v "$c" || echo "$c MISSING"; done
   ls -l /dev/dri/by-path/ | grep render      # 确认哪个 renderD* 是 AMD：本机 renderD128＝AMD 核显、renderD129＝NVIDIA dGPU
   DISPLAY= WAYLAND_DISPLAY= timeout 30 eglinfo -B   # surfaceless 直接看 renderer，不碰真实桌面
   ```

   - 优先 `xvfb-run` 配 `vglrun -d /dev/dri/renderD128`，或 `weston --backend=headless --use-gl` / `gamescope` 等虚拟 Wayland 显示。
   - 开跑前**必须**在虚拟显示里验证 `OpenGL renderer` / Godot 日志 `Using Device:` 是 AMD Radeon 而非 `llvmpipe`（测核显需 `MESA_LOADER_DRIVER_OVERRIDE=radeonsi`，否则可能落到 zink/NVIDIA dGPU）；验证不过＝没有硬件加速，按下一档处理。

2. **本机只有纯 `Xvfb`**（如 `xvfb-run -a -s "-screen 0 1920x1080x24"`；本机更原始，连包装脚本都没有，需手动 `Xvfb :97`）：
   - 允许：**少量帧**的截图与布局验证，全部命令挂 `timeout`（2026-11-26 实测：llvmpipe + gl_compatibility 启动 + `--quit-after 5` 约 23 s）。
   - 禁止：在掉回 `llvmpipe` 的纯 `Xvfb` 里硬跑长帧率 ABBA 基准——FPS 无参考价值、还长时间烧 CPU。
   - 需要真实核显 FPS 时：明确提示用户在真实桌面自行运行（口径按第 1 条：同窗口尺寸、同预热、交叠 AB），或仅在验证过 renderer＝AMD Radeon 的虚拟显示中运行。

3. **纯逻辑与回归测试继续 `--headless`**：显示隔离由本条管，软渲染超时风险仍由第 2 条管，两条并行不冲突。

---

## 交付前自查

- [ ] 数字都带口径与数据源，对比表同口径；
- [ ] 本轮没把任何渲染/游戏窗口弹到用户真实桌面；开过的窗口都在隔离虚拟显示里，renderer 已验证并在汇报写明（AMD Radeon / llvmpipe）；
- [ ] 软渲染环境没跑长帧率基准；FPS 数据要么来自验证过硬件加速的虚拟显示、要么明确请用户本机运行或标"未测"；
- [ ] 有截图就先逐张客观描述，再给通过/待修结论；只跑了 headless 时明确写"视觉未验证（仅 headless 逻辑通过）"；
- [ ] 代码改动已过 `cargo test` + 相关 playtest，并已询问或执行 `./scripts/sync_drive.sh`。
