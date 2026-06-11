# 第零阶段渲染压测：10000 个 6 帧动画精灵，MultiMesh + 每帧 buffer 整块上传。
# 需要显示环境运行：godot --path game
extends Node2D

const N := 10000
const WORLD := 16384.0
const FRAMES := 6

var world: SimWorld
var mm := MultiMesh.new()
var label := Label.new()
var tick_ms := 0.0
var upload_ms := 0.0
var hud_timer := 0.0
var run_time := 0.0
var fps_samples: Array[float] = []


func _ready() -> void:
	world = SimWorld.new()
	world.setup(N, WORLD, 12345, 6)

	var quad := QuadMesh.new()
	quad.size = Vector2(16, 16)
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = N

	var mmi := MultiMeshInstance2D.new()
	mmi.multimesh = mm
	mmi.texture = _make_atlas()
	mmi.material = _make_material()
	add_child(mmi)

	var cam := Camera2D.new()
	cam.position = Vector2(WORLD * 0.5, WORLD * 0.5)
	cam.zoom = Vector2(0.25, 0.25)
	add_child(cam)
	cam.make_current()

	var layer := CanvasLayer.new()
	label.position = Vector2(8, 8)
	layer.add_child(label)
	add_child(layer)


func _process(delta: float) -> void:
	# 压测取每帧 tick（比生产的 10Hz 更苛刻）
	var t0 := Time.get_ticks_usec()
	world.tick(delta)
	tick_ms = (Time.get_ticks_usec() - t0) / 1000.0

	t0 = Time.get_ticks_usec()
	world.write_render_buffer()
	RenderingServer.multimesh_set_buffer(mm.get_rid(), world.get_render_buffer())
	upload_ms = (Time.get_ticks_usec() - t0) / 1000.0

	run_time += delta
	hud_timer += delta
	if hud_timer >= 1.0:
		hud_timer = 0.0
		var fps := Engine.get_frames_per_second()
		if run_time > 3.0: # 跳过预热
			fps_samples.append(fps)
		var line := "units: %d | FPS: %d | tick: %.2f ms | buffer+upload: %.2f ms" % [
			N, fps, tick_ms, upload_ms,
		]
		label.text = line.replace(" | ", "\n")
		print("[bench] ", line)

	if run_time >= 15.0:
		var sum := 0.0
		var worst := fps_samples[0]
		for f in fps_samples:
			sum += f
			worst = minf(worst, f)
		print("[bench] RESULT: avg FPS %.0f | worst %.0f | %d units" % [
			sum / fps_samples.size(), worst, N,
		])
		get_tree().quit()


# 程序化 6 帧占位图集（96x16，6 个色块），避免引入美术资产
func _make_atlas() -> ImageTexture:
	var img := Image.create(16 * FRAMES, 16, false, Image.FORMAT_RGBA8)
	var colors := [
		Color(0.9, 0.3, 0.3), Color(0.9, 0.6, 0.2), Color(0.9, 0.9, 0.3),
		Color(0.3, 0.8, 0.3), Color(0.3, 0.5, 0.9), Color(0.7, 0.3, 0.9),
	]
	for f in FRAMES:
		for y in 16:
			for x in 16:
				var border := x == 0 or y == 0 or x == 15 or y == 15
				img.set_pixel(f * 16 + x, y, Color.BLACK if border else colors[f])
	return ImageTexture.create_from_image(img)


func _make_material() -> ShaderMaterial:
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
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat
