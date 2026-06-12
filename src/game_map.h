#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cstdint>
#include <vector>

namespace cive {

// 地形 ID（渲染端 TileSet 槽位与此对应）
enum ResourceType : uint8_t {
    RES_WOOD = 0,
    RES_STONE = 1,
    RES_FOOD = 2,
    RES_COUNT = 3,
};

enum Terrain : uint8_t {
    T_DEEP_WATER = 0,
    T_WATER = 1,
    T_PLAINS = 2,
    T_GRASS = 3,
    T_FOREST = 4,
    T_DENSE_FOREST = 5,
    T_HILLS = 6,
    T_MOUNTAIN = 7,
    T_DESERT = 8,
    T_SWAMP = 9,
    T_SNOW = 10,
    T_COUNT = 11,
};

class GameMap : public godot::RefCounted {
    GDCLASS(GameMap, godot::RefCounted)

    int dim = 0;
    uint32_t seed = 0;
    std::vector<uint8_t> terrain;
    std::vector<uint16_t> resource_amount; // 每格剩余资源量
    godot::PackedInt32Array terrain_events; // 本帧地形变化格（瞬态，渲染刷新用）

public:
    void generate(int p_dim, int p_seed);

    int get_dim() const { return dim; }
    int get_terrain(int p_cx, int p_cy) const;
    godot::PackedByteArray get_terrain_buffer() const;

    bool is_passable(int p_cx, int p_cy) const;
    // 移动代价 ×10 定点（平原 10 = 1.0），不可通行 = 0
    int move_cost(int p_cx, int p_cy) const;

    godot::PackedByteArray save_state() const;
    bool load_state(const godot::PackedByteArray &p_data);

    int get_resource_amount(int p_cx, int p_cy) const;

    // C++ 热路径
    inline uint8_t terrain_at(int p_cx, int p_cy) const {
        return terrain[size_t(p_cy) * dim + p_cx];
    }
    inline uint16_t resource_at(size_t p_cell) const { return resource_amount[p_cell]; }
    // 从格子取走至多 p_amount，返回实际取得；枯竭森林退化为草地
    int take_resource(size_t p_cell, int p_amount);
    godot::PackedInt32Array take_terrain_events(); // 取走并清空
    // GDScript 包装（bench/调试用）：导出 API 必须有越界守卫
    int take_resource_at(int p_cell, int p_amount) {
        if (p_cell < 0 || size_t(p_cell) >= resource_amount.size() || p_amount < 0) {
            return 0;
        }
        return take_resource(size_t(p_cell), p_amount);
    }
    static int terrain_move_cost(uint8_t p_t);
    // 地形产出的资源类型（RES_*），-1 = 无
    static int terrain_resource(uint8_t p_t);

protected:
    static void _bind_methods();
};

} // namespace cive
