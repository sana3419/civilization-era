# 第零阶段 headless 压测：godot --headless --path game -s bench/bench_sim.gd
# 测：GDScript↔C++ 边界成本、10k 单位 tick 耗时（1/2/6 线程）、确定性、buffer 写出耗时
extends SceneTree

const N := 10000
const WORLD := 16384.0
const LOOPS := 1000000
const GOLDEN_PATH := "res://bench/golden_hash.txt"

var failures := 0


func _init() -> void:
	print("=== CivEra headless bench ===")
	var core := SimCore.new()
	print("extension: ", core.get_version())

	_bench_boundary(core)
	_bench_determinism()
	_bench_tick()
	_bench_buffer()
	_bench_flow_field()
	_bench_map()
	_bench_astar()
	_bench_saveload()
	_bench_gather()
	_bench_combat()
	_bench_golden()

	print("=== done, failures: %d ===" % failures)
	quit(0 if failures == 0 else 1)


func _check(ok: bool, what: String) -> String:
	if not ok:
		failures += 1
	return "PASS" if ok else "FAIL"


func _bench_boundary(core: SimCore) -> void:
	var t0 := Time.get_ticks_usec()
	for i in LOOPS:
		pass
	var empty_us := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	for i in LOOPS:
		core.bench_noop()
	var noop_us := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	var acc := 0
	for i in LOOPS:
		acc = core.bench_add(acc, 1)
	var add_us := Time.get_ticks_usec() - t0

	print("boundary (1M calls): empty-loop %.0f ns/it | noop %.0f ns/call (net %.0f) | add %.0f ns/call (net %.0f), acc=%d" % [
		empty_us * 1000.0 / LOOPS,
		noop_us * 1000.0 / LOOPS, (noop_us - empty_us) * 1000.0 / LOOPS,
		add_us * 1000.0 / LOOPS, (add_us - empty_us) * 1000.0 / LOOPS, acc,
	])


func _bench_determinism() -> void:
	var hashes: Array[int] = []
	for threads in [6, 6, 1]:
		var w := SimWorld.new()
		w.setup(N, WORLD, 42, threads)
		for i in 100:
			w.tick(0.1)
		hashes.append(w.state_hash())
	print("determinism: same-seed %s | thread-count-invariant %s (hash %d)" % [
		_check(hashes[0] == hashes[1], "same-seed"),
		_check(hashes[0] == hashes[2], "thread-invariant"),
		hashes[0],
	])


func _bench_tick() -> void:
	for threads in [1, 2, 6]:
		var w := SimWorld.new()
		w.setup(N, WORLD, 7, threads)
		for i in 20:
			w.tick(0.1)
		var t0 := Time.get_ticks_usec()
		for i in 300:
			w.tick(0.1)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 300.0
		print("tick %d units, %d thread(s): %.3f ms/tick" % [N, threads, ms])


func _bench_buffer() -> void:
	var w := SimWorld.new()
	w.setup(N, WORLD, 7, 6)
	w.tick(0.1)
	var t0 := Time.get_ticks_usec()
	for i in 300:
		w.write_render_buffer(1.0)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 300.0
	var buf := w.get_render_buffer()
	print("write_render_buffer %d units: %.3f ms (%d floats)" % [N, ms, buf.size()])


func _bench_flow_field() -> void:
	var ff := FlowField.new()
	ff.setup(512, 32.0, 99, 0.1) # 512×512 格，10% 不可通行

	var t0 := Time.get_ticks_usec()
	for i in 10:
		ff.generate(256, 256)
	var gen_ms := (Time.get_ticks_usec() - t0) / 1000.0 / 10.0
	print("flow field generate 512x512: %.2f ms" % gen_ms)

	var dir: Vector2 = ff.sample(Vector2(1000.0, 1000.0))
	print("flow sample sanity: dir(1000,1000) = %s (len %.2f)" % [dir, dir.length()])

	for count in [1000, 10000]:
		var w := SimWorld.new()
		w.setup(count, 16384.0, 7, 6)
		w.set_flow_field(ff)
		for i in 20:
			w.tick(0.1)
		t0 = Time.get_ticks_usec()
		for i in 300:
			w.tick(0.1)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 300.0
		print("flow-follow tick %d units: %.3f ms/tick" % [count, ms])


func _bench_map() -> void:
	var map := GameMap.new()
	var t0 := Time.get_ticks_usec()
	for i in 5:
		map.generate(512, 2026)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 5.0

	var buf := map.get_terrain_buffer()
	var counts := {}
	for b in buf:
		counts[b] = counts.get(b, 0) + 1
	var passable := 0
	for cy in 512:
		for cx in 512:
			if map.is_passable(cx, cy):
				passable += 1
	var ratio := passable / float(512 * 512)
	print("map generate 512x512: %.1f ms | passable %.0f%% %s | terrain kinds %d" % [
		ms, ratio * 100.0, _check(ratio > 0.3 and ratio < 0.9, "passable ratio"), counts.size(),
	])


func _bench_astar() -> void:
	var map := GameMap.new()
	map.generate(512, 2026)
	var pf := Pathfinder.new()
	pf.set_map(map)

	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var pairs: Array[Vector2i] = []
	while pairs.size() < 200: # 100 对
		var p := Vector2i(rng.randi_range(0, 511), rng.randi_range(0, 511))
		if map.is_passable(p.x, p.y):
			pairs.append(p)

	var ok := 0
	var total_len := 0
	var t0 := Time.get_ticks_usec()
	for i in 100:
		var path := pf.find_path(pairs[i * 2], pairs[i * 2 + 1], 200000)
		if path.size() > 0:
			ok += 1
			total_len += path.size()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 100.0
	print("A* 100 random paths: %.2f ms avg | success %d/100 | avg len %d" % [
		ms, ok, total_len / maxi(ok, 1),
	])


func _bench_saveload() -> void:
	var w1 := SimWorld.new()
	w1.setup(N, WORLD, 42, 6)
	for i in 100:
		w1.tick(0.1)
	var data := w1.save_state()

	var w2 := SimWorld.new()
	w2.setup(1, 100.0, 0, 6) # 故意不同，验证 load 完全覆盖
	var loaded := w2.load_state(data)
	# 双方再各跑 50 tick，验证"读档后继续模拟"与原世界逐位一致
	for i in 50:
		w1.tick(0.1)
		w2.tick(0.1)
	print("save/load: load %s | resume-equivalence %s | %d bytes" % [
		_check(loaded, "load"),
		_check(w1.state_hash() == w2.state_hash(), "resume"),
		data.size(),
	])


func _run_gather_sim() -> SimWorld:
	var map := GameMap.new()
	map.generate(512, 2026)
	# 找一片森林和附近的可通行存储点
	var fc := Vector2i(-1, -1)
	for cy in range(100, 412):
		for cx in range(100, 412):
			if map.get_terrain(cx, cy) == 4: # T_FOREST
				fc = Vector2i(cx, cy)
				break
		if fc.x >= 0:
			break
	var drop := fc
	for dx in range(4, 16):
		if map.is_passable(fc.x + dx, fc.y):
			drop = Vector2i(fc.x + dx, fc.y)
			break

	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	w.spawn_workers(20, Vector2(fc) * 32.0 + Vector2(16, 16))
	w.set_dropoff(Vector2(drop) * 32.0 + Vector2(16, 16))
	var ids := PackedInt32Array(range(20))
	w.command_gather(ids, Vector2(fc) * 32.0 + Vector2(16, 16))
	for i in 1200: # 120 秒模拟
		w.tick(0.1)
	return w


func _bench_gather() -> void:
	var t0 := Time.get_ticks_usec()
	var w1 := _run_gather_sim()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var w2 := _run_gather_sim()
	var wood := w1.get_stockpile(0)
	print("gather: 20 workers, 1200 ticks → wood %d %s | determinism %s | %.0f ms total" % [
		wood, _check(wood > 0, "gather yield"),
		_check(w1.state_hash() == w2.state_hash(), "gather determinism"), ms,
	])


func _run_combat_sim() -> SimWorld:
	var map := GameMap.new()
	map.generate(512, 2026)
	# 找一片开阔草地当战场
	var bc := Vector2i(-1, -1)
	for cy in range(150, 400):
		for cx in range(150, 400):
			var ok := true
			for oy in range(-3, 4):
				for ox in range(-3, 4):
					if map.get_terrain(cx + ox, cy + oy) != 3: # 草地
						ok = false
			if ok:
				bc = Vector2i(cx, cy)
				break
		if bc.x >= 0:
			break
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var p := Vector2(bc) * 32.0
	w.spawn_units(1, 5, p - Vector2(80, 0), 0) # 5 民兵
	w.spawn_units(2, 5, p + Vector2(80, 0), 1) # 5 土匪，间距 160 = 仇恨边缘
	for i in 900: # 90 秒
		w.tick(0.1)
	return w


func _bench_combat() -> void:
	var w1 := _run_combat_sim()
	var w2 := _run_combat_sim()
	var p_alive := w1.count_alive(0)
	var b_alive := w1.count_alive(1)
	print("combat 5v5: player %d vs bandit %d alive | resolved %s | determinism %s" % [
		p_alive, b_alive,
		_check(p_alive == 0 or b_alive == 0, "combat resolved"),
		_check(w1.state_hash() == w2.state_hash(), "combat determinism"),
	])
	# 远程价值 = 贴脸前的免费输出窗口；对等数量近战仍应占优（设计克制表如此）。
	# 断言：弓手在被歼前至少换掉 2 个土匪（射程消耗成立）
	var wa := _run_archer_sim()
	print("combat archers 5v5: archers %d vs bandit %d | first-strike trade %s" % [
		wa.count_alive(0), wa.count_alive(1),
		_check(wa.count_alive(1) <= 3, "ranged chip"),
	])


func _run_archer_sim() -> SimWorld:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var p := Vector2(260, 260) * 32.0
	w.spawn_units(3, 5, p - Vector2(100, 0), 0) # 5 弓手
	w.spawn_units(2, 5, p + Vector2(100, 0), 1) # 5 土匪
	for i in 900:
		w.tick(0.1)
	return w


func _bench_golden() -> void:
	var w := SimWorld.new()
	w.setup(N, WORLD, 42, 6)
	for i in 500:
		w.tick(0.1)
	var sim_hash := w.state_hash()

	var map := GameMap.new()
	map.generate(512, 2026)
	var map_hash := hash(map.get_terrain_buffer())

	var current := "%d\n%d" % [sim_hash, map_hash]
	if not FileAccess.file_exists(GOLDEN_PATH):
		var f := FileAccess.open(GOLDEN_PATH, FileAccess.WRITE)
		f.store_string(current)
		print("golden: initialized (sim %d, map %d)" % [sim_hash, map_hash])
		return
	var expected := FileAccess.get_file_as_string(GOLDEN_PATH)
	print("golden: %s (sim %d, map %d)" % [
		_check(expected.strip_edges() == current.strip_edges(), "golden"), sim_hash, map_hash,
	])
