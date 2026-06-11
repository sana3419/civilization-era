# 第一阶段主场景：地图 + 营地 + 工人采集 + RTS 操控 + HUD
extends Node2D

const MAP_DIM := 512
const MAP_SEED := 2026
const TILE := 32
const SIM_HZ := 30.0 # 暂用 30Hz 规避插值；上渲染插值后回 10Hz（PLAN 1.3）
const START_WORKERS := 10

# 与 src/game_map.h 的 Terrain 枚举一一对应
const TERRAIN_COLORS: Array[Color] = [
	Color("19335c"), Color("2e64a8"), Color("c2b280"), Color("7bb35a"),
	Color("3d7a3a"), Color("275427"), Color("8a7d5a"), Color("787878"),
	Color("ddc97a"), Color("4a5e3d"), Color("e8eef0"),
]

var map: GameMap
var sim: SimWorld
var camera := Camera2D.new()
var unit_mm := MultiMesh.new()
var sim_accum := 0.0
var selected := PackedInt32Array()
var groups := {} # 编队号 -> PackedInt32Array
var dragging := false
var drag_anchor := Vector2.ZERO
var camp_pos := Vector2.ZERO
var res_label := Label.new()
var info_label := Label.new()
var shot_timer := 0.0


func _ready() -> void:
	map = GameMap.new()
	map.generate(MAP_DIM, MAP_SEED)
	_build_tilemap()

	sim = SimWorld.new()
	sim.setup(0, MAP_DIM * TILE, 1, 6)
	sim.set_map(map)

	var camp_cell := _find_camp_cell()
	camp_pos = (Vector2(camp_cell) + Vector2(0.5, 0.5)) * TILE
	_build_camp_visual()
	sim.set_dropoff(camp_pos)
	sim.spawn_workers(START_WORKERS, camp_pos + Vector2(0, TILE * 2))
	_sync_unit_mesh()

	camera.position = camp_pos
	camera.zoom = Vector2.ONE
	add_child(camera)
	camera.make_current()

	_build_hud()

	if OS.get_environment("CIVERA_SHOT") != "":
		# 截图模式：全选工人 → 采附近森林，验证完整链路
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
				if t != 2 and t != 3: # 平原/草地
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


func _build_camp_visual() -> void:
	var rect := ColorRect.new()
	rect.color = Color("6b4a2a")
	rect.size = Vector2(TILE * 2, TILE * 2)
	rect.position = camp_pos - rect.size * 0.5
	add_child(rect)


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
		# 工人占位：蓝衣小方块，帧间亮度微变（行走感）
		var c := Color(0.25, 0.45, 0.9).lightened(0.06 * (f % 3))
		img.fill_rect(Rect2i(f * 16 + 3, 3, 10, 10), c)
		img.fill_rect(Rect2i(f * 16 + 5, 1, 6, 4), Color(0.95, 0.8, 0.6)) # 头
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
	if (inst_custom.y > 0.0) { // 载货高亮
		COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.85, 0.2), 0.45);
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	top.position = Vector2(-280, 8)
	res_label.text = "木材 0  石料 0  食物 0"
	res_label.add_theme_font_size_override("font_size", 24)
	top.add_child(res_label)
	layer.add_child(top)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom.position = Vector2(8, -44)
	info_label.add_theme_font_size_override("font_size", 24)
	bottom.add_child(info_label)
	layer.add_child(bottom)


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

	sim.write_render_buffer()
	if unit_mm.instance_count > 0:
		RenderingServer.multimesh_set_buffer(unit_mm.get_rid(), sim.get_render_buffer())

	res_label.text = "木材 %d  石料 %d  食物 %d" % [
		sim.get_stockpile(0), sim.get_stockpile(1), sim.get_stockpile(2),
	]
	info_label.text = "已选工人 %d / %d   FPS %d" % [
		selected.size(), sim.get_unit_count(), Engine.get_frames_per_second(),
	]
	queue_redraw()

	if OS.get_environment("CIVERA_SHOT") != "":
		shot_timer += delta
		if shot_timer > 4.0:
			get_viewport().get_texture().get_image().save_png("/tmp/civera_game.png")
			print("[shot] saved /tmp/civera_game.png | wood=%d" % sim.get_stockpile(0))
			get_tree().quit()


func _draw() -> void:
	# 选中圈
	if selected.size() > 0:
		var pts := sim.get_unit_positions(selected)
		for p in pts:
			draw_arc(p, 11.0, 0, TAU, 24, Color(0.3, 1.0, 0.3, 0.9), 2.0)
	# 框选橡皮筋
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
					dragging = true
					drag_anchor = get_global_mouse_position()
				MOUSE_BUTTON_RIGHT:
					if selected.size() > 0:
						# 点资源地形自动转采集，否则移动（C++ 侧分派）
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
		selected = PackedInt32Array()
	elif key.keycode == KEY_A and key.ctrl_pressed:
		selected = PackedInt32Array(range(sim.get_unit_count()))
