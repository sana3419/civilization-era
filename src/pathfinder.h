#pragma once

#include "game_map.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <vector>

namespace cive {

// 网格 A*：8 邻接，整数代价 ×10，generation 标记避免每次清表。
// 少量单位/精确路径用；大军团走 FlowField。
class Pathfinder : public godot::RefCounted {
    GDCLASS(Pathfinder, godot::RefCounted)

    godot::Ref<GameMap> map;

    std::vector<uint32_t> g_cost;
    std::vector<int32_t> came_from;
    std::vector<uint32_t> visit_gen;
    uint32_t generation = 0;

public:
    void set_map(const godot::Ref<GameMap> &p_map);
    // 返回格子坐标序列（含起终点）；失败返回空数组
    godot::PackedVector2Array find_path(godot::Vector2i p_from, godot::Vector2i p_to, int p_max_explored);

protected:
    static void _bind_methods();
};

} // namespace cive
