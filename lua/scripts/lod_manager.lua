-- lod_manager.lua
-- Phase 1: AI Level-of-Detail manager.
--
-- Maintains two rosters:
--   active_roster[unit_id]  — dwarves that trigger API calls on next tick
--   dormant_roster[unit_id] — dwarves that are tracked but silent
--
-- Rules:
--   • On player cursor focus change: move the focused dwarf dormant→active.
--   • Dwarves in high_priority_zones (tavern, mayor_office, etc.) are always active.
--   • All other dwarves are dormant by default.
--
-- Config is read from ~/dwarf-ai/python/config.yaml via a minimal line parser.
-- No external YAML library required.
--
-- Usage (from another script):
--   local lod = require('scripts.lod_manager')
--   lod.init()               -- call once on load
--   lod.on_tick()            -- call from your tick handler
--   if lod.is_active(uid) then ... end

local M = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

M.active_roster  = {}   -- unit_id (number) → true
M.dormant_roster = {}   -- unit_id (number) → true

local _high_priority_zones = {}  -- set of lowercase zone strings
local _last_cursor_unit    = nil  -- unit_id of the dwarf last under cursor
local _initialized         = false

-- ---------------------------------------------------------------------------
-- Minimal YAML reader
-- ---------------------------------------------------------------------------
-- Only parses the top-level list under a given key, e.g.:
--   high_priority_zones:
--     - tavern
--     - mayor_office
-- Returns a table of string values, or {} on any error.

local function read_yaml_list(path, key)
    local f = io.open(path, 'r')
    if not f then return {} end
    local lines = {}
    for line in f:lines() do table.insert(lines, line) end
    f:close()

    local result  = {}
    local in_list = false

    for _, line in ipairs(lines) do
        -- Trim trailing whitespace
        local trimmed = line:match('^(.-)%s*$')

        if in_list then
            -- A dash-prefixed item at any indentation
            local item = trimmed:match('^%s*%-%s+(.+)$')
            if item then
                table.insert(result, item:lower())
            elseif trimmed ~= '' and not trimmed:match('^%s') then
                -- Hit a non-indented, non-blank line → end of list
                in_list = false
            end
        else
            -- Look for the target key
            if trimmed:match('^' .. key .. '%s*:') then
                in_list = true
            end
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Config loader
-- ---------------------------------------------------------------------------

local _CONFIG_PATH = '/home/nemoclaw/dwarf-ai/python/config.yaml'

local function load_config()
    local zones = read_yaml_list(_CONFIG_PATH, 'high_priority_zones')
    _high_priority_zones = {}
    for _, z in ipairs(zones) do
        _high_priority_zones[z] = true
    end
    if next(_high_priority_zones) == nil then
        -- Defaults if config missing / unparseable
        for _, z in ipairs({ 'tavern', 'mayor_office', 'meeting_hall', 'throne_room' }) do
            _high_priority_zones[z] = true
        end
    end
end

-- ---------------------------------------------------------------------------
-- Zone detection heuristic
-- ---------------------------------------------------------------------------
-- Returns a lowercase zone label for a unit's position, or nil.

local _ZONE_BUILDING_MAP = {
    INN_TAVERN    = 'tavern',
    MAYOR         = 'mayor_office',
    THRONE        = 'meeting_hall',
    TRADE_DEPOT   = 'trade_depot',
}

local function get_unit_zone(unit)
    local ok_pos, pos = pcall(function() return unit.pos end)
    if not ok_pos or not pos then return nil end

    -- Check if the unit is inside a civzone with a relevant type
    local ok_zones, zone_list = pcall(function()
        return dfhack.buildings.findCivZone(pos.x, pos.y, pos.z)
    end)
    if ok_zones and zone_list then
        -- findCivZone returns a single building or nil
        local ok_t, btype = pcall(function()
            return tostring(df.civzone_type[zone_list.type]):upper()
        end)
        if ok_t then
            if btype:find('INN') or btype:find('TAVERN') then return 'tavern' end
            if btype:find('THRONE')  then return 'meeting_hall'  end
        end
    end

    -- Check buildings at the tile for mayor / throne room
    local ok_bld, bld = pcall(function()
        return dfhack.buildings.findAtTile(pos.x, pos.y, pos.z)
    end)
    if ok_bld and bld then
        local ok_t, btype = pcall(function()
            return tostring(df.building_type[bld:getType()]):upper()
        end)
        if ok_t then
            for token, zone in pairs(_ZONE_BUILDING_MAP) do
                if btype:find(token) then return zone end
            end
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Roster management
-- ---------------------------------------------------------------------------

local function promote(unit_id)
    M.dormant_roster[unit_id] = nil
    M.active_roster[unit_id]  = true
end

local function demote(unit_id)
    M.active_roster[unit_id]  = nil
    M.dormant_roster[unit_id] = true
end

local function ensure_tracked(unit_id)
    if not M.active_roster[unit_id] and not M.dormant_roster[unit_id] then
        M.dormant_roster[unit_id] = true
    end
end

-- ---------------------------------------------------------------------------
-- Full roster refresh  (called periodically)
-- ---------------------------------------------------------------------------

local function refresh_all()
    local ok_units, active = pcall(function() return df.global.world.units.active end)
    if not ok_units or not active then return end

    for _, unit in ipairs(active) do
        local ok_id, uid = pcall(function() return unit.id end)
        if not ok_id then goto continue end

        -- Skip dead units
        local ok_dead, dead = pcall(function() return unit.flags1.dead end)
        if ok_dead and dead then
            M.active_roster[uid]  = nil
            M.dormant_roster[uid] = nil
            goto continue
        end

        ensure_tracked(uid)

        -- High-priority zone check
        local zone = get_unit_zone(unit)
        if zone and _high_priority_zones[zone] then
            promote(uid)
        end

        ::continue::
    end
end

-- ---------------------------------------------------------------------------
-- Cursor / focus detection
-- ---------------------------------------------------------------------------

local function update_focus()
    -- Attempt to read the cursor from dwarfmode
    local ok_guidm, guidm = pcall(require, 'gui.dwarfmode')
    if not ok_guidm then return end

    local ok_cur, cursor = pcall(function() return guidm.getCursorPos() end)
    if not ok_cur or not cursor then return end

    -- Find unit at cursor
    local ok_units, active = pcall(function() return df.global.world.units.active end)
    if not ok_units or not active then return end

    for _, unit in ipairs(active) do
        local ok_pos, pos = pcall(function() return unit.pos end)
        if ok_pos and pos and
           pos.x == cursor.x and pos.y == cursor.y and pos.z == cursor.z then
            local ok_id, uid = pcall(function() return unit.id end)
            if ok_id and uid ~= _last_cursor_unit then
                -- Cursor moved onto a new unit — promote it
                if _last_cursor_unit then
                    -- Only demote previous if it's not in a high-priority zone
                    local ok_prev, prev_unit = pcall(function()
                        return df.unit.find(_last_cursor_unit)
                    end)
                    if ok_prev and prev_unit then
                        local prev_zone = get_unit_zone(prev_unit)
                        if not (prev_zone and _high_priority_zones[prev_zone]) then
                            demote(_last_cursor_unit)
                        end
                    end
                end
                promote(uid)
                _last_cursor_unit = uid
            end
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Periodic LOD sweep  (every N ticks)
-- ---------------------------------------------------------------------------

local _SWEEP_TICKS    = 300   -- ~10 seconds at 30 ticks/sec
local _tick_counter   = 0

local function sweep()
    _tick_counter = _tick_counter + 1
    if _tick_counter < _SWEEP_TICKS then return end
    _tick_counter = 0
    refresh_all()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialise the LOD manager. Call once after world load.
function M.init()
    if _initialized then return end
    load_config()
    refresh_all()
    _initialized = true
end

--- Call from your dfhack.timeout / onTick handler every tick.
function M.on_tick()
    if not _initialized then M.init() end
    update_focus()
    sweep()
end

--- Returns true if the given unit_id is in the active roster.
--- @param unit_id number
--- @return boolean
function M.is_active(unit_id)
    return M.active_roster[unit_id] == true
end

--- Force-activate a unit (e.g. when they speak).
--- @param unit_id number
function M.activate(unit_id)
    promote(unit_id)
end

--- Force-deactivate a unit.
--- @param unit_id number
function M.deactivate(unit_id)
    demote(unit_id)
end

--- Reload config from disk (call after editing config.yaml).
function M.reload_config()
    load_config()
end

--- Returns a snapshot table { active = {...}, dormant = {...} } for debugging.
function M.debug_dump()
    local a, d = {}, {}
    for id in pairs(M.active_roster)  do table.insert(a, id) end
    for id in pairs(M.dormant_roster) do table.insert(d, id) end
    return { active = a, dormant = d }
end

return M
