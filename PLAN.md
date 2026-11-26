# 巨人破坏城市 · Godot + Rust PC 原型

## 首版目标

在当前 `gba` 目录独立创建一个 3D 单机游戏，先在 Linux 跑通。玩家从主菜单选择人类或巨人，两种玩法共用一张原创城市街区，采用键鼠和第三人称视角。

## 玩法与关卡

- **人类撤离。** 玩家独自穿过街区，躲避 AI 巨人，抵达有明显标识的撤离点即获胜。人类有 3 点生命，耗尽即失败。撤离无倒计时。人类在移动时可以按住 Shift 疾跑并消耗体力，界面实时显示体力条。体力耗尽后自动恢复普通移动，松开 Shift 后恢复体力。
- **巨人沙盒。** 玩家在街区自由移动，按空格向前踩踏。踩踏前显示短暂的落点预警，范围内的建筑和挡路障碍第一次命中受损，第二次命中被破坏。界面显示已摧毁建筑数。没有倒计时或拆楼配额，拆完后仍可探索。
- **共用街区。** 使用指定的 Breakwater District 模块组装约 100 × 100 米的四街块，布置 12 栋建筑和连通的街道。巨人可以走遍街区，遇到挡路的楼体、围挡等障碍可以踩踏开路。破坏时移除楼体原有阻挡，播放约 3.5 秒的倒塌动画，用少量碎屑、扬尘和镜头震动表现冲击。动画结束后保留同等比例的废墟并启用可步行的斜面碰撞。
- **桌面操作。** WASD 移动，鼠标转镜头。Esc 打开暂停菜单，可继续、重开当前模式或返回主菜单。人类结算后也可重开或换阵营。

## 实现

- 使用本机 Godot 4.7.2、Rust 1.94 和 `godot` crate 0.5.5，通过 GDExtension 加载 Linux 原生库。Rust 负责输入、角色控制、人类体力、巨人 AI、踩踏判定、可破坏物状态和本局流程。Godot 场景负责地图、碰撞、镜头、界面和效果。 [godot-rust 0.5.5](https://github.com/godot-rust/gdext/releases/tag/v0.5.5) · [Rust 工具链要求](https://godot-rust.github.io/book/migrate/v0.5.html)
- 玩家和 AI 巨人共用踩踏逻辑。首轮使用约半秒预警和 5 米落点半径，命中时判定范围内的人类和可破坏物，同一次踩踏对同一目标只计一次。AI 沿可通行道路追击，遇到挡路障碍时用踩踏开路，再根据破坏后的通路继续追击。
- 两种模式使用同一套场景和建筑资源。开始或重开时重新实例化街区，复位建筑、障碍、角色、体力、计数、踩踏冷却和界面。README 记录构建、启动和操作方式。首版交付可在 Linux 本地运行的工程，桌面发行包留到后续。

巨人使用 Kawaii GLB，人类使用 Kenney GLB。资产来源、构建和验证入口见 [README.md](README.md)。

## 验收

- Rust 测试覆盖可破坏物两次命中后移除阻挡、单次踩踏去重、疾跑耗体力与耗尽回退、松开 Shift 后恢复、撤离成功、生命耗尽和本局复位。
- 用 Godot 无界面导入与启动检查扩展加载，再在 Linux 图形会话分别试玩。验证人类疾跑期间体力条下降，松开 Shift 后体力恢复，并能通过跑位躲避、受伤和撤离。验证玩家和 AI 巨人都能拆除挡路障碍并通过废墟，玩家拆完后仍可自由移动。
- 两种模式都验证暂停、连续重开和返回主菜单。暂停时体力冻结，重开后楼体和障碍碰撞、生命、体力、拆楼计数和界面恢复初始状态。

## 《港区警报》Android 移植计划

首个目标是可在 ARM64 真机安装的横屏调试 APK，覆盖当前的「人类撤离」「巨人沙盒」「巨人成长」。前三步已实现并导出调试 APK。构建、验收步骤和日志命令见 [README 的 Android 调试 APK](README.md#android-调试-apk)。第四步等待真机验收与性能数据。

1. **交叉编译和导出。** [构建脚本](scripts/build_android.sh) 沿用同级 [`gtb` 的本机工具链](../gtb/README.md#android-调试-apk)，以 `aarch64-linux-android24-clang` 链接 `aarch64-linux-android`。[扩展配置](native/harbor.gdextension) 登记 `libharbor_android.so`，[导出预设](export_presets.cfg) 使用独立包名 `org.gba.harboralert`。签名调试 APK 已核对为仅 ARM64，最低 API 24，目标 API 36。
2. **移动渲染和资源。** [project.godot](project.godot) 设为移动端 Compatibility 并开启 ETC2/ASTC 导入。APK 已核对包含扩展、道路、角色、纹理和废墟碰撞资源。依赖核对后排除了未引用的 `assets/district/buildings/`。手机安装后用 `adb logcat` 确认扩展能加载并进入主菜单与三个模式。
3. **多点触控和系统生命周期。** [触控界面](scenes/touch_controls.gd) 按手指 ID 跟踪摇杆、环视和动作，经 [回合逻辑](rust/src/round.rs) 共用移动、镜头与踩踏。成长模式在人类阶段不能踩踏，长成巨人后恢复。Android 返回优先关闭设置，其次进入局内暂停。触控取消和场景切换会清理相应的输入，退到后台后回前台由玩家主动继续。已接入横屏安全区、中文字体和软键盘布局，设置沿用 `user://gameplay.cfg`。合成触控测试已通过，系统手势、软键盘与杀进程读取设置交由真机确认。
4. **按真机数据优化并验收。** Android 基线关闭 4× MSAA，默认视距为 200 米，阴影距离为 95 米。港区有 1,718 栋建筑，菜单和开局会同步实例化街区，[分块裁剪](scenes/district.gd) 主要控制可见性。在中低端真机测冷启动、连续重开、内存峰值和多巨人连续拆楼的帧时间，再根据瓶颈决定是否简化菜单预览或分批生成地图。试玩三个模式的移动、环视与动作并发，暂停和重开，以及成长模式厘米视角、第一和第三人称、复活和大型巨人的镜头裁切。

若准备上架 Google Play，另做 Gradle 签名 AAB，确认发布时的目标 API 政策和原生库的 16 KB 页兼容，并在公开分发前核实 Kawaii 模型的再发行许可。 [Godot AAB 导出](https://docs.godotengine.org/en/4.7/tutorials/export/android_gradle_build.html) · [Play 目标 API](https://developer.android.com/google/play/requirements/target-sdk) · [16 KB 页要求](https://developer.android.com/guide/practices/page-sizes)
