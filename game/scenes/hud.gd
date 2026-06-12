# HUD 层：顶栏资源/人口、底部状态行、建造/训练栏、小地图。
# 只读 main 的游戏状态（sim/map/selected/camera），按钮回调走 main 的方法。
class_name GameHud
extends CanvasLayer

const UNIT_NAMES := ["工人", "民兵", "土匪", "弓手", "骑兵", "长枪兵", "攻城槌", "投石车"]
const STATE_NAMES := ["游荡", "待命", "行军", "采集", "运回", "作战", "溃逃", "驻墙", "修理"]
const TERRAIN_NAMES := ["深水", "浅水", "平原", "草地", "森林", "密林", "丘陵", "高山", "沙漠", "沼泽", "雪原"]
const RES_NAMES := ["木材", "石料", "食物"]
const POP_BASE := 10 # 人口上限：基础 + 每座房屋 +5（同步 DESIGN.md）
const POP_PER_HOUSE := 5

var main: Node2D
var res_label := Label.new()
var info_label := Label.new()
var minimap := Control.new()
var minimap_base: ImageTexture
var minimap_img: Image
var notice_text := "" # 短消息（来袭/资源不足…），带 TTL 否则会被状态行覆盖
var notice_ttl := 0.0
var text_accum := 1.0 # 文本节流（0.2s 一次，首帧立即刷）


func _init(p_main: Node2D) -> void:
	main = p_main
	name = "HUD"


func _ready() -> void:
	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	top.position = Vector2(-300, 8)
	res_label.add_theme_font_size_override("font_size", 24)
	top.add_child(res_label)
	add_child(top)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom.position = Vector2(8, -44)
	info_label.add_theme_font_size_override("font_size", 24)
	bottom.add_child(info_label)
	add_child(bottom)

	# 上下文面板（铁锈战争式：选中什么 → 显示什么功能，见 UI_PLAN.md）
	# CenterContainer 包裹：内容宽度变化时自动水平居中，置于状态行上方
	var wrap := CenterContainer.new()
	wrap.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	wrap.offset_top = -230
	wrap.offset_bottom = -50
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE # 空白处不挡世界点击
	context_box.add_theme_constant_override("separation", 4)
	context_panel.add_child(context_box)
	context_panel.visible = false
	wrap.add_child(context_panel)
	add_child(wrap)

	_build_minimap()


# ---- 选中上下文面板 ----

const ECON_BUILDINGS := [1, 2, 3, 4, 5] # 伐木场/采石场/农田/房屋/仓库
const MIL_BUILDINGS := [6, 7, 8, 9, 10, 11, 12, 13, 14] # 兵营…攻城工坊/墙/门
const FORMATION_SHORT := ["横线", "纵队", "方阵", "锥形", "盾墙", "圆阵", "散兵", "新月"]

var context_panel := PanelContainer.new()
var context_box := VBoxContainer.new()
var bld_hp_label: Label = null # 建筑面板的 HP 行（update 节流刷新）
var context_building := -1


func _ctx_button(text: String, font := 14) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", font)
	return btn


# 选中变化时由 main 调用：按"工人→建造、军队→命令/阵型、建筑→训练/门"重建面板
func refresh_context() -> void:
	for child in context_box.get_children():
		child.queue_free()
	bld_hp_label = null
	context_building = main.selected_building
	if context_building >= 0:
		_fill_building_panel(context_building)
		context_panel.visible = true
		return
	var sel: PackedInt32Array = main.selected
	if sel.size() == 0:
		context_panel.visible = false
		return
	context_panel.visible = true

	var sim: SimWorld = main.sim
	var counts := {}
	for id in sel:
		var t: int = sim.get_unit_type(id)
		counts[t] = counts.get(t, 0) + 1
	var has_worker: bool = counts.has(0)
	var has_military := false
	for t in counts:
		if t != 0:
			has_military = true

	# 类型分组 chips（RW 侧栏）：左键=只选该类型，右键=剔除该类型
	if counts.size() > 1:
		var chips := HBoxContainer.new()
		for t in counts:
			var chip := _ctx_button("%s×%d" % [UNIT_NAMES[t], counts[t]], 13)
			chip.gui_input.connect(_chip_input.bind(t))
			chips.add_child(chip)
		context_box.add_child(chips)

	# 命令行
	var cmd := HBoxContainer.new()
	var stop := _ctx_button("停止(S)")
	stop.pressed.connect(func() -> void: main.sim.command_stop(main.selected))
	cmd.add_child(stop)
	if has_military:
		var hint := Label.new()
		hint.text = " 右键：移动/集火/登墙"
		hint.add_theme_font_size_override("font_size", 13)
		hint.modulate = Color(1, 1, 1, 0.6)
		cmd.add_child(hint)
	elif has_worker:
		var hint := Label.new()
		hint.text = " 右键：移动/采集(树·石)/修理"
		hint.add_theme_font_size_override("font_size", 13)
		hint.modulate = Color(1, 1, 1, 0.6)
		cmd.add_child(hint)
	context_box.add_child(cmd)

	# 军事：阵型一排
	if has_military:
		var frow := HBoxContainer.new()
		for f in 8:
			var fb := _ctx_button("%s(F%d)" % [FORMATION_SHORT[f], f + 1], 13)
			fb.pressed.connect(main._set_formation.bind(f + 1))
			frow.add_child(fb)
		context_box.add_child(frow)

	# 工人：建造菜单（经济 / 军防 两行）
	if has_worker:
		for group in [ECON_BUILDINGS, MIL_BUILDINGS]:
			var row := HBoxContainer.new()
			for t in group:
				var cost: Vector2i = SimWorld.building_cost(t)
				var btn := _ctx_button("%s\n%d木 %d石" % [main.BUILDINGS[t]["name"], cost.x, cost.y])
				btn.pressed.connect(main._enter_place_mode.bind(t))
				row.add_child(btn)
			context_box.add_child(row)


func _chip_input(event: InputEvent, type: int) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		main.filter_selection_type(type, false) # 只选该类型
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		main.filter_selection_type(type, true) # 剔除该类型


func _fill_building_panel(b: int) -> void:
	var sim: SimWorld = main.sim
	var flat: PackedInt32Array = sim.get_buildings()
	var btype := flat[b * 2]

	var title := Label.new()
	title.text = main.BUILDINGS[btype]["name"]
	title.add_theme_font_size_override("font_size", 18)
	context_box.add_child(title)

	bld_hp_label = Label.new()
	bld_hp_label.add_theme_font_size_override("font_size", 14)
	_refresh_building_hp(b, btype)
	context_box.add_child(bld_hp_label)

	var row := HBoxContainer.new()
	for t in main.TRAIN: # 训练按钮只出现在对应军事建筑面板
		if t["building"] == btype:
			var btn := _ctx_button("训练%s\n%d木 %d食" % [t["name"], t["wood"], t["food"]])
			btn.pressed.connect(main._train_unit_at.bind(t, b))
			row.add_child(btn)
	if btype == 11 or btype == 14: # 木门/石门
		var gate := _ctx_button("开 / 关")
		gate.pressed.connect(func() -> void:
			if main.sim.toggle_gate(b):
				main._rebuild_building_visuals())
		row.add_child(gate)
	if row.get_child_count() > 0:
		context_box.add_child(row)
		if btype in [6, 7, 8, 13]: # 出兵建筑：集结点提示
			var hint := Label.new()
			hint.text = "右键地面 = 设集结点"
			hint.add_theme_font_size_override("font_size", 13)
			hint.modulate = Color(1, 1, 1, 0.6)
			context_box.add_child(hint)


func _refresh_building_hp(b: int, btype: int) -> void:
	if bld_hp_label != null:
		bld_hp_label.text = "HP %d / %d" % [
			int(main.sim.get_building_hp(b)), int(SimWorld.building_max_hp(btype)),
		]


func notice(text: String, ttl := 3.0) -> void:
	notice_text = text
	notice_ttl = ttl


func pop_cap() -> int:
	var flat: PackedInt32Array = main.sim.get_buildings()
	var cap := POP_BASE
	for b in range(flat.size() / 2):
		if flat[b * 2] == 4 and main.sim.get_building_hp(b) > 0.0: # 房屋
			cap += POP_PER_HOUSE
	return cap


# 每帧由 main 调用：文本节流刷新 + 小地图重绘
func update(delta: float) -> void:
	notice_ttl -= delta
	text_accum += delta
	if text_accum >= 0.2: # 状态行每秒 5 次足够；小地图同节流（全量重绘成本高）
		text_accum = 0.0
		var sim: SimWorld = main.sim
		res_label.text = "木材 %d  石料 %d  食物 %d  人口 %d/%d" % [
			sim.get_stockpile(0), sim.get_stockpile(1), sim.get_stockpile(2),
			sim.count_alive(0), pop_cap(),
		]
		info_label.text = _status_line()
		minimap.queue_redraw()
		if context_building >= 0: # 建筑面板 HP 跟随刷新
			var flat: PackedInt32Array = main.sim.get_buildings()
			_refresh_building_hp(context_building, flat[context_building * 2])


# 底部状态行：通知 | 选中详情 | 悬停地块 | 全局态势
func _status_line() -> String:
	var sim: SimWorld = main.sim
	var parts := PackedStringArray()
	if notice_ttl > 0.0:
		parts.append(notice_text)
	var selected: PackedInt32Array = main.selected
	if selected.size() == 1 and sim.is_unit_alive(selected[0]):
		var id := selected[0]
		var t: int = sim.get_unit_type(id)
		parts.append("%s HP %d/%d  士气 %d  %s" % [
			UNIT_NAMES[t], int(sim.get_unit_hp(id)), int(SimWorld.unit_max_hp(t)),
			int(sim.get_unit_morale(id)), STATE_NAMES[sim.get_unit_state(id)],
		])
	elif selected.size() > 1:
		var counts := {}
		for id in selected:
			var t: int = sim.get_unit_type(id)
			counts[t] = counts.get(t, 0) + 1
		var bits := PackedStringArray()
		for t in counts:
			bits.append("%s×%d" % [UNIT_NAMES[t], counts[t]])
		parts.append("已选 " + " ".join(bits))
	# 悬停地块（用 main 的世界坐标系，CanvasLayer 内坐标不同）
	var hc := Vector2i(main.get_global_mouse_position() / float(main.TILE))
	if hc.x >= 0 and hc.x < main.MAP_DIM and hc.y >= 0 and hc.y < main.MAP_DIM:
		var tname: String = TERRAIN_NAMES[main.map.get_terrain(hc.x, hc.y)]
		var res: int = GameMap.terrain_resource(main.map.get_terrain(hc.x, hc.y))
		if res >= 0:
			tname += "·%s %d" % [RES_NAMES[res], main.map.get_resource_amount(hc.x, hc.y)]
		parts.append(tname)
	parts.append("兵力 %d  敌 %d  FPS %d" % [
		sim.count_alive(0), sim.count_alive(1), Engine.get_frames_per_second(),
	])
	return "  |  ".join(parts)


func _build_minimap() -> void:
	var dim: int = main.MAP_DIM
	minimap_img = Image.create(dim, dim, false, Image.FORMAT_RGBA8)
	var buf: PackedByteArray = main.map.get_terrain_buffer()
	for cy in dim:
		var row := cy * dim
		for cx in dim:
			minimap_img.set_pixel(cx, cy, main.TERRAIN_COLORS[buf[row + cx]])
	minimap_base = ImageTexture.create_from_image(minimap_img)

	minimap.custom_minimum_size = Vector2(200, 200)
	minimap.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	minimap.position = Vector2(-208, -208)
	minimap.size = Vector2(200, 200)
	minimap.draw.connect(_draw_minimap)
	minimap.gui_input.connect(_minimap_input)
	add_child(minimap)


# 单格刷新（枯竭地块），调用后由 commit_minimap 统一提交
func set_minimap_pixel(cell: Vector2i) -> void:
	minimap_img.set_pixel(cell.x, cell.y, main.TERRAIN_COLORS[main.map.get_terrain(cell.x, cell.y)])


func commit_minimap() -> void:
	minimap_base.update(minimap_img)


# 读档后全量重刷（地形可能与初始生成不同）
func refresh_minimap() -> void:
	var dim: int = main.MAP_DIM
	var buf: PackedByteArray = main.map.get_terrain_buffer()
	for cy in dim:
		var row := cy * dim
		for cx in dim:
			minimap_img.set_pixel(cx, cy, main.TERRAIN_COLORS[buf[row + cx]])
	minimap_base.update(minimap_img)


func _draw_minimap() -> void:
	var sim: SimWorld = main.sim
	var dim: int = main.MAP_DIM
	var mscale: float = 200.0 / float(dim * main.TILE)
	minimap.draw_texture_rect(minimap_base, Rect2(Vector2.ZERO, Vector2(200, 200)), false)
	# 建筑
	var flat: PackedInt32Array = sim.get_buildings()
	for b in range(flat.size() / 2):
		if sim.get_building_hp(b) <= 0.0:
			continue
		var cell := flat[b * 2 + 1]
		var p := Vector2(cell % dim, cell / dim) / float(dim) * 200.0
		minimap.draw_rect(Rect2(p - Vector2(1.5, 1.5), Vector2(3, 3)), Color.ORANGE)
	# 单位
	var all_ids := PackedInt32Array(range(sim.get_unit_count()))
	var pts := sim.get_unit_positions(all_ids)
	for k in all_ids.size():
		if not sim.is_unit_alive(all_ids[k]):
			continue
		var col := Color.RED if sim.get_unit_faction(all_ids[k]) == 1 else Color.WHITE
		minimap.draw_rect(Rect2(pts[k] * mscale - Vector2(1, 1), Vector2(2, 2)), col)
	# 相机视口框
	var camera: Camera2D = main.camera
	var vp_size := minimap.get_viewport_rect().size / camera.zoom.x
	var r := Rect2((camera.position - vp_size * 0.5) * mscale, vp_size * mscale)
	minimap.draw_rect(r, Color(1, 1, 1, 0.8), false, 1.0)


var game_over_panel: CenterContainer


func show_game_over(win: bool, detail: String) -> void:
	if game_over_panel != null:
		game_over_panel.queue_free()
	game_over_panel = CenterContainer.new()
	game_over_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = "🏆 匪营已破——胜利！" if win else "💀 营地陷落——战败"
	title.add_theme_font_size_override("font_size", 42)
	var stats := Label.new()
	stats.text = detail
	stats.add_theme_font_size_override("font_size", 20)
	var hint := Label.new()
	hint.text = "按 R 重新开始"
	hint.add_theme_font_size_override("font_size", 18)
	hint.modulate = Color(1, 1, 1, 0.7)
	vbox.add_child(title)
	vbox.add_child(stats)
	vbox.add_child(hint)
	panel.add_child(vbox)
	game_over_panel.add_child(panel)
	add_child(game_over_panel)


func hide_game_over() -> void:
	if game_over_panel != null:
		game_over_panel.queue_free()
		game_over_panel = null


func _minimap_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	var mm := event as InputEventMouseMotion
	if (mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT) \
			or (mm != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var local := minimap.get_local_mouse_position()
		main.camera.position = local / 200.0 * main.MAP_DIM * main.TILE
