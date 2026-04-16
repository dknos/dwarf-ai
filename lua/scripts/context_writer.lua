-- context_writer.lua
-- Keybind: triggered when player faces an NPC and presses Talk (dfai-talk)
-- 1. Shows *Urist is thinking...* immediately
-- 2. Reads NPC state with nil-guards
-- 3. Prompts player for input
-- 4. Writes ipc/context/{uuid}.json

local json        = require('json')
local utils       = require('utils')
local guidm       = require('gui.dwarfmode')
local dialogs     = require('gui.dialogs')
local dwarf_state = reqscript('dfai/state/dwarf_state')
local world_state = reqscript('dfai/state/world_state')

local IPC_CONTEXT_DIR = 'C:/dwarf-ai-ipc/context'

local function uuid()
    -- Simple UUID-ish from tick + random
    math.randomseed(os.time and os.time() or dfhack.getTickCount())
    return string.format('%d-%d-%d',
        dfhack.getTickCount(), math.random(10000, 99999), math.random(100, 999))
end

local function get_facing_unit()
    -- Returns the unit the player cursor is on/nearest
    local cursor = guidm.getCursorPos()
    local player = df.global.world.units.active[0]
    local ppos = player and player.pos
    -- 1. Try current selected unit (works in adventure mode "look" cursor)
    local sel = dfhack.gui.getSelectedUnit(true)
    if sel and sel ~= player then return sel end
    -- 2. Try cursor position
    if cursor then
        for _, unit in ipairs(df.global.world.units.active) do
            local ok, pos = pcall(function() return unit.pos end)
            if ok and pos and pos.x == cursor.x and pos.y == cursor.y and pos.z == cursor.z then
                if unit ~= player then return unit end
            end
        end
    end
    -- 3. Fall back: nearest adjacent unit to player (within 2 tiles)
    if ppos then
        local best, best_dist = nil, 999
        for _, unit in ipairs(df.global.world.units.active) do
            if unit ~= player then
                local ok, p = pcall(function() return unit.pos end)
                if ok and p and p.z == ppos.z then
                    local dx = math.abs(p.x - ppos.x)
                    local dy = math.abs(p.y - ppos.y)
                    local d = math.max(dx, dy)
                    if d <= 2 and d < best_dist then
                        best, best_dist = unit, d
                    end
                end
            end
        end
        if best then return best end
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

-- Prompt the user for a message directed at a specific already-extracted state.
-- Used for initial talk() and for "Reply" continuations from response_reader.
local function prompt_and_send(state, unit)
    dialogs.showInputPrompt(
        'Speak to ' .. state.npc_name,
        'What do you say?',
        COLOR_WHITE,
        '',
        function(text)
            if not text or text == '' then return end
            state.interaction_id = uuid()
            state.type           = 'interactive'
            state.player_input   = text
            state.core_memories  = state.core_memories or {}

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

-- Continuation hook — called by response_reader when player clicks "Reply".
-- Receives the previous response's data dict so we can find the same unit.
_G.dfai_continue_talk = function(prev)
    local uid = prev and prev.unit_id
    local unit = uid and df.unit.find(uid) or nil
    if not unit then
        dfhack.gui.showAnnouncement('That NPC is no longer here.', COLOR_RED, false)
        return
    end
    local state = extract_npc_state(unit)
    prompt_and_send(state, unit)
end

-- Main entry point
local function talk()
    local unit = get_facing_unit()
    if not unit then
        dfhack.gui.showAnnouncement('No NPC nearby to talk to.', COLOR_RED, false)
        return
    end
    local state = extract_npc_state(unit)
    show_thinking(state.npc_name)
    prompt_and_send(state, unit)
end

talk()
