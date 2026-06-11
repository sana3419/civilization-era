# 第一阶段主场景（当前：地图可视化 + 相机 + 点击寻路验证）
extends Node2D

const MAP_DIM := 512
const MAP_SEED := 2026
const TILE := 32

# 与 src/game_map.h 的 Terrain 枚举一一对应
const TERRAIN_COLORS: Array[Color] = [
	Color("19335c"), # 深海
	Color("2e64a8"), # 浅水
	Color("c2b280"), # 平原
	Color("7bb35a"), # 草地
	Color("3d7a3a"), # 森林
	Color("275427"), # 密林
	Color("8a7d5a"), # 丘陵
	Color("787878"), # 山地
	Color("ddc97a"), # 沙漠
	Color("4a5e3d"), # 沼泽
	Color("e8eef0"), # 雪地
]

var map: GameMap
var pathfinder: Pathfinder
var camera := Camera2D.new()
var path_line := Line2D.new()
var last_click := Vector2i(-1, -1)
var shot_timer := 0.0


func _ready() -> void:
	map = GameMap.new()
	map.generate(MAP_DIM, MAP_SEED)
	pathfinder = Pathfinder.new()
	pathfinder.set_map(map)

	_build_tilemap()

	camera.position = Vector2(MAP_DIM, MAP_DIM) * TILE * 0.5
	camera.zoom = Vector2(0.08, 0.08)
	add_child(camera)
	camera.make_current()

	path_line.width = 24.0
	path_line.default_color = Color(1.0, 0.2, 0.2, 0.9)
	add_child(path_line)


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


func _process(delta: float) -> void:
	var pan := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	# WASD（未配置 InputMap 时退回方向键）
	var raw := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)),
	)
	if raw.length_squared() > 0.0:
		pan = raw
	camera.position += pan * delta * 900.0 / camera.zoom.x

	if OS.get_environment("CIVERA_SHOT") != "":
		shot_timer += delta
		if shot_timer > 1.5:
			var img := get_viewport().get_texture().get_image()
			img.save_png("/tmp/civera_map.png")
			print("[shot] saved /tmp/civera_map.png")
			get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				camera.zoom = (camera.zoom * 1.15).clamp(Vector2(0.03, 0.03), Vector2(4, 4))
			MOUSE_BUTTON_WHEEL_DOWN:
				camera.zoom = (camera.zoom / 1.15).clamp(Vector2(0.03, 0.03), Vector2(4, 4))
			MOUSE_BUTTON_LEFT:
				_click_path(get_global_mouse_position())


func _click_path(world_pos: Vector2) -> void:
	var cell := Vector2i(world_pos / TILE)
	if last_click.x >= 0:
		var path := pathfinder.find_path(last_click, cell, 200000)
		path_line.clear_points()
		for p in path:
			path_line.add_point(Vector2(p) * TILE + Vector2(TILE, TILE) * 0.5)
		print("path %s -> %s: %d cells" % [last_click, cell, path.size()])
	last_click = cell
