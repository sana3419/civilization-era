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
]

var map: GameMap
var sim: SimWorld
var camera := Camera2D.new()
var unit_mm := MultiMesh.new()
var building_layer := Node2D.new()
var sim_accum := 0.0
var selected := PackedInt32Array()
var groups := {}
var dragging := false
var drag_anchor := Vector2.ZERO
var camp_pos := Vector2.ZERO
var res_label := Label.new()
var info_label := Label.new()
var minimap := Control.new()
var minimap_base: ImageTexture
var place_mode := -1 # 建造放置模式：建筑类型，-1 = 关闭
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
	_sync_unit_mesh()

	camera.position = camp_pos
	camera.zoom = Vector2.ONE
	add_child(camera)
	camera.make_current()

	_build_hud()
	_build_minimap()

	ghost.size = Vector2(TILE * 2, TILE * 2)
	ghost.visible = false
	add_child(ghost)

	if OS.get_environment("CIVERA_SHOT") != "":
		selected = PackedInt32Array(range(sim.get_unit_count()))
		var forest := _find_nearest_terrain(camp_cell, 4)
		if forest.x >= 0:
			sim.command_gather(selected, (Vector2(forest) + Vector2(0.5, 0.5)) * TILE)


func _find_camp_cell() -> Vector2i:
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
				if ok:
					return Vector2i(c + ox, c + oy)
	return Vector2i(c, c)


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

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	var buf := map.get_terrain_buffer()
	for cy in MAP_DIM:
		var row := cy * MAP_DIM
		for cx in MAP_DIM:
			layer.set_cell(Vector2i(cx, cy), 0, Vector2i(buf[row + cx], 0))
	add_child(layer)


func _add_building_visual(type: int, anchor_cell: Vector2i) -> void:
	var rect := ColorRect.new()
	rect.color = BUILDINGS[type]["color"]
	rect.size = Vector2(TILE * 2, TILE * 2)
	rect.position = Vector2(anchor_cell) * TILE
	building_layer.add_child(rect)
	var tag := Label.new()
	tag.text = BUILDINGS[type]["name"]
	tag.add_theme_font_size_override("font_size", 12)
	tag.position = Vector2(2, TILE * 2 - 18)
	rect.add_child(tag)


func _rebuild_building_visuals() -> void:
	for child in building_layer.get_children():
		child.queue_free()
	var flat := sim.get_buildings()
	for b in range(flat.size() / 2):
		var cell := flat[b * 2 + 1]
		_add_building_visual(flat[b * 2], Vector2i(cell % MAP_DIM, cell / MAP_DIM))


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
	var img := Image.create(16 * 6, 16, false, Image.FORMAT_RGBA8)
	for f in 6:
		var c := Color(0.25, 0.45, 0.9).lightened(0.06 * (f % 3))
		img.fill_rect(Rect2i(f * 16 + 3, 3, 10, 10), c)
		img.fill_rect(Rect2i(f * 16 + 5, 1, 6, 4), Color(0.95, 0.8, 0.6))
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
	vec2 uv = vec2((UV.x + frame) / 6.0, UV.y);
	COLOR = texture(TEXTURE, uv);
	if (inst_custom.y > 0.0) {
		COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.85, 0.2), 0.45);
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	top.position = Vector2(-300, 8)
	res_label.add_theme_font_size_override("font_size", 24)
	top.add_child(res_label)
	layer.add_child(top)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom.position = Vector2(8, -44)
	info_label.add_theme_font_size_override("font_size", 24)
	bottom.add_child(info_label)
	layer.add_child(bottom)

	# 建造栏（文明6 式底部按钮）
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.position = Vector2(-260, -52)
	var hbox := HBoxContainer.new()
	for t in range(1, BUILDINGS.size()):
		var cost: Vector2i = SimWorld.building_cost(t)
		var btn := Button.new()
		btn.text = "%s\n%d木 %d石" % [BUILDINGS[t]["name"], cost.x, cost.y]
		btn.add_theme_font_size_override("font_size", 14)
		btn.pressed.connect(_enter_place_mode.bind(t))
		hbox.add_child(btn)
	bar.add_child(hbox)
	layer.add_child(bar)


func _build_minimap() -> void:
	var img := Image.create(MAP_DIM, MAP_DIM, false, Image.FORMAT_RGBA8)
	var buf := map.get_terrain_buffer()
	for cy in MAP_DIM:
		var row := cy * MAP_DIM
		for cx in MAP_DIM:
			img.set_pixel(cx, cy, TERRAIN_COLORS[buf[row + cx]])
	minimap_base = ImageTexture.create_from_image(img)

	minimap.custom_minimum_size = Vector2(200, 200)
	minimap.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	minimap.position = Vector2(-208, -208)
	minimap.size = Vector2(200, 200)
	minimap.draw.connect(_draw_minimap)
	minimap.gui_input.connect(_minimap_input)
	get_node("HUD").add_child(minimap)


func _draw_minimap() -> void:
	var mscale := 200.0 / (MAP_DIM * TILE)
	minimap.draw_texture_rect(minimap_base, Rect2(Vector2.ZERO, Vector2(200, 200)), false)
	# 建筑
	var flat := sim.get_buildings()
	for b in range(flat.size() / 2):
		var cell := flat[b * 2 + 1]
		var p := Vector2(cell % MAP_DIM, cell / MAP_DIM) / MAP_DIM * 200.0
		minimap.draw_rect(Rect2(p - Vector2(1.5, 1.5), Vector2(3, 3)), Color.ORANGE)
	# 单位
	var pts := sim.get_unit_positions(PackedInt32Array(range(sim.get_unit_count())))
	for p in pts:
		minimap.draw_rect(Rect2(p * mscale - Vector2(1, 1), Vector2(2, 2)), Color.WHITE)
	# 相机视口框
	var vp_size := get_viewport_rect().size / camera.zoom.x
	var r := Rect2((camera.position - vp_size * 0.5) * mscale, vp_size * mscale)
	minimap.draw_rect(r, Color(1, 1, 1, 0.8), false, 1.0)


func _minimap_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	var mm := event as InputEventMouseMotion
	if (mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT) \
			or (mm != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var local := minimap.get_local_mouse_position()
		camera.position = local / 200.0 * MAP_DIM * TILE


func _enter_place_mode(type: int) -> void:
	place_mode = type
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

	sim_accum += delta * (20.0 if OS.get_environment("CIVERA_SHOT") != "" else 1.0)
	var step := 1.0 / SIM_HZ
	while sim_accum >= step:
		sim_accum -= step
		sim.tick(step)

	sim.write_render_buffer(sim_accum / step) # 插值系数
	if unit_mm.instance_count > 0:
		RenderingServer.multimesh_set_buffer(unit_mm.get_rid(), sim.get_render_buffer())

	if place_mode >= 0: # 放置幽灵跟随 + 合法性着色
		var cell := Vector2i(get_global_mouse_position() / TILE)
		ghost.position = Vector2(cell) * TILE
		var ok := sim.can_place_building(place_mode, Vector2(cell) * TILE + Vector2(1, 1))
		ghost.color = Color(0.2, 1.0, 0.2, 0.45) if ok else Color(1.0, 0.2, 0.2, 0.45)

	res_label.text = "木材 %d  石料 %d  食物 %d" % [
		sim.get_stockpile(0), sim.get_stockpile(1), sim.get_stockpile(2),
	]
	info_label.text = "已选工人 %d / %d   FPS %d" % [
		selected.size(), sim.get_unit_count(), Engine.get_frames_per_second(),
	]
	queue_redraw()
	minimap.queue_redraw()

	if OS.get_environment("CIVERA_SHOT") != "":
		shot_timer += delta
		# 木材够了就放一座伐木场，验证建造链路
		if sim.get_buildings().size() / 2 < 2 and sim.get_stockpile(0) >= 20:
			var bcell := Vector2i((camp_pos + Vector2(TILE * 3, 0)) / TILE)
			if sim.place_building(1, Vector2(bcell) * TILE + Vector2(1, 1)):
				_add_building_visual(1, bcell)
		if shot_timer > 6.0:
			get_viewport().get_texture().get_image().save_png("/tmp/civera_game.png")
			print("[shot] saved /tmp/civera_game.png | wood=%d buildings=%d" % [
				sim.get_stockpile(0), sim.get_buildings().size() / 2,
			])
			get_tree().quit()


func _draw() -> void:
	if selected.size() > 0:
		var pts := sim.get_unit_positions(selected)
		for p in pts:
			draw_arc(p, 11.0, 0, TAU, 24, Color(0.3, 1.0, 0.3, 0.9), 2.0)
	if dragging:
		var rect := _drag_rect()
		draw_rect(rect, Color(0.4, 1.0, 0.4, 0.12), true)
		draw_rect(rect, Color(0.4, 1.0, 0.4, 0.9), false, 2.0 / camera.zoom.x)


func _drag_rect() -> Rect2:
	var cur := get_global_mouse_position()
	return Rect2(drag_anchor, cur - drag_anchor).abs()


func _unhandled_input(event: InputEvent) -> void:
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
							if not Input.is_key_pressed(KEY_SHIFT): # Shift 连放
								_exit_place_mode()
					else:
						dragging = true
						drag_anchor = get_global_mouse_position()
				MOUSE_BUTTON_RIGHT:
					if place_mode >= 0:
						_exit_place_mode()
					elif selected.size() > 0:
						sim.command_gather(selected, get_global_mouse_position())
		elif event.button_index == MOUSE_BUTTON_LEFT and dragging:
			dragging = false
			var rect := _drag_rect()
			if rect.size.length() < 8.0:
				rect = Rect2(rect.position - Vector2(12, 12), Vector2(24, 24))
			selected = sim.get_units_in_rect(rect.position, rect.end)


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
		selected = PackedInt32Array(range(sim.get_unit_count()))
	elif key.keycode == KEY_F5:
		_save_game()
	elif key.keycode == KEY_F9:
		_load_game()


func _save_game() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	var map_data := map.save_state()
	var sim_data := sim.save_state()
	f.store_32(map_data.size())
	f.store_buffer(map_data)
	f.store_32(sim_data.size())
	f.store_buffer(sim_data)
	info_label.text = "已存档"


func _load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var map_data := f.get_buffer(f.get_32())
	var sim_data := f.get_buffer(f.get_32())
	if not map.load_state(map_data) or not sim.load_state(sim_data):
		info_label.text = "读档失败"
		return
	# sim 持有的 map 引用不变，load_state 已重建占地位图与流场缓存
	selected = PackedInt32Array()
	_sync_unit_mesh()
	_rebuild_building_visuals()
	info_label.text = "已读档"
