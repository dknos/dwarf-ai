-- action_executor.lua
-- Validates and applies JSON action commands from the LLM.
-- On validation failure: writes a replan context file so the LLM can react.

local json = require('json')

local IPC_CONTEXT_DIR = '/home/nemoclaw/dwarf-ai/lua/ipc/context'

local function uuid()
    math.randomseed(dfhack.getTickCount() + math.random(99999))
    return string.format('replan-%d-%d', dfhack.getTickCount(), math.random(10000,99999))
end

local function write_replan(original_data, reason)
    local ctx = {
        interaction_id = uuid(),
        unit_id        = original_data.unit_id or 0,
        type           = 'interactive',
        player_input   = '',
        system_note    = 'System Note: ' .. reason .. ' Respond with confusion or frustration.',
        npc_name       = original_data.npc_name or 'Unknown',
        npc_race       = original_data.npc_race or '',
        npc_profession = original_data.npc_profession or '',
        facets         = original_data.facets or {},
        values         = original_data.values or {},
        emotions       = original_data.emotions or {},
        wounds         = original_data.wounds or {},
        hunger = 0, thirst = 0, fatigue = 0, alcohol = 0,
        room_description = original_data.room_description or '',
        interlocutor_description = original_data.interlocutor_description or '',
        core_memories  = original_data.core_memories or {},
    }
    local path = IPC_CONTEXT_DIR .. '/' .. ctx.interaction_id .. '.json'
    local ok, encoded = pcall(function() return json.encode(ctx) end)
    if not ok then return end
    local f = io.open(path, 'w')
    if not f then return end
    f:write(encoded)
    f:close()
    dfhack.printerr('[dfai] action failed — replan written: ' .. ctx.interaction_id)
end

local function unit_alive(unit_id)
    local ok, unit = pcall(function() return df.unit.find(unit_id) end)
    if not ok or not unit then return false end
    local ok2, dead = pcall(function() return unit.flags1.dead end)
    return ok2 and not dead
end

local function execute(action, original_data)
    local atype = action.type or 'none'

    if atype == 'none' or atype == 'speak' then
        -- speak is handled by show_dialogue in response_reader
        return

    elseif atype == 'initiate_brawl' then
        if not unit_alive(action.instigator_id) then
            write_replan(original_data,
                'You tried to start a brawl but the instigator no longer exists.')
            return
        end
        if not unit_alive(action.target_id) then
            write_replan(original_data,
                'You moved to attack but your target is no longer there.')
            return
        end
        -- Apply: set unit to brawl order (DFHack job injection)
        local ok, err = pcall(function()
            local instigator = df.unit.find(action.instigator_id)
            dfhack.units.teleport(instigator, df.unit.find(action.target_id).pos)
        end)
        if not ok then
            write_replan(original_data, 'Could not initiate brawl: ' .. tostring(err))
        end

    elseif atype == 'flee' then
        if not unit_alive(action.unit_id) then return end
        -- Mark unit as fleeing via panic flag
        local ok, err = pcall(function()
            local unit = df.unit.find(action.unit_id)
            unit.status.retreat_status = 1
        end)
        if not ok then
            dfhack.printerr('[dfai] flee action error: ' .. tostring(err))
        end

    elseif atype == 'modify_mood' then
        if not unit_alive(action.unit_id) then return end
        local ok, err = pcall(function()
            local unit = df.unit.find(action.unit_id)
            local delta = math.max(-1000, math.min(1000, action.stress_delta or 0))
            unit.status.current_soul.personality.stress_level =
                (unit.status.current_soul.personality.stress_level or 0) + delta
        end)
        if not ok then
            dfhack.printerr('[dfai] modify_mood error: ' .. tostring(err))
        end

    elseif atype == 'public_rant' then
        if not unit_alive(action.unit_id) then return end
        dfhack.gui.showAnnouncement(
            (original_data.npc_name or 'A dwarf') .. ' rants: ' .. (action.topic or '...'),
            COLOR_RED, true
        )

    elseif atype == 'request_meeting' then
        dfhack.gui.showAnnouncement(
            (original_data.npc_name or 'Someone') .. ' requests an audience with the mayor.',
            COLOR_YELLOW, true
        )
    end
end

return { execute = execute }
