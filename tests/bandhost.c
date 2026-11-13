/* Band-like Lua host for the watchface tests.
 *   bandhost <limitKB|0> script.lua [args...]
 * - hard heap limit and peak report (like a small-RAM device);
 * - every freed or moved block is overwritten with 0xDD first, so reading memory that Lua has
 *   already released (a dangling image pointer) shows up as garbage instead of passing silently;
 * - peek(addr, n): the bytes at a raw address, which is exactly what LVGL does with an
 *   lv_image_dsc_t / its data pointer;
 * - srcptr(s): the pointer luavgl hands to lv_image_set_src for a Lua string (lua_tolstring). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
static size_t used = 0, peak = 0, limit = 0; static int fails = 0;
/* stress: after `burstEvery` growing allocations, the next `burstLen` all fail (Lua's own
   emergency collection and retry fail too, so the error reaches the program) */
static long burstEvery = 0, burstLen = 0, allocCount = 0, burstLeft = 0, injected = 0;
static void *l_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud; if (ptr == NULL) osize = 0;
  if (nsize == 0) { if (ptr) { memset(ptr, 0xDD, osize); free(ptr); used -= osize; } return NULL; }
  if (limit && used - osize + nsize > limit) { fails++; return NULL; }
  if (burstEvery && nsize > osize) {
    if (burstLeft > 0) { burstLeft--; injected++; return NULL; }
    if (++allocCount % burstEvery == 0) { burstLeft = burstLen - 1; injected++; return NULL; }
  }
  void *p = malloc(nsize); if (!p) return NULL;
  if (ptr) { memcpy(p, ptr, osize < nsize ? osize : nsize); memset(ptr, 0xDD, osize); free(ptr); }
  used = used - osize + nsize; if (used > peak) peak = used; return p;
}
static int l_heap(lua_State *L) { lua_pushinteger(L, (lua_Integer)used); lua_pushinteger(L, (lua_Integer)peak); return 2; }
static int l_inject(lua_State *L) { burstEvery = (long)luaL_optinteger(L, 1, 0); burstLen = (long)luaL_optinteger(L, 2, 3); burstLeft = 0; lua_pushinteger(L, injected); return 1; }
static int l_peek(lua_State *L) {
  uintptr_t a = (uintptr_t)luaL_checkinteger(L, 1); size_t n = (size_t)luaL_checkinteger(L, 2);
  lua_pushlstring(L, (const char *)a, n); return 1;
}
static int l_srcptr(lua_State *L) {
  const char *s = lua_tolstring(L, 1, NULL); lua_pushinteger(L, (lua_Integer)(uintptr_t)s); return 1;
}
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: bandhost limitKB script.lua [args]\n"); return 2; }
  limit = (size_t)atol(argv[1]) * 1024;
  lua_State *L = lua_newstate(l_alloc, NULL);
  luaL_openlibs(L);
  lua_register(L, "heap_usage", l_heap);
  lua_register(L, "inject_alloc_failures", l_inject);
  lua_register(L, "peek", l_peek);
  lua_register(L, "srcptr", l_srcptr);
  lua_pushinteger(L, (lua_Integer)sizeof(void *)); lua_setglobal(L, "HOST_PTR_BYTES");
  lua_newtable(L); for (int i = 2; i < argc; i++) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 2); } lua_setglobal(L, "arg");
  int rc = luaL_dofile(L, argv[2]);
  if (rc != LUA_OK) fprintf(stderr, "LUA ERROR: %s\n", lua_tostring(L, -1));
  printf("PEAK_HEAP_KB %zu FAILED_ALLOCS %d STATUS %s\n", peak / 1024, fails, rc == LUA_OK ? "ok" : "error");
  lua_close(L);
  return rc == LUA_OK ? 0 : 1;
}
