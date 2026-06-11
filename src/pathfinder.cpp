#include "pathfinder.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <queue>

using namespace godot;

namespace cive {

void Pathfinder::set_map(const Ref<GameMap> &p_map) {
    map = p_map;
    const size_t n = map.is_valid() ? size_t(map->get_dim()) * map->get_dim() : 0;
    g_cost.assign(n, 0);
    came_from.assign(n, -1);
    visit_gen.assign(n, 0);
    generation = 0;
}

PackedVector2Array Pathfinder::find_path(Vector2i p_from, Vector2i p_to, int p_max_explored) {
    PackedVector2Array result;
    if (map.is_null()) {
        return result;
    }
    const int dim = map->get_dim();
    if (!map->is_passable(p_from.x, p_from.y) || !map->is_passable(p_to.x, p_to.y)) {
        return result;
    }

    generation++;
    const int32_t start = p_from.y * dim + p_from.x;
    const int32_t goal = p_to.y * dim + p_to.x;

    // 八方向；对角代价 ×1.4（整数：cost*14/10）
    static const int OFF[8][2] = {
        { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
        { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 }
    };

    auto heuristic = [&](int p_cx, int p_cy) -> uint32_t {
        const uint32_t dx = std::abs(p_cx - p_to.x);
        const uint32_t dy = std::abs(p_cy - p_to.y);
        const uint32_t lo = std::min(dx, dy), hi = std::max(dx, dy);
        return lo * 14 + (hi - lo) * 10; // 八方向 octile，地形最低代价 10
    };

    using QEntry = std::pair<uint32_t, int32_t>; // (f, cell)
    std::priority_queue<QEntry, std::vector<QEntry>, std::greater<QEntry>> open;

    g_cost[start] = 0;
    came_from[start] = -1;
    visit_gen[start] = generation;
    open.push({ heuristic(p_from.x, p_from.y), start });

    int explored = 0;
    bool found = false;
    while (!open.empty() && explored < p_max_explored) {
        const auto [f, c] = open.top();
        open.pop();
        if (c == goal) {
            found = true;
            break;
        }
        if (f - heuristic(c % dim, c / dim) > g_cost[c]) {
            continue; // 过期表项
        }
        explored++;
        const int cx = c % dim, cy = c / dim;
        for (int k = 0; k < 8; k++) {
            const int nx = cx + OFF[k][0], ny = cy + OFF[k][1];
            if (nx < 0 || nx >= dim || ny < 0 || ny >= dim) {
                continue;
            }
            const int mc = GameMap::terrain_move_cost(map->terrain_at(nx, ny));
            if (mc == 0) {
                continue;
            }
            const uint32_t step = (k < 4) ? uint32_t(mc) : uint32_t(mc) * 14 / 10;
            const uint32_t ng = g_cost[c] + step;
            const int32_t n = ny * dim + nx;
            if (visit_gen[n] == generation && g_cost[n] <= ng) {
                continue;
            }
            visit_gen[n] = generation;
            g_cost[n] = ng;
            came_from[n] = c;
            open.push({ ng + heuristic(nx, ny), n });
        }
    }

    if (!found) {
        return result;
    }
    std::vector<int32_t> cells;
    for (int32_t c = goal; c != -1; c = came_from[c]) {
        cells.push_back(c);
    }
    result.resize(cells.size());
    for (size_t i = 0; i < cells.size(); i++) {
        const int32_t c = cells[cells.size() - 1 - i];
        result[i] = Vector2(c % dim, c / dim);
    }
    return result;
}

void Pathfinder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_map", "map"), &Pathfinder::set_map);
    ClassDB::bind_method(D_METHOD("find_path", "from", "to", "max_explored"), &Pathfinder::find_path, DEFVAL(100000));
}

} // namespace cive
