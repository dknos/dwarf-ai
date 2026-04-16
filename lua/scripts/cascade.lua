-- cascade.lua
--@module = true
-- When a hostile action fires, ripple outward to all nearby NPCs so the
-- LLM gets a chance to pick their individual reaction (flee / attack /
-- call guards / do nothing) based on their personality.

local json        = require('json')
local dwarf_state = reqscript('dfai/state/dwarf_state')

local IPC_CONTEXT_DIR = 'C:/dwarf-ai-ipc/context'

local function uuid()
    math.randomseed(dfhack.getTickCount() + math.random(99999))
    return string.format('cascade-%d-%d',
        dfhack.getTickCount(), math.random(10000, 99999))
end

local function sanitize(v)
    if type(v) == 'string' then return (v:gsub('[\128-\255]', '?'))
    elseif type(v) == 'table' then
        local out = {}
        for k, vv in pairs(v) do out[k] = sanitize(vv) end
        return out
    end
    return v
end

local function write(ctx)
    if dfhack.filesystem and dfhack.filesystem.mkdir_recursive then
        pcall(function() dfhack.filesystem.mkdir_recursive(IPC_CONTEXT_DIR) end)
    end
    local path = IPC_CONTEXT_DIR .. '/' .. ctx.interaction_id .. '.json'
    local ok, enc = pcall(function() return json.encode(ctx) end)
    if not ok then return end
    local f = io.open(path, 'w')
    if not f then return end
    f:write(enc); f:close()
end

-- Find all living NPCs within `radius` of `origin_pos`, excluding the
-- origin NPC and the player. Returns up to `max_count` units.
function find_bystanders(origin_pos, exclude_ids, radius, max_count)
    exclude_ids = exclude_ids or {}
    radius      = radius or 10
    max_count   = max_count or 8
    local out = {}
    local player
    pcall(function() player = dfhack.world.getAdventurer() end)
    for _, unit in ipairs(df.global.world.units.active) do
        if unit ~= player then
            local ok_d, dead = pcall(function() return unit.flags1.dead end)
            if ok_d and not dead then
                local ok_p, p = pcall(function() return unit.pos end)
                if ok_p and p and p.z == origin_pos.z then
                    local dx = math.abs(p.x - origin_pos.x)
                    local dy = math.abs(p.y - origin_pos.y)
                    local d  = math.max(dx, dy)
                    if d <= radius then
                        local id = tonumber(unit.id) or 0
                        local skip = false
                        for _, eid in ipairs(exclude_ids) do
                            if eid == id then skip = true; break end
                        end
                        if not skip then
                            table.insert(out, unit)
                            if #out >= max_count then return out end
                        end
                    end
                end
            end
        end
    end
    return out
end

-- Fire a spontaneous context request asking a witness how they react.
function fire_witness_reaction(witness, event_description, location)
    local ok_state, state = pcall(function() return dwarf_state.extract(witness) end)
    if not ok_state or not state then return end

    state.interaction_id = 'witness-' .. uuid()
    state.type           = 'spontaneous'
    state.pressure_type  = 'witness'
    state.pressure_level = 80
    state.player_input   = ''
    state.system_note    =
        'You just witnessed: ' .. (event_description or 'something violent') ..
        ' at ' .. (location or 'this location') ..
        '. The player is right here. What do you do NOW? ' ..
        'Your personality decides: flee in terror, shout for the guard, ' ..
        'attack the attacker, or stand paralyzed. Pick an action that ' ..
        'matches your values, courage, and physical state. Do not stay silent.'
    state.room_description         = ''
    state.interlocutor_description = 'The player stands before you, right after the event.'
    state.core_memories            = {}

    write(sanitize(state))
    dfhack.print('[dfai] cascade witness id=' .. tostring(state.unit_id) .. '\n')
end

-- Public entry: call this after any hostile / violent action.
-- Loops all bystanders in range and fires a witness reaction for each.
function trigger(origin_pos, origin_unit_id, event_description)
    local location = 'here'
    pcall(function()
        local site = df.global.world.world_data.active_site[0]
        if site then
            location = dfhack.TranslateName(site.name, true) or 'here'
        end
    end)
    local witnesses = find_bystanders(origin_pos,
        origin_unit_id and { origin_unit_id } or {}, 10, 6)
    for _, w in ipairs(witnesses) do
        fire_witness_reaction(w, event_description, location)
    end
    dfhack.gui.showAnnouncement(
        '[dfai] Cascade fired to ' .. #witnesses .. ' bystanders',
        COLOR_LIGHTMAGENTA, false)
end
