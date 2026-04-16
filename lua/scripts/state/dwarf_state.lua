-- dwarf_state.lua
--@module = true
-- Canonical NPC state extractor for dwarf-ai Phase 1.
-- Returns a state table with personality facets, values, emotions,
-- body wounds, and hunger/thirst/fatigue/alcohol counters.
-- All field accesses use nil-guards or pcall — current_soul may be nil
-- for visitors, husks, and dead units.
--
-- Usage:
--   local dwarf_state = require('scripts.state.dwarf_state')
--   local state = dwarf_state.extract(unit)

local M = _ENV

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Safely traverse a chain of table/userdata keys.
--- Returns nil on any access failure instead of raising.
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

--- Safely read a numeric counter from unit.counters[key].
local function safe_counter(unit, key)
    local ok, v = pcall(function() return unit.counters[key] end)
    return ok and (tonumber(v) or 0) or 0
end

-- ---------------------------------------------------------------------------
-- Name resolution
-- ---------------------------------------------------------------------------

local function resolve_name(unit)
    -- 1. DFHack's canonical readable name — handles historical figures,
    --    translation, epithets, profession-prefixed names, etc.
    local ok_rn, rn = pcall(function()
        return dfhack.units.getReadableName(unit)
    end)
    if ok_rn and rn and rn ~= '' then return rn end

    -- 2. Historical figure translated name
    local ok_hf, hfig = pcall(function()
        return df.historical_figure.find(unit.hist_figure_id)
    end)
    if ok_hf and hfig then
        local ok_n, name = pcall(function()
            return dfhack.TranslateName(hfig.name, true)
        end)
        if ok_n and name and name ~= '' then return name end
        -- native (dwarvish) name
        local ok_nn, nn = pcall(function()
            return dfhack.TranslateName(hfig.name, false)
        end)
        if ok_nn and nn and nn ~= '' then return nn end
    end

    -- 3. Unit name translated / native
    local ok_n2, n2 = pcall(function()
        return dfhack.TranslateName(unit.name, true)
    end)
    if ok_n2 and n2 and n2 ~= '' then return n2 end
    local ok_n3, n3 = pcall(function()
        return dfhack.TranslateName(unit.name, false)
    end)
    if ok_n3 and n3 and n3 ~= '' then return n3 end

    -- 4. Profession + race fallback
    local ok_prof, prof = pcall(function()
        local p = df['profession'][unit.profession] or ''
        return tostring(p):lower():gsub('_', ' ')
    end)
    local ok_race, rr = pcall(function()
        return df.creature_raw.find(unit.race).name[0]
    end)
    if ok_prof and ok_race and prof ~= '' and rr then
        return rr:gsub("^%l", string.upper) .. ' ' .. prof
    end
    return 'Unknown'
end

-- ---------------------------------------------------------------------------
-- Race / profession
-- ---------------------------------------------------------------------------

local function resolve_race(unit)
    local ok, race_raw = pcall(function() return df.creature_raw.find(unit.race) end)
    if ok and race_raw then
        local ok_n, rn = pcall(function() return race_raw.name[0] end)
        if ok_n and rn and rn ~= '' then
            return rn:gsub("^%l", string.upper)
        end
    end
    return 'Unknown'
end

local function resolve_profession(unit)
    local ok, prof = pcall(function()
        return df['profession'][unit.profession] or 'UNKNOWN'
    end)
    if ok then
        return tostring(prof):lower():gsub('_', ' ')
    end
    return 'commoner'
end

-- ---------------------------------------------------------------------------
-- Personality facets
-- ---------------------------------------------------------------------------

local function extract_facets(soul)
    local facets = {}
    local facet_list = safe_get(soul, 'personality', 'facets')
    if not facet_list then return facets end

    local ft = df.personality_facet_type
    if not ft then return facets end

    for k, v in pairs(ft) do
        if type(k) == 'string' then
            local ok_f, val = pcall(function() return facet_list[v] end)
            if ok_f and type(val) == 'number' then
                facets[k] = val
            end
        end
    end
    return facets
end

-- ---------------------------------------------------------------------------
-- Belief / value system
-- ---------------------------------------------------------------------------

local function extract_values(soul)
    local values = {}
    local value_list = safe_get(soul, 'personality', 'values')
    if not value_list then return values end

    local bt = df.belief_system_type
    if not bt then return values end

    for k, v in pairs(bt) do
        if type(k) == 'string' then
            local ok_v, val = pcall(function() return value_list[v] end)
            if ok_v and type(val) == 'number' then
                values[k] = val
            end
        end
    end
    return values
end

-- ---------------------------------------------------------------------------
-- Emotions (top 3 by absolute strength)
-- ---------------------------------------------------------------------------

local function extract_emotions(soul)
    local emotions = {}
    local raw_emotions = safe_get(soul, 'emotions')
    if not raw_emotions then return emotions end

    local elist = {}
    for _, em in ipairs(raw_emotions) do
        local ok_e, etype    = pcall(function() return df['emotion_type'][em.type] end)
        local ok_s, strength = pcall(function() return em.strength end)
        local ok_t, thought  = pcall(function() return em.thought end)
        if ok_e and ok_s then
            table.insert(elist, {
                type     = tostring(etype or 'unknown'):lower(),
                strength = strength or 0,
                thought  = ok_t and tostring(thought or '') or '',
            })
        end
    end

    -- Sort by strength descending
    table.sort(elist, function(a, b) return a.strength > b.strength end)
    for i = 1, math.min(3, #elist) do
        table.insert(emotions, elist[i])
    end
    return emotions
end

-- ---------------------------------------------------------------------------
-- Body wounds
-- ---------------------------------------------------------------------------

local function extract_wounds(unit)
    local wounds = {}
    local raw_wounds = safe_get(unit, 'body', 'wounds')
    if not raw_wounds then return wounds end

    for _, w in ipairs(raw_wounds) do
        local ok_bp, bp = pcall(function()
            return unit.body.body_plan.body_parts[w.body_part_id].token
        end)
        local ok_bl, bleeding = pcall(function() return w.flags.BLEEDING end)
        local ok_ms, missing  = pcall(function() return w.flags.MISSING   end)
        local ok_sv, severity = pcall(function()
            -- DF wound severity is tracked per-layer; approximate via wound count
            local layers = 0
            for _ in ipairs(w.layer_wound) do layers = layers + 1 end
            if layers >= 4 then return 'severe'
            elseif layers >= 2 then return 'moderate'
            else return 'minor'
            end
        end)
        table.insert(wounds, {
            body_part = ok_bp and tostring(bp):lower() or 'body',
            bleeding  = ok_bl and bleeding or false,
            missing   = ok_ms and missing  or false,
            severity  = ok_sv and severity  or 'minor',
        })
    end
    return wounds
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Extract a full state table from a df.unit.
--- Safe against nil souls, dead units, and visitors.
--- @param unit df.unit
--- @return table state
function M.extract(unit)
    if not unit then
        return { unit_id = 0, npc_name = 'Unknown', npc_race = '', npc_profession = '',
                 facets = {}, values = {}, emotions = {}, wounds = {},
                 hunger = 0, thirst = 0, fatigue = 0, alcohol = 0 }
    end

    local state = {
        unit_id        = tonumber(unit.id) or 0,
        npc_name       = resolve_name(unit),
        npc_race       = resolve_race(unit),
        npc_profession = resolve_profession(unit),
        facets         = {},
        values         = {},
        emotions       = {},
        wounds         = {},
        hunger         = 0,
        thirst         = 0,
        fatigue        = 0,
        alcohol        = 0,
    }

    -- Soul-dependent fields (nil for visitors/dead units)
    local soul = safe_get(unit, 'status', 'current_soul')
    if soul then
        state.facets   = extract_facets(soul)
        state.values   = extract_values(soul)
        state.emotions = extract_emotions(soul)
    end

    -- Physical state
    state.wounds  = extract_wounds(unit)
    state.hunger  = safe_counter(unit, 'hunger_timer')
    state.thirst  = safe_counter(unit, 'thirst_timer')
    state.fatigue = safe_counter(unit, 'fatigue_timer')
    state.alcohol = safe_counter(unit, 'alcohol')

    return state
end

-- Also export safe_get so other modules can use the same helper
M.safe_get = safe_get
