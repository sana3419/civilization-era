#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cstdint>
#include <vector>

namespace cive {

// 第零阶段压测用模拟世界：SoA 布局、均匀网格碰撞、分块多线程、确定性。
// 玩法无关，但数据通路（tick → render buffer 整块上传）即未来正式架构。
class SimWorld : public godot::RefCounted {
    GDCLASS(SimWorld, godot::RefCounted)

    int unit_count = 0;
    float world_size = 16384.0f;
    int thread_count = 1;
    uint64_t tick_index = 0;

    static constexpr float UNIT_RADIUS = 6.0f;
    static constexpr float UNIT_SPEED = 60.0f;
    static constexpr float CELL_SIZE = 32.0f;
    static constexpr int MAX_NEIGHBORS = 8;

    // SoA 单位数据
    std::vector<float> pos_x, pos_y;
    std::vector<float> vel_x, vel_y;
    std::vector<float> way_x, way_y;
    std::vector<float> new_x, new_y; // 分离阶段双缓冲，保证并行确定性
    std::vector<uint32_t> rng_state;

    // 均匀网格（每 tick 计数排序重建）
    int grid_dim = 0;
    std::vector<uint32_t> cell_of;
    std::vector<uint32_t> cell_starts; // grid_dim*grid_dim + 1
    std::vector<uint32_t> cell_entries;

    godot::PackedFloat32Array render_buffer;

    void move_range(int p_begin, int p_end, float p_dt);
    void separate_range(int p_begin, int p_end);
    void build_grid();

public:
    void setup(int p_count, float p_world_size, int p_seed, int p_threads);
    void tick(float p_dt);
    void write_render_buffer();
    godot::PackedFloat32Array get_render_buffer() const { return render_buffer; }
    int64_t state_hash() const;
    int get_unit_count() const { return unit_count; }

protected:
    static void _bind_methods();
};

} // namespace cive
