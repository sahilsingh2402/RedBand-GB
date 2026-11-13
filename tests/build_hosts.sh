#!/bin/sh
# Build the test hosts: bandhost64 (system Lua 5.4) and bandhost32 (Lua 5.4.0 like the band:
# 32-bit pointers, 64-bit integers, double floats). Needs gcc, gcc-multilib, git, liblua5.4-dev.
set -e
cd "$(dirname "$0")"
gcc -O2 -o bandhost64 bandhost.c -I/usr/include/lua5.4 -llua5.4
T=$(mktemp -d); git clone -q --depth 1 --branch v5.4.0 https://github.com/lua/lua.git "$T/lua" 2>/dev/null
SRC=$(cd "$T/lua" && ls *.c | grep -v -E '^(lua|luac|onelua|ltests)\.c$' | sed "s#^#$T/lua/#")
gcc -m32 -O2 -DLUA_USE_LINUX -I"$T/lua" -o bandhost32 bandhost.c $SRC -lm -ldl
rm -rf "$T"
echo "built tests/bandhost64 and tests/bandhost32 (Lua 5.4.0, 32-bit)"
