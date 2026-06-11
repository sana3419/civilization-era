#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

namespace cive {

// 模拟核心入口。第零阶段：版本探针 + GDScript↔C++ 边界基准用的空方法。
class SimCore : public godot::RefCounted {
    GDCLASS(SimCore, godot::RefCounted)

public:
    godot::String get_version() const;
    // 边界调用成本基准：无参无返回、整型参数两种最常见形态
    void bench_noop();
    int64_t bench_add(int64_t a, int64_t b);

protected:
    static void _bind_methods();
};

} // namespace cive
