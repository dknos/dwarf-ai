-- mayor_briefing.lua
-- Phase 6: Seamless UI Overlays — Mayor / Expedition Leader Briefing
--
-- Invoked by keybind (default: M key in fortress mode).
-- Reads aggregate fortress state, fires a fortress_briefing context request,
-- polls for the LLM reply, and renders it as a CP437-bordered report window.
--
--   ╔═══════════════════════════════╗
--   ║  EXPEDITION LEADER'S REPORT  ║
--   ║  [date]                      ║
--   ║──────────────────────────── ║
--   ║ [dialogue]                   ║
--   ╚═══════════════════════════════╝
--
-- IPC base: /home/nemoclaw/dwarf-ai/lua/ipc/

local json  = require('json')
local gui   = require('gui')

local IPC_CONTEXT_DIR   = '/home/nemoclaw/dwarf-ai/lua/ipc/context'
local IPC_RESPONSES_DIR = '/home/nemoclaw/dwarf-ai/lua/ipc/responses'
local POLL_TICKS        = 20
local TIMEOUT_SEC       = 10.0

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function uuid()
    math.randomseed(dfhack.getTickCount() + math.random(99999))
    return string.format('mbrf-%d-%d', dfhack.getTickCount(), math.random(10000, 99999))
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

local function ensure_dir(path)
    if dfhack.filesystem and dfhack.filesystem.mkdir_recursive then
        pcall(function() dfhack.filesystem.mkdir_recursive(path) end)
    end
end

local function atomic_write(path, text)
    local tmp = path .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return false end
    f:write(text)
    f:close()
    os.rename(tmp, path)
    return true
end

local function read_json(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local raw = f:read('*all')
    f:close()
    if not raw or raw == '' then return nil end
    local ok, data = pcall(function() return json.decode(raw) end)
    return ok and data or nil
end

-- ─── Fortress state readers ───────────────────────────────────────────────────

local MOOD_LABELS = {
    [  0] = 'content',
    [  1] = 'pleased',
    [  2] = 'happy',
    [  3] = 'ecstatic',
    [ -1] = 'unhappy',
    [ -2] = 'miserable',
    [ -3] = 'very unhappy',
    [ -4] = 'melancholy',
    [ -5] = 'tantrum',
}

--- Return a rough "overall mood" label for the active fortress population.
local function read_overall_mood()
    local total = 0
    local count = 0
    local ok_units, units = pcall(function() return df.global.world.units.active end)
    if not ok_units then return 'unknown' end

    for _, unit in ipairs(units) do
        -- Only fortress citizens (civ_id matches, not dead, not a visitor)
        local ok_civ = pcall(function()
            return unit.civ_id == df.global.ui.civ_id
        end)
        if ok_civ then
            local ok_dead, dead = pcall(function() return unit.flags1.dead end)
            if not (ok_dead and dead) then
                local stress = safe_get(unit, 'status', 'current_soul',
                                        'personality', 'stress_level')
                if stress then
                    total = total + tonumber(stress)
                    count = count + 1
                end
            end
        end
    end

    if count == 0 then return 'unknown' end
    local avg = total / count
    if avg < -2000 then return 'ecstatic'
    elseif avg < -500 then return 'happy'
    elseif avg < 500  then return 'content'
    elseif avg < 2000 then return 'unhappy'
    elseif avg < 5000 then return 'miserable'
    else                    return 'tantrum spiral' end
end

--- Collect up to 10 recently generated "bad thoughts" across all citizens.
local BAD_THOUGHT_TYPES = {
    PAIN = true, HUNGER = true, THIRST = true, DEATH_CITIZEN = true,
    MASSACRE = true, TANTRUM = true, DRAFT = true, PRESSURE = true,
    ATTACKED = true, MISCARRIAGE = true,
}

local function read_bad_thoughts_count()
    local count = 0
    local ok_units, units = pcall(function() return df.global.world.units.active end)
    if not ok_units then return 0 end
    for _, unit in ipairs(units) do
        local ok_civ = pcall(function()
            return unit.civ_id == df.global.ui.civ_id
        end)
        if ok_civ then
            local ok_dead, dead = pcall(function() return unit.flags1.dead end)
            if not (ok_dead and dead) then
                local emotions = safe_get(unit, 'status', 'current_soul', 'emotions')
                if emotions then
                    for _, em in ipairs(emotions) do
                        local ok_e, etype = pcall(function()
                            return tostring(df['emotion_type'][em.type])
                        end)
                        local ok_s, strength = pcall(function() return em.strength end)
                        if ok_e and ok_s and strength and strength > 50 then
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    return count
end

--- Return list of top unmet needs (needs with high level).
local NEED_LABELS = {
    SOCIALIZE   = 'social interaction',
    PRAY        = 'prayer',
    DRINK_BOOZE = 'alcohol',
    EAT_GOOD    = 'good food',
    REST        = 'rest',
    ART         = 'artistic stimulation',
    CRAFT       = 'craft work',
    MUSIC       = 'music',
}

local function read_unmet_needs()
    local need_counts = {}
    local ok_units, units = pcall(function() return df.global.world.units.active end)
    if not ok_units then return {} end
    for _, unit in ipairs(units) do
        local ok_civ = pcall(function()
            return unit.civ_id == df.global.ui.civ_id
        end)
        if ok_civ then
            local ok_dead, dead = pcall(function() return unit.flags1.dead end)
            if not (ok_dead and dead) then
                local needs = safe_get(unit, 'status', 'current_soul', 'personality', 'needs')
                if needs then
                    for _, need in ipairs(needs) do
                        local ok_n, ntype  = pcall(function()
                            return tostring(df['need_type'][need.id])
                        end)
                        local ok_l, level  = pcall(function() return need.need_level end)
                        if ok_n and ok_l and level and level > 5000 then
                            local label = NEED_LABELS[ntype] or ntype:lower():gsub('_', ' ')
                            need_counts[label] = (need_counts[label] or 0) + 1
                        end
                    end
                end
            end
        end
    end

    -- Sort by count descending, return top 5
    local sorted = {}
    for label, cnt in pairs(need_counts) do
        table.insert(sorted, {label = label, count = cnt})
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local result = {}
    for i = 1, math.min(5, #sorted) do
        table.insert(result, sorted[i].label .. ' (' .. sorted[i].count .. ')')
    end
    return result
end

--- Get current DF date as a string.
local function get_df_date()
    local ok, date = pcall(function()
        local year  = df.global.cur_year
        local tick  = df.global.cur_year_tick
        local day   = math.floor(tick / 1200) + 1
        local month = math.floor((day - 1) / 28) + 1
        day = ((day - 1) % 28) + 1
        local month_names = {
            'Granite','Slate','Felsite','Hematite','Malachite','Galena',
            'Limestone','Sandstone','Timber','Moonstone','Opal','Obsidian',
        }
        return string.format('%d %s, %d', day, month_names[month] or '?', year)
    end)
    return ok and date or 'unknown date'
end

-- ─── Build fortress briefing context ─────────────────────────────────────────

local function build_briefing_context()
    local iid = uuid()
    local mood = read_overall_mood()
    local unmet = read_unmet_needs()
    local bad_count = read_bad_thoughts_count()
    local tick = safe_get(df, 'global', 'cur_year_tick') or 0

    -- Construct player_input as the question posed to the expedition leader
    local player_input = string.format(
        'Give me a briefing. Fortress mood: %s. ' ..
        'Unmet needs: %s. ' ..
        'Distressed dwarves with bad thoughts: %d.',
        mood,
        #unmet > 0 and table.concat(unmet, ', ') or 'none detected',
        bad_count
    )

    return {
        interaction_id     = iid,
        type               = 'fortress_briefing',
        overall_mood       = mood,
        unmet_needs        = unmet,
        bad_thoughts_count = bad_count,
        tick               = tonumber(tick),
        -- Standard NPC context fields (expedition leader persona)
        unit_id            = 0,
        npc_name           = 'The Expedition Leader',
        npc_race           = 'Dwarf',
        npc_profession     = 'expedition leader',
        facets             = { LEADERSHIP = 80, DETERMINATION = 75 },
        values             = { COMMUNITY = 90, CRAFTSMANSHIP = 70 },
        emotions           = {},
        wounds             = {},
        hunger = 0, thirst = 0, fatigue = 0, alcohol = 0,
        room_description   = 'You are in the expedition leader\'s office.',
        interlocutor_description = 'The player, the overseer.',
        core_memories      = {
            'You are responsible for the welfare of all dwarves in this fortress.',
            'Your duty is to advise the overseer honestly, even when the news is grim.',
        },
        player_input       = player_input,
    }
end

-- ─── Report screen ────────────────────────────────────────────────────────────

-- CP437 box-drawing characters (using Lua string literals)
local BOX = {
    tl  = '\xc9',  -- ╔
    tr  = '\xbb',  -- ╗
    bl  = '\xc8',  -- ╚
    br  = '\xbc',  -- ╝
    h   = '\xcd',  -- ═
    v   = '\xba',  -- ║
    sep = '\xc4',  -- ─ (thin, for separator line)
    ml  = '\xcc',  -- ╠  left separator connector
    mr  = '\xb9',  -- ╣  right separator connector
}
local INNER_W  = 35   -- inner content width
local PANEL_W  = INNER_W + 4  -- including borders + 1 padding each side

local ReportScreen = defclass(ReportScreen, gui.Screen)
ReportScreen.ATTRS {
    dialogue = '',
    df_date  = '',
    spinning = false,
    focus_path = 'dfai/mayor_briefing',
}

local SPINNER_FRAMES = { '/', '-', '\\', '|' }
local _spin_idx = 1

local function wrap_text(text, max_w)
    local lines = {}
    for para in (text .. '\n'):gmatch('([^\n]*)\n') do
        if #para == 0 then
            table.insert(lines, '')
        else
            local pos = 1
            while pos <= #para do
                local chunk = para:sub(pos, pos + max_w - 1)
                if #chunk == max_w and pos + max_w <= #para then
                    local sp = chunk:match('.*()%s')
                    if sp and sp > 1 then
                        chunk = para:sub(pos, pos + sp - 2)
                    end
                end
                table.insert(lines, chunk)
                pos = pos + #chunk
                if para:sub(pos, pos) == ' ' then pos = pos + 1 end
            end
        end
    end
    return lines
end

function ReportScreen:onRenderFrame(dc, rect)
    self:renderParent()

    -- Current text
    local display_text = self.dialogue
    if self.spinning then
        _spin_idx = (_spin_idx % #SPINNER_FRAMES) + 1
        display_text = 'Awaiting report ' .. SPINNER_FRAMES[_spin_idx] .. '...'
    end

    local content_lines = wrap_text(display_text, INNER_W)
    local header_lines  = 2  -- title + date
    local sep_lines     = 1
    local footer_lines  = 1  -- "[SPACE to dismiss]"
    local panel_h = header_lines + sep_lines + #content_lines + footer_lines + 2 -- +2 top/bottom border

    local sw, sh = dfhack.screen.getWindowSize()
    local px = math.floor((sw - PANEL_W) / 2)
    local py = math.floor((sh - panel_h) / 2)

    -- Background
    for row = 0, panel_h - 1 do
        dc:seek(px, py + row):string(string.rep(' ', PANEL_W), COLOR_BLACK)
    end

    -- Top border  ╔═══...═══╗
    dc:seek(px, py)
       :string(BOX.tl, COLOR_WHITE)
       :string(string.rep(BOX.h, PANEL_W - 2), COLOR_WHITE)
       :string(BOX.tr, COLOR_WHITE)

    local row = 1

    -- Title line  ║  EXPEDITION LEADER'S REPORT  ║
    local title = 'EXPEDITION LEADER\'S REPORT'
    local title_pad = math.floor((INNER_W - #title) / 2)
    dc:seek(px, py + row)
       :string(BOX.v, COLOR_WHITE)
       :string(string.rep(' ', title_pad + 1), COLOR_BLACK)
       :string(title, COLOR_YELLOW)
       :string(string.rep(' ', INNER_W - title_pad - #title + 1), COLOR_BLACK)
       :string(BOX.v, COLOR_WHITE)
    row = row + 1

    -- Date line  ║  [date]  ║
    local date_str = self.df_date
    dc:seek(px, py + row)
       :string(BOX.v, COLOR_WHITE)
       :string('  ' .. date_str ..
               string.rep(' ', INNER_W - #date_str) .. ' ', COLOR_GREY)
       :string(BOX.v, COLOR_WHITE)
    row = row + 1

    -- Separator  ╠────────────────────────────────╣
    dc:seek(px, py + row)
       :string(BOX.ml, COLOR_WHITE)
       :string(string.rep(BOX.sep, PANEL_W - 2), COLOR_WHITE)
       :string(BOX.mr, COLOR_WHITE)
    row = row + 1

    -- Content lines
    for _, line in ipairs(content_lines) do
        dc:seek(px, py + row)
           :string(BOX.v, COLOR_WHITE)
           :string(' ' .. line .. string.rep(' ', INNER_W + 1 - #line), COLOR_LIGHTGREY)
           :string(BOX.v, COLOR_WHITE)
        row = row + 1
    end

    -- Footer hint
    dc:seek(px, py + row)
       :string(BOX.v, COLOR_WHITE)
       :string(string.rep(' ', INNER_W + 2), COLOR_BLACK)
       :string(BOX.v, COLOR_WHITE)
    local hint = '[SPACE/ESC to dismiss]'
    local hint_x = px + math.floor((PANEL_W - #hint) / 2)
    dc:seek(hint_x, py + row):string(hint, COLOR_DARKGREY)
    row = row + 1

    -- Bottom border  ╚═══...═══╝
    dc:seek(px, py + row)
       :string(BOX.bl, COLOR_WHITE)
       :string(string.rep(BOX.h, PANEL_W - 2), COLOR_WHITE)
       :string(BOX.br, COLOR_WHITE)
end

function ReportScreen:onInput(keys)
    if keys.LEAVESCREEN or keys.LEAVESCREEN_ALL or keys.SELECT then
        self:dismiss()
        return true
    end
    return self:passInputToParent(keys)
end

-- ─── Main entry point ─────────────────────────────────────────────────────────

local _current_screen = nil
local _current_iid    = nil
local _ts_sent        = 0

local function poll_for_response()
    if not _current_iid then return end
    if not _current_screen or not _current_screen:isActive() then
        _current_iid    = nil
        _current_screen = nil
        return
    end

    -- Timeout check
    local now = os.time and os.time() or 0
    if (now - _ts_sent) >= TIMEOUT_SEC then
        _current_screen.dialogue = '*The expedition leader stares at the reports blankly.*'
        _current_screen.spinning = false
        _current_iid = nil
        return
    end

    -- Check for response
    local resp_path = IPC_RESPONSES_DIR .. '/' .. _current_iid .. '.json'
    local data = read_json(resp_path)
    if data then
        _current_screen.dialogue = data.dialogue or '...'
        _current_screen.spinning = false
        os.remove(resp_path)
        _current_iid = nil
        return
    end

    -- Schedule next poll
    dfhack.timeout(POLL_TICKS, 'ticks', poll_for_response)
end

local function open_briefing()
    -- Prevent duplicate screens
    if _current_screen and _current_screen:isActive() then
        return
    end

    ensure_dir(IPC_CONTEXT_DIR)
    ensure_dir(IPC_RESPONSES_DIR)

    local ctx = build_briefing_context()
    local iid = ctx.interaction_id
    local date_str = get_df_date()

    -- Write context file
    local path = IPC_CONTEXT_DIR .. '/' .. iid .. '.json'
    local ok_enc, encoded = pcall(function() return json.encode(ctx) end)
    if not ok_enc then
        dfhack.printerr('[dfai] mayor_briefing: json encode failed')
        return
    end
    if not atomic_write(path, encoded) then
        dfhack.printerr('[dfai] mayor_briefing: could not write context file')
        return
    end

    -- Open report screen with spinner
    local screen = ReportScreen {
        dialogue = 'Gathering fortress intelligence...',
        df_date  = date_str,
        spinning = true,
    }
    screen:show()

    _current_screen = screen
    _current_iid    = iid
    _ts_sent        = os.time and os.time() or 0

    dfhack.timeout(POLL_TICKS, 'ticks', poll_for_response)
    dfhack.print('[dfai] mayor_briefing: context sent (' .. iid .. ')\n')
end

-- ─── Keybinding registration ──────────────────────────────────────────────────

dfhack.enablePlugin('hotkeys')

-- Register as a script that can be bound in dfhack.init
-- Usage in dfhack.init:  keybinding add M@dwarfmode scripts/ui/mayor_briefing
open_briefing()

return {
    open_briefing = open_briefing,
}
