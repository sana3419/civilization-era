#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <vector>

namespace cive {

// 流场：一次 generate 服务任意数量单位。第零阶段测全图生成耗时 + 单位跟随成本。
// 正式版按 64×64 Chunk 分块缓存、跨 tick 摊销生成（PLAN.md 1.3）。
class FlowField : public godot::RefCounted {
    GDCLASS(FlowField, godot::RefCounted)

    int dim = 0;
    float cell_size = 32.0f;
    std::vector<uint8_t> terrain_cost; // 1..15 移动代价，255 = 不可通行
    std::vector<uint32_t> integration;
    std::vector<float> dir_x, dir_y; // 每格归一化流向，0,0 = 不可达/目标

public:
    void setup(int p_dim, float p_cell_size, int p_seed, float p_blocked_ratio);
    void setup_from_map(const class GameMap *p_map, float p_cell_size);
    void generate(int p_target_cx, int p_target_cy);

    // 叠加动态障碍（建筑占地），generate 前调用
    inline void set_blocked(int p_cx, int p_cy) {
        if (p_cx >= 0 && p_cx < dim && p_cy >= 0 && p_cy < dim) {
            terrain_cost[size_t(p_cy) * dim + p_cx] = 255;
        }
    }
    godot::Vector2 sample(godot::Vector2 p_world_pos) const;
    int get_dim() const { return dim; }

    // C++ 热路径直采（SimWorld 移动阶段用，绕过 Variant）
    inline void sample_raw(float p_wx, float p_wy, float &r_dx, float &r_dy) const {
        const float inv = 1.0f / cell_size;
        int cx = int(p_wx * inv);
        int cy = int(p_wy * inv);
        cx = cx < 0 ? 0 : (cx >= dim ? dim - 1 : cx);
        cy = cy < 0 ? 0 : (cy >= dim ? dim - 1 : cy);
        const size_t c = size_t(cy) * dim + cx;
        r_dx = dir_x[c];
        r_dy = dir_y[c];
    }

protected:
    static void _bind_methods();
};

} // namespace cive
