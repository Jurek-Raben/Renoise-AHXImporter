-- Hands out the modulation sets of an instrument loaded from a template (`XrniWriter`): the template holds enough
-- sets with the macros already mapped, the writers take them instead of inserting new ones (a new set would have no
-- mapping), and the unused ones are removed at the end.

local XrniWriter = require('importer.xrni_writer')

local ModulationSets = {}

---@param modulation_set renoise.SampleModulationSet
---@return boolean
local function is_unused(modulation_set)
  return modulation_set.name == XrniWriter.UNUSED_SET_NAME
end

---Set 1, shared by the samples that need no set of their own.
---@param target renoise.Instrument
---@return renoise.SampleModulationSet
function ModulationSets.first(target)
  if #target.sample_modulation_sets == 0 then
    target:insert_sample_modulation_set_at(1)
  end
  local modulation_set = target.sample_modulation_sets[1]
  if is_unused(modulation_set) then
    modulation_set.name = 'Set 01'
  end
  return modulation_set
end

---The next set: the first unused one of the template, otherwise a new one at the end (without macro mappings).
---@param target renoise.Instrument
---@return renoise.SampleModulationSet modulation_set
---@return integer index
function ModulationSets.take(target)
  for index, modulation_set in ipairs(target.sample_modulation_sets) do
    if is_unused(modulation_set) then
      modulation_set.name = ('Set %02d'):format(index)
      return modulation_set, index
    end
  end
  local index = #target.sample_modulation_sets + 1
  target:insert_sample_modulation_set_at(index)
  return target.sample_modulation_sets[index], index
end

---Removes the unused sets of the template (always the last ones).
---@param target renoise.Instrument
function ModulationSets.trim(target)
  for index = #target.sample_modulation_sets, 1, -1 do
    if not is_unused(target.sample_modulation_sets[index]) then
      break
    end
    target:delete_sample_modulation_set_at(index)
  end
end

return ModulationSets
