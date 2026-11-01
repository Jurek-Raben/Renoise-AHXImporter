-- luacheck config for the Renoise tool (LuaJIT / Lua 5.1 with Renoise extensions).

std = 'luajit'
max_line_length = 120

-- Renoise reads this global to auto-reload the tool on file changes.
globals = { '_AUTO_RELOAD_DEBUG' }

read_globals = {
  'renoise',
  'rprint',
  'oprint',
  table = { fields = { 'create', 'is_empty', 'count', 'find', 'keys', 'values', 'copy', 'rcopy', 'clear' } },
  os = { fields = { 'platform', 'currentdir', 'dirnames', 'filenames', 'mkdir', 'move' } },
  io = { fields = { 'exists', 'stat', 'chmod' } },
  math = { fields = { 'lin2db', 'db2lin', 'db2fader', 'fader2db' } },
}
