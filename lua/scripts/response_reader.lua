-- response_reader.lua
-- Polls ipc/responses/ every 30 ticks for {uuid}.json files.
-- Shows dialogue via announcement.
-- Passes actions to action_executor.
-- Graceful degradation: 5s wall-clock timeout on interactive requests.

local json    = require('json')
local dialogs = require('gui.dialogs')
-- Chat view module (Phase UX). Lazy-load to avoid circular requires.
local function get_chat_view()
    local ok, cv = pcall(function() return reqscript('dfai/ui/chat_view') end)
    return ok and cv or nil
end

local IPC_RESPONSES_DIR = 'C:/dwarf-ai-ipc/responses'
local IPC_CONTEXT_DIR   = 'C:/dwarf-ai-ipc/context'
local POLL_TICKS        = 30
local INTERACTIVE_TIMEOUT_SEC = 5.0
local FALLBACKS = {
    '*Urist glares at you silently.*',
    '*Urist seems lost in thought.*',
    '*Urist mutters something unintelligible.*',
}

local _tick_counter = 0
local _pending = {}  -- interaction_id -> {ts_sent, unit_name, type}

-- Register a pending interactive request so we can timeout it
local function register_pending(interaction_id, unit_name, req_type)
    _pending[interaction_id] = {
        ts = os.time and os.time() or 0,
        unit_name = unit_name or 'Someone',
        type = req_type or 'interactive',
    }
end

local function list_dir(path)
    local files = {}
    if dfhack.filesystem and dfhack.filesystem.listdir then
        local ok, listing = pcall(function() return dfhack.filesystem.listdir(path) end)
        if ok and listing then
            for _, f in ipairs(listing) do
                if f:match('%.json$') and not f:match('^%.') then
                    table.insert(files, f)
                end
            end
        end
    end
    return files
end

local function read_json(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local raw = f:read('*all')
    f:close()
    if not raw or raw == '' then return nil end
    local ok, data = pcall(function() return json.decode(raw) end)
    if not ok then return nil end
    return data
end

local function delete_file(path)
    os.remove(path)
end

local function show_dialogue(data)
    local text = data.dialogue or '*...*'
    local name = data.npc_name or 'Unknown'
    local uid  = data.unit_id or -1

    -- Prefer pushing into the active chat panel for the same NPC.
    local cv = get_chat_view()
    local active = cv and cv.active and cv.active() or nil
    if active and active.unit_id == uid then
        active:pushReply(text)
        return
    end
    -- Fallback: announcement if no panel is open.
    dfhack.gui.showAnnouncement(name .. ': ' .. text, COLOR_WHITE, true)
end

local function on_tick()
    _tick_counter = _tick_counter + 1
    if _tick_counter < POLL_TICKS then return end
    _tick_counter = 0

    -- Check timeouts on pending interactive requests
    local now = os.time and os.time() or 0
    for id, info in pairs(_pending) do
        if info.type == 'interactive' and (now - info.ts) >= INTERACTIVE_TIMEOUT_SEC then
            local fb = FALLBACKS[math.random(#FALLBACKS)]
            dfhack.gui.showAnnouncement(info.unit_name .. ': ' .. fb, COLOR_GREY, false)
            -- Clean up dangling context file if still there
            local ctx_path = IPC_CONTEXT_DIR .. '/' .. id .. '.json'
            os.remove(ctx_path)
            _pending[id] = nil
        end
    end

    -- Poll responses dir
    local files = list_dir(IPC_RESPONSES_DIR)
    for _, fname in ipairs(files) do
        local path = IPC_RESPONSES_DIR .. '/' .. fname
        local data = read_json(path)
        if data then
            local id = data.interaction_id or fname:gsub('%.json$','')
            _pending[id] = nil  -- clear timeout guard

            if data.type == 'interactive' or data.type == 'd2d' then
                show_dialogue(data)
                -- Pass action to executor
                if data.action and data.action.type ~= 'none' then
                    local ok, err = pcall(function()
                        local executor = reqscript('dfai/action_executor')
                        executor.execute(data.action, data)
                    end)
                    if not ok then
                        dfhack.printerr('[dfai] action_executor error: ' .. tostring(err))
                    end
                end
            end

            delete_file(path)
        end
    end
end

-- Register onTick handler
dfhack.onStateChange = dfhack.onStateChange or {}
local _orig_tick = dfhack.onStateChange[SC_WORLD_LOADED]

-- Use repeat timer via dfhack.timeout with 'frames' so it runs in real time
-- even when game is paused (game ticks only advance unpaused).
local function start_poll()
    on_tick()
    dfhack.timeout(30, 'frames', start_poll)
end

start_poll()

return {
    register_pending = register_pending,
}
