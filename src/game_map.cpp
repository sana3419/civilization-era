#include "game_map.h"

#include "noise.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>

using namespace godot;

namespace cive {

// 移动代价 ×10（设计文档地形表），0 = 不可通行
int GameMap::terrain_move_cost(uint8_t p_t) {
    switch (p_t) {
        case T_PLAINS:
        case T_GRASS:
            return 10;
        case T_FOREST:
        case T_HILLS:
        case T_DESERT:
            return 15;
        case T_DENSE_FOREST:
        case T_SNOW:
            return 20;
        case T_SWAMP:
            return 25;
        default: // 水域 / 山地
            return 0;
    }
}

// 地形 → 资源类型
int GameMap::terrain_resource(uint8_t p_t) {
    switch (p_t) {
        case T_FOREST:
        case T_DENSE_FOREST:
            return RES_WOOD;
        case T_HILLS:
            return RES_STONE;
        case T_PLAINS:
            return RES_FOOD;
        default:
            return -1;
    }
}

static uint16_t terrain_resource_init(uint8_t p_t) {
    switch (p_t) {
        case T_FOREST:
            return 150;
        case T_DENSE_FOREST:
            return 250;
        case T_HILLS:
            return 200;
        case T_PLAINS:
            return 100;
        default:
            return 0;
    }
}

int GameMap::get_resource_amount(int p_cx, int p_cy) const {
    if (p_cx < 0 || p_cx >= dim || p_cy < 0 || p_cy >= dim) {
        return 0;
    }
    return resource_amount[size_t(p_cy) * dim + p_cx];
}

int GameMap::take_resource(size_t p_cell, int p_amount) {
    const int avail = resource_amount[p_cell];
    const int taken = std::min(avail, p_amount);
    resource_amount[p_cell] = uint16_t(avail - taken);
    return taken;
}

void GameMap::generate(int p_dim, int p_seed) {
    dim = p_dim;
    seed = uint32_t(p_seed);
    terrain.assign(size_t(dim) * dim, T_GRASS);

    const float freq = 4.0f / float(dim); // 全图约 4 个大陆尺度特征
    for (int cy = 0; cy < dim; cy++) {
        for (int cx = 0; cx < dim; cx++) {
            const float nx = cx * freq;
            const float ny = cy * freq;
            const float h = fbm(nx, ny, seed, 5); // 高度
            const float m = fbm(nx, ny, seed + 7919u, 4); // 湿度
            // 纬度温度：两极冷、赤道热，叠噪声扰动
            const float lat = 1.0f - std::abs(float(cy) / float(dim) * 2.0f - 1.0f);
            const float t = lat * 0.8f + fbm(nx, ny, seed + 104729u, 3) * 0.2f;

            uint8_t ter;
            if (h < 0.38f) {
                ter = T_DEEP_WATER;
            } else if (h < 0.45f) {
                ter = T_WATER;
            } else if (h > 0.78f) {
                ter = T_MOUNTAIN;
            } else if (h > 0.68f) {
                ter = (t < 0.25f) ? T_SNOW : T_HILLS;
            } else if (t < 0.22f) {
                ter = T_SNOW;
            } else if (m < 0.30f && t > 0.62f) {
                ter = T_DESERT;
            } else if (m > 0.78f && h < 0.52f) {
                ter = T_SWAMP;
            } else if (m > 0.62f) {
                ter = T_DENSE_FOREST;
            } else if (m > 0.48f) {
                ter = T_FOREST;
            } else if (m > 0.36f) {
                ter = T_GRASS;
            } else {
                ter = T_PLAINS;
            }
            terrain[size_t(cy) * dim + cx] = ter;
        }
    }
    resource_amount.resize(terrain.size());
    for (size_t i = 0; i < terrain.size(); i++) {
        resource_amount[i] = terrain_resource_init(terrain[i]);
    }
}

int GameMap::get_terrain(int p_cx, int p_cy) const {
    if (p_cx < 0 || p_cx >= dim || p_cy < 0 || p_cy >= dim) {
        return -1;
    }
    return terrain_at(p_cx, p_cy);
}

PackedByteArray GameMap::get_terrain_buffer() const {
    PackedByteArray out;
    out.resize(terrain.size());
    std::memcpy(out.ptrw(), terrain.data(), terrain.size());
    return out;
}

bool GameMap::is_passable(int p_cx, int p_cy) const {
    if (p_cx < 0 || p_cx >= dim || p_cy < 0 || p_cy >= dim) {
        return false;
    }
    return terrain_move_cost(terrain_at(p_cx, p_cy)) > 0;
}

int GameMap::move_cost(int p_cx, int p_cy) const {
    if (p_cx < 0 || p_cx >= dim || p_cy < 0 || p_cy >= dim) {
        return 0;
    }
    return terrain_move_cost(terrain_at(p_cx, p_cy));
}

static constexpr uint32_t MAP_MAGIC = 0x4D564943; // "CIVM" LE
static constexpr uint32_t MAP_VERSION = 2; // v2: + resource_amount

PackedByteArray GameMap::save_state() const {
    const size_t n = terrain.size();
    PackedByteArray out;
    out.resize(4 * 4 + n + n * 2);
    uint8_t *w = out.ptrw();
    uint32_t header[4] = { MAP_MAGIC, MAP_VERSION, uint32_t(dim), seed };
    std::memcpy(w, header, sizeof(header));
    std::memcpy(w + 16, terrain.data(), n);
    std::memcpy(w + 16 + n, resource_amount.data(), n * 2);
    return out;
}

bool GameMap::load_state(const PackedByteArray &p_data) {
    if (p_data.size() < 16) {
        return false;
    }
    uint32_t header[4];
    std::memcpy(header, p_data.ptr(), sizeof(header));
    if (header[0] != MAP_MAGIC || header[1] != MAP_VERSION) {
        return false;
    }
    const int d = int(header[2]);
    const size_t n = size_t(d) * d;
    if (size_t(p_data.size()) != 16 + n + n * 2) {
        return false;
    }
    dim = d;
    seed = header[3];
    terrain.resize(n);
    resource_amount.resize(n);
    std::memcpy(terrain.data(), p_data.ptr() + 16, n);
    std::memcpy(resource_amount.data(), p_data.ptr() + 16 + n, n * 2);
    return true;
}

void GameMap::_bind_methods() {
    ClassDB::bind_method(D_METHOD("generate", "dim", "seed"), &GameMap::generate);
    ClassDB::bind_method(D_METHOD("get_dim"), &GameMap::get_dim);
    ClassDB::bind_method(D_METHOD("get_terrain", "cx", "cy"), &GameMap::get_terrain);
    ClassDB::bind_method(D_METHOD("get_terrain_buffer"), &GameMap::get_terrain_buffer);
    ClassDB::bind_method(D_METHOD("is_passable", "cx", "cy"), &GameMap::is_passable);
    ClassDB::bind_method(D_METHOD("get_resource_amount", "cx", "cy"), &GameMap::get_resource_amount);
    ClassDB::bind_method(D_METHOD("move_cost", "cx", "cy"), &GameMap::move_cost);
    ClassDB::bind_static_method("GameMap", D_METHOD("terrain_resource", "terrain"), &GameMap::terrain_resource);
    ClassDB::bind_method(D_METHOD("save_state"), &GameMap::save_state);
    ClassDB::bind_method(D_METHOD("load_state", "data"), &GameMap::load_state);
}

} // namespace cive
