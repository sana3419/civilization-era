#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstdint>
#include <vector>

namespace cive {

// 地形 ID（渲染端 TileSet 槽位与此对应）
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

    // C++ 热路径
    inline uint8_t terrain_at(int p_cx, int p_cy) const {
        return terrain[size_t(p_cy) * dim + p_cx];
    }
    static int terrain_move_cost(uint8_t p_t);

protected:
    static void _bind_methods();
};

} // namespace cive
