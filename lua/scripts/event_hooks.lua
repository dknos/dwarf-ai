-- event_hooks.lua
-- Installs DFHack event hooks for unit death, item creation, and combat reports.
-- For each event, writes a memory_event to ipc/context/{uuid}.json
-- so the Python bridge can index it via episodic.add_event().
--
-- Compatible with DFHack 50.x: uses dfhack.onStateChange (world load) and
-- repeat-call timers since the newer event API varies by build.

local json = require('json')

local IPC_CONTEXT_DIR = dfhack.getSavePath and dfhack.getSavePath() and
    (dfhack.getSavePath() .. '/dfai/ipc/context') or
    '/home/nemoclaw/dwarf-ai/lua/ipc/context'

-- ---------------------------------------------------------------------------
-- Helpers (mirrors context_writer.lua patterns)
-- ---------------------------------------------------------------------------

local function uuid()
    math.randomseed(os.time and os.time() or dfhack.getTickCount())
    return string.format('%d-%d-%d',
        dfhack.getTickCount(), math.random(10000, 99999), math.random(100, 999))
end

local function safe_get(tbl, ...)
    local cur = tbl
    for _, k in ipairs({...}) do
        if type(cur) ~= 'table' and type(cur) ~= 'userdata' then return nil end
        local ok, val = pcall(function() return cur[k] end)
        if not ok then return nil end
        cur = val
        if cur == nil then return nil end
    end
    return cur
end

local function unit_name(unit)
    if not unit then return 'someone' end
    -- Try historical figure name first
    local ok_hf, hfig = pcall(function()
        return df.historical_figure.find(unit.hist_figure_id)
    end)
    if ok_hf and hfig then
        local ok_n, name = pcall(function()
            return dfhack.TranslateName(hfig.name, true)
        end)
        if ok_n and name and name ~= '' then return name end
    end
    -- Fall back to unit.name
    local ok_n2, n2 = pcall(function()
        return dfhack.TranslateName(unit.name, true)
    end)
    if ok_n2 and n2 and n2 ~= '' then return n2 end
    return 'an unnamed dwarf'
end

local function site_name()
    -- Best-effort: try to get current site name
    local ok, site = pcall(function()
        return df.global.world.world_data.active_site[0]
    end)
    if ok and site then
        local ok_n, n = pcall(function()
            return dfhack.TranslateName(site.name, true)
        end)
        if ok_n and n and n ~= '' then return n end
    end
    return 'the fortress'
end

local function write_memory_event(payload)
    -- Ensure directory exists
    if dfhack.filesystem and dfhack.filesystem.mkdir_recursive then
        pcall(function() dfhack.filesystem.mkdir_recursive(IPC_CONTEXT_DIR) end)
    end
    local path = IPC_CONTEXT_DIR .. '/' .. payload.interaction_id .. '.json'
    local ok_enc, encoded = pcall(function() return json.encode(payload) end)
    if not ok_enc then
        dfhack.printerr('[dfai] event_hooks: json encode failed: ' .. tostring(encoded))
        return false
    end
    local f = io.open(path, 'w')
    if not f then
        dfhack.printerr('[dfai] event_hooks: cannot write: ' .. path)
        return false
    end
    f:write(encoded)
    f:close()
    return true
end

-- Build and dispatch a memory_event for a given unit
local function emit_memory_event(unit_id, event_text, emotional_weight)
    local payload = {
        interaction_id  = uuid(),
        type            = 'memory_event',
        unit_id         = unit_id,
        event_text      = event_text,
        emotional_weight = emotional_weight,
        tick            = dfhack.getTickCount(),
    }
    write_memory_event(payload)
    dfhack.print('[dfai] memory_event unit=' .. tostring(unit_id)
        .. ' ew=' .. tostring(emotional_weight) .. '\n')
end

-- ---------------------------------------------------------------------------
-- Witness detection: find dwarves near a position who would witness an event
-- ---------------------------------------------------------------------------

local function get_nearby_dwarves(pos, radius)
    radius = radius or 10
    local witnesses = {}
    if not pos then return witnesses end
    local ok_units, units = pcall(function() return df.global.world.units.active end)
    if not ok_units or not units then return witnesses end
    for _, u in ipairs(units) do
        -- Only consider dwarves (caste check) who are alive
        local ok_race, race = pcall(function() return u.race end)
        if ok_race and race then
            local ok_alive = pcall(function()
                return not u.flags1.dead
            end)
            if ok_alive then
                local ok_pos, upos = pcall(function() return u.pos end)
                if ok_pos and upos then
                    local dx = math.abs((upos.x or 0) - (pos.x or 0))
                    local dy = math.abs((upos.y or 0) - (pos.y or 0))
                    local dz = math.abs((upos.z or 0) - (pos.z or 0))
                    if dx <= radius and dy <= radius and dz <= 2 then
                        table.insert(witnesses, u)
                        if #witnesses >= 8 then break end
                    end
                end
            end
        end
    end
    return witnesses
end

-- ---------------------------------------------------------------------------
-- Event: unit death
-- ---------------------------------------------------------------------------

-- Track known-dead units to avoid repeat emissions
local _known_dead = {}

local function check_unit_deaths()
    local ok_units, units = pcall(function() return df.global.world.units.active end)
    if not ok_units or not units then return end

    for _, unit in ipairs(units) do
        local ok_id, uid = pcall(function() return unit.id end)
        if ok_id and uid then
            local ok_dead, is_dead = pcall(function() return unit.flags1.dead end)
            if ok_dead and is_dead and not _known_dead[uid] then
                _known_dead[uid] = true

                local dead_name = unit_name(unit)
                local ok_pos, pos = pcall(function() return unit.pos end)
                local loc = site_name()

                -- Determine cause (combat vs other)
                local cause = 'unknown causes'
                local ok_wound = pcall(function()
                    if unit.body and unit.body.wounds and #unit.body.wounds > 0 then
                        cause = 'combat wounds'
                    end
                end)
                if not ok_wound then cause = 'unknown causes' end

                local event_text = dead_name .. ' died from ' .. cause .. ' at ' .. loc .. '.'

                -- Emit for all nearby witnesses
                if ok_pos and pos then
                    local witnesses = get_nearby_dwarves(pos, 10)
                    for _, witness in ipairs(witnesses) do
                        local ok_wid, wid = pcall(function() return witness.id end)
                        if ok_wid and wid and wid ~= uid then
                            local wname = unit_name(witness)
                            local witness_text = wname .. ' witnessed ' .. dead_name
                                .. ' die from ' .. cause .. ' at ' .. loc .. '.'
                            emit_memory_event(wid, witness_text, 75)
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Event: item creation (high-quality craft)
-- ---------------------------------------------------------------------------

local _known_items = {}

local function check_item_creations()
    -- Only track masterwork+ items (quality >= 5)
    local ok_items, items = pcall(function() return df.global.world.items.all end)
    if not ok_items or not items then return end

    for _, item in ipairs(items) do
        local ok_id, iid = pcall(function() return item.id end)
        if not ok_id then goto continue end
        if _known_items[iid] then goto continue end

        -- Use getQuality() — masterwork is quality level 5
        local ok_q, quality = pcall(function() return item:getQuality() end)
        if not ok_q or not quality or quality < 5 then goto continue end

        _known_items[iid] = true

        -- Find the maker unit
        local ok_maker, maker_id = pcall(function() return item.maker end)
        if not ok_maker or not maker_id or maker_id <= 0 then goto continue end

        local ok_unit, maker_unit = pcall(function()
            return df.unit.find(maker_id)
        end)
        if not ok_unit or not maker_unit then goto continue end

        -- Item type name
        local ok_itype, itype = pcall(function()
            return df['item_type'][item:getType()] or 'item'
        end)
        local item_type_name = ok_itype and tostring(itype):lower():gsub('_', ' ') or 'item'

        local maker_name = unit_name(maker_unit)
        local event_text = maker_name .. ' crafted a masterwork ' .. item_type_name
            .. '. The quality is exceptional.'
        emit_memory_event(maker_id, event_text, 60)

        ::continue::
    end
end

-- ---------------------------------------------------------------------------
-- Event: combat reports
-- ---------------------------------------------------------------------------

local _last_combat_report_count = 0

local function check_combat_reports()
    local ok_reports, reports = pcall(function()
        return df.global.world.status.reports
    end)
    if not ok_reports or not reports then return end

    local count = #reports
    if count <= _last_combat_report_count then
        _last_combat_report_count = count
        return
    end

    -- Process new reports since last check
    for i = _last_combat_report_count, count - 1 do
        local ok_r, report = pcall(function() return reports[i] end)
        if not ok_r or not report then goto continue end

        -- Only combat-type reports
        local ok_type, rtype = pcall(function() return report.type end)
        if not ok_type then goto continue end
        local rtype_str = tostring(rtype):lower()
        if not rtype_str:find('combat') and not rtype_str:find('fight') then
            goto continue
        end

        -- Get text
        local ok_text, rtext = pcall(function() return report.text end)
        if not ok_text or not rtext or rtext == '' then goto continue end

        -- Get associated unit
        local ok_uid, report_uid = pcall(function() return report.unit_id end)
        if not ok_uid or not report_uid or report_uid < 0 then goto continue end

        local ok_unit, rep_unit = pcall(function()
            return df.unit.find(report_uid)
        end)
        if not ok_unit or not rep_unit then goto continue end

        local uname = unit_name(rep_unit)
        local event_text = uname .. ' was involved in combat: ' .. tostring(rtext):sub(1, 120)
        emit_memory_event(report_uid, event_text, 55)

        ::continue::
    end

    _last_combat_report_count = count
end

-- ---------------------------------------------------------------------------
-- Polling timer (DFHack 50.x compatible)
-- ---------------------------------------------------------------------------

-- Poll every 100 ticks (~1.7 game seconds at standard speed)
local POLL_INTERVAL = 100
local _last_tick = -1

local function on_tick()
    local ok_tick, tick = pcall(function() return dfhack.getTickCount() end)
    if not ok_tick then return end
    if tick - _last_tick < POLL_INTERVAL then return end
    _last_tick = tick

    -- Run each check in a protected call so one failure doesn't break others
    pcall(check_unit_deaths)
    pcall(check_item_creations)
    pcall(check_combat_reports)
end

-- ---------------------------------------------------------------------------
-- Install: hook into DFHack's repeat-util scheduler
-- ---------------------------------------------------------------------------

local repeatUtil = require('repeat-util')

-- Cancel any previous registration so re-loading this script is safe
repeatUtil.cancel('dfai_event_hooks')

-- Schedule on_tick to fire every POLL_INTERVAL ticks
repeatUtil.scheduleEvery('dfai_event_hooks', POLL_INTERVAL, 'ticks', on_tick)

dfhack.print('[dfai] event_hooks.lua loaded — polling every '
    .. tostring(POLL_INTERVAL) .. ' ticks\n')
