#include "sim_world.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

namespace cive {

static inline uint32_t xorshift32(uint32_t &s) {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

static inline float rand01(uint32_t &s) {
    return float(xorshift32(s) >> 8) * (1.0f / 16777216.0f);
}

// 单位属性表（设计文档数值；攻击距离为中心距，近战 = 范围 + 双方半径）
static constexpr UnitStats STATS[UT_COUNT] = {
    { 100.0f, 2.0f, 20.0f, 1.0f, 0.0f }, // 工人：不主动索敌
    { 60.0f, 8.0f, 20.0f, 1.0f, 160.0f }, // 民兵
    { 60.0f, 8.0f, 20.0f, 1.0f, 160.0f }, // 土匪
    { 50.0f, 10.0f, 200.0f, 1.5f, 220.0f }, // 弓箭手：远程
};

// 兵种克制系数 [攻击方][防守方]（设计文档克制表：轻步兵→弓兵 ×1.2，弓兵→轻步兵 ×1.1）
static constexpr float COUNTER[UT_COUNT][UT_COUNT] = {
    { 1.0f, 1.0f, 1.0f, 1.0f }, // 工人
    { 1.0f, 1.0f, 1.0f, 1.2f }, // 民兵
    { 1.0f, 1.0f, 1.0f, 1.2f }, // 土匪
    { 1.1f, 1.1f, 1.1f, 1.0f }, // 弓手
};

void SimWorld::resize_arrays(int p_count) {
    pos_x.resize(p_count);
    pos_y.resize(p_count);
    vel_x.resize(p_count, 0.0f);
    vel_y.resize(p_count, 0.0f);
    way_x.resize(p_count, 0.0f);
    way_y.resize(p_count, 0.0f);
    rng_state.resize(p_count, 1u);
    state.resize(p_count, U_IDLE);
    goal_cell.resize(p_count, -1);
    target_cell.resize(p_count, -1);
    carry.resize(p_count, 0);
    carry_type.resize(p_count, 0);
    timer.resize(p_count, 0.0f);
    slot_x.resize(p_count, 0.0f);
    slot_y.resize(p_count, 0.0f);
    u_type.resize(p_count, UT_WORKER);
    faction.resize(p_count, 0);
    alive.resize(p_count, 1);
    hp.resize(p_count, STATS[UT_WORKER].max_hp);
    attack_target.resize(p_count, -1);

    new_x.resize(p_count);
    new_y.resize(p_count);
    prev_x.resize(p_count);
    prev_y.resize(p_count);
    unit_field.resize(p_count, nullptr);
    cell_of.resize(p_count);
    cell_entries.resize(p_count);
    render_buffer.resize(int64_t(p_count) * 12);
}

void SimWorld::setup(int p_count, float p_world_size, int p_seed, int p_threads) {
    unit_count = p_count;
    world_size = p_world_size;
    thread_count = std::max(1, p_threads);
    tick_index = 0;
    if (!pool || pool->worker_count() != thread_count) {
        pool = std::make_unique<ThreadPool>(thread_count);
    }

    grid_dim = std::max(1, int(world_size / CELL_SIZE));
    resize_arrays(unit_count);
    cell_starts.assign(size_t(grid_dim) * grid_dim + 1, 0);
    occupied.assign(size_t(grid_dim) * grid_dim, 0);
    std::fill(stockpile, stockpile + RES_COUNT, 0);
    dropoff_cell = -1;
    b_type.clear();
    b_cell.clear();
    field_cache.clear();

    // 压测模式出生：中心 1/4 区域随机（rng 采样顺序不可变，golden 依赖）
    const float center = world_size * 0.5f;
    const float half = world_size * 0.125f;
    for (int i = 0; i < unit_count; i++) {
        uint32_t s = uint32_t(p_seed) * 2654435761u + uint32_t(i) * 40503u + 1u;
        xorshift32(s);
        rng_state[i] = s;
        pos_x[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
        pos_y[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
        way_x[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
        way_y[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
        state[i] = U_WANDER;
        prev_x[i] = pos_x[i];
        prev_y[i] = pos_y[i];
    }
}

void SimWorld::set_map(const Ref<GameMap> &p_map) {
    map = p_map;
    if (map.is_valid()) {
        world_size = map->get_dim() * CELL_SIZE;
        grid_dim = map->get_dim();
        cell_starts.assign(size_t(grid_dim) * grid_dim + 1, 0);
        occupied.assign(size_t(grid_dim) * grid_dim, 0);
    }
    field_cache.clear();
}

int32_t SimWorld::cell_of_pos(float p_x, float p_y) const {
    const float inv = 1.0f / CELL_SIZE;
    const int cx = std::clamp(int(p_x * inv), 0, grid_dim - 1);
    const int cy = std::clamp(int(p_y * inv), 0, grid_dim - 1);
    return int32_t(cy) * grid_dim + cx;
}

bool SimWorld::cell_adjacent(int32_t p_a, int32_t p_b) const {
    if (p_a < 0 || p_b < 0) {
        return false;
    }
    const int ax = p_a % grid_dim, ay = p_a / grid_dim;
    const int bx = p_b % grid_dim, by = p_b / grid_dim;
    return std::abs(ax - bx) <= 1 && std::abs(ay - by) <= 1;
}

void SimWorld::set_dropoff(Vector2 p_world_pos) {
    dropoff_cell = cell_of_pos(p_world_pos.x, p_world_pos.y);
}

int SimWorld::spawn_workers(int p_count, Vector2 p_world_pos) {
    return spawn_units(UT_WORKER, p_count, p_world_pos, 0);
}

int SimWorld::spawn_units(int p_type, int p_count, Vector2 p_world_pos, int p_faction) {
    const int first = unit_count;
    unit_count += p_count;
    resize_arrays(unit_count);
    const uint8_t type = uint8_t(std::clamp(p_type, 0, int(UT_COUNT) - 1));
    // 方阵排布（确定性整数，无 rng/三角函数）
    const int cols = std::max(1, int(std::ceil(std::sqrt(float(p_count)))));
    for (int k = 0; k < p_count; k++) {
        const int i = first + k;
        pos_x[i] = p_world_pos.x + float(k % cols - cols / 2) * 16.0f;
        pos_y[i] = p_world_pos.y + float(k / cols - cols / 2) * 16.0f;
        vel_x[i] = vel_y[i] = 0.0f;
        rng_state[i] = uint32_t(i) * 2654435761u + 1u;
        state[i] = U_IDLE;
        goal_cell[i] = target_cell[i] = -1;
        carry[i] = 0;
        carry_type[i] = 0;
        timer[i] = 0.0f;
        u_type[i] = type;
        faction[i] = uint8_t(p_faction);
        alive[i] = 1;
        hp[i] = STATS[type].max_hp;
        attack_target[i] = -1;
        prev_x[i] = pos_x[i];
        prev_y[i] = pos_y[i];
    }
    return first;
}

bool SimWorld::try_spend(int p_wood, int p_stone, int p_food) {
    if (stockpile[RES_WOOD] < p_wood || stockpile[RES_STONE] < p_stone ||
            stockpile[RES_FOOD] < p_food) {
        return false;
    }
    stockpile[RES_WOOD] -= p_wood;
    stockpile[RES_STONE] -= p_stone;
    stockpile[RES_FOOD] -= p_food;
    return true;
}

int32_t SimWorld::find_nearest_enemy(int p_unit, float p_range) const {
    // 用上一 tick 的空间网格（确定性：与本 tick 写入无关）
    const float px = pos_x[p_unit], py = pos_y[p_unit];
    const int cr = int(p_range / CELL_SIZE) + 1;
    const int cx = std::clamp(int(px / CELL_SIZE), 0, grid_dim - 1);
    const int cy = std::clamp(int(py / CELL_SIZE), 0, grid_dim - 1);
    int32_t best = -1;
    float best_d2 = p_range * p_range;
    for (int gy = std::max(0, cy - cr); gy <= std::min(grid_dim - 1, cy + cr); gy++) {
        for (int gx = std::max(0, cx - cr); gx <= std::min(grid_dim - 1, cx + cr); gx++) {
            const uint32_t cell = uint32_t(gy) * grid_dim + gx;
            for (uint32_t e = cell_starts[cell]; e < cell_starts[cell + 1]; e++) {
                const int32_t j = int32_t(cell_entries[e]);
                if (!alive[j] || faction[j] == faction[p_unit]) {
                    continue;
                }
                const float dx = pos_x[j] - px;
                const float dy = pos_y[j] - py;
                const float d2 = dx * dx + dy * dy;
                if (d2 < best_d2 || (d2 == best_d2 && (best < 0 || j < best))) {
                    best_d2 = d2;
                    best = j;
                }
            }
        }
    }
    return best;
}

const FlowField *SimWorld::ensure_field(int32_t p_goal) {
    auto it = field_cache.find(p_goal);
    if (it != field_cache.end()) {
        return it->second.ptr();
    }
    Ref<FlowField> ff;
    ff.instantiate();
    ff->setup_from_map(map.ptr(), CELL_SIZE);
    for (size_t b = 0; b < b_cell.size(); b++) { // 建筑占地阻挡
        const int bx = b_cell[b] % grid_dim, by = b_cell[b] / grid_dim;
        for (int oy = 0; oy < 2; oy++) {
            for (int ox = 0; ox < 2; ox++) {
                ff->set_blocked(bx + ox, by + oy);
            }
        }
    }
    ff->generate(p_goal % grid_dim, p_goal / grid_dim);
    field_cache[p_goal] = ff;
    return ff.ptr();
}

void SimWorld::command_move(const PackedInt32Array &p_ids, Vector2 p_world_pos) {
    const int32_t goal = cell_of_pos(p_world_pos.x, p_world_pos.y);
    // 方阵阵型槽位：按选中顺序排格，间距 20px，整体居中于目标点
    const int n = p_ids.size();
    const int cols = std::max(1, int(std::ceil(std::sqrt(float(n)))));
    const float spacing = 20.0f;
    for (int k = 0; k < n; k++) {
        const int i = p_ids[k];
        if (i < 0 || i >= unit_count || state[i] == U_WANDER) {
            continue;
        }
        state[i] = U_MOVING;
        goal_cell[i] = goal;
        slot_x[i] = p_world_pos.x + (float(k % cols) - float(cols - 1) * 0.5f) * spacing;
        slot_y[i] = p_world_pos.y + (float(k / cols) - float((n - 1) / cols) * 0.5f) * spacing;
        timer[i] = 0.0f;
    }
}

void SimWorld::command_gather(const PackedInt32Array &p_ids, Vector2 p_world_pos) {
    if (map.is_null()) {
        return;
    }
    const int32_t cell = cell_of_pos(p_world_pos.x, p_world_pos.y);
    const int res = GameMap::terrain_resource(map->terrain_at(cell % grid_dim, cell / grid_dim));
    if (res < 0) {
        command_move(p_ids, p_world_pos);
        return;
    }
    for (int k = 0; k < p_ids.size(); k++) {
        const int i = p_ids[k];
        if (i < 0 || i >= unit_count || state[i] == U_WANDER) {
            continue;
        }
        state[i] = U_GATHER;
        target_cell[i] = cell;
        carry_type[i] = uint8_t(res);
        timer[i] = 0.0f;
    }
}

int32_t SimWorld::find_nearest_resource(int32_t p_from_cell, int p_res_type) const {
    const int fx = p_from_cell % grid_dim, fy = p_from_cell / grid_dim;
    for (int r = 0; r <= 48; r++) {
        for (int oy = -r; oy <= r; oy++) {
            for (int ox = -r; ox <= r; ox++) {
                if (std::max(std::abs(ox), std::abs(oy)) != r) {
                    continue; // 只扫环边，由近及远确定性顺序
                }
                const int nx = fx + ox, ny = fy + oy;
                if (nx < 0 || nx >= grid_dim || ny < 0 || ny >= grid_dim) {
                    continue;
                }
                const size_t c = size_t(ny) * grid_dim + nx;
                if (GameMap::terrain_resource(map->terrain_at(nx, ny)) == p_res_type &&
                        map->resource_at(c) > 0) {
                    return int32_t(c);
                }
            }
        }
    }
    return -1;
}

// 串行状态机：到达判定、采集、入库、重定目标。每 tick 一次，按单位序号顺序 → 确定性。
void SimWorld::logic_pass(float p_dt) {
    if (map.is_null()) {
        return;
    }
    for (int i = 0; i < unit_count; i++) {
        unit_field[i] = nullptr;
        if (!alive[i]) {
            continue;
        }
        // 自动索敌（错峰扫描，1/5 单位每 tick）
        const UnitStats &st = STATS[u_type[i]];
        if (st.aggro_range > 0.0f && attack_target[i] < 0 &&
                (state[i] == U_IDLE || state[i] == U_MOVING) &&
                (tick_index + uint64_t(i)) % 5 == 0) {
            const int32_t enemy = find_nearest_enemy(i, st.aggro_range);
            if (enemy >= 0) {
                attack_target[i] = enemy;
                state[i] = U_ATTACK;
                timer[i] = 0.0f;
            }
        }
        switch (state[i]) {
            case U_WANDER:
            case U_IDLE:
                break;

            case U_MOVING: {
                const float sdx = slot_x[i] - pos_x[i];
                const float sdy = slot_y[i] - pos_y[i];
                if (sdx * sdx + sdy * sdy < 100.0f) { // 到达阵型槽位
                    state[i] = U_IDLE;
                    break;
                }
                const int32_t cell = cell_of_pos(pos_x[i], pos_y[i]);
                const int cx = cell % grid_dim, cy = cell / grid_dim;
                const int gx = goal_cell[i] % grid_dim, gy = goal_cell[i] / grid_dim;
                if (std::max(std::abs(cx - gx), std::abs(cy - gy)) <= 3) {
                    break; // 近目标：unit_field 留空 → move_range 直线驶向槽位
                }
                const FlowField *ff = ensure_field(goal_cell[i]);
                float dx, dy;
                ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
                if (dx == 0.0f && dy == 0.0f) {
                    state[i] = U_IDLE; // 流场终点或不可达
                    break;
                }
                unit_field[i] = ff;
                break;
            }

            case U_GATHER: {
                if (target_cell[i] < 0 || map->resource_at(size_t(target_cell[i])) == 0) {
                    target_cell[i] = find_nearest_resource(
                            target_cell[i] >= 0 ? target_cell[i] : cell_of_pos(pos_x[i], pos_y[i]),
                            carry_type[i]);
                    timer[i] = 0.0f;
                    if (target_cell[i] < 0) {
                        state[i] = U_IDLE; // 周边资源枯竭
                        break;
                    }
                }
                const int32_t cell = cell_of_pos(pos_x[i], pos_y[i]);
                if (cell_adjacent(cell, target_cell[i]) || cell == target_cell[i]) {
                    timer[i] += p_dt;
                    if (timer[i] >= GATHER_TIME) {
                        timer[i] = 0.0f;
                        const int got = map->take_resource(size_t(target_cell[i]), GATHER_YIELD);
                        if (got > 0) {
                            carry[i] = uint8_t(got);
                            if (nearest_dropoff(carry_type[i], cell) < 0) { // 无存储点：就地入库
                                stockpile[carry_type[i]] += carry[i];
                                carry[i] = 0;
                            } else {
                                state[i] = U_RETURN;
                            }
                        }
                    }
                    break;
                }
                const FlowField *ff = ensure_field(target_cell[i]);
                float dx, dy;
                ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
                if (dx == 0.0f && dy == 0.0f) {
                    state[i] = U_IDLE; // 不可达
                    break;
                }
                unit_field[i] = ff;
                break;
            }

            case U_RETURN: {
                const int32_t cell = cell_of_pos(pos_x[i], pos_y[i]);
                const int32_t drop = nearest_dropoff(carry_type[i], cell);
                if (drop < 0) { // 存储点消失：就地入库防卡死
                    stockpile[carry_type[i]] += carry[i];
                    carry[i] = 0;
                    state[i] = U_IDLE;
                    break;
                }
                if (cell_adjacent(cell, drop) || cell == drop) {
                    stockpile[carry_type[i]] += carry[i];
                    carry[i] = 0;
                    state[i] = U_GATHER; // 回去继续采
                    break;
                }
                const FlowField *ff = ensure_field(drop);
                float dx, dy;
                ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
                if (dx == 0.0f && dy == 0.0f) { // 不可达：就地入库防卡死
                    stockpile[carry_type[i]] += carry[i];
                    carry[i] = 0;
                    state[i] = U_IDLE;
                    break;
                }
                unit_field[i] = ff;
                break;
            }

            case U_ATTACK: {
                const int32_t t = attack_target[i];
                if (t < 0 || !alive[t]) {
                    attack_target[i] = -1;
                    state[i] = U_IDLE; // 下次扫描重新索敌
                    break;
                }
                const float dx = pos_x[t] - pos_x[i];
                const float dy = pos_y[t] - pos_y[i];
                const float reach = st.attack_range + UNIT_RADIUS * 2.0f;
                if (dx * dx + dy * dy <= reach * reach) { // 攻击范围内：站定输出
                    timer[i] -= p_dt;
                    if (timer[i] <= 0.0f) {
                        timer[i] = st.attack_interval;
                        hp[t] -= st.damage * COUNTER[u_type[i]][u_type[t]];
                        attack_events.push_back(i);
                        attack_events.push_back(t);
                        if (hp[t] <= 0.0f) {
                            hp[t] = 0.0f;
                            alive[t] = 0;
                        }
                    }
                    break;
                }
                slot_x[i] = pos_x[t]; // 追击点 → move_range 直线驶向
                slot_y[i] = pos_y[t];
                break;
            }
        }
    }
}

void SimWorld::move_range(int p_begin, int p_end, float p_dt) {
    const float center = world_size * 0.5f;
    const float half = world_size * 0.125f;
    const bool bench_field = flow_field.is_valid();

    for (int i = p_begin; i < p_end; i++) {
        if (!alive[i]) {
            vel_x[i] = vel_y[i] = 0.0f;
            continue;
        }
        if (state[i] == U_WANDER) {
            if (bench_field) { // 压测：整场跟随
                float dx, dy;
                flow_field->sample_raw(pos_x[i], pos_y[i], dx, dy);
                vel_x[i] = dx * UNIT_SPEED;
                vel_y[i] = dy * UNIT_SPEED;
                pos_x[i] += vel_x[i] * p_dt;
                pos_y[i] += vel_y[i] * p_dt;
                continue;
            }
            float dx = way_x[i] - pos_x[i];
            float dy = way_y[i] - pos_y[i];
            const float d2 = dx * dx + dy * dy;
            if (d2 < 100.0f) {
                way_x[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
                way_y[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
                continue;
            }
            const float inv_d = 1.0f / std::sqrt(d2);
            vel_x[i] = dx * inv_d * UNIT_SPEED;
            vel_y[i] = dy * inv_d * UNIT_SPEED;
            pos_x[i] += vel_x[i] * p_dt;
            pos_y[i] += vel_y[i] * p_dt;
            continue;
        }

        const FlowField *ff = unit_field[i];
        float dx = 0.0f, dy = 0.0f;
        if (ff == nullptr) {
            if (state[i] == U_MOVING || state[i] == U_ATTACK) { // 直线驶向槽位/追击点
                const float sx = slot_x[i] - pos_x[i];
                const float sy = slot_y[i] - pos_y[i];
                const float d2 = sx * sx + sy * sy;
                if (d2 > 1e-4f) {
                    const float inv = 1.0f / std::sqrt(d2);
                    dx = sx * inv;
                    dy = sy * inv;
                }
            }
            if (dx == 0.0f && dy == 0.0f) {
                vel_x[i] = vel_y[i] = 0.0f;
                continue;
            }
        } else {
            ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
        }
        // 地形速度系数：cost 10 → 1.0，cost 25 → 0.4
        float mult = 1.0f;
        if (map.is_valid()) {
            const int32_t c = cell_of_pos(pos_x[i], pos_y[i]);
            const int mc = GameMap::terrain_move_cost(map->terrain_at(c % grid_dim, c / grid_dim));
            if (mc > 0) {
                mult = 10.0f / float(mc);
            }
        }
        vel_x[i] = dx * UNIT_SPEED * mult;
        vel_y[i] = dy * UNIT_SPEED * mult;
        pos_x[i] += vel_x[i] * p_dt;
        pos_y[i] += vel_y[i] * p_dt;
    }
}

void SimWorld::build_grid() {
    uint32_t *starts = cell_starts.data();
    std::memset(starts, 0, cell_starts.size() * sizeof(uint32_t));

    const float inv_cell = 1.0f / CELL_SIZE;
    for (int i = 0; i < unit_count; i++) {
        if (!alive[i]) {
            continue; // 尸体不进网格
        }
        int cx = std::clamp(int(pos_x[i] * inv_cell), 0, grid_dim - 1);
        int cy = std::clamp(int(pos_y[i] * inv_cell), 0, grid_dim - 1);
        cell_of[i] = uint32_t(cy) * grid_dim + cx;
        starts[cell_of[i] + 1]++;
    }
    const size_t n_cells = size_t(grid_dim) * grid_dim;
    for (size_t c = 0; c < n_cells; c++) {
        starts[c + 1] += starts[c];
    }
    std::vector<uint32_t> cursor(cell_starts.begin(), cell_starts.end() - 1);
    for (int i = 0; i < unit_count; i++) {
        if (!alive[i]) {
            continue;
        }
        cell_entries[cursor[cell_of[i]]++] = uint32_t(i);
    }
}

void SimWorld::separate_range(int p_begin, int p_end) {
    const float min_d = UNIT_RADIUS * 2.0f;
    const float min_d2 = min_d * min_d;
    const float inv_cell = 1.0f / CELL_SIZE;
    const float lo = UNIT_RADIUS;
    const float hi = world_size - UNIT_RADIUS;

    for (int i = p_begin; i < p_end; i++) {
        if (!alive[i]) {
            new_x[i] = pos_x[i];
            new_y[i] = pos_y[i];
            continue;
        }
        const float px = pos_x[i];
        const float py = pos_y[i];
        float push_x = 0.0f;
        float push_y = 0.0f;
        int found = 0;

        const int cx = std::clamp(int(px * inv_cell), 0, grid_dim - 1);
        const int cy = std::clamp(int(py * inv_cell), 0, grid_dim - 1);
        for (int gy = std::max(0, cy - 1); gy <= std::min(grid_dim - 1, cy + 1) && found < MAX_NEIGHBORS; gy++) {
            for (int gx = std::max(0, cx - 1); gx <= std::min(grid_dim - 1, cx + 1) && found < MAX_NEIGHBORS; gx++) {
                const uint32_t cell = uint32_t(gy) * grid_dim + gx;
                for (uint32_t e = cell_starts[cell]; e < cell_starts[cell + 1]; e++) {
                    const uint32_t j = cell_entries[e];
                    if (int(j) == i) {
                        continue;
                    }
                    const float dx = px - pos_x[j];
                    const float dy = py - pos_y[j];
                    const float d2 = dx * dx + dy * dy;
                    if (d2 >= min_d2 || d2 < 1e-6f) {
                        continue;
                    }
                    const float d = std::sqrt(d2);
                    const float overlap = (min_d - d) * 0.5f / d;
                    push_x += dx * overlap;
                    push_y += dy * overlap;
                    if (++found >= MAX_NEIGHBORS) {
                        break;
                    }
                }
            }
        }
        new_x[i] = std::clamp(px + push_x, lo, hi);
        new_y[i] = std::clamp(py + push_y, lo, hi);
    }
}

void SimWorld::tick(float p_dt) {
    std::memcpy(prev_x.data(), pos_x.data(), pos_x.size() * sizeof(float));
    std::memcpy(prev_y.data(), pos_y.data(), pos_y.size() * sizeof(float));
    if (field_cache.size() > FIELD_CACHE_MAX) {
        field_cache.clear(); // tick 开头清理，pass 内指针不会悬空
    }
    logic_pass(p_dt);
    pool->run(unit_count, [&](int b, int e) { move_range(b, e, p_dt); });
    build_grid();
    pool->run(unit_count, [&](int b, int e) { separate_range(b, e); });
    pos_x.swap(new_x);
    pos_y.swap(new_y);
    tick_index++;
}

void SimWorld::write_render_buffer(float p_alpha) {
    // MultiMesh TRANSFORM_2D + custom_data 布局：每实例 12 float
    // 人形单位不随速度旋转（PLAN 美术降级梯子），仅按横向速度镜像
    const float a = std::clamp(p_alpha, 0.0f, 1.0f);
    float *w = render_buffer.ptrw();
    pool->run(unit_count, [&](int b, int e) {
        for (int i = b; i < e; i++) {
            float *o = w + size_t(i) * 12;
            if (!alive[i]) { // 尸体隐藏（零缩放）
                std::memset(o, 0, 12 * sizeof(float));
                continue;
            }
            const bool moving = vel_x[i] * vel_x[i] + vel_y[i] * vel_y[i] > 1.0f;
            const float mirror = (vel_x[i] < -0.5f) ? -1.0f : 1.0f;
            o[0] = mirror;
            o[1] = 0.0f;
            o[2] = 0.0f;
            o[3] = prev_x[i] + (pos_x[i] - prev_x[i]) * a;
            o[4] = 0.0f;
            o[5] = 1.0f;
            o[6] = 0.0f;
            o[7] = prev_y[i] + (pos_y[i] - prev_y[i]) * a;
            o[8] = moving ? float((tick_index + uint64_t(i)) % 6) : 0.0f;
            o[9] = float(carry[i]) / 10.0f; // 载货指示（shader 用）
            o[10] = float(u_type[i]); // 图集行
            o[11] = 0.0f;
        }
    });
}

PackedInt32Array SimWorld::get_units_in_rect(Vector2 p_min, Vector2 p_max) const {
    PackedInt32Array out;
    for (int i = 0; i < unit_count; i++) {
        if (alive[i] && faction[i] == 0 && // 只选玩家存活单位
                pos_x[i] >= p_min.x && pos_x[i] <= p_max.x &&
                pos_y[i] >= p_min.y && pos_y[i] <= p_max.y) {
            out.push_back(i);
        }
    }
    return out;
}

PackedVector2Array SimWorld::get_unit_positions(const PackedInt32Array &p_ids) const {
    PackedVector2Array out;
    out.resize(p_ids.size());
    for (int k = 0; k < p_ids.size(); k++) {
        const int i = p_ids[k];
        out[k] = (i >= 0 && i < unit_count) ? Vector2(pos_x[i], pos_y[i]) : Vector2();
    }
    return out;
}

int SimWorld::get_unit_state(int p_id) const {
    return (p_id >= 0 && p_id < unit_count) ? state[p_id] : -1;
}

int SimWorld::get_unit_carry(int p_id) const {
    return (p_id >= 0 && p_id < unit_count) ? carry[p_id] : 0;
}

int SimWorld::get_unit_type(int p_id) const {
    return (p_id >= 0 && p_id < unit_count) ? u_type[p_id] : -1;
}

float SimWorld::get_unit_hp(int p_id) const {
    return (p_id >= 0 && p_id < unit_count) ? hp[p_id] : 0.0f;
}

bool SimWorld::is_unit_alive(int p_id) const {
    return p_id >= 0 && p_id < unit_count && alive[p_id];
}

PackedInt32Array SimWorld::take_attack_events() {
    PackedInt32Array out = attack_events;
    attack_events.clear();
    return out;
}

int SimWorld::count_alive(int p_faction) const {
    int n = 0;
    for (int i = 0; i < unit_count; i++) {
        if (alive[i] && faction[i] == p_faction) {
            n++;
        }
    }
    return n;
}

int64_t SimWorld::get_stockpile(int p_type) const {
    return (p_type >= 0 && p_type < RES_COUNT) ? stockpile[p_type] : 0;
}

// ---- 建筑 ----

Vector2i SimWorld::building_cost(int p_type) { // (木材, 石料)
    switch (p_type) {
        case B_LUMBER:
            return Vector2i(20, 0);
        case B_QUARRY:
            return Vector2i(20, 0);
        case B_FARM:
            return Vector2i(10, 0);
        case B_HOUSE:
            return Vector2i(15, 5);
        case B_STOREHOUSE:
            return Vector2i(30, 10);
        case B_BARRACKS:
            return Vector2i(30, 20);
        case B_ARCHERY:
            return Vector2i(25, 10);
        default: // 营地（初始建筑）
            return Vector2i(0, 0);
    }
}

// 该建筑是否接收某资源
static bool building_accepts(uint8_t p_btype, int p_res) {
    switch (p_btype) {
        case B_CAMP:
        case B_STOREHOUSE:
            return true;
        case B_LUMBER:
            return p_res == RES_WOOD;
        case B_QUARRY:
            return p_res == RES_STONE;
        case B_FARM:
            return p_res == RES_FOOD;
        default:
            return false;
    }
}

int32_t SimWorld::nearest_dropoff(int p_res_type, int32_t p_from_cell) const {
    const int fx = p_from_cell % grid_dim, fy = p_from_cell / grid_dim;
    int32_t best = -1;
    int best_d = INT32_MAX;
    for (size_t b = 0; b < b_cell.size(); b++) {
        if (!building_accepts(b_type[b], p_res_type)) {
            continue;
        }
        const int bx = b_cell[b] % grid_dim, by = b_cell[b] / grid_dim;
        const int d = std::max(std::abs(bx - fx), std::abs(by - fy));
        if (d < best_d) {
            best_d = d;
            best = b_cell[b];
        }
    }
    if (best < 0 && dropoff_cell >= 0) { // 兼容压测：无建筑时退回 set_dropoff
        best = dropoff_cell;
    }
    return best;
}

void SimWorld::mark_occupancy(int p_b_index, uint8_t p_value) {
    const int bx = b_cell[p_b_index] % grid_dim, by = b_cell[p_b_index] / grid_dim;
    for (int oy = 0; oy < 2; oy++) {
        for (int ox = 0; ox < 2; ox++) {
            const int nx = bx + ox, ny = by + oy;
            if (nx >= 0 && nx < grid_dim && ny >= 0 && ny < grid_dim) {
                occupied[size_t(ny) * grid_dim + nx] = p_value;
            }
        }
    }
}

bool SimWorld::can_place_building(int p_type, Vector2 p_world_pos) const {
    if (map.is_null() || p_type < 0 || p_type >= B_COUNT) {
        return false;
    }
    const int32_t anchor = cell_of_pos(p_world_pos.x, p_world_pos.y);
    const int bx = anchor % grid_dim, by = anchor / grid_dim;
    if (bx + 1 >= grid_dim || by + 1 >= grid_dim) {
        return false;
    }
    for (int oy = 0; oy < 2; oy++) {
        for (int ox = 0; ox < 2; ox++) {
            if (!map->is_passable(bx + ox, by + oy) ||
                    occupied[size_t(by + oy) * grid_dim + bx + ox]) {
                return false;
            }
        }
    }
    const Vector2i cost = building_cost(p_type);
    return stockpile[RES_WOOD] >= cost.x && stockpile[RES_STONE] >= cost.y;
}

bool SimWorld::place_building(int p_type, Vector2 p_world_pos) {
    if (!can_place_building(p_type, p_world_pos)) {
        return false;
    }
    const Vector2i cost = building_cost(p_type);
    stockpile[RES_WOOD] -= cost.x;
    stockpile[RES_STONE] -= cost.y;
    b_type.push_back(uint8_t(p_type));
    b_cell.push_back(cell_of_pos(p_world_pos.x, p_world_pos.y));
    mark_occupancy(int(b_cell.size()) - 1, 1);
    field_cache.clear(); // 占地变化，全部流场失效
    return true;
}

PackedInt32Array SimWorld::get_buildings() const {
    PackedInt32Array out;
    out.resize(int(b_cell.size()) * 2);
    for (size_t b = 0; b < b_cell.size(); b++) {
        out[int(b) * 2] = b_type[b];
        out[int(b) * 2 + 1] = b_cell[b];
    }
    return out;
}

// 存档格式 v2：+ 状态机数组 + 库存 + 存储点。
// 数据布局变更必须升版本号；golden 基线随逻辑变更重置（删 golden_hash.txt 重新初始化）。
static constexpr uint32_t SAVE_MAGIC = 0x57564943; // "CIVW" LE
static constexpr uint32_t SAVE_VERSION = 4; // v4: + 单位类型/阵营/HP/攻击目标

template <typename T>
static void blob_write(PackedByteArray &r_out, const T *p_data, size_t p_count) {
    const size_t at = r_out.size();
    r_out.resize(at + p_count * sizeof(T));
    std::memcpy(r_out.ptrw() + at, p_data, p_count * sizeof(T));
}

template <typename T>
static bool blob_read(const PackedByteArray &p_in, size_t &r_at, T *p_data, size_t p_count) {
    const size_t bytes = p_count * sizeof(T);
    if (r_at + bytes > size_t(p_in.size())) {
        return false;
    }
    std::memcpy(p_data, p_in.ptr() + r_at, bytes);
    r_at += bytes;
    return true;
}

PackedByteArray SimWorld::save_state() const {
    PackedByteArray out;
    blob_write(out, &SAVE_MAGIC, 1);
    blob_write(out, &SAVE_VERSION, 1);
    blob_write(out, &tick_index, 1);
    const int32_t count = unit_count;
    blob_write(out, &count, 1);
    blob_write(out, &world_size, 1);
    blob_write(out, &dropoff_cell, 1);
    blob_write(out, stockpile, RES_COUNT);
    blob_write(out, pos_x.data(), pos_x.size());
    blob_write(out, pos_y.data(), pos_y.size());
    blob_write(out, vel_x.data(), vel_x.size());
    blob_write(out, vel_y.data(), vel_y.size());
    blob_write(out, way_x.data(), way_x.size());
    blob_write(out, way_y.data(), way_y.size());
    blob_write(out, rng_state.data(), rng_state.size());
    blob_write(out, state.data(), state.size());
    blob_write(out, goal_cell.data(), goal_cell.size());
    blob_write(out, target_cell.data(), target_cell.size());
    blob_write(out, carry.data(), carry.size());
    blob_write(out, carry_type.data(), carry_type.size());
    blob_write(out, timer.data(), timer.size());
    blob_write(out, slot_x.data(), slot_x.size());
    blob_write(out, slot_y.data(), slot_y.size());
    blob_write(out, u_type.data(), u_type.size());
    blob_write(out, faction.data(), faction.size());
    blob_write(out, alive.data(), alive.size());
    blob_write(out, hp.data(), hp.size());
    blob_write(out, attack_target.data(), attack_target.size());
    const int32_t n_buildings = int32_t(b_cell.size());
    blob_write(out, &n_buildings, 1);
    blob_write(out, b_type.data(), b_type.size());
    blob_write(out, b_cell.data(), b_cell.size());
    return out;
}

bool SimWorld::load_state(const PackedByteArray &p_data) {
    size_t at = 0;
    uint32_t magic = 0, version = 0;
    if (!blob_read(p_data, at, &magic, 1) || magic != SAVE_MAGIC) {
        return false;
    }
    if (!blob_read(p_data, at, &version, 1) || version != SAVE_VERSION) {
        return false;
    }
    uint64_t saved_tick = 0;
    int32_t count = 0;
    float ws = 0.0f;
    if (!blob_read(p_data, at, &saved_tick, 1) || !blob_read(p_data, at, &count, 1) ||
            !blob_read(p_data, at, &ws, 1) || count < 0) {
        return false;
    }
    setup(count, ws, 0, thread_count);
    tick_index = saved_tick;
    if (!blob_read(p_data, at, &dropoff_cell, 1) ||
            !blob_read(p_data, at, stockpile, RES_COUNT) ||
            !blob_read(p_data, at, pos_x.data(), pos_x.size()) ||
            !blob_read(p_data, at, pos_y.data(), pos_y.size()) ||
            !blob_read(p_data, at, vel_x.data(), vel_x.size()) ||
            !blob_read(p_data, at, vel_y.data(), vel_y.size()) ||
            !blob_read(p_data, at, way_x.data(), way_x.size()) ||
            !blob_read(p_data, at, way_y.data(), way_y.size()) ||
            !blob_read(p_data, at, rng_state.data(), rng_state.size()) ||
            !blob_read(p_data, at, state.data(), state.size()) ||
            !blob_read(p_data, at, goal_cell.data(), goal_cell.size()) ||
            !blob_read(p_data, at, target_cell.data(), target_cell.size()) ||
            !blob_read(p_data, at, carry.data(), carry.size()) ||
            !blob_read(p_data, at, carry_type.data(), carry_type.size()) ||
            !blob_read(p_data, at, timer.data(), timer.size()) ||
            !blob_read(p_data, at, slot_x.data(), slot_x.size()) ||
            !blob_read(p_data, at, slot_y.data(), slot_y.size()) ||
            !blob_read(p_data, at, u_type.data(), u_type.size()) ||
            !blob_read(p_data, at, faction.data(), faction.size()) ||
            !blob_read(p_data, at, alive.data(), alive.size()) ||
            !blob_read(p_data, at, hp.data(), hp.size()) ||
            !blob_read(p_data, at, attack_target.data(), attack_target.size())) {
        return false;
    }
    int32_t n_buildings = 0;
    if (!blob_read(p_data, at, &n_buildings, 1) || n_buildings < 0) {
        return false;
    }
    b_type.resize(n_buildings);
    b_cell.resize(n_buildings);
    if (!blob_read(p_data, at, b_type.data(), b_type.size()) ||
            !blob_read(p_data, at, b_cell.data(), b_cell.size())) {
        return false;
    }
    for (int b = 0; b < n_buildings; b++) { // 重建占地位图
        mark_occupancy(b, 1);
    }
    std::memcpy(prev_x.data(), pos_x.data(), pos_x.size() * sizeof(float));
    std::memcpy(prev_y.data(), pos_y.data(), pos_y.size() * sizeof(float));
    return true;
}

int64_t SimWorld::state_hash() const {
    // FNV-1a 64：位置 + 状态机 + 库存，golden test 用
    uint64_t h = 14695981039346656037ull;
    auto mix_bytes = [&h](const void *p_ptr, size_t p_bytes) {
        const uint8_t *p = static_cast<const uint8_t *>(p_ptr);
        for (size_t i = 0; i < p_bytes; i++) {
            h ^= p[i];
            h *= 1099511628211ull;
        }
    };
    mix_bytes(pos_x.data(), pos_x.size() * 4);
    mix_bytes(pos_y.data(), pos_y.size() * 4);
    mix_bytes(state.data(), state.size());
    mix_bytes(carry.data(), carry.size());
    mix_bytes(stockpile, sizeof(stockpile));
    mix_bytes(hp.data(), hp.size() * 4);
    mix_bytes(alive.data(), alive.size());
    mix_bytes(b_type.data(), b_type.size());
    mix_bytes(b_cell.data(), b_cell.size() * 4);
    return int64_t(h);
}

void SimWorld::_bind_methods() {
    ClassDB::bind_method(D_METHOD("setup", "count", "world_size", "seed", "threads"), &SimWorld::setup);
    ClassDB::bind_method(D_METHOD("set_map", "map"), &SimWorld::set_map);
    ClassDB::bind_method(D_METHOD("set_flow_field", "field"), &SimWorld::set_flow_field);
    ClassDB::bind_method(D_METHOD("set_dropoff", "world_pos"), &SimWorld::set_dropoff);
    ClassDB::bind_method(D_METHOD("spawn_workers", "count", "world_pos"), &SimWorld::spawn_workers);
    ClassDB::bind_method(D_METHOD("spawn_units", "type", "count", "world_pos", "faction"), &SimWorld::spawn_units);
    ClassDB::bind_method(D_METHOD("try_spend", "wood", "stone", "food"), &SimWorld::try_spend);
    ClassDB::bind_method(D_METHOD("get_unit_type", "id"), &SimWorld::get_unit_type);
    ClassDB::bind_method(D_METHOD("get_unit_hp", "id"), &SimWorld::get_unit_hp);
    ClassDB::bind_method(D_METHOD("is_unit_alive", "id"), &SimWorld::is_unit_alive);
    ClassDB::bind_method(D_METHOD("count_alive", "faction"), &SimWorld::count_alive);
    ClassDB::bind_method(D_METHOD("take_attack_events"), &SimWorld::take_attack_events);
    ClassDB::bind_method(D_METHOD("command_move", "ids", "world_pos"), &SimWorld::command_move);
    ClassDB::bind_method(D_METHOD("command_gather", "ids", "world_pos"), &SimWorld::command_gather);
    ClassDB::bind_method(D_METHOD("get_units_in_rect", "min", "max"), &SimWorld::get_units_in_rect);
    ClassDB::bind_method(D_METHOD("get_unit_positions", "ids"), &SimWorld::get_unit_positions);
    ClassDB::bind_method(D_METHOD("get_unit_state", "id"), &SimWorld::get_unit_state);
    ClassDB::bind_method(D_METHOD("get_unit_carry", "id"), &SimWorld::get_unit_carry);
    ClassDB::bind_method(D_METHOD("get_stockpile", "type"), &SimWorld::get_stockpile);
    ClassDB::bind_method(D_METHOD("can_place_building", "type", "world_pos"), &SimWorld::can_place_building);
    ClassDB::bind_method(D_METHOD("place_building", "type", "world_pos"), &SimWorld::place_building);
    ClassDB::bind_method(D_METHOD("get_buildings"), &SimWorld::get_buildings);
    ClassDB::bind_static_method("SimWorld", D_METHOD("building_cost", "type"), &SimWorld::building_cost);
    ClassDB::bind_method(D_METHOD("tick", "dt"), &SimWorld::tick);
    ClassDB::bind_method(D_METHOD("write_render_buffer", "alpha"), &SimWorld::write_render_buffer);
    ClassDB::bind_method(D_METHOD("get_render_buffer"), &SimWorld::get_render_buffer);
    ClassDB::bind_method(D_METHOD("state_hash"), &SimWorld::state_hash);
    ClassDB::bind_method(D_METHOD("get_unit_count"), &SimWorld::get_unit_count);
    ClassDB::bind_method(D_METHOD("save_state"), &SimWorld::save_state);
    ClassDB::bind_method(D_METHOD("load_state", "data"), &SimWorld::load_state);
}

} // namespace cive
