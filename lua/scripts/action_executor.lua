-- action_executor.lua
--@module = true
-- Validates and applies JSON action commands from the LLM.
-- On validation failure: writes a replan context file so the LLM can react.

local json = require('json')

local IPC_CONTEXT_DIR = 'C:/dwarf-ai-ipc/context'

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

-- Always-resolve helpers — instigator = the NPC this conversation is with,
-- target = the player character. No LLM-provided IDs needed.
local function get_npc_unit(original_data)
    local uid = original_data and original_data.unit_id
    if uid then
        local ok, u = pcall(function() return df.unit.find(uid) end)
        if ok and u then return u end
    end
    return nil
end

local function get_player_unit()
    -- Canonical: dfhack.world.getAdventurer() works in adventure mode.
    local ok, u = pcall(function() return dfhack.world.getAdventurer() end)
    if ok and u then return u end
    -- Fallback for fort mode: no player; use units.active[0]
    local ok2, u2 = pcall(function() return df.global.world.units.active[0] end)
    return ok2 and u2 or nil
end

function execute(action, original_data)
    local atype = action.type or 'none'

    if atype == 'none' or atype == 'speak' then
        return

    elseif atype == 'initiate_brawl' then
        local npc    = get_npc_unit(original_data)
        local player = get_player_unit()
        if not npc or not player then
            write_replan(original_data,
                'The one you wished to strike is no longer in the world.')
            return
        end
        local intensity = action.intensity or 'strike'
        local ok, err = pcall(function()
            -- Real hostility setup — works in both fort and adventure mode.
            -- 1. Strip civ affiliation so vanilla AI treats player as enemy.
            npc.civ_id               = -1
            -- 2. Flag as invader (combat AI will engage nearest non-hostile).
            npc.flags1.active_invader = true
            npc.flags2.visitor        = false
            npc.flags2.visitor_uninvited = true
            -- 3. Drop any friendly relations
            pcall(function() npc.relationship_ids:resize(0) end)
            -- 4. Add a hate-link general_ref so DF's AI knows who to target.
            local ref = df.general_ref_unit_attackerst:new()
            ref.unit_id = tonumber(player.id) or 0
            npc.general_refs:insert('#', ref)
            -- 5. Clear any current job so the combat AI takes over immediately.
            if npc.job.current_job then
                dfhack.job.removeJob(npc.job.current_job)
            end
            -- 6. Teleport adjacent to guarantee they can see the player.
            dfhack.units.teleport(npc, player.pos)
            -- 7. Point the NPC's facing at the player.
            npc.facing_direction = 0  -- will re-target on next tick
        end)
        if not ok then
            dfhack.printerr('[dfai] initiate_brawl err: ' .. tostring(err))
        end
        local verb = intensity == 'kill' and 'lunges with lethal intent' or
                     intensity == 'shove' and 'shoves you back' or
                     'attacks'
        dfhack.gui.showAnnouncement(
            (original_data.npc_name or 'A dwarf') .. ' ' .. verb .. '!',
            COLOR_LIGHTRED, true
        )
        -- Ripple: trigger witness reactions for nearby NPCs.
        pcall(function()
            local cascade = reqscript('dfai/cascade')
            cascade.trigger(player.pos, tonumber(npc.id),
                (original_data.npc_name or 'Someone') .. ' attacks the player')
        end)

    elseif atype == 'flee' then
        local npc    = get_npc_unit(original_data)
        local player = get_player_unit()
        if not npc then return end
        pcall(function()
            -- Real flee: teleport away from player + set retreat flag + speed boost.
            if player and player.pos then
                local away_x = npc.pos.x + (npc.pos.x - player.pos.x) * 5
                local away_y = npc.pos.y + (npc.pos.y - player.pos.y) * 5
                -- Keep on same z level, clamp to reasonable map range.
                local dest = {
                    x = math.max(1, math.min(200, away_x)),
                    y = math.max(1, math.min(200, away_y)),
                    z = npc.pos.z,
                }
                dfhack.units.teleport(npc, dest)
            end
            npc.status.retreat_status = 1
            npc.flags3.dangerous_terrain = false
        end)
        dfhack.gui.showAnnouncement(
            (original_data.npc_name or 'Someone') .. ' flees in terror!',
            COLOR_YELLOW, true)
        -- Panic spreads: others nearby get a witness reaction too.
        pcall(function()
            local cascade = reqscript('dfai/cascade')
            if player and player.pos then
                cascade.trigger(player.pos, tonumber(npc.id),
                    (original_data.npc_name or 'Someone') .. ' flees from the player in terror')
            end
        end)

    elseif atype == 'call_guards' then
        local reason = action.reason or 'a disturbance'
        dfhack.gui.showAnnouncement(
            (original_data.npc_name or 'Someone') .. ' shouts for the guard: "' .. reason .. '!"',
            COLOR_LIGHTRED, true
        )
        -- The shout alerts everyone nearby — cascade witness reactions.
        pcall(function()
            local cascade = reqscript('dfai/cascade')
            local player = get_player_unit()
            if player and player.pos then
                cascade.trigger(player.pos,
                    tonumber((get_npc_unit(original_data) or {}).id) or -1,
                    (original_data.npc_name or 'Someone')
                        .. ' shouts for the guards: ' .. reason)
            end
        end)

    elseif atype == 'issue_threat' then
        local threat = action.threat or 'Consequences will follow.'
        dfhack.gui.showAnnouncement(
            (original_data.npc_name or 'Someone') .. ' warns: "' .. threat .. '"',
            COLOR_YELLOW, true
        )

    elseif atype == 'demand_payment' then
        local amt    = action.amount or 0
        local reason = action.reason or ''
        dfhack.gui.showAnnouncement(
            (original_data.npc_name or 'Someone') .. ' demands '
                .. tostring(amt) .. ' coins — ' .. reason,
            COLOR_YELLOW, true
        )

    elseif atype == 'offer_quest' then
        local title     = action.title or 'An errand'
        local objective = action.objective or ''
        local reward    = action.reward or ''
        dfhack.gui.showAnnouncement(
            '[Quest] ' .. (original_data.npc_name or 'Someone') .. ' offers: '
                .. title .. ' -- ' .. objective .. ' (reward: ' .. reward .. ')',
            COLOR_LIGHTCYAN, true
        )

    elseif atype == 'modify_mood' then
        local npc = get_npc_unit(original_data)
        if not npc then return end
        local ok, err = pcall(function()
            local delta = math.max(-1000, math.min(1000, action.stress_delta or 0))
            npc.status.current_soul.personality.stress_level =
                (npc.status.current_soul.personality.stress_level or 0) + delta
        end)
        if not ok then
            dfhack.printerr('[dfai] modify_mood error: ' .. tostring(err))
        end

    elseif atype == 'public_rant' then
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

