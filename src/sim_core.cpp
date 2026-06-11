#include "sim_core.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

namespace cive {

String SimCore::get_version() const {
    return "sim_core 0.1.0";
}

void SimCore::bench_noop() {}

int64_t SimCore::bench_add(int64_t a, int64_t b) {
    return a + b;
}

void SimCore::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_version"), &SimCore::get_version);
    ClassDB::bind_method(D_METHOD("bench_noop"), &SimCore::bench_noop);
    ClassDB::bind_method(D_METHOD("bench_add", "a", "b"), &SimCore::bench_add);
}

} // namespace cive
