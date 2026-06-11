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

    new_x.resize(p_count);
    new_y.resize(p_count);
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
    std::fill(stockpile, stockpile + RES_COUNT, 0);
    dropoff_cell = -1;
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
    }
}

void SimWorld::set_map(const Ref<GameMap> &p_map) {
    map = p_map;
    if (map.is_valid()) {
        world_size = map->get_dim() * CELL_SIZE;
        grid_dim = map->get_dim();
        cell_starts.assign(size_t(grid_dim) * grid_dim + 1, 0);
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
    const int first = unit_count;
    unit_count += p_count;
    resize_arrays(unit_count);
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
    }
    return first;
}

const FlowField *SimWorld::ensure_field(int32_t p_goal) {
    auto it = field_cache.find(p_goal);
    if (it != field_cache.end()) {
        return it->second.ptr();
    }
    Ref<FlowField> ff;
    ff.instantiate();
    ff->setup_from_map(map.ptr(), CELL_SIZE);
    ff->generate(p_goal % grid_dim, p_goal / grid_dim);
    field_cache[p_goal] = ff;
    return ff.ptr();
}

void SimWorld::command_move(const PackedInt32Array &p_ids, Vector2 p_world_pos) {
    const int32_t goal = cell_of_pos(p_world_pos.x, p_world_pos.y);
    for (int k = 0; k < p_ids.size(); k++) {
        const int i = p_ids[k];
        if (i < 0 || i >= unit_count || state[i] == U_WANDER) {
            continue;
        }
        state[i] = U_MOVING;
        goal_cell[i] = goal;
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
        switch (state[i]) {
            case U_WANDER:
            case U_IDLE:
                break;

            case U_MOVING: {
                const int32_t cell = cell_of_pos(pos_x[i], pos_y[i]);
                if (cell == goal_cell[i]) {
                    state[i] = U_IDLE;
                    break;
                }
                const FlowField *ff = ensure_field(goal_cell[i]);
                float dx, dy;
                ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
                if (dx == 0.0f && dy == 0.0f) {
                    state[i] = U_IDLE; // 到达流场终点或不可达
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
                            if (dropoff_cell < 0) { // 无存储点：就地入库
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
                if (cell_adjacent(cell, dropoff_cell) || cell == dropoff_cell) {
                    stockpile[carry_type[i]] += carry[i];
                    carry[i] = 0;
                    state[i] = U_GATHER; // 回去继续采
                    break;
                }
                const FlowField *ff = ensure_field(dropoff_cell);
                float dx, dy;
                ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
                if (dx == 0.0f && dy == 0.0f) { // 存储点不可达：就地入库防卡死
                    stockpile[carry_type[i]] += carry[i];
                    carry[i] = 0;
                    state[i] = U_IDLE;
                    break;
                }
                unit_field[i] = ff;
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
        if (ff == nullptr) {
            vel_x[i] = vel_y[i] = 0.0f;
            continue;
        }
        float dx, dy;
        ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
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

void SimWorld::write_render_buffer() {
    // MultiMesh TRANSFORM_2D + custom_data 布局：每实例 12 float
    float *w = render_buffer.ptrw();
    pool->run(unit_count, [&](int b, int e) {
        for (int i = b; i < e; i++) {
            const float vx = vel_x[i];
            const float vy = vel_y[i];
            const float len2 = vx * vx + vy * vy;
            float c = 1.0f, s = 0.0f;
            if (len2 > 1e-4f) {
                const float inv = 1.0f / std::sqrt(len2);
                c = vx * inv;
                s = vy * inv;
            }
            float *o = w + size_t(i) * 12;
            o[0] = c;
            o[1] = -s;
            o[2] = 0.0f;
            o[3] = pos_x[i];
            o[4] = s;
            o[5] = c;
            o[6] = 0.0f;
            o[7] = pos_y[i];
            o[8] = float((tick_index + uint64_t(i)) % 6);
            o[9] = float(carry[i]) / 10.0f; // 载货指示（shader 可用）
            o[10] = 0.0f;
            o[11] = 0.0f;
        }
    });
}

PackedInt32Array SimWorld::get_units_in_rect(Vector2 p_min, Vector2 p_max) const {
    PackedInt32Array out;
    for (int i = 0; i < unit_count; i++) {
        if (pos_x[i] >= p_min.x && pos_x[i] <= p_max.x &&
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

int64_t SimWorld::get_stockpile(int p_type) const {
    return (p_type >= 0 && p_type < RES_COUNT) ? stockpile[p_type] : 0;
}

// 存档格式 v2：+ 状态机数组 + 库存 + 存储点。
// 数据布局变更必须升版本号；golden 基线随逻辑变更重置（删 golden_hash.txt 重新初始化）。
static constexpr uint32_t SAVE_MAGIC = 0x57564943; // "CIVW" LE
static constexpr uint32_t SAVE_VERSION = 2;

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
            !blob_read(p_data, at, timer.data(), timer.size())) {
        return false;
    }
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
    return int64_t(h);
}

void SimWorld::_bind_methods() {
    ClassDB::bind_method(D_METHOD("setup", "count", "world_size", "seed", "threads"), &SimWorld::setup);
    ClassDB::bind_method(D_METHOD("set_map", "map"), &SimWorld::set_map);
    ClassDB::bind_method(D_METHOD("set_flow_field", "field"), &SimWorld::set_flow_field);
    ClassDB::bind_method(D_METHOD("set_dropoff", "world_pos"), &SimWorld::set_dropoff);
    ClassDB::bind_method(D_METHOD("spawn_workers", "count", "world_pos"), &SimWorld::spawn_workers);
    ClassDB::bind_method(D_METHOD("command_move", "ids", "world_pos"), &SimWorld::command_move);
    ClassDB::bind_method(D_METHOD("command_gather", "ids", "world_pos"), &SimWorld::command_gather);
    ClassDB::bind_method(D_METHOD("get_units_in_rect", "min", "max"), &SimWorld::get_units_in_rect);
    ClassDB::bind_method(D_METHOD("get_unit_positions", "ids"), &SimWorld::get_unit_positions);
    ClassDB::bind_method(D_METHOD("get_unit_state", "id"), &SimWorld::get_unit_state);
    ClassDB::bind_method(D_METHOD("get_unit_carry", "id"), &SimWorld::get_unit_carry);
    ClassDB::bind_method(D_METHOD("get_stockpile", "type"), &SimWorld::get_stockpile);
    ClassDB::bind_method(D_METHOD("tick", "dt"), &SimWorld::tick);
    ClassDB::bind_method(D_METHOD("write_render_buffer"), &SimWorld::write_render_buffer);
    ClassDB::bind_method(D_METHOD("get_render_buffer"), &SimWorld::get_render_buffer);
    ClassDB::bind_method(D_METHOD("state_hash"), &SimWorld::state_hash);
    ClassDB::bind_method(D_METHOD("get_unit_count"), &SimWorld::get_unit_count);
    ClassDB::bind_method(D_METHOD("save_state"), &SimWorld::save_state);
    ClassDB::bind_method(D_METHOD("load_state", "data"), &SimWorld::load_state);
}

} // namespace cive
