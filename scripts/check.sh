#!/bin/sh
# Static checks for the Renoise tool. Never executes tool code.
# 1. Syntax check with LuaJIT (same Lua flavor as Renoise).
# 2. Lint with luacheck, run under LuaJIT because the Homebrew luacheck (Lua 5.5) does not start.
#    luacheck needs LuaFileSystem only for directory/cache handling, so a minimal stub is used and files are passed
#    explicitly.

cd "$(dirname "$0")/.." || exit 1

FILES=$(find ai.claude.AHXImporter.xrnx -name '*.lua' | sort)
STATUS=0

for file in $FILES; do
  luajit -bl "$file" > /dev/null || STATUS=1
done

LUACHECK_SHARE=/opt/homebrew/share/lua/5.5
LUACHECK_BIN=$(ls /opt/homebrew/lib/luarocks/rocks-5.5/luacheck/*/bin/luacheck | tail -n 1)

# shellcheck disable=SC2086
luajit -e "
package.path = '$LUACHECK_SHARE/?.lua;$LUACHECK_SHARE/?/init.lua;' .. package.path
package.preload.lfs = function()
  return {
    _VERSION = 'LuaFileSystem 1.8.0',
    currentdir = function() return os.getenv('PWD') end,
    attributes = function(path, key)
      local file = io.open(path)
      if not file then return nil end
      file:close()
      local attributes = { mode = 'file', modification = 0 }
      if key then return attributes[key] end
      return attributes
    end,
    dir = function() return function() return nil end end,
  }
end
" "$LUACHECK_BIN" --no-cache --config .luacheckrc $FILES || STATUS=1

exit $STATUS
