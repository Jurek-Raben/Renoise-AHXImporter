# Code Formatting

Formatting is derived from [.prettierrc.json](../.prettierrc.json). Prettier does not format Lua, so its settings are
translated into the following Lua rules. If TypeScript/JavaScript is ever added, Prettier applies to it directly.

## Mapping of .prettierrc.json to Lua

| Prettier setting            | Lua rule                                                                             |
| --------------------------- | ------------------------------------------------------------------------------------ |
| `printWidth: 120`           | Max line length 120 characters.                                                      |
| `tabWidth: 2`               | Indent with 2 spaces.                                                                |
| `useTabs: false`            | Never use tabs.                                                                      |
| `singleQuote: true`         | Use single quotes for strings (`'text'`); double quotes only to avoid escaping `'`.  |
| `semi: true`                | Not applicable to Lua: do **not** end statements with `;` (idiomatic Lua).           |
| `trailingComma: "es5"`      | Multiline table constructors get a trailing comma after the last entry.              |
| `importOrder: ["^[./]"]`    | `require` calls at the top of a file: Renoise/third-party first, then local modules. |
| `importOrderSeparation`     | Separate those two `require` groups with one empty line.                             |
| `importOrderSortSpecifiers` | Sort `require` calls alphabetically within each group.                               |

## General Lua conventions

- `local` for every variable and function unless it must be global (only Renoise entry points).
- Naming: `snake_case` for variables and functions, `PascalCase` for class-like module tables,
  `UPPER_SNAKE_CASE` for constants. Names ported from the AHX replayer are converted to `snake_case`
  (`SquareLowerLimit` → `square_lower_limit`).
- One module per file, returning a table: `local M = {} … return M`.
- Comments in English. LuaCATS annotations (`---@param`, `---@return`, `---@class`) for public functions and for the
  AHX data structures.
- Bit operations use LuaJIT's `bit` library (`local bit = require('bit')`), never Lua 5.3 operators.
- Wrap long function calls/tables like Prettier would: one argument/entry per line, closing bracket on its own line.

```lua
local bit = require('bit')

local Waves = require('ahx.waves')

local MAX_FILTER_SETS = 63

---Returns the square offset for a square position and wave length.
---@param square_pos integer
---@param wave_length integer 0..5
---@return integer
local function square_offset(square_pos, wave_length)
  return bit.lshift(square_pos, 5 - wave_length)
end

local defaults = {
  speed_multiplier = 1,
  track_length = 64,
}
```
