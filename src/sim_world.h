#pragma once

#include "flow_field.h"
#include "game_map.h"
#include "thread_pool.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

namespace cive {

enum UnitState : uint8_t {
    U_WANDER = 0, // 压测模式：随机路径点游走
    U_IDLE = 1,
    U_MOVING = 2, // 移向 goal_cell + 阵型槽位，到达转 IDLE
    U_GATHER = 3, // 移向 target_cell 资源格并采集
    U_RETURN = 4, // 满载运回最近有效存储点
};

enum BuildingType : uint8_t {
    B_CAMP = 0, // 营地：万能存储点
    B_LUMBER = 1, // 伐木场：木材存储点
    B_QUARRY = 2, // 采石场：石料存储点
    B_FARM = 3, // 农田：食物存储点
    B_HOUSE = 4, // 房屋（人口，暂占位）
    B_STOREHOUSE = 5, // 仓库：万能存储点
    B_COUNT = 6,
};

// 模拟世界：SoA、确定性、串行状态机 + 并行移动/分离。
// 移动统一走流场缓存（同目的地共享一张场）。
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
    static constexpr float GATHER_TIME = 2.0f; // 秒/次
    static constexpr int GATHER_YIELD = 10; // 每次采得 = 满载
    static constexpr int FIELD_CACHE_MAX = 32;

    // SoA 单位数据（序列化范围）
    std::vector<float> pos_x, pos_y;
    std::vector<float> vel_x, vel_y;
    std::vector<float> way_x, way_y;
    std::vector<uint32_t> rng_state;
    std::vector<uint8_t> state;
    std::vector<int32_t> goal_cell; // 当前移动目的格，-1 = 无
    std::vector<int32_t> target_cell; // 采集资源格，-1 = 无
    std::vector<uint8_t> carry; // 携带量
    std::vector<uint8_t> carry_type; // RES_*
    std::vector<float> timer; // 采集计时
    std::vector<float> slot_x, slot_y; // 编队到达槽位（世界坐标）

    // 建筑（序列化范围）：2×2 占地，锚点为左上格
    std::vector<uint8_t> b_type;
    std::vector<int32_t> b_cell;

    int64_t stockpile[RES_COUNT] = { 0, 0, 0 };
    int32_t dropoff_cell = -1;

    // 运行时（不序列化）
    std::vector<float> new_x, new_y;
    std::vector<float> prev_x, prev_y; // 渲染插值
    std::vector<uint8_t> occupied; // 建筑占地位图（由 b_* 重建）
    std::vector<const FlowField *> unit_field; // 本 tick 各单位用的流场
    godot::Ref<GameMap> map;
    std::unordered_map<int32_t, godot::Ref<FlowField>> field_cache;
    std::unique_ptr<ThreadPool> pool;
    godot::Ref<FlowField> flow_field; // 压测：外部整场

    int grid_dim = 0;
    std::vector<uint32_t> cell_of;
    std::vector<uint32_t> cell_starts;
    std::vector<uint32_t> cell_entries;

    godot::PackedFloat32Array render_buffer;

    void resize_arrays(int p_count);
    const FlowField *ensure_field(int32_t p_goal); // 仅串行 pass 调用
    void logic_pass(float p_dt); // 串行：状态机/采集/入库
    void move_range(int p_begin, int p_end, float p_dt);
    void separate_range(int p_begin, int p_end);
    void build_grid();
    int32_t cell_of_pos(float p_x, float p_y) const;
    int32_t find_nearest_resource(int32_t p_from_cell, int p_res_type) const;
    bool cell_adjacent(int32_t p_a, int32_t p_b) const;
    int32_t nearest_dropoff(int p_res_type, int32_t p_from_cell) const;
    void mark_occupancy(int p_b_index, uint8_t p_value);

public:
    void setup(int p_count, float p_world_size, int p_seed, int p_threads);
    void set_map(const godot::Ref<GameMap> &p_map);
    void set_flow_field(const godot::Ref<FlowField> &p_field) { flow_field = p_field; }
    void set_dropoff(godot::Vector2 p_world_pos);

    int spawn_workers(int p_count, godot::Vector2 p_world_pos);
    void command_move(const godot::PackedInt32Array &p_ids, godot::Vector2 p_world_pos);
    void command_gather(const godot::PackedInt32Array &p_ids, godot::Vector2 p_world_pos);

    bool can_place_building(int p_type, godot::Vector2 p_world_pos) const;
    bool place_building(int p_type, godot::Vector2 p_world_pos);
    godot::PackedInt32Array get_buildings() const; // 扁平 [type, cell, ...]
    static godot::Vector2i building_cost(int p_type); // (木材, 石料)

    godot::PackedInt32Array get_units_in_rect(godot::Vector2 p_min, godot::Vector2 p_max) const;
    godot::PackedVector2Array get_unit_positions(const godot::PackedInt32Array &p_ids) const;
    int get_unit_state(int p_id) const;
    int get_unit_carry(int p_id) const;
    int64_t get_stockpile(int p_type) const;

    void tick(float p_dt);
    void write_render_buffer(float p_alpha); // p_alpha: 上 tick→本 tick 插值系数
    godot::PackedFloat32Array get_render_buffer() const { return render_buffer; }
    int64_t state_hash() const;
    int get_unit_count() const { return unit_count; }

    godot::PackedByteArray save_state() const;
    bool load_state(const godot::PackedByteArray &p_data);

protected:
    static void _bind_methods();
};

} // namespace cive
