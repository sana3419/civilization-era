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
	_bench_siege()
	_bench_siege_engines()
	_bench_collision()
	_bench_fixes()
	_bench_resume_in_battle()
	_bench_satiety()
	_bench_sawmill()
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
	# 士气：3 民兵 vs 9 土匪，弱势方目击队友阵亡应溃逃
	var fled := [false, false]
	for run in 2:
		var map := GameMap.new()
		map.generate(512, 2026)
		var w := SimWorld.new()
		w.setup(0, 16384.0, 1, 6)
		w.set_map(map)
		var p := _find_battlefield(map)
		w.spawn_units(1, 3, p - Vector2(60, 0), 0)
		w.spawn_units(2, 9, p + Vector2(60, 0), 1)
		for i in 600:
			w.tick(0.1)
			if w.count_state(6, 0) > 0: # U_FLEE
				fled[run] = true
	print("morale: outnumbered militia fled %s" % [
		_check(fled[0] and fled[1], "morale break"),
	])
	# 阵型机制：同一场 1v1 决斗，盾墙（防 ×1.5）方应比无阵型留更多血。
	# （镜像 5v5 是刀尖平衡，先手序/寻路噪声会翻面，不适合做断言场景）
	var hp_shield := _run_duel(5)
	var hp_none := _run_duel(0)
	print("formation shield-wall duel: 盾墙余血 %.0f vs 无阵型 %.0f | %s" % [
		hp_shield, hp_none,
		_check(hp_shield > hp_none and hp_shield > 0.0, "shield wall defense"),
	])
	# 骑兵：4 骑兵冲锋（克步兵 ×1.3 + 冲锋首击 ×1.5）应胜 5 土匪
	var wc := _run_cavalry_sim()
	print("cavalry charge 4v5: cavalry %d vs bandit %d | %s" % [
		wc.count_alive(0), wc.count_alive(1),
		_check(wc.count_alive(1) == 0 and wc.count_alive(0) >= 2, "cavalry charge"),
	])
	# 箭塔：塔射程内 3 土匪应被自动清除
	var wt := _run_tower_sim()
	print("tower defense: bandits remaining %d | %s" % [
		wt.count_alive(1), _check(wt.count_alive(1) == 0, "tower kills"),
	])
	# 长枪兵：4 长枪（克骑 ×1.5，骑→枪 ×0.7）应顶住 4 骑兵冲锋并获胜
	var wp := _run_spearman_sim()
	print("spearman anti-cavalry 4v4: spearmen %d vs cavalry %d | %s" % [
		wp.count_alive(0), wp.count_alive(1),
		_check(wp.count_alive(1) == 0 and wp.count_alive(0) >= 2, "spear wall"),
	])


func _run_cavalry_sim() -> SimWorld:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var p := _find_battlefield(map)
	var first := w.spawn_units(4, 4, p - Vector2(120, 0), 0) # 拉开距离起冲，积累动量
	w.spawn_units(2, 5, p + Vector2(100, 0), 1)
	w.command_move(PackedInt32Array(range(first, first + 4)), p + Vector2(100, 0))
	for i in 900:
		w.tick(0.1)
	return w


func _run_spearman_sim() -> SimWorld:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var p := _find_battlefield(map)
	w.spawn_units(5, 4, p - Vector2(100, 0), 0) # 4 长枪兵原地接敌
	var first := w.spawn_units(4, 4, p + Vector2(120, 0), 1)
	w.command_move(PackedInt32Array(range(first, first + 4)), p - Vector2(100, 0)) # 骑兵带动量冲入
	for i in 900:
		w.tick(0.1)
	return w


func _run_tower_sim() -> SimWorld:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	# 找草地放塔
	var bc := Vector2i(-1, -1)
	for cy in range(150, 400):
		for cx in range(150, 400):
			var ok := true
			for oy in range(0, 2):
				for ox in range(0, 2):
					if not map.is_passable(cx + ox, cy + oy):
						ok = false
			if ok:
				bc = Vector2i(cx, cy)
				break
		if bc.x >= 0:
			break
	w.debug_add_resources(100, 100, 0)
	assert(w.place_building(9, Vector2(bc) * 32.0 + Vector2(1, 1)))
	w.spawn_units(2, 3, Vector2(bc) * 32.0 + Vector2(150, 32), 1) # 塔射程内
	for i in 400: # 40 秒
		w.tick(0.1)
	return w


# 1v1 决斗：民兵（指定阵型）vs 土匪，返回民兵余血（阵亡 = 0）
func _run_duel(formation: int) -> float:
	var mw := _new_world()
	var w: SimWorld = mw[1]
	var p: Vector2 = _find_battlefield(mw[0])
	var militia := w.spawn_units(1, 1, p - Vector2(60, 0), 0)
	var bandit := w.spawn_units(2, 1, p + Vector2(60, 0), 1)
	w.command_set_formation(PackedInt32Array([militia]), formation)
	w.command_attack(PackedInt32Array([militia]), bandit)
	for i in 400:
		w.tick(0.1)
	return w.get_unit_hp(militia) if w.is_unit_alive(militia) else 0.0


# 找一片 9×9 全草地的开阔战场（此前硬编码 (260,260) 其实是深海！）
func _find_battlefield(map: GameMap) -> Vector2:
	for cy in range(150, 400):
		for cx in range(150, 400):
			var ok := true
			for oy in range(-4, 5):
				for ox in range(-4, 5):
					if map.get_terrain(cx + ox, cy + oy) != 3:
						ok = false
			if ok:
				return Vector2(cx, cy) * 32.0
	return Vector2(256, 256) * 32.0


func _run_archer_sim() -> SimWorld:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var p := _find_battlefield(map)
	w.spawn_units(3, 5, p - Vector2(100, 0), 0) # 5 弓手
	w.spawn_units(2, 5, p + Vector2(100, 0), 1) # 5 土匪
	for i in 900:
		w.tick(0.1)
	return w


# 栅栏环 + 城门围住工人，土匪攻城：破门前圈内无伤亡，破门后涌入歼灭
func _run_siege_sim() -> Dictionary:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var pc := Vector2i(_find_battlefield(map) / 32.0)
	w.debug_add_resources(400, 0, 0)
	var gate_cell := Vector2i(pc.x + 3, pc.y)
	var placed := 0
	for oy in range(-3, 4): # 7×7 环，东侧开门
		for ox in range(-3, 4):
			if maxi(absi(ox), absi(oy)) != 3:
				continue
			var c := pc + Vector2i(ox, oy)
			var t := 11 if c == gate_cell else 10
			if w.place_building(t, Vector2(c) * 32.0 + Vector2(1, 1)):
				placed += 1
	w.spawn_workers(4, Vector2(pc) * 32.0 + Vector2(16, 16))
	w.toggle_gate_at(Vector2(gate_cell) * 32.0 + Vector2(16, 16)) # 关门
	var first := w.spawn_units(2, 6, Vector2(pc) * 32.0 + Vector2(320, 16), 1)
	w.command_move(PackedInt32Array(range(first, first + 6)), Vector2(pc) * 32.0 + Vector2(16, 16))
	var engaged := false
	for i in 600: # 60 秒：土匪应转攻城门（普攻 ×0.2 啃不穿 800HP）
		w.tick(0.1)
		var ev := w.take_attack_events()
		for e in range(1, ev.size(), 2):
			if ev[e] < 0:
				engaged = true
	var pre := w.count_alive(0)
	var gate_held := false # 600 tick 内门应还没被啃穿
	var flat := w.get_buildings()
	for b in range(flat.size() / 2):
		if flat[b * 2] == 11:
			gate_held = w.get_building_hp(b) > 0.0
			w.debug_damage_building(b, 10000.0) # 破门，验证恢复行军 + 涌入
	for i in 600:
		w.tick(0.1)
	return {
		"hash": w.state_hash(), "placed": placed, "engaged": engaged,
		"gate_held": gate_held, "pre": pre, "post": w.count_alive(0),
	}


# 城门通行：开门己方可穿行，关门全挡（敌方由攻城测试覆盖）
func _run_gate_pass_sim(open: bool) -> float:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var pc := Vector2i(_find_battlefield(map) / 32.0)
	w.debug_add_resources(400, 0, 0)
	var gate_cell := Vector2i(pc.x + 3, pc.y)
	for oy in range(-3, 4):
		for ox in range(-3, 4):
			if maxi(absi(ox), absi(oy)) != 3:
				continue
			var c := pc + Vector2i(ox, oy)
			w.place_building(11 if c == gate_cell else 10, Vector2(c) * 32.0 + Vector2(1, 1))
	w.spawn_workers(1, Vector2(pc) * 32.0 + Vector2(16, 16))
	if not open:
		w.toggle_gate_at(Vector2(gate_cell) * 32.0 + Vector2(16, 16))
	var target := Vector2(pc + Vector2i(8, 0)) * 32.0 + Vector2(16, 16)
	w.command_move(PackedInt32Array([0]), target)
	for i in 300:
		w.tick(0.1)
	return w.get_unit_positions(PackedInt32Array([0]))[0].distance_to(target)


func _bench_siege() -> void:
	var r1 := _run_siege_sim()
	var r2 := _run_siege_sim()
	print("siege: ring %d/24 %s | engaged %s | gate held %s | workers %d→%d %s | determinism %s" % [
		r1["placed"], _check(r1["placed"] == 24, "ring placed"),
		_check(r1["engaged"], "wall engaged"),
		_check(r1["gate_held"], "gate held"),
		r1["pre"], r1["post"],
		_check(r1["pre"] == 4 and r1["post"] < 4, "breach kills"),
		_check(r1["hash"] == r2["hash"], "siege determinism"),
	])
	var d_open := _run_gate_pass_sim(true)
	var d_closed := _run_gate_pass_sim(false)
	print("gate passage: open dist %.0f %s | closed dist %.0f %s" % [
		d_open, _check(d_open < 48.0, "open passage"),
		d_closed, _check(d_closed > 96.0, "closed blocked"),
	])


# 攻城槌带队破石门（×3.0），破门后土匪涌入
func _run_ram_sim() -> Dictionary:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var pc := Vector2i(_find_battlefield(map) / 32.0)
	w.debug_add_resources(100, 400, 0)
	var gate_cell := Vector2i(pc.x + 3, pc.y)
	for oy in range(-3, 4): # 7×7 石墙环，东侧石门
		for ox in range(-3, 4):
			if maxi(absi(ox), absi(oy)) != 3:
				continue
			var c := pc + Vector2i(ox, oy)
			w.place_building(14 if c == gate_cell else 13, Vector2(c) * 32.0 + Vector2(1, 1))
	w.spawn_workers(4, Vector2(pc) * 32.0 + Vector2(16, 16))
	w.toggle_gate_at(Vector2(gate_cell) * 32.0 + Vector2(16, 16)) # 关门
	var first := w.spawn_units(2, 4, Vector2(pc) * 32.0 + Vector2(320, 16), 1)
	var ram := w.spawn_units(6, 1, Vector2(pc) * 32.0 + Vector2(380, 16), 1)
	var ids := PackedInt32Array(range(first, first + 4))
	ids.append(ram)
	w.command_move(ids, Vector2(pc) * 32.0 + Vector2(16, 16))
	var breach_tick := -1
	for i in 1100: # 槌 45dps + 4 匪 6.4dps → 3000HP 约 60s + 行军
		w.tick(0.1)
		if breach_tick < 0 and w.take_building_events().size() > 0:
			breach_tick = i
			if w.count_alive(0) < 4: # 破门前圈内必须无伤亡
				breach_tick = -2
	return {
		"hash": w.state_hash(), "breach": breach_tick,
		"post": w.count_alive(0), "ram_alive": w.is_unit_alive(ram),
	}


# 弓手登石墙：墙上射程 +2 格、防御 ×5，顶住贴脸土匪
func _run_garrison_sim() -> Dictionary:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var pc := Vector2i(_find_battlefield(map) / 32.0)
	w.debug_add_resources(0, 100, 0)
	for oy in range(-2, 3): # 南北向 5 段石墙
		w.place_building(13, Vector2(pc + Vector2i(0, oy)) * 32.0 + Vector2(1, 1))
	var archer := w.spawn_units(3, 1, Vector2(pc) * 32.0 + Vector2(-48, 16), 0)
	var ok := w.command_garrison(PackedInt32Array([archer]),
			Vector2(pc) * 32.0 + Vector2(16, 16))
	for i in 100:
		w.tick(0.1)
	var garrisoned := w.get_unit_state(archer) == 7 # U_GARRISON
	var bandit := w.spawn_units(2, 1, Vector2(pc) * 32.0 + Vector2(300, 16), 1)
	w.command_move(PackedInt32Array([bandit]), Vector2(pc) * 32.0 + Vector2(64, 16))
	for i in 400:
		w.tick(0.1)
	return {
		"ok": ok, "garrisoned": garrisoned,
		"bandit_dead": not w.is_unit_alive(bandit),
		"archer_hp": w.get_unit_hp(archer),
		"still_garrisoned": w.get_unit_state(archer) == 7,
	}


# 投石车 10 格外站桩拆栅栏（×2.0 普通建筑列对墙是 ×1.5）
func _run_catapult_sim() -> Dictionary:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var pc := Vector2i(_find_battlefield(map) / 32.0)
	w.debug_add_resources(50, 0, 0)
	w.place_building(10, Vector2(pc + Vector2i(4, 0)) * 32.0 + Vector2(1, 1))
	var cata := w.spawn_units(7, 1, Vector2(pc + Vector2i(-4, 0)) * 32.0 + Vector2(16, 16), 0)
	var start: Vector2 = w.get_unit_positions(PackedInt32Array([cata]))[0]
	w.command_attack_building(PackedInt32Array([cata]), 0)
	for i in 450: # 40×1.5/4s = 15dps → 500HP 约 34s
		w.tick(0.1)
	var moved: float = w.get_unit_positions(PackedInt32Array([cata]))[0].distance_to(start)
	return { "destroyed": w.get_building_hp(0) <= 0.0, "moved": moved }


func _bench_siege_engines() -> void:
	var r1 := _run_ram_sim()
	var r2 := _run_ram_sim()
	print("ram: breach@%d %s | post-breach workers %d %s | ram alive %s | determinism %s" % [
		r1["breach"], _check(r1["breach"] >= 0, "ram breached clean"),
		r1["post"], _check(r1["post"] < 4, "breach kills"),
		_check(r1["ram_alive"], "ram survives"),
		_check(r1["hash"] == r2["hash"], "ram determinism"),
	])
	var g := _run_garrison_sim()
	print("garrison: cmd %s | mounted %s | bandit dead %s | archer hp %.0f %s | held %s" % [
		_check(g["ok"], "garrison cmd"), _check(g["garrisoned"], "mounted"),
		_check(g["bandit_dead"], "bandit dead"),
		g["archer_hp"], _check(g["archer_hp"] > 25.0, "wall bonus"),
		_check(g["still_garrisoned"], "held wall"),
	])
	var c := _run_catapult_sim()
	print("catapult: wall destroyed %s | stand-off moved %.0fpx %s" % [
		_check(c["destroyed"], "catapult kill"),
		c["moved"], _check(c["moved"] < 24.0, "stand-off"),
	])


# 真地形碰撞：命令单位走进不可通行格，应被挡在外面（旧行为是 0.25 减速渗入）
func _bench_collision() -> void:
	var map := GameMap.new()
	map.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(map)
	var dim := map.get_dim()
	var target := Vector2i(-1, -1) # 找一个左邻可通行的不可通行格
	for cy in range(1, dim - 1):
		for cx in range(1, dim - 1):
			if not map.is_passable(cx, cy) and map.is_passable(cx - 1, cy):
				target = Vector2i(cx, cy)
				break
		if target.x >= 0:
			break
	w.spawn_workers(1, Vector2(target.x - 1, target.y) * 32.0 + Vector2(16, 16))
	w.command_move(PackedInt32Array([0]), Vector2(target) * 32.0 + Vector2(16, 16))
	for i in 100:
		w.tick(0.1)
	var p: Vector2 = w.get_unit_positions(PackedInt32Array([0]))[0]
	var cell := Vector2i(p / 32.0)
	print("collision: unit at passable cell %s" % _check(map.is_passable(cell.x, cell.y), "terrain collision"))


func _new_world() -> Array: # [GameMap, SimWorld]
	var m := GameMap.new()
	m.generate(512, 2026)
	var w := SimWorld.new()
	w.setup(0, 16384.0, 1, 6)
	w.set_map(m)
	return [m, w]


# 修复批次回归：追击放弃/投石溅射/工人修理/槽位回收/枯竭退化
func _bench_fixes() -> void:
	# 1) 追击放弃：攻击封闭石环内的目标，不可达应转 IDLE 而非永久卡墙
	var mw := _new_world()
	var w: SimWorld = mw[1]
	var pc := Vector2i(_find_battlefield(mw[0]) / 32.0)
	w.debug_add_resources(0, 400, 0)
	for oy in range(-2, 3):
		for ox in range(-2, 3):
			if maxi(absi(ox), absi(oy)) == 2:
				w.place_building(13, Vector2(pc + Vector2i(ox, oy)) * 32.0 + Vector2(1, 1))
	var archer := w.spawn_units(3, 1, Vector2(pc) * 32.0 + Vector2(16, 16), 0)
	var bandit := w.spawn_units(2, 1, Vector2(pc) * 32.0 + Vector2(320, 16), 1)
	w.command_attack(PackedInt32Array([bandit]), archer)
	for i in 200:
		w.tick(0.1)
	print("chase: give-up state %d %s" % [
		w.get_unit_state(bandit), _check(w.get_unit_state(bandit) != 5, "chase give-up"),
	])

	# 2) 投石车溅射：炮击石门波及旁边的土匪（落点 48px、×0.5 基伤）
	mw = _new_world()
	w = mw[1]
	pc = Vector2i(_find_battlefield(mw[0]) / 32.0)
	w.debug_add_resources(100, 100, 0)
	var gate_pos := Vector2(pc + Vector2i(4, 0)) * 32.0 + Vector2(1, 1)
	w.place_building(14, gate_pos)
	var cata := w.spawn_units(7, 1, Vector2(pc + Vector2i(-4, 0)) * 32.0 + Vector2(16, 16), 0)
	var b2 := w.spawn_units(2, 2, Vector2(pc + Vector2i(5, 0)) * 32.0 + Vector2(16, 16), 1)
	w.command_attack_building(PackedInt32Array([cata]), 0)
	for i in 250:
		w.tick(0.1)
	var splash_dead := not w.is_unit_alive(b2) and not w.is_unit_alive(b2 + 1)
	print("splash: bandits dead %s | gate hp %.0f %s" % [
		_check(splash_dead, "splash kills"), w.get_building_hp(0),
		_check(w.get_building_hp(0) < 3000.0, "gate damaged"),
	])

	# 3) 工人修理：受损栅栏修回满血后收工
	mw = _new_world()
	w = mw[1]
	pc = Vector2i(_find_battlefield(mw[0]) / 32.0)
	w.debug_add_resources(50, 0, 0)
	w.place_building(10, Vector2(pc + Vector2i(2, 0)) * 32.0 + Vector2(1, 1))
	w.debug_damage_building(0, 300.0) # 500 → 200
	var worker := w.spawn_workers(1, Vector2(pc) * 32.0 + Vector2(16, 16))
	w.command_repair(PackedInt32Array([worker]),
			Vector2(pc + Vector2i(2, 0)) * 32.0 + Vector2(16, 16))
	for i in 400: # 12HP/s → 约 25s
		w.tick(0.1)
	print("repair: hp %.0f %s | worker idle %s" % [
		w.get_building_hp(0), _check(w.get_building_hp(0) >= 500.0, "repaired full"),
		_check(w.get_unit_state(worker) == 1, "worker done"),
	])

	# 4) 尸体槽位回收：整波阵亡后再出兵不增长数组
	mw = _new_world()
	w = mw[1]
	pc = Vector2i(_find_battlefield(mw[0]) / 32.0)
	w.spawn_units(1, 4, Vector2(pc) * 32.0 + Vector2(-64, 16), 0)
	w.spawn_units(2, 5, Vector2(pc) * 32.0 + Vector2(64, 16), 1)
	for i in 900:
		w.tick(0.1)
	var before := w.get_unit_count()
	var resolved := w.count_alive(0) == 0 or w.count_alive(1) == 0
	w.spawn_units(2, 3, Vector2(pc) * 32.0 + Vector2(64, 16), 1)
	print("recycle: fight resolved %s | units %d → %d %s" % [
		_check(resolved, "fight resolved"), before, w.get_unit_count(),
		_check(w.get_unit_count() == before, "slots recycled"),
	])

	# 5) 枯竭退化：砍光的森林变草地并发地形事件
	var m5 := GameMap.new()
	m5.generate(512, 2026)
	var fcell := -1
	for cy in range(150, 400):
		for cx in range(150, 400):
			if m5.get_terrain(cx, cy) == 4: # 森林
				fcell = cy * 512 + cx
				break
		if fcell >= 0:
			break
	m5.take_resource_at(fcell, 65535)
	var ev5 := m5.take_terrain_events()
	print("deplete: terrain %d %s | event %s" % [
		m5.get_terrain(fcell % 512, fcell / 512),
		_check(m5.get_terrain(fcell % 512, fcell / 512) == 3, "forest→grass"),
		_check(ev5.size() == 1 and ev5[0] == fcell, "terrain event"),
	])


# "存→读→续跑" 必须与不存档的延续逐位一致——在真实地图上验证
# （旧的续跑等价测试跑在无地图 WANDER 模式，空间网格/流场缓存全不参与，
#  曾漏掉读档后网格失明与枯竭地形缓存陈旧两个分歧源）
func _bench_resume_in_battle() -> void:
	# 场景 A：交战中（索敌/士气/溅射全走空间网格）
	var ha := _run_resume_sim(true)
	# 场景 B：采集中 + 资源格枯竭（流场缓存按地形重建的一致性）
	var hb := _run_resume_sim(false)
	print("resume-in-battle: combat %s | gather+deplete %s" % [
		_check(ha[0] == ha[1], "combat resume"),
		_check(hb[0] == hb[1], "gather resume"),
	])


func _run_resume_sim(combat: bool) -> Array:
	# 续跑基准
	var mw := _new_world()
	var m: GameMap = mw[0]
	var w: SimWorld = mw[1]
	var pc := Vector2i(_find_battlefield(m) / 32.0)
	_setup_resume_scene(m, w, pc, combat)
	for i in 100:
		w.tick(0.1)
	var blob: PackedByteArray = w.save_state()
	var map_blob: PackedByteArray = m.save_state()
	for i in 60:
		w.tick(0.1)
	var h_cont: int = w.state_hash()
	# 读档续跑
	var m2 := GameMap.new()
	m2.generate(512, 2026)
	if not m2.load_state(map_blob):
		return [1, 2]
	var w2 := SimWorld.new()
	w2.setup(0, 16384.0, 1, 6)
	w2.set_map(m2)
	if not w2.load_state(blob):
		return [1, 2]
	for i in 60:
		w2.tick(0.1)
	return [h_cont, w2.state_hash()]


func _setup_resume_scene(m: GameMap, w: SimWorld, pc: Vector2i, combat: bool) -> void:
	if combat:
		w.spawn_units(1, 4, Vector2(pc) * 32.0 + Vector2(-64, 16), 0)
		w.spawn_units(3, 2, Vector2(pc) * 32.0 + Vector2(-96, 48), 0) # 弓手参战
		w.spawn_units(2, 5, Vector2(pc) * 32.0 + Vector2(64, 16), 1)
		return
	# 采集 + 人工把目标格逼近枯竭（第 ~12 次采集触发地形退化）
	w.set_dropoff(Vector2(pc) * 32.0 + Vector2(16, 16))
	var f := _find_forest_near(m, pc)
	m.take_resource_at(f.y * 512 + f.x, maxi(0, m.get_resource_amount(f.x, f.y) - 120))
	var first := w.spawn_workers(6, Vector2(pc) * 32.0 + Vector2(16, 16))
	w.command_gather(PackedInt32Array(range(first, first + 6)),
			Vector2(f) * 32.0 + Vector2(16, 16))


func _find_forest_near(m: GameMap, pc: Vector2i) -> Vector2i:
	for r in range(1, 128):
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if maxi(absi(ox), absi(oy)) != r:
					continue
				if m.get_terrain(pc.x + ox, pc.y + oy) == 4:
					return pc + Vector2i(ox, oy)
	return pc


# 饱食度：断粮减速采集、压士气基线；有粮自动进食
func _bench_satiety() -> void:
	# 饿汉 vs 饱汉：各自单独世界采木 400 tick，饿汉产出应明显少（系数 0.5）
	var wood := [0, 0]
	for hungry in [true, false]:
		var mw := _new_world()
		var w: SimWorld = mw[1]
		var pc := Vector2i(_find_battlefield(mw[0]) / 32.0)
		var f := _find_forest_near(mw[0], pc)
		w.set_dropoff(Vector2(pc) * 32.0 + Vector2(16, 16))
		var id := w.spawn_workers(1, Vector2(pc) * 32.0 + Vector2(16, 16))
		if hungry:
			w.debug_set_satiety(id, 10.0) # 无存粮，吃不上
		w.command_gather(PackedInt32Array([id]), Vector2(f) * 32.0 + Vector2(16, 16))
		for i in 400:
			w.tick(0.1)
		wood[0 if hungry else 1] = w.get_stockpile(0)
	# 进食：低饱食 + 有存粮 → 立即吃回，库存下降
	var mw2 := _new_world()
	var w2: SimWorld = mw2[1]
	var pc2 := Vector2i(_find_battlefield(mw2[0]) / 32.0)
	var e := w2.spawn_workers(1, Vector2(pc2) * 32.0 + Vector2(16, 16))
	w2.debug_add_resources(0, 0, 100)
	w2.debug_set_satiety(e, 20.0)
	for i in 5:
		w2.tick(0.1)
	# 饥饿压士气基线：断粮民兵士气应滑向 40
	var mw3 := _new_world()
	var w3: SimWorld = mw3[1]
	var pc3 := Vector2i(_find_battlefield(mw3[0]) / 32.0)
	var m := w3.spawn_units(1, 1, Vector2(pc3) * 32.0 + Vector2(16, 16), 0)
	w3.debug_set_satiety(m, 10.0)
	for i in 300:
		w3.tick(0.1)
	print("satiety: 饿/饱采集 %d/%d %s | 进食后 %d(粮%d) %s | 饥饿士气 %.0f %s" % [
		wood[0], wood[1], _check(wood[0] < wood[1] and wood[0] > 0, "hungry slower"),
		int(w2.get_unit_satiety(e)), w2.get_stockpile(2),
		_check(w2.get_unit_satiety(e) > 50.0 and w2.get_stockpile(2) < 100, "auto eat"),
		w3.get_unit_morale(m),
		_check(w3.get_unit_morale(m) < 50.0 and w3.get_unit_morale(m) > 30.0, "hunger morale"),
	])


# 锯木厂：自动 5 木 → 3 木板 / 4s，缺料待机
func _bench_sawmill() -> void:
	var mw := _new_world()
	var w: SimWorld = mw[1]
	var pc := Vector2i(_find_battlefield(mw[0]) / 32.0)
	w.debug_add_resources(100, 50, 0)
	w.place_building(15, Vector2(pc) * 32.0 + Vector2(1, 1)) # 锯木厂 30木10石 → 余 70 木
	for i in 200: # 20s → 5 轮转化：70-25=45 木，15 板
		w.tick(0.1)
	var ok_conv := w.get_stockpile(0) == 45 and w.get_stockpile(3) == 15
	for i in 400: # 再 40s：木 45→可再 9 轮=45 木耗尽，板 +27=42
		w.tick(0.1)
	print("sawmill: 20s 后 木%d 板%d %s | 耗尽后 木%d 板%d %s" % [
		45 if ok_conv else w.get_stockpile(0), 15 if ok_conv else w.get_stockpile(3),
		_check(ok_conv, "sawmill convert"),
		w.get_stockpile(0), w.get_stockpile(3),
		_check(w.get_stockpile(0) < 5 and w.get_stockpile(3) == 42, "sawmill idle on empty"),
	])


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
