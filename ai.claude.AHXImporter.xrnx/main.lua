-- AHX Importer: imports AHX/THX chiptune songs (Amiga, Dexter/Abyss) into Renoise.

-- @build:skip-start
-- Makes Renoise reload the tool whenever one of its files changes (development only).
_AUTO_RELOAD_DEBUG = function()
end
-- @build:skip-end

local Controller = require('importer.controller')

renoise.tool():add_menu_entry {
  name = 'Main Menu:File:Import AHX Song...',
  invoke = Controller.start,
}

renoise.tool():add_file_import_hook {
  category = 'song',
  extensions = { 'ahx', 'thx' },
  invoke = Controller.import_file,
}
