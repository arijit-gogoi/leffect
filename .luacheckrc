-- "min" is the intersection of the standard globals of every Lua version, so
-- anything only one of LuaJIT 2.1 / Lua 5.4 provides (unpack, table.unpack,
-- coroutine.close, jit, ...) must be feature-detected and whitelisted locally.
std = "min"

-- CI actions install Lua and LuaRocks inside the checkout.
exclude_files = { ".lua/**", ".luarocks/**", "lua_modules/**", ".install/**" }

files["spec"] = { std = "+busted" }
