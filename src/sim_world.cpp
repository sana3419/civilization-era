#include "sim_world.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>

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

// 把 [0, n) 切成 thread_count 块并行执行。f(begin, end) 只允许读共享旧状态、
// 写本块单位自己的槽位，从而结果与线程数和调度顺序无关（确定性前提）。
template <typename F>
static void parallel_run(int p_threads, int p_n, F p_f) {
    if (p_threads <= 1 || p_n < 256) {
        p_f(0, p_n);
        return;
    }
    std::vector<std::thread> pool;
    pool.reserve(p_threads);
    const int chunk = (p_n + p_threads - 1) / p_threads;
    for (int t = 0; t < p_threads; t++) {
        const int begin = t * chunk;
        const int end = std::min(p_n, begin + chunk);
        if (begin >= end) {
            break;
        }
        pool.emplace_back([=] { p_f(begin, end); });
    }
    for (std::thread &th : pool) {
        th.join();
    }
}

void SimWorld::setup(int p_count, float p_world_size, int p_seed, int p_threads) {
    unit_count = p_count;
    world_size = p_world_size;
    thread_count = std::max(1, p_threads);
    tick_index = 0;

    grid_dim = std::max(1, int(world_size / CELL_SIZE));

    pos_x.resize(unit_count);
    pos_y.resize(unit_count);
    vel_x.assign(unit_count, 0.0f);
    vel_y.assign(unit_count, 0.0f);
    way_x.resize(unit_count);
    way_y.resize(unit_count);
    new_x.resize(unit_count);
    new_y.resize(unit_count);
    rng_state.resize(unit_count);

    cell_of.resize(unit_count);
    cell_starts.assign(size_t(grid_dim) * grid_dim + 1, 0);
    cell_entries.resize(unit_count);

    // 出生在中心 1/4 区域，保证有碰撞密度
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
    }

    render_buffer.resize(int64_t(unit_count) * 12);
}

void SimWorld::move_range(int p_begin, int p_end, float p_dt) {
    if (flow_field.is_valid()) {
        const FlowField *ff = flow_field.ptr();
        for (int i = p_begin; i < p_end; i++) {
            float dx, dy;
            ff->sample_raw(pos_x[i], pos_y[i], dx, dy);
            vel_x[i] = dx * UNIT_SPEED;
            vel_y[i] = dy * UNIT_SPEED;
            pos_x[i] += vel_x[i] * p_dt;
            pos_y[i] += vel_y[i] * p_dt;
        }
        return;
    }
    const float center = world_size * 0.5f;
    const float half = world_size * 0.125f;
    for (int i = p_begin; i < p_end; i++) {
        float dx = way_x[i] - pos_x[i];
        float dy = way_y[i] - pos_y[i];
        const float d2 = dx * dx + dy * dy;
        if (d2 < 100.0f) { // 到达，选新路径点
            way_x[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
            way_y[i] = center + (rand01(rng_state[i]) * 2.0f - 1.0f) * half;
            continue;
        }
        const float inv_d = 1.0f / std::sqrt(d2);
        vel_x[i] = dx * inv_d * UNIT_SPEED;
        vel_y[i] = dy * inv_d * UNIT_SPEED;
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
    parallel_run(thread_count, unit_count, [&](int b, int e) { move_range(b, e, p_dt); });
    build_grid();
    parallel_run(thread_count, unit_count, [&](int b, int e) { separate_range(b, e); });
    pos_x.swap(new_x);
    pos_y.swap(new_y);
    tick_index++;
}

void SimWorld::write_render_buffer() {
    // MultiMesh TRANSFORM_2D + custom_data 布局：每实例 12 float
    // [xx, yx, 0, ox, xy, yy, 0, oy, c0, c1, c2, c3]
    float *w = render_buffer.ptrw();
    parallel_run(thread_count, unit_count, [&](int b, int e) {
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
            o[8] = float((tick_index + uint64_t(i)) % 6); // 动画帧索引
            o[9] = 0.0f;
            o[10] = 0.0f;
            o[11] = 0.0f;
        }
    });
}

int64_t SimWorld::state_hash() const {
    // FNV-1a 64，跑在位置数据上，golden test 用
    uint64_t h = 14695981039346656037ull;
    auto mix = [&h](const std::vector<float> &v) {
        const uint8_t *p = reinterpret_cast<const uint8_t *>(v.data());
        const size_t n = v.size() * sizeof(float);
        for (size_t i = 0; i < n; i++) {
            h ^= p[i];
            h *= 1099511628211ull;
        }
    };
    mix(pos_x);
    mix(pos_y);
    return int64_t(h);
}

void SimWorld::_bind_methods() {
    ClassDB::bind_method(D_METHOD("setup", "count", "world_size", "seed", "threads"), &SimWorld::setup);
    ClassDB::bind_method(D_METHOD("set_flow_field", "field"), &SimWorld::set_flow_field);
    ClassDB::bind_method(D_METHOD("tick", "dt"), &SimWorld::tick);
    ClassDB::bind_method(D_METHOD("write_render_buffer"), &SimWorld::write_render_buffer);
    ClassDB::bind_method(D_METHOD("get_render_buffer"), &SimWorld::get_render_buffer);
    ClassDB::bind_method(D_METHOD("state_hash"), &SimWorld::state_hash);
    ClassDB::bind_method(D_METHOD("get_unit_count"), &SimWorld::get_unit_count);
}

} // namespace cive
