#include "flow_field.h"

#include "game_map.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

namespace cive {

static inline uint32_t ff_xorshift(uint32_t &s) {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

void FlowField::setup(int p_dim, float p_cell_size, int p_seed, float p_blocked_ratio) {
    dim = p_dim;
    cell_size = p_cell_size;
    const size_t n = size_t(dim) * dim;
    terrain_cost.resize(n);
    integration.resize(n);
    dir_x.assign(n, 0.0f);
    dir_y.assign(n, 0.0f);

    uint32_t s = uint32_t(p_seed) * 2654435761u + 1u;
    const uint32_t blocked_threshold = uint32_t(p_blocked_ratio * 4294967295.0);
    for (size_t i = 0; i < n; i++) {
        const uint32_t r = ff_xorshift(s);
        if (r < blocked_threshold) {
            terrain_cost[i] = 255; // 不可通行（山地/水域）
        } else {
            terrain_cost[i] = 1 + (r >> 8) % 3; // 1..3：平原/森林/丘陵
        }
    }
}

void FlowField::setup_from_map(const GameMap *p_map, float p_cell_size) {
    dim = p_map->get_dim();
    cell_size = p_cell_size;
    const size_t n = size_t(dim) * dim;
    terrain_cost.resize(n);
    integration.resize(n);
    dir_x.assign(n, 0.0f);
    dir_y.assign(n, 0.0f);
    for (int cy = 0; cy < dim; cy++) {
        for (int cx = 0; cx < dim; cx++) {
            const int mc = GameMap::terrain_move_cost(p_map->terrain_at(cx, cy));
            terrain_cost[size_t(cy) * dim + cx] = (mc == 0) ? 255 : uint8_t(mc / 10 + (mc % 10 != 0));
        }
    }
}

void FlowField::generate(int p_target_cx, int p_target_cy) {
    const size_t n = size_t(dim) * dim;
    constexpr uint32_t UNREACHED = 0xFFFFFFFFu;
    integration.assign(n, UNREACHED);

    // 目标不可通行时取最近可通行格（点击山地 → 走到最近可达点）
    size_t target = size_t(p_target_cy) * dim + p_target_cx;
    for (int r = 1; terrain_cost[target] == 255 && r < dim; r++) {
        bool found = false;
        for (int oy = -r; oy <= r && !found; oy++) {
            for (int ox = -r; ox <= r && !found; ox++) {
                if (std::max(std::abs(ox), std::abs(oy)) != r) {
                    continue; // 只扫环边
                }
                const int nx = p_target_cx + ox, ny = p_target_cy + oy;
                if (nx < 0 || nx >= dim || ny < 0 || ny >= dim) {
                    continue;
                }
                if (terrain_cost[size_t(ny) * dim + nx] != 255) {
                    target = size_t(ny) * dim + nx;
                    found = true;
                }
            }
        }
        if (found) {
            break;
        }
    }
    if (terrain_cost[target] == 255) {
        return;
    }

    // Dial（桶）队列 Dijkstra，4 邻接，边代价 = 邻居地形代价（1..15）→ 桶环 16 即可
    constexpr int RING = 16;
    std::vector<uint32_t> buckets[RING];
    integration[target] = 0;
    buckets[0].push_back(uint32_t(target));
    size_t pending = 1;

    uint32_t cur_dist = 0;
    while (pending > 0) {
        std::vector<uint32_t> &bucket = buckets[cur_dist % RING];
        if (bucket.empty()) {
            cur_dist++;
            continue;
        }
        const uint32_t c = bucket.back();
        bucket.pop_back();
        pending--;
        if (integration[c] != cur_dist) {
            continue; // 过期表项
        }
        const int cx = int(c) % dim;
        const int cy = int(c) / dim;
        const int nbs[4][2] = { { cx - 1, cy }, { cx + 1, cy }, { cx, cy - 1 }, { cx, cy + 1 } };
        for (const auto &nb : nbs) {
            if (nb[0] < 0 || nb[0] >= dim || nb[1] < 0 || nb[1] >= dim) {
                continue;
            }
            const size_t j = size_t(nb[1]) * dim + nb[0];
            const uint8_t tc = terrain_cost[j];
            if (tc == 255) {
                continue;
            }
            const uint32_t nd = cur_dist + tc;
            if (nd < integration[j]) {
                integration[j] = nd;
                buckets[nd % RING].push_back(uint32_t(j));
                pending++;
            }
        }
    }

    // 方向场：指向 8 邻接中积分值最小的格子
    for (int cy = 0; cy < dim; cy++) {
        for (int cx = 0; cx < dim; cx++) {
            const size_t c = size_t(cy) * dim + cx;
            if (integration[c] == UNREACHED || integration[c] == 0) {
                dir_x[c] = 0.0f;
                dir_y[c] = 0.0f;
                continue;
            }
            uint32_t best = integration[c];
            int bx = 0, by = 0;
            for (int oy = -1; oy <= 1; oy++) {
                for (int ox = -1; ox <= 1; ox++) {
                    if (ox == 0 && oy == 0) {
                        continue;
                    }
                    const int nx = cx + ox, ny = cy + oy;
                    if (nx < 0 || nx >= dim || ny < 0 || ny >= dim) {
                        continue;
                    }
                    const uint32_t v = integration[size_t(ny) * dim + nx];
                    if (v < best) {
                        best = v;
                        bx = ox;
                        by = oy;
                    }
                }
            }
            const float len = std::sqrt(float(bx * bx + by * by));
            if (len > 0.0f) {
                dir_x[c] = bx / len;
                dir_y[c] = by / len;
            }
        }
    }
}

Vector2 FlowField::sample(Vector2 p_world_pos) const {
    float dx, dy;
    sample_raw(p_world_pos.x, p_world_pos.y, dx, dy);
    return Vector2(dx, dy);
}

void FlowField::_bind_methods() {
    ClassDB::bind_method(D_METHOD("setup", "dim", "cell_size", "seed", "blocked_ratio"), &FlowField::setup);
    ClassDB::bind_method(D_METHOD("generate", "target_cx", "target_cy"), &FlowField::generate);
    ClassDB::bind_method(D_METHOD("sample", "world_pos"), &FlowField::sample);
    ClassDB::bind_method(D_METHOD("get_dim"), &FlowField::get_dim);
}

} // namespace cive
