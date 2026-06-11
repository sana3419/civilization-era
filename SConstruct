#!/usr/bin/env python
import os

# godot-cpp 4.5 分支 + 4.6 dump 的 API（精确匹配运行引擎）
ARGUMENTS.setdefault("custom_api_file", "extension_api_4.6.json")

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/"])
# 模拟核心禁 FMA 合并：golden test 依赖跨架构（arm 开发机 / x86 CI）逐位一致，
# 仅使用 IEEE 精确运算（+ - * / sqrt floor）
env.Append(CCFLAGS=["-ffp-contract=off"])
sources = Glob("src/*.cpp")

library = env.SharedLibrary(
    "game/bin/libsim_core{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)
Default(library)
