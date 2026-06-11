# 第零阶段 headless 压测：godot --headless --path game -s bench/bench_sim.gd
# 测：GDScript↔C++ 边界成本、10k 单位 tick 耗时（1/2/6 线程）、确定性、buffer 写出耗时
extends SceneTree

const N := 10000
const WORLD := 16384.0
const LOOPS := 1000000


func _init() -> void:
	print("=== CivEra Phase-0 headless bench ===")
	var core := SimCore.new()
	print("extension: ", core.get_version())

	_bench_boundary(core)
	_bench_determinism()
	_bench_tick()
	_bench_buffer()

	print("=== done ===")
	quit()


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
	var same_seed_ok := hashes[0] == hashes[1]
	var thread_inv_ok := hashes[0] == hashes[2]
	print("determinism: same-seed %s | thread-count-invariant %s (hash %d)" % [
		"PASS" if same_seed_ok else "FAIL",
		"PASS" if thread_inv_ok else "FAIL",
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
		w.write_render_buffer()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 300.0
	var buf := w.get_render_buffer()
	print("write_render_buffer %d units: %.3f ms (%d floats)" % [N, ms, buf.size()])
