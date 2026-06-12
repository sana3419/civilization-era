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
    U_ATTACK = 5, // 追击 attack_target 并近战
    U_FLEE = 6, // 士气崩溃，逃向出生点，恢复后转 IDLE
    U_GARRISON = 7, // 驻守石墙顶（防御×5、射程+2格），不移动
    U_REPAIR = 8, // 工人修理受损建筑（贴近后 12HP/s）
};

enum UnitType : uint8_t {
    UT_WORKER = 0,
    UT_MILITIA = 1, // 民兵
    UT_BANDIT = 2, // 土匪
    UT_ARCHER = 3, // 弓箭手（远程）
    UT_CAVALRY = 4, // 轻骑兵
    UT_SPEARMAN = 5, // 长枪兵（反骑兵）
    UT_RAM = 6, // 攻城槌：只攻建筑（城门×3.0），无士气/索敌
    UT_CATAPULT = 7, // 投石车：远程只攻建筑（城墙×1.5）
    UT_COUNT = 8,
};

struct UnitStats {
    float max_hp;
    float damage;
    float attack_range; // px
    float attack_interval; // 秒
    float aggro_range; // px，0 = 不主动索敌
    float speed; // px/s
    float charge; // 冲锋伤害系数（×阵型冲锋系数）
};

enum Formation : uint8_t {
    F_NONE = 0, // 无阵型（默认）
    F_LINE = 1, // 横线阵
    F_COLUMN = 2, // 纵队
    F_SQUARE = 3, // 方阵
    F_WEDGE = 4, // 锥形阵
    F_SHIELD = 5, // 盾墙
    F_CIRCLE = 6, // 圆阵（方环近似）
    F_SKIRMISH = 7, // 散兵线
    F_CRESCENT = 8, // 新月阵
    F_COUNT = 9,
};

enum BuildingType : uint8_t {
    B_CAMP = 0, // 营地：万能存储点
    B_LUMBER = 1, // 伐木场：木材存储点
    B_QUARRY = 2, // 采石场：石料存储点
    B_FARM = 3, // 农田：食物存储点
    B_HOUSE = 4, // 房屋（人口，暂占位）
    B_STOREHOUSE = 5, // 仓库：万能存储点
    B_BARRACKS = 6, // 兵营：训练民兵
    B_ARCHERY = 7, // 射箭场：训练弓箭手
    B_STABLE = 8, // 马厩：训练骑兵
    B_TOWER = 9, // 箭塔：自动攻击范围内敌人
    B_PALISADE = 10, // 木栅栏：1×1 线性障碍
    B_GATE = 11, // 木门：1×1 可开关；开 = 己方通行，敌方永远阻挡（需破坏）
    B_SWORKSHOP = 12, // 攻城工坊：制造攻城槌/投石车
    B_STONE_WALL = 13, // 石墙：1×1，可驻军 1 单位（墙上状态）
    B_STONE_GATE = 14, // 石门：1×1 可开关，同木门规则
    B_COUNT = 15,
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
    std::vector<float> timer; // 采集计时 / 攻击冷却（互斥使用）
    std::vector<float> slot_x, slot_y; // 编队到达槽位 / 追击点（世界坐标）
    std::vector<uint8_t> u_type; // UT_*
    std::vector<uint8_t> faction; // 0 = 玩家，1 = 土匪
    std::vector<uint8_t> alive;
    std::vector<float> hp;
    std::vector<int32_t> attack_target; // 单位 id，-1 = 无
    std::vector<float> morale; // 0-100，基线 60
    std::vector<float> home_x, home_y; // 出生点（溃逃目的地）
    std::vector<uint8_t> formation; // F_*
    std::vector<float> move_streak; // 持续全速移动秒数（冲锋动量）

    // 本帧攻击事件（渲染特效用，瞬态不序列化）：
    // [attacker, target, ...]，attacker/target < 0 表示建筑 -(index+1)
    godot::PackedInt32Array attack_events;
    godot::PackedInt32Array building_events; // 本帧被摧毁的建筑 index（瞬态）
    godot::PackedInt32Array death_events; // 本帧阵亡 [type, faction, x, y, ...]（死亡反馈）

    // 建筑（序列化范围）：占地 footprint×footprint，锚点为左上格
    std::vector<uint8_t> b_type;
    std::vector<int32_t> b_cell;
    std::vector<float> b_hp;
    std::vector<float> b_timer; // 箭塔射击冷却
    std::vector<uint8_t> b_state; // 门：1 = 开（默认），0 = 关；其余建筑未用

    int64_t stockpile[RES_COUNT] = { 0, 0, 0 };
    int32_t dropoff_cell = -1;

    // 运行时（不序列化）
    std::vector<float> new_x, new_y;
    std::vector<float> prev_x, prev_y; // 渲染插值
    std::vector<int32_t> occupied; // 建筑占地：0 = 空，否则建筑 index+1（由 b_* 重建）
    std::vector<int32_t> b_garrison; // 各建筑驻军单位 id，-1 = 空（由单位状态重建）
    std::vector<const FlowField *> unit_field; // 本 tick 各单位用的流场
    godot::Ref<GameMap> map;
    // 流场按 (目的格, 阵营) 缓存：城门通行性按阵营区分（开门只放行己方）
    std::unordered_map<int64_t, godot::Ref<FlowField>> field_cache;
    bool field_cache_dirty = false; // pass 内不可清缓存（unit_field 持裸指针），tick 开头统一清
    std::unique_ptr<ThreadPool> pool;
    godot::Ref<FlowField> flow_field; // 压测：外部整场

    int grid_dim = 0;
    std::vector<uint32_t> cell_of;
    std::vector<uint32_t> cell_starts;
    std::vector<uint32_t> cell_entries;

    godot::PackedFloat32Array render_buffer;

    void resize_arrays(int p_count);
    const FlowField *ensure_field(int32_t p_goal, uint8_t p_faction); // 仅串行 pass 调用
    void logic_pass(float p_dt); // 串行：状态机/采集/入库
    void move_range(int p_begin, int p_end, float p_dt);
    void separate_range(int p_begin, int p_end);
    void build_grid();
    int32_t cell_of_pos(float p_x, float p_y) const;
    // 真地形碰撞：不可通行地形/建筑占地 = 实体（开门放行己方）。
    // worker 线程只读共享状态，可并行调用。
    bool cell_blocked_for(int p_cx, int p_cy, uint8_t p_faction) const;
    int32_t find_nearest_resource(int32_t p_from_cell, int p_res_type) const;
    bool cell_adjacent(int32_t p_a, int32_t p_b) const;
    int32_t nearest_dropoff(int p_res_type, int32_t p_from_cell) const;
    void mark_occupancy(int p_b_index, uint8_t p_value);
    int32_t find_nearest_enemy(int p_unit, float p_range) const; // 用上一 tick 的空间网格
    void on_unit_killed(int p_victim); // 周边士气结算
    int32_t find_nearest_blocking_building(int p_unit) const; // 攻城目标：城门优先，串行调用
    void destroy_building(int p_b);
    void release_garrison(int p_unit); // 离墙：清驻军占位（换命令/死亡/溃逃时调用）
    void splash_damage(int p_attacker, float p_x, float p_y); // 投石车溅射（串行调用）
    godot::Vector2 find_free_spot(godot::Vector2 p_pos, uint8_t p_faction) const; // 出生点防实体格

public:
    void setup(int p_count, float p_world_size, int p_seed, int p_threads);
    void set_map(const godot::Ref<GameMap> &p_map);
    void set_flow_field(const godot::Ref<FlowField> &p_field) { flow_field = p_field; }
    void set_dropoff(godot::Vector2 p_world_pos);

    int spawn_workers(int p_count, godot::Vector2 p_world_pos);
    int spawn_units(int p_type, int p_count, godot::Vector2 p_world_pos, int p_faction);
    bool try_spend(int p_wood, int p_stone, int p_food); // 资源足够则扣除
    void debug_add_resources(int p_wood, int p_stone, int p_food); // 测试/作弊
    void command_move(const godot::PackedInt32Array &p_ids, godot::Vector2 p_world_pos);
    void command_gather(const godot::PackedInt32Array &p_ids, godot::Vector2 p_world_pos);
    void command_attack(const godot::PackedInt32Array &p_ids, int p_target_id);
    void command_attack_building(const godot::PackedInt32Array &p_ids, int p_building);
    bool command_garrison(const godot::PackedInt32Array &p_ids, godot::Vector2 p_world_pos);
    bool command_repair(const godot::PackedInt32Array &p_ids, godot::Vector2 p_world_pos);
    void despawn_unit(int p_id); // 静默移除（无士气涟漪），槽位可复用
    int get_unit_faction(int p_id) const;
    static float unit_max_hp(int p_type); // STATS 表单一来源，GDScript 查询用
    void command_set_formation(const godot::PackedInt32Array &p_ids, int p_formation);
    int get_unit_formation(int p_id) const;
    int get_unit_at(godot::Vector2 p_world_pos, float p_radius, int p_faction) const; // faction -1 = 任意

    bool can_place_building(int p_type, godot::Vector2 p_world_pos) const;
    bool place_building(int p_type, godot::Vector2 p_world_pos);
    godot::PackedInt32Array get_buildings() const; // 扁平 [type, cell, ...]（含已摧毁，hp<=0）
    float get_building_hp(int p_index) const;
    int get_building_state(int p_index) const;
    int get_building_at(godot::Vector2 p_world_pos) const; // 含占地判定，无 → -1
    bool toggle_gate(int p_index); // 开/关城门（按索引，UI 面板用）
    bool toggle_gate_at(godot::Vector2 p_world_pos); // 开/关己方城门
    void command_stop(const godot::PackedInt32Array &p_ids); // 停止：清命令转 IDLE
    godot::PackedInt32Array take_building_events(); // 取走并清空（本帧摧毁列表）
    void debug_damage_building(int p_index, float p_damage); // 测试用
    static godot::Vector2i building_cost(int p_type); // (木材, 石料)
    static int building_footprint(int p_type); // 占地边长（格）
    static float building_max_hp_of(int p_type); // 血条/修理 UI 用

    godot::PackedInt32Array get_units_in_rect(godot::Vector2 p_min, godot::Vector2 p_max) const;
    godot::PackedVector2Array get_unit_positions(const godot::PackedInt32Array &p_ids) const;
    int get_unit_state(int p_id) const;
    int get_unit_carry(int p_id) const;
    int get_unit_type(int p_id) const;
    float get_unit_hp(int p_id) const;
    bool is_unit_alive(int p_id) const;
    int count_alive(int p_faction) const;
    int count_state(int p_state, int p_faction) const;
    float get_unit_morale(int p_id) const;
    int64_t get_stockpile(int p_type) const;
    godot::PackedInt32Array take_attack_events(); // 取走并清空
    godot::PackedInt32Array take_death_events();

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
