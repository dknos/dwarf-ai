-- context_writer.lua
-- Keybind: triggered when player faces an NPC and presses Talk (dfai-talk)
-- 1. Shows *Urist is thinking...* immediately
-- 2. Reads NPC state with nil-guards
-- 3. Prompts player for input
-- 4. Writes ipc/context/{uuid}.json

local json        = require('json')
local utils       = require('utils')
local guidm       = require('gui.dwarfmode')
local dwarf_state = require('scripts.state.dwarf_state')
local world_state = require('scripts.state.world_state')

local IPC_CONTEXT_DIR = dfhack.getSavePath() and
    (dfhack.getSavePath() .. '/dfai/ipc/context') or
    '/home/nemoclaw/dwarf-ai/lua/ipc/context'

local function uuid()
    -- Simple UUID-ish from tick + random
    math.randomseed(os.time and os.time() or dfhack.getTickCount())
    return string.format('%d-%d-%d',
        dfhack.getTickCount(), math.random(10000, 99999), math.random(100, 999))
end

local function get_facing_unit()
    -- Returns the unit the player cursor is on/nearest
    local cursor = guidm.getCursorPos()
    if not cursor then return nil end
    for _, unit in ipairs(df.global.world.units.active) do
        local ok, pos = pcall(function() return unit.pos end)
        if ok and pos and pos.x == cursor.x and pos.y == cursor.y and pos.z == cursor.z then
            if unit ~= df.global.world.units.active[0] then -- exclude player
                return unit
            end
        end
    end
    return nil
end

-- Delegate to canonical module (Phase 1).
local function extract_npc_state(unit)
    return dwarf_state.extract(unit)
end

local function show_thinking(unit_name)
    dfhack.gui.showAnnouncement(
        '*' .. unit_name .. ' is thinking...*',
        COLOR_YELLOW, false
    )
end

local function write_context(ctx)
    local dir = IPC_CONTEXT_DIR
    -- Ensure dir exists (DFHack can't mkdir -p, try dfhack.filesystem)
    if dfhack.filesystem and dfhack.filesystem.mkdir then
        pcall(function() dfhack.filesystem.mkdir_recursive(dir) end)
    end
    local path = dir .. '/' .. ctx.interaction_id .. '.json'
    local ok_enc, encoded = pcall(function() return json.encode(ctx) end)
    if not ok_enc then
        dfhack.printerr('[dfai] json encode failed: ' .. tostring(encoded))
        return false
    end
    local f = io.open(path, 'w')
    if not f then
        dfhack.printerr('[dfai] cannot write context: ' .. path)
        return false
    end
    f:write(encoded)
    f:close()
    return true
end

-- Main entry point — called from keybinding
local function talk()
    local unit = get_facing_unit()
    if not unit then
        dfhack.gui.showAnnouncement('No NPC nearby to talk to.', COLOR_RED, false)
        return
    end

    local state = extract_npc_state(unit)
    show_thinking(state.npc_name)

    dfhack.gui.showInputPrompt(
        'Speak to ' .. state.npc_name,
        'What do you say?',
        COLOR_WHITE,
        '',
        function(text)
            if not text or text == '' then return end
            state.interaction_id = uuid()
            state.type           = 'interactive'
            state.player_input   = text
            state.core_memories  = {}

            -- Phase 1: populate spatial context
            local ok_ws, ws = pcall(function() return world_state.scan(unit) end)
            if ok_ws and ws then
                state.room_description         = ws.room_description or ''
                state.interlocutor_description = ws.interlocutor_description or ''
            else
                state.room_description         = ''
                state.interlocutor_description = ''
            end

            write_context(state)
        end
    )
end

-- Keybinding registration
if dfhack.gui then
    dfhack.enablePlugin('hotkeys')
end

talk()   -- can also be called directly: script runs talk() on load
