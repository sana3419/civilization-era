#pragma once

#include <cmath>
#include <cstdint>

namespace cive {

// 自实现 value-noise fBm。只用 IEEE 精确运算（+ - * / floor），
// 配合 -ffp-contract=off 保证跨架构逐位一致（golden test 依赖）。
// 不用引擎 FastNoiseLite：模拟层不依赖引擎实现细节。

static inline uint32_t noise_hash2(int p_x, int p_y, uint32_t p_seed) {
    uint32_t h = p_seed;
    h ^= uint32_t(p_x) * 0x9E3779B9u;
    h ^= uint32_t(p_y) * 0x85EBCA6Bu;
    h ^= h >> 13;
    h *= 0xC2B2AE35u;
    h ^= h >> 16;
    return h;
}

static inline float noise_value_at(int p_x, int p_y, uint32_t p_seed) {
    return float(noise_hash2(p_x, p_y, p_seed) >> 8) * (1.0f / 16777216.0f);
}

static inline float value_noise(float p_x, float p_y, uint32_t p_seed) {
    const float fx = std::floor(p_x);
    const float fy = std::floor(p_y);
    const int x0 = int(fx), y0 = int(fy);
    const float tx = p_x - fx, ty = p_y - fy;
    const float ux = tx * tx * (3.0f - 2.0f * tx);
    const float uy = ty * ty * (3.0f - 2.0f * ty);

    const float v00 = noise_value_at(x0, y0, p_seed);
    const float v10 = noise_value_at(x0 + 1, y0, p_seed);
    const float v01 = noise_value_at(x0, y0 + 1, p_seed);
    const float v11 = noise_value_at(x0 + 1, y0 + 1, p_seed);

    const float a = v00 + (v10 - v00) * ux;
    const float b = v01 + (v11 - v01) * ux;
    return a + (b - a) * uy;
}

static inline float fbm(float p_x, float p_y, uint32_t p_seed, int p_octaves) {
    float sum = 0.0f;
    float amp = 0.5f;
    float freq = 1.0f;
    float norm = 0.0f;
    for (int o = 0; o < p_octaves; o++) {
        sum += value_noise(p_x * freq, p_y * freq, p_seed + uint32_t(o) * 1013u) * amp;
        norm += amp;
        amp *= 0.5f;
        freq *= 2.0f;
    }
    return sum / norm;
}

} // namespace cive
