# CLAUDE.md — 《文明纪元》开发须知

2D 像素大型 RTS（Godot 4.6 + C++ GDExtension 模拟核心）。
规划与第零阶段压测结果：`PLAN.md`；构建/操作：`README.md`。

## 环境差异（重要）

- **主开发机**：Jetson Orin Nano（ARM64 Linux），Godot 编辑器在 `/usr/local/bin/godot`，
  llvm-mingw 在 `/opt/llvm-mingw`，无显示器时用 `Xorg :0` 起无头 X 跑渲染测试。
- **云端会话（手机/网页 Claude Code）**：x86_64 容器，没有上述环境。可以做的：
  改 C++/GDScript、装 x86 Godot 跑 headless bench（见下）。不能做的：渲染性能测试、截图验证。
- CI（GitHub Actions）会对每次 push 做三平台编译 + x86 headless bench，
  云端没装环境时可以依赖 CI 验证。

## 构建与测试（x86 云端）

```sh
# 依赖
apt-get install -y scons ccache && pip install scons 2>/dev/null || true
curl -sL -o godot.zip https://github.com/godotengine/godot-builds/releases/download/4.6-stable/Godot_v4.6-stable_linux.x86_64.zip
unzip godot.zip && install Godot_v4.6-stable_linux.x86_64 /usr/local/bin/godot

# 编译（仓库根目录；godot-cpp 是 submodule，记得 --recursive 克隆）
PATH=/usr/lib/ccache:$PATH scons platform=linux arch=x86_64 target=template_debug -j$(nproc)

# 测试（改完必跑；失败 exit 1）
godot --headless --path game --import   # 首次必须，注册 GDExtension
godot --headless --path game -s bench/bench_sim.gd
```

## 铁律：确定性（违反会破坏跨架构 golden，CI 直接红）

模拟核心（`src/`）已验证 ARM/x86 逐位一致，靠的是：

1. **禁用三角函数/libm 超越函数**（sin/cos/exp/pow…）。只允许 `+ - * / sqrt floor abs`
   （IEEE 精确）。需要旋转用归一化方向向量做基（见 `command_move` 的做法）。
2. `-ffp-contract=off` 已在 SConstruct 设置，不要移除。
3. **并行规则**：worker 线程只允许"读共享旧状态 + 写本单位自己的槽位"
   （见 `move_range`/`separate_range`）。任何跨单位写（伤害、士气、入库、索敌）
   必须放在 `logic_pass`（串行，按单位序号顺序）。
4. 索敌/士气扫描用**上一 tick 末位置的空间网格**（`build_grid` 在 tick 开头跑，
   从当前位置构建——这样读档后能逐位重建，存读档续跑不分歧）。
5. 模拟内不用 `Math.random`/时间源；RNG 是每单位 xorshift（`rng_state`）。

## Golden 回归工作流

- `game/bench/golden_hash.txt` 是固定种子模拟的状态哈希基线（已入库）。
- **无意改变模拟行为** → bench 的 golden FAIL → 你引入了回归，修代码。
- **有意改变模拟逻辑** → 删掉 `golden_hash.txt`，跑一次 bench 重新初始化，
  连同代码一起提交（提交信息说明逻辑变更），CI 会在 x86 上复核新基线。

## 其他约定

- **存档版本**：改动任何序列化数组（SoA 字段/建筑字段）必须升 `SAVE_VERSION`
  （`sim_world.cpp`）并同步 save_state/load_state 两处，hash 视情况加新字段。
- **数值表**：单位血量上限/建筑造价/占地已由 C++ 绑定单源提供
  （`SimWorld.unit_max_hp/building_cost/building_size`）；仍为双份的是
  `main.gd` 的 BUILDINGS（名字/颜色）与 TRAIN（训练成本/所属建筑），
  改 C++ 枚举或加兵种建筑时要同步。
- 枚举（UnitType/BuildingType/Terrain/Formation）在 C++ 与 GDScript 间按数值对应，
  改枚举两边都要动。
- godot-cpp pinned `godot-4.5-stable`，绑定用根目录 `extension_api_4.6.json`
  （从 4.6 dump，已剥 `"meta":"required"`）。不要升级 submodule 或重新 dump，
  除非整体换引擎版本。
- 注释/提交信息用中文；代码风格跟随现有文件（4 空格、godot-cpp 命名习惯）。
- 美术决策：开发期全部旋转单图/程序化占位，序列帧补帧推迟到项目完成后。

## 当前进度与路线（2026-06-11）

已完成：第零阶段全部压测（10k 精灵 283FPS@Jetson）、第一阶段全部
（地图/采集/建筑/RTS 操控/UI/存读档/小地图）、**第二阶段全部**
（民兵/弓手/骑兵/长枪兵、克制表、士气溃败、8 阵型、冲锋动量、箭塔、土匪袭扰、
木栅栏/木门：1×1 占地 + 阵营流场 + 土匪攻城破门 AI、
攻城槌/投石车 + 攻城工坊 + 石墙/石门 + 墙上驻军：右键石墙登墙，
防御×5 / 射程+2 格，攻城伤害修正全表化，袭扰每第三波带攻城槌）。

切片胜负闭环已就绪（匪营 12 守卫=目标、营地陷落=战败、波次递增、结算/重开、
暂停、建筑与交战单位血条、Ctrl+A/W 分类全选）；经多 agent 审查修复了
确定性 P0（读档网格重建/枯竭流场失效）与"工人球"士气漏洞等（提交历史详述）。

RTS 操控补完：Shift 命令队列（PLAN 第一阶段声称但当时未实现）、训练队列
（4s/个+进度条）、集结点（建筑选中+右键）、S 停止——均为游戏层（main.gd），
队列/集结点不入存档。

下一步：**发真人试玩**（v0.2.0-slice Release 已出包；不好玩 → 砍系统重排）。
攻城侧明确推迟：攻方登墙（攻城梯/塔）、火攻/火炮、护城河。

真地形碰撞已实现（move/separate 按中心点判格 + 轴向滑动，开门放行己方；
worker 线程只读 occupied/b_state，符合铁律 3）。
追击/修理寻路：>1 格走流场、不可达放弃；尸体槽位按"最小连续块"复用
（调用方依赖 spawn_units 返回 first+连续区间，复用规则纯派生自 alive[]，
读档后一致）。枯竭森林退化草地（take_resource 内，发 terrain_events）。
工人可修理受损建筑（右键，12HP/s）；废墟原地重建即可（占地已释放）。
HUD/小地图在 `game/scenes/hud.gd`（GameHud），main.gd 只留世界与输入。
完整设计数值（兵种/地形/政策/外交等全部表格）见 **`DESIGN.md`**——
实现新系统前先查它；代码数值与其冲突时以代码 + bench 为准并回写 DESIGN.md。
