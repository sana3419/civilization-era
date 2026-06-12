# 文明纪元 (Civilization Era)

2D 像素大型 RTS 模拟游戏。规划见 [PLAN.md](PLAN.md)。

## 技术栈

- Godot 4.6（锁定版本）+ C++ GDExtension 模拟核心
- godot-cpp pinned `godot-4.5-stable` + 仓库根的 `extension_api_4.6.json`
  （从 4.6 二进制 dump，已剥离 4.5 生成器不识别的 `"meta": "required"` 字段）

## 目录

```
game/        Godot 项目（GDScript / 场景 / 资产）
src/         C++ 模拟核心（GDExtension）
godot-cpp/   submodule，pinned godot-4.5-stable
```

## 构建

```sh
# 开发机原生（Jetson, linux arm64）
PATH=/usr/lib/ccache:$PATH scons platform=linux arch=arm64 target=template_debug -j6

# Windows 交叉编译（llvm-mingw 在 /opt/llvm-mingw）
PATH=/opt/llvm-mingw/bin:$PATH scons platform=windows arch=x86_64 use_mingw=yes target=template_debug -j6
```

## 第零阶段压测

```sh
# headless（模拟/边界/确定性，CI 也跑这个）
godot --headless --path game -s bench/bench_sim.gd

# 渲染压测（需要显示环境）：10000 个 6 帧动画精灵 + 每帧 buffer 整块上传
godot --path game
```

达标线（PLAN.md 第零阶段）：10000 单位 tick + 渲染在 Jetson 上稳 30+ FPS；
不达标降级路径：单位 10000→3000，地图 512→256。（已全部通过，见 PLAN.md 结果表）

## 当前可玩切片操作（godot --path game）

- 左键拖动框选工人，左键点选，Esc 取消，Ctrl+A 全选
- 右键：点资源地形（森林=木材/丘陵=石料/平原=食物）= 采集，其他 = 移动（方阵阵型到达）
- Ctrl+1~9 设编队，1~9 选编队
- WASD 平移相机，滚轮缩放；小地图点击/拖动跳转
- 底部建造栏：选建筑 → 幽灵预览（绿可放/红不可）→ 左键放置（Shift 连放），右键/Esc 取消
- 栅栏/石墙按住左键拖动划线连放；空地左键点己方城门/石门 = 开/关（开门只放行己方，土匪会攻门）
- 选中士兵右键点己方石墙 = 派一人登墙（防御×5、射程+2格）；攻城工坊出攻城槌/投石车，土匪每第三波带槌
- 人口上限 = 10 + 每座房屋 +5，满了先盖房；营地可训练工人；状态行显示选中详情与悬停地块资源余量
- 工人右键受损建筑 = 修理（12HP/s）；砍光的森林会退化成草地；打完仗的土匪会撤回匪营消失
- 工人满载自动运回**最近有效存储点**（营地/仓库收全部；伐木场=木材、采石场=石料、农田=食物）
- F1~F8 切换阵型（横线/纵队/方阵/锥形/盾墙/圆阵/散兵/新月），影响攻防与移速
- 右键点敌方单位 = 集火攻击；军事单位自动索敌，士气崩溃会溃逃（士气兵力比只数战斗单位）
- Space 暂停；Ctrl+A 全选军队 / Ctrl+W 全选工人
- 胜负：清空匪营守卫并兵临其址 = 胜利；初始营地被拆 = 战败；结算后按 R 重开
- 袭扰首波 150s，之后每 90s 一波且规模递增（3+波数/2，上限 8），第三波带槌、第五波带投石车
- Ctrl+S 存档 / F9 读档（user://save1.civ）
- 模拟 10Hz 固定步长 + 渲染插值；人形单位不随速度旋转，仅左右镜像
- 调试截图模式：CIVERA_SHOT=1 环境变量（20× 加速，6 秒后存 /tmp/civera_game.png 退出）
