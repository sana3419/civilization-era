# 第一阶段主场景：地图 + 建筑 + 工人采集 + RTS 操控 + HUD + 小地图 + 存读档
extends Node2D

const MAP_DIM := 512
const MAP_SEED := 2026
const TILE := 32
const SIM_HZ := 10.0 # 固定步长（PLAN 1.3），渲染插值补偿
const START_WORKERS := 10
const SAVE_PATH := "user://save1.civ"

# 与 src/game_map.h 的 Terrain 枚举一一对应
const TERRAIN_COLORS: Array[Color] = [
	Color("19335c"), Color("2e64a8"), Color("c2b280"), Color("7bb35a"),
	Color("3d7a3a"), Color("275427"), Color("8a7d5a"), Color("787878"),
	Color("ddc97a"), Color("4a5e3d"), Color("e8eef0"),
]

# 与 src/sim_world.h 的 BuildingType 一一对应
const BUILDINGS := [
	{ "name": "营地", "color": Color("6b4a2a") },
	{ "name": "伐木场", "color": Color("8a5a20") },
	{ "name": "采石场", "color": Color("5a5a66") },
	{ "name": "农田", "color": Color("a8a832") },
	{ "name": "房屋", "color": Color("a87850") },
	{ "name": "仓库", "color": Color("7a5a8a") },
	{ "name": "兵营", "color": Color("8a3a3a") },
	{ "name": "射箭场", "color": Color("3a6a5a") },
	{ "name": "马厩", "color": Color("7a5a30") },
	{ "name": "箭塔", "color": Color("4a4a58") },
	{ "name": "栅栏", "color": Color("9a7b4f") },
	{ "name": "城门", "color": Color("c49a5a") },
	{ "name": "攻城工坊", "color": Color("5a4a3a") },
	{ "name": "石墙", "color": Color("8a8a96") },
	{ "name": "石门", "color": Color("aaa9b8") },
]
const WALL_TYPES := [10, 13] # 可拖动划线连放的 1×1 墙体
# 训练表：单位类型 → 所需建筑/成本（与 src/sim_world.h 对应）
const TRAIN := [
	{ "type": 0, "name": "工人", "building": 0, "wood": 0, "food": 20 },
	{ "type": 1, "name": "民兵", "building": 6, "wood": 10, "food": 20 },
	{ "type": 3, "name": "弓手", "building": 7, "wood": 15, "food": 15 },
	{ "type": 4, "name": "骑兵", "building": 8, "wood": 30, "food": 30 },
	{ "type": 5, "name": "长枪兵", "building": 6, "wood": 20, "food": 25 },
	{ "type": 6, "name": "攻城槌", "building": 12, "wood": 60, "stone": 0, "food": 20 },
	{ "type": 7, "name": "投石车", "building": 12, "wood": 80, "stone": 20, "food": 10 },
]
# 单位血量上限由 SimWorld.unit_max_hp(type) 提供（STATS 表单一来源）；
# 文案/人口常量在 hud.gd（GameHud）
const RAID_INTERVAL := 90.0 # 土匪袭扰间隔（模拟秒）
const FORMATION_NAMES := ["无阵型", "横线阵", "纵队", "方阵", "锥形阵", "盾墙", "圆阵", "散兵线", "新月阵"]

var map: GameMap
var sim: SimWorld
var camera := Camera2D.new()
var unit_mm := MultiMesh.new()
var building_layer := Node2D.new()
var sim_accum := 0.0
var selected := PackedInt32Array()
var groups := {}
var panning := false # 左键拖动地图
var pan_dist := 0.0
var left_anchor := Vector2.ZERO # 左键按下时世界坐标（短击 = 点选）
var box_selecting := false # 右键拖动框选
var drag_anchor := Vector2.ZERO
var overlay := Node2D.new() # 覆盖层：橡皮筋/血条/选中圈/特效（置于地图之上）
var deco_layer: TileMapLayer
var camp_pos := Vector2.ZERO
var hud: GameHud
var place_mode := -1 # 建造放置模式：建筑类型，-1 = 关闭
var bandit_pos := Vector2.ZERO
var attack_fx := [] # [{from, to, ttl}]
var raid_timer := 150.0 # 首波缓 60s：实测最快民兵 ~150s，90s 接敌是无解窗口
var raid_count := 0
var paused := false
var game_over := "" # ""=进行中 / "win" / "lose"
var sim_time := 0.0
var bandits_spawned := 0
var terrain_layer: TileMapLayer # 枯竭地块刷新用
var raid_units := {} # 袭扰单位 id → 连续空闲检查次数（收尾 AI 用）
var raid_ai_timer := 0.0
var ghost := ColorRect.new()
var shot_timer := 0.0


func _ready() -> void:
	map = GameMap.new()
	map.generate(MAP_DIM, MAP_SEED)
	_build_tilemap()
	add_child(building_layer)

	sim = SimWorld.new()
	sim.setup(0, MAP_DIM * TILE, 1, 6)
	sim.set_map(map)

	var camp_cell := _find_camp_cell()
	camp_pos = Vector2(camp_cell) * TILE + Vector2(TILE, TILE)
	sim.place_building(0, camp_pos) # 营地（免费初始建筑）
	_add_building_visual(0, camp_cell)
	sim.spawn_workers(START_WORKERS, camp_pos + Vector2(0, TILE * 2.5))
	sim.spawn_units(1, 2, camp_pos + Vector2(TILE * 2, TILE * 2.5), 0) # 开局 2 民兵：首波前不至于零反制
	_spawn_bandit_camp(camp_cell)
	_sync_unit_mesh()

	camera.position = camp_pos
	camera.zoom = Vector2.ONE
	add_child(camera)
	camera.make_current()

	hud = GameHud.new(self)
	add_child(hud)

	ghost.size = Vector2(TILE * 2, TILE * 2)
	ghost.visible = false
	add_child(ghost)

	# 覆盖层最后加入 → 渲染在地图/建筑/单位之上（父节点 _draw 会被子节点盖住）
	overlay.z_index = 50
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)

	if OS.get_environment("CIVERA_SHOT") != "":
		selected = PackedInt32Array(range(START_WORKERS))
		var forest := _find_nearest_terrain(camp_cell, 4)
		if forest.x >= 0:
			sim.command_gather(selected, (Vector2(forest) + Vector2(0.5, 0.5)) * TILE)
		# 战斗验证：土匪营旁放 6 民兵，自动交战；相机对准战场
		sim.spawn_units(1, 6, bandit_pos + Vector2(-140, 0), 0)
		_sync_unit_mesh()
		camera.position = bandit_pos
		camera.zoom = Vector2(2, 2)


func _find_camp_cell() -> Vector2i:
	# 严格档要求 20 格内有森林、60 格内有丘陵：开局经济节奏不随 seed 漂移
	#（实测有 seed 最近丘陵 126 格 = 单程 68 秒，90 秒采石量为 0）；找不到再放宽
	var loose := Vector2i(-1, -1)
	var c := MAP_DIM / 2
	for r in range(0, MAP_DIM / 2):
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if maxi(absi(ox), absi(oy)) != r:
					continue
				var t := map.get_terrain(c + ox, c + oy)
				if t != 2 and t != 3:
					continue
				var ok := true
				for ny in range(-2, 3):
					for nx in range(-2, 3):
						if not map.is_passable(c + ox + nx, c + oy + ny):
							ok = false
				if not ok:
					continue
				var cell := Vector2i(c + ox, c + oy)
				if loose.x < 0:
					loose = cell # 放宽档兜底（旧行为）
				if _has_terrain_within(cell, [4, 5], 20) and _has_terrain_within(cell, [6], 60):
					return cell
	return loose if loose.x >= 0 else Vector2i(c, c)


func _has_terrain_within(from: Vector2i, terrain_ids: Array, radius: int) -> bool:
	for r in range(1, radius + 1):
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if maxi(absi(ox), absi(oy)) != r:
					continue
				if map.get_terrain(from.x + ox, from.y + oy) in terrain_ids:
					return true
	return false


func _spawn_bandit_camp(camp_cell: Vector2i) -> void:
	# 营地 40~80 格外找开阔地驻扎土匪（第一章目标：击退土匪）
	for r in range(40, 80, 4):
		for ang in 8:
			var dir := Vector2.from_angle(ang * TAU / 8.0)
			var c := camp_cell + Vector2i((dir * r).round())
			var ok := true
			for oy in range(-2, 3):
				for ox in range(-2, 3):
					if not map.is_passable(c.x + ox, c.y + oy):
						ok = false
			if ok:
				bandit_pos = Vector2(c) * TILE + Vector2(16, 16)
				# 12 守卫 = 匪营的"血量"：清空守卫并兵临其址即胜利（给循环一个出口）
				sim.spawn_units(2, 12, bandit_pos, 1)
				bandits_spawned += 12
				return


func _find_nearest_terrain(from: Vector2i, terrain_id: int) -> Vector2i:
	for r in range(1, 128):
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if maxi(absi(ox), absi(oy)) != r:
					continue
				if map.get_terrain(from.x + ox, from.y + oy) == terrain_id:
					return Vector2i(from.x + ox, from.y + oy)
	return Vector2i(-1, -1)


func _build_tilemap() -> void:
	var img := Image.create(TILE * TERRAIN_COLORS.size(), TILE, false, Image.FORMAT_RGBA8)
	for t in TERRAIN_COLORS.size():
		img.fill_rect(Rect2i(t * TILE, 0, TILE, TILE), TERRAIN_COLORS[t])
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(TILE, TILE)
	for t in TERRAIN_COLORS.size():
		src.create_tile(Vector2i(t, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_source(src, 0)

	terrain_layer = TileMapLayer.new()
	terrain_layer.tile_set = ts
	_build_deco_layer()
	var buf := map.get_terrain_buffer()
	for cy in MAP_DIM:
		var row := cy * MAP_DIM
		for cx in MAP_DIM:
			terrain_layer.set_cell(Vector2i(cx, cy), 0, Vector2i(buf[row + cx], 0))
			_set_deco_cell(Vector2i(cx, cy), buf[row + cx])
	add_child(terrain_layer)
	add_child(deco_layer) # 装饰层在地形之上、建筑/单位之下


# 地形 → 装饰图集行（树/草丛/岩石等程序化像素占位）
const DECO_ROW := { 3: 0, 4: 1, 5: 2, 6: 3, 8: 4, 9: 5 } # 草地/森林/密林/丘陵/沙漠/沼泽


func _set_deco_cell(tc: Vector2i, terrain: int) -> void:
	var row: int = DECO_ROW.get(terrain, -1)
	# 确定性视觉散布：草地 1/3 概率长草丛，其余地形全铺
	var h := absi((tc.x * 73856093) ^ (tc.y * 19349663))
	if row < 0 or (terrain == 3 and h % 3 != 0):
		deco_layer.erase_cell(tc)
		return
	deco_layer.set_cell(tc, 0, Vector2i(h % 4 * 2, row)) # 偶数列为动画基帧


# 装饰图集：4 变体 × 2 动画帧（横向相邻），6 行地形。
# TileSet 原生帧动画：树冠摆动/草丛弯腰/水洼闪烁，GPU 播放零运行时开销。
func _build_deco_layer() -> void:
	var img := Image.create(TILE * 8, TILE * 6, false, Image.FORMAT_RGBA8)
	for v in 4:
		for f in 2: # f=1 为摆动帧
			var bx := (v * 2 + f) * TILE
			var dx := (v * 7) % 12
			var dy := (v * 5) % 10
			# 行0 草丛
			_px_tuft(img, bx + 8 + dx, 14 + dy, f)
			if v % 2 == 0:
				_px_tuft(img, bx + 20, 22, f)
			# 行1 森林：1-2 棵树
			_px_tree(img, bx + 4 + dx % 8, TILE + 4, Color("2c5a28"), Color("1d3f1b"), f)
			if v >= 2:
				_px_tree(img, bx + 17, TILE + 12, Color("36692f"), Color("234a20"), 1 - f)
			# 行2 密林：2-3 棵更深的树（相位交错，风感更自然）
			_px_tree(img, bx + 2, 2 * TILE + 2, Color("1d3f1b"), Color("122a11"), f)
			_px_tree(img, bx + 15, 2 * TILE + 8 + dy % 6, Color("234a20"), Color("122a11"), 1 - f)
			if v % 2 == 1:
				_px_tree(img, bx + 8, 2 * TILE + 14, Color("1d3f1b"), Color("122a11"), f)
			# 行3 丘陵：岩石（不动画）
			_px_rock(img, bx + 6 + dx, 3 * TILE + 16 + dy % 6)
			_px_rock(img, bx + 18, 3 * TILE + 8)
			# 行4 沙漠：变体0 仙人掌（微摆），其余沙纹（飘移 1px）
			if v == 0:
				_px_cactus(img, bx + 13, 4 * TILE + 6, f)
			else:
				for k in 2:
					img.fill_rect(Rect2i(bx + 4 + k * 12 + f, 4 * TILE + 12 + k * 8 + dy % 4, 9, 1), Color("c9b15f"))
			# 行5 沼泽：芦苇（弯腰）+ 水洼（闪烁）
			for k in 3:
				img.fill_rect(Rect2i(bx + 6 + k * 7 + (f if k % 2 == 0 else 0), 5 * TILE + 10 + (k + v) % 5, 1, 7), Color("2f4a26"))
			img.fill_rect(Rect2i(bx + 10 + dx % 8, 5 * TILE + 22, 7, 3),
					Color("3a5a78") if f == 0 else Color("46688a"))

	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(TILE, TILE)
	for v in 4:
		for r in 6:
			var at := Vector2i(v * 2, r)
			src.create_tile(at)
			if r == 3:
				continue # 岩石不动画
			src.set_tile_animation_frames_count(at, 2)
			# 各变体周期错开，避免全图同步摆动
			var dur := 0.55 + 0.1 * v
			src.set_tile_animation_frame_duration(at, 0, dur)
			src.set_tile_animation_frame_duration(at, 1, dur * 0.85)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_source(src, 0)
	deco_layer = TileMapLayer.new()
	deco_layer.tile_set = ts


func _px_tree(img: Image, x: int, y: int, canopy: Color, dark: Color, sway: int) -> void:
	img.fill_rect(Rect2i(x + 5, y + 12, 3, 5), Color("5a4026")) # 树干（不动）
	img.fill_rect(Rect2i(x + 1, y + 7, 11, 5), canopy) # 下层树冠
	img.fill_rect(Rect2i(x + 3 + sway, y + 3, 7, 5), canopy) # 中上层随风偏移
	img.fill_rect(Rect2i(x + 5 + sway, y, 3, 4), dark)
	img.fill_rect(Rect2i(x + 1, y + 11, 11, 1), dark)


func _px_tuft(img: Image, x: int, y: int, sway: int) -> void:
	for k in 4:
		var bend := sway if k % 2 == 0 else 0 # 一半草叶弯腰
		img.fill_rect(Rect2i(x + k * 2 + bend, y - (k % 2) * 2, 1, 4 + (k % 2) * 2), Color("4d7a35"))


func _px_rock(img: Image, x: int, y: int) -> void:
	img.fill_rect(Rect2i(x + 1, y, 6, 4), Color("8f8f8f"))
	img.fill_rect(Rect2i(x, y + 2, 8, 3), Color("6e6e6e"))


func _px_cactus(img: Image, x: int, y: int, sway: int) -> void:
	img.fill_rect(Rect2i(x, y + 6, 3, 16), Color("3a7a3a"))
	img.fill_rect(Rect2i(x - 5, y + 10, 5, 2), Color("3a7a3a"))
	img.fill_rect(Rect2i(x - 5, y + 6 - sway, 2, 6 + sway), Color("3a7a3a"))
	img.fill_rect(Rect2i(x + 3, y + 13, 4, 2), Color("3a7a3a"))
	img.fill_rect(Rect2i(x + 6, y + 8 - sway, 2, 7 + sway), Color("3a7a3a"))


func _add_building_visual(type: int, anchor_cell: Vector2i, open := true) -> void:
	var bsize: int = SimWorld.building_size(type)
	var is_gate := type == 11 or type == 14
	var rect := ColorRect.new()
	rect.color = BUILDINGS[type]["color"]
	if is_gate and not open: # 关闭的城门加深
		rect.color = rect.color.darkened(0.45)
	rect.size = Vector2(TILE, TILE) * bsize
	rect.position = Vector2(anchor_cell) * TILE
	building_layer.add_child(rect)
	if type in WALL_TYPES: # 墙段不挂名牌（太密）
		return
	var tag := Label.new()
	tag.text = BUILDINGS[type]["name"] if not is_gate else ("门·开" if open else "门·关")
	tag.add_theme_font_size_override("font_size", 12 if bsize == 2 else 8)
	tag.position = Vector2(2, TILE * bsize - (18 if bsize == 2 else 12))
	rect.add_child(tag)


func _rebuild_building_visuals() -> void:
	for child in building_layer.get_children():
		child.queue_free()
	var flat := sim.get_buildings()
	for b in range(flat.size() / 2):
		if sim.get_building_hp(b) <= 0.0: # 废墟不画
			continue
		var cell := flat[b * 2 + 1]
		_add_building_visual(flat[b * 2], Vector2i(cell % MAP_DIM, cell / MAP_DIM),
				sim.get_building_state(b) == 1)


func _sync_unit_mesh() -> void:
	if unit_mm.mesh == null:
		var quad := QuadMesh.new()
		quad.size = Vector2(16, 16)
		unit_mm.transform_format = MultiMesh.TRANSFORM_2D
		unit_mm.use_custom_data = true
		unit_mm.mesh = quad
		var mmi := MultiMeshInstance2D.new()
		mmi.multimesh = unit_mm
		mmi.texture = _make_unit_atlas()
		mmi.material = _make_unit_material()
		add_child(mmi)
	unit_mm.instance_count = sim.get_unit_count()


func _make_unit_atlas() -> ImageTexture:
	# 8 行 × 6 帧：工人（蓝）/ 民兵（银甲红缨）/ 土匪（暗红）/ 弓手（绿帽）/ 骑兵（棕鬃）/
	# 长枪兵（铁灰金缨）/ 攻城槌（原木）/ 投石车（深木）
	var body := [
		Color(0.25, 0.45, 0.9), Color(0.7, 0.7, 0.78),
		Color(0.55, 0.15, 0.15), Color(0.5, 0.65, 0.35),
		Color(0.6, 0.42, 0.2), Color(0.45, 0.5, 0.58),
		Color(0.62, 0.48, 0.28), Color(0.4, 0.3, 0.18),
	]
	var head := [
		Color(0.95, 0.8, 0.6), Color(0.85, 0.2, 0.2),
		Color(0.3, 0.25, 0.2), Color(0.2, 0.5, 0.25),
		Color(0.35, 0.22, 0.1), Color(0.85, 0.7, 0.2),
		Color(0.35, 0.35, 0.38), Color(0.55, 0.55, 0.6),
	]
	var img := Image.create(16 * 6, 16 * 8, false, Image.FORMAT_RGBA8)
	for row in 8:
		for f in 6:
			var c: Color = body[row].lightened(0.06 * (f % 3))
			img.fill_rect(Rect2i(f * 16 + 3, row * 16 + 3, 10, 10), c)
			img.fill_rect(Rect2i(f * 16 + 5, row * 16 + 1, 6, 4), head[row])
	return ImageTexture.create_from_image(img)


func _make_unit_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

varying flat vec4 inst_custom;

void vertex() {
	inst_custom = INSTANCE_CUSTOM;
}

void fragment() {
	float frame = floor(inst_custom.x);
	float row = floor(inst_custom.z); // 单位类型 → 图集行
	vec2 uv = vec2((UV.x + frame) / 6.0, (UV.y + row) / 8.0);
	COLOR = texture(TEXTURE, uv);
	if (inst_custom.y > 0.0) {
		COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.85, 0.2), 0.45);
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


# 胜利 = 匪营无活匪驻守（300px 内无 faction1）且玩家兵临其址（160px 内有己方单位）。
# 按物理占领判定而非守卫 id 清单：尸体槽位复用后 id 不可靠
func _check_victory() -> void:
	if game_over != "" or bandit_pos == Vector2.ZERO:
		return
	var ids := PackedInt32Array(range(sim.get_unit_count()))
	var pts := sim.get_unit_positions(ids)
	var occupier := false
	for id in ids:
		if not sim.is_unit_alive(id):
			continue
		if sim.get_unit_faction(id) == 1:
			if pts[id].distance_to(bandit_pos) < 300.0:
				return # 匪营还有驻守/援军
		elif pts[id].distance_to(bandit_pos) < 160.0:
			occupier = true
	if occupier:
		_game_over(true)


func _game_over(win: bool) -> void:
	if game_over != "":
		return
	game_over = "win" if win else "lose"
	var detail := "用时 %d:%02d   击退波次 %d   歼敌 %d   存活兵力 %d" % [
		int(sim_time) / 60, int(sim_time) % 60, raid_count,
		bandits_spawned - sim.count_alive(1), sim.count_alive(0),
	]
	hud.show_game_over(win, detail)


# 袭扰收尾：打完仗发呆的土匪撤回匪营并消失（防止长局堆积站桩单位）；
# 同节拍顺带做胜利判定
func _tick_raid_ai(step: float) -> void:
	raid_ai_timer -= step
	if raid_ai_timer > 0.0:
		return
	raid_ai_timer = 2.0
	_check_victory()
	for id in raid_units.keys():
		# 槽位可能被复用成别的单位：阵营不对就放弃跟踪
		if not sim.is_unit_alive(id) or sim.get_unit_faction(id) != 1:
			raid_units.erase(id)
			continue
		if sim.get_unit_state(id) != 1: # 非待命（作战/行军/溃逃中）
			raid_units[id] = 0
			continue
		raid_units[id] += 1
		var pos: Vector2 = sim.get_unit_positions(PackedInt32Array([id]))[0]
		if pos.distance_to(bandit_pos) < 64.0:
			if raid_units[id] >= 2: # 在家发呆：消失
				sim.despawn_unit(id)
				raid_units.erase(id)
		elif raid_units[id] >= 2: # 在外发呆：撤回匪营
			sim.command_move(PackedInt32Array([id]), bandit_pos)
			raid_units[id] = 0


func _train_unit(t: Dictionary) -> void:
	if sim.count_alive(0) >= hud.pop_cap():
		hud.notice("人口已满，先造房屋（+%d/座）" % GameHud.POP_PER_HOUSE)
		return
	var flat := sim.get_buildings()
	for b in range(flat.size() / 2):
		if flat[b * 2] == t["building"] and sim.get_building_hp(b) > 0.0:
			if sim.try_spend(t["wood"], t.get("stone", 0), t["food"]):
				var cell := flat[b * 2 + 1]
				var pos := Vector2(cell % MAP_DIM, cell / MAP_DIM) * TILE + Vector2(TILE, TILE * 3)
				sim.spawn_units(t["type"], 1, pos, 0)
				_sync_unit_mesh()
				hud.notice("%s +1（出自%s）" % [t["name"], BUILDINGS[t["building"]]["name"]], 2.0)
			else:
				hud.notice("资源不足")
			return
	hud.notice("需要先建%s" % BUILDINGS[t["building"]]["name"])


# 读档后全量重刷地形贴图/装饰/小地图（枯竭草地与初始生成不同）
func _refresh_terrain_visuals() -> void:
	var buf := map.get_terrain_buffer()
	for cy in MAP_DIM:
		var row := cy * MAP_DIM
		for cx in MAP_DIM:
			terrain_layer.set_cell(Vector2i(cx, cy), 0, Vector2i(buf[row + cx], 0))
			_set_deco_cell(Vector2i(cx, cy), buf[row + cx])
	hud.refresh_minimap()


func _enter_place_mode(type: int) -> void:
	place_mode = type
	ghost.size = Vector2(TILE, TILE) * SimWorld.building_size(type)
	ghost.visible = true


func _exit_place_mode() -> void:
	place_mode = -1
	ghost.visible = false


func _process(delta: float) -> void:
	var pan := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var raw := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)),
	)
	if raw.length_squared() > 0.0:
		pan = raw
	camera.position += pan * delta * 900.0 / camera.zoom.x

	if paused or game_over != "":
		sim_accum = 0.0
		overlay.queue_redraw()
		return
	sim_accum += delta * (20.0 if OS.get_environment("CIVERA_SHOT") != "" else 1.0)
	var step := 1.0 / SIM_HZ
	while sim_accum >= step:
		sim_accum -= step
		sim.tick(step)
		sim_time += step
		# 土匪袭扰：定期从匪营出兵压向玩家营地
		raid_timer -= step
		if raid_timer <= 0.0 and bandit_pos != Vector2.ZERO:
			raid_timer = RAID_INTERVAL
			raid_count += 1
			# 波次随时间升级：防御建设永远落后半步才有张力（上限 8 防失控）
			var n := mini(3 + raid_count / 2, 8)
			var first: int = sim.spawn_units(2, n, bandit_pos, 1)
			var wave := PackedInt32Array(range(first, first + n))
			var tag := ""
			if raid_count % 3 == 0: # 每第三波带攻城槌（破门）
				wave.append(sim.spawn_units(6, 1, bandit_pos + Vector2(0, 48), 1))
				tag = "——带着攻城槌！"
			if raid_count % 5 == 0: # 每第五波带投石车（拆墙 + 溅射）
				wave.append(sim.spawn_units(7, 1, bandit_pos + Vector2(48, 48), 1))
				tag = "——带着攻城器械！"
			sim.command_move(wave, camp_pos)
			for id in wave:
				raid_units[id] = 0 # 收尾 AI 跟踪
			bandits_spawned += wave.size()
			_sync_unit_mesh()
			hud.notice("⚔ 土匪来袭（×%d）%s" % [wave.size(), tag], 5.0)
		_tick_raid_ai(step)

	sim.write_render_buffer(sim_accum / step) # 插值系数
	if unit_mm.instance_count > 0:
		RenderingServer.multimesh_set_buffer(unit_mm.get_rid(), sim.get_render_buffer())

	# 攻击特效：取本帧事件画箭线/挥击线，0.25 秒淡出；负值为建筑 -(index+1)
	var events := sim.take_attack_events()
	var flat_b := sim.get_buildings()
	for e in range(0, events.size(), 2):
		var from_pos := _event_pos(events[e], flat_b)
		var to_pos := _event_pos(events[e + 1], flat_b)
		attack_fx.append({ "from": from_pos, "to": to_pos, "ttl": 0.25 })
	if attack_fx.size() > 300: # 大型混战限流，防覆盖层绘制拖帧
		attack_fx = attack_fx.slice(attack_fx.size() - 300)
	var bev := sim.take_building_events()
	if bev.size() > 0: # 有建筑被摧毁，重画
		_rebuild_building_visuals()
		if 0 in bev: # 初始营地（building 0）被拆 = 战败
			_game_over(false)
	var tev := map.take_terrain_events() # 枯竭森林→草地：刷贴图/装饰/小地图
	if tev.size() > 0:
		for cell in tev:
			var tc := Vector2i(cell % MAP_DIM, cell / MAP_DIM)
			var t := map.get_terrain(tc.x, tc.y)
			terrain_layer.set_cell(tc, 0, Vector2i(t, 0))
			_set_deco_cell(tc, t) # 树砍光 → 树木消失
			hud.set_minimap_pixel(tc)
		hud.commit_minimap()
	for fx in attack_fx:
		fx["ttl"] -= delta
	attack_fx = attack_fx.filter(func(fx): return fx["ttl"] > 0.0)

	if place_mode >= 0: # 放置幽灵跟随 + 合法性着色
		var cell := Vector2i(get_global_mouse_position() / TILE)
		ghost.position = Vector2(cell) * TILE
		var ok := sim.can_place_building(place_mode, Vector2(cell) * TILE + Vector2(1, 1))
		ghost.color = Color(0.2, 1.0, 0.2, 0.45) if ok else Color(1.0, 0.2, 0.2, 0.45)

	# 槽位复用后旧 id 可能变成别的单位：清掉死亡/非己方的选中项
	if selected.size() > 0:
		var keep := PackedInt32Array()
		for id in selected:
			if sim.is_unit_alive(id) and sim.get_unit_faction(id) == 0:
				keep.append(id)
		selected = keep
	hud.update(delta)
	overlay.queue_redraw()

	if OS.get_environment("CIVERA_SHOT") != "":
		shot_timer += delta
		# 木材够了就放一座伐木场，验证建造链路
		if sim.get_buildings().size() / 2 < 2 and sim.get_stockpile(0) >= 20:
			var bcell := Vector2i((camp_pos + Vector2(TILE * 3, 0)) / TILE)
			if sim.place_building(1, Vector2(bcell) * TILE + Vector2(1, 1)):
				_add_building_visual(1, bcell)
		if shot_timer > 6.0:
			get_viewport().get_texture().get_image().save_png("/tmp/civera_game.png")
			print("[shot] saved /tmp/civera_game.png | wood=%d buildings=%d militia=%d bandits=%d" % [
				sim.get_stockpile(0), sim.get_buildings().size() / 2,
				sim.count_alive(0), sim.count_alive(1),
			])
			get_tree().quit()


# 攻击事件端点 → 世界坐标（id >= 0 单位，否则建筑 -(index+1) 取占地中心）
func _event_pos(id: int, flat_b: PackedInt32Array) -> Vector2:
	if id >= 0:
		return sim.get_unit_positions(PackedInt32Array([id]))[0]
	var bi := -id - 1
	var bcell := flat_b[bi * 2 + 1]
	var half := SimWorld.building_size(flat_b[bi * 2]) * TILE * 0.5
	return Vector2(bcell % MAP_DIM, bcell / MAP_DIM) * TILE + Vector2(half, half)


# 覆盖层绘制（独立子节点，渲染在地图/建筑/单位之上）
func _draw_overlay() -> void:
	for fx in attack_fx:
		var a: float = fx["ttl"] / 0.25
		overlay.draw_line(fx["from"], fx["to"], Color(1.0, 0.9, 0.4, a), 1.5)
	# 受损单位无条件画血条（乱战可读性：不选中也得知道该撤谁）
	var all_ids := PackedInt32Array(range(sim.get_unit_count()))
	var all_pts := sim.get_unit_positions(all_ids)
	for id in all_ids:
		if not sim.is_unit_alive(id):
			continue
		var ratio: float = sim.get_unit_hp(id) / SimWorld.unit_max_hp(sim.get_unit_type(id))
		if ratio >= 1.0:
			continue
		var p := all_pts[id]
		overlay.draw_rect(Rect2(p + Vector2(-9, -15), Vector2(18, 3)), Color(0, 0, 0, 0.7))
		overlay.draw_rect(Rect2(p + Vector2(-9, -15), Vector2(18 * ratio, 3)),
				Color(1.0 - ratio, ratio, 0.1))
	# 受损建筑血条（土匪啃门时玩家必须看得见门在掉血）
	var flat_b := sim.get_buildings()
	for b in range(flat_b.size() / 2):
		var bhp: float = sim.get_building_hp(b)
		var bmax: float = SimWorld.building_max_hp(flat_b[b * 2])
		if bhp <= 0.0 or bhp >= bmax:
			continue
		var cell := flat_b[b * 2 + 1]
		var bw: float = SimWorld.building_size(flat_b[b * 2]) * TILE
		var bp := Vector2(cell % MAP_DIM, cell / MAP_DIM) * TILE
		overlay.draw_rect(Rect2(bp + Vector2(0, -6), Vector2(bw, 4)), Color(0, 0, 0, 0.7))
		overlay.draw_rect(Rect2(bp + Vector2(0, -6), Vector2(bw * bhp / bmax, 4)),
				Color(1.0 - bhp / bmax, bhp / bmax, 0.1))
	if selected.size() > 0:
		var pts := sim.get_unit_positions(selected)
		for k in selected.size():
			var id := selected[k]
			if not sim.is_unit_alive(id):
				continue
			overlay.draw_arc(pts[k], 11.0, 0, TAU, 24, Color(0.3, 1.0, 0.3, 0.9), 2.0)
	if box_selecting:
		var rect := _drag_rect()
		overlay.draw_rect(rect, Color(0.4, 1.0, 0.4, 0.12), true)
		overlay.draw_rect(rect, Color(0.4, 1.0, 0.4, 0.9), false, 2.0 / camera.zoom.x)


func _select_all(workers: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	for id in sim.get_unit_count():
		if sim.is_unit_alive(id) and sim.get_unit_faction(id) == 0 \
				and (sim.get_unit_type(id) == 0) == workers:
			out.append(id)
	return out


func _drag_rect() -> Rect2:
	var cur := get_global_mouse_position()
	return Rect2(drag_anchor, cur - drag_anchor).abs()


# 操控方案：左键拖动 = 平移地图，左键短击 = 点选/开关门；
# 右键拖动 = 框选，右键短击 = 命令（集火/登墙/修理/采集/移动）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if place_mode in WALL_TYPES and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			# 墙体拖动连放（按住左键划线）
			var cell := Vector2i(get_global_mouse_position() / TILE)
			if sim.place_building(place_mode, Vector2(cell) * TILE + Vector2(1, 1)):
				_add_building_visual(place_mode, cell)
			return
		if panning:
			camera.position -= event.relative / camera.zoom.x
			pan_dist += event.relative.length()
		return
	if event is InputEventMouseButton:
		if event.pressed:
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					camera.zoom = (camera.zoom * 1.15).clamp(Vector2(0.03, 0.03), Vector2(4, 4))
				MOUSE_BUTTON_WHEEL_DOWN:
					camera.zoom = (camera.zoom / 1.15).clamp(Vector2(0.03, 0.03), Vector2(4, 4))
				MOUSE_BUTTON_LEFT:
					if place_mode >= 0:
						var cell := Vector2i(get_global_mouse_position() / TILE)
						if sim.place_building(place_mode, Vector2(cell) * TILE + Vector2(1, 1)):
							_add_building_visual(place_mode, cell)
							# Shift 连放；墙体默认连放（拖动划线），右键/Esc 退出
							if not Input.is_key_pressed(KEY_SHIFT) and place_mode not in WALL_TYPES:
								_exit_place_mode()
					else:
						panning = true
						pan_dist = 0.0
						left_anchor = get_global_mouse_position()
				MOUSE_BUTTON_RIGHT:
					if place_mode >= 0:
						_exit_place_mode()
					else:
						box_selecting = true
						drag_anchor = get_global_mouse_position()
		else:
			match event.button_index:
				MOUSE_BUTTON_LEFT:
					if panning:
						panning = false
						if pan_dist < 8.0: # 短击 = 点选 / 开关门
							var rect := Rect2(left_anchor - Vector2(12, 12), Vector2(24, 24))
							selected = sim.get_units_in_rect(rect.position, rect.end)
							if selected.size() == 0 and sim.toggle_gate_at(left_anchor):
								_rebuild_building_visuals()
				MOUSE_BUTTON_RIGHT:
					if box_selecting:
						box_selecting = false
						var rect := _drag_rect()
						if rect.size.length() >= 8.0: # 拖动 = 框选
							selected = sim.get_units_in_rect(rect.position, rect.end)
						elif selected.size() > 0: # 短击 = 命令
							var pos := get_global_mouse_position()
							var enemy: int = sim.get_unit_at(pos, 20.0, 1)
							if enemy >= 0: # 点敌人 = 集火
								sim.command_attack(selected, enemy)
							elif sim.command_garrison(selected, pos):
								pass # 点己方石墙 = 派一人登墙驻守（士兵）
							elif sim.command_repair(selected, pos):
								pass # 点受损建筑 = 工人修理
							else:
								sim.command_gather(selected, pos)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.keycode >= KEY_1 and key.keycode <= KEY_9:
		var n := key.keycode - KEY_0
		if key.ctrl_pressed:
			groups[n] = selected.duplicate()
		else:
			selected = groups.get(n, PackedInt32Array())
	elif key.keycode == KEY_ESCAPE:
		if place_mode >= 0:
			_exit_place_mode()
		else:
			selected = PackedInt32Array()
	elif key.keycode == KEY_A and key.ctrl_pressed:
		selected = _select_all(false) # 全选军队（混编工人会让右键命令歧义）
	elif key.keycode == KEY_W and key.ctrl_pressed:
		selected = _select_all(true) # 全选工人
	elif key.keycode == KEY_SPACE:
		if game_over == "":
			paused = not paused
			hud.notice("⏸ 已暂停（Space 继续）" if paused else "▶ 继续", 600.0 if paused else 1.5)
	elif key.keycode == KEY_R and game_over != "":
		get_tree().reload_current_scene()
	elif key.keycode >= KEY_F1 and key.keycode <= KEY_F8 and selected.size() > 0:
		var f := key.keycode - KEY_F1 + 1 # F1=横线 … F8=新月
		sim.command_set_formation(selected, f)
		# 以当前质心重整队形
		var pts := sim.get_unit_positions(selected)
		var c := Vector2.ZERO
		for p in pts:
			c += p
		sim.command_move(selected, c / pts.size())
		hud.notice("阵型：" + FORMATION_NAMES[f])
	elif key.keycode == KEY_S and key.ctrl_pressed:
		_save_game()
	elif key.keycode == KEY_F9:
		_load_game()


const SAVE_MAGIC := 0x43495633 # "CIV3"：游戏层头（袭扰状态+战局统计），魔数不符 = 旧格式拒载


func _save_game() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_32(SAVE_MAGIC)
	f.store_float(raid_timer) # 游戏层状态：袭扰节奏与升级进度
	f.store_32(raid_count)
	f.store_float(sim_time) # 战局统计（结算面板用）
	f.store_32(bandits_spawned)
	var map_data := map.save_state()
	var sim_data := sim.save_state()
	f.store_32(map_data.size())
	f.store_buffer(map_data)
	f.store_32(sim_data.size())
	f.store_buffer(sim_data)
	hud.notice("已存档")


func _load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f.get_32() != SAVE_MAGIC:
		hud.notice("读档失败（存档版本过旧）")
		return
	var saved_raid_timer := f.get_float()
	var saved_raid_count := f.get_32()
	var saved_sim_time := f.get_float()
	var saved_spawned := f.get_32()
	var map_data := f.get_buffer(f.get_32())
	var sim_data := f.get_buffer(f.get_32())
	if not map.load_state(map_data) or not sim.load_state(sim_data):
		hud.notice("读档失败")
		return
	raid_timer = saved_raid_timer
	raid_count = saved_raid_count
	sim_time = saved_sim_time
	bandits_spawned = saved_spawned
	game_over = ""
	paused = false
	hud.hide_game_over()
	# 跟踪表不入档：野外的土匪（非匪营守卫）重新纳入收尾 AI
	raid_units.clear()
	for id in sim.get_unit_count():
		if sim.is_unit_alive(id) and sim.get_unit_faction(id) == 1:
			var pos: Vector2 = sim.get_unit_positions(PackedInt32Array([id]))[0]
			if pos.distance_to(bandit_pos) > 96.0:
				raid_units[id] = 0
	_refresh_terrain_visuals() # 地形可能与初始生成不同（枯竭草地）
	# sim 持有的 map 引用不变，load_state 已重建占地位图与流场缓存
	selected = PackedInt32Array()
	_sync_unit_mesh()
	_rebuild_building_visuals()
	hud.notice("已读档")
