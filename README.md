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
- 右键：点资源地形（森林=木材/丘陵=石料/平原=食物）= 采集，其他 = 移动
- Ctrl+1~9 设编队，1~9 选编队
- WASD 平移相机，滚轮缩放
- 工人满载自动运回营地（棕色方块）入库，HUD 右上显示库存
- 调试截图模式：CIVERA_SHOT=1 环境变量（20× 加速，4 秒后存 /tmp/civera_game.png 退出）
