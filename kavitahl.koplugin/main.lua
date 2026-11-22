--[[--
Kavita highlight sync for KOReader.

Two-way sync of EPUB highlights and notes between the open book and the matching
Kavita chapter. The book is matched by KOReader's partial MD5 hash, which Kavita
already stores for every file for its progress sync.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local KavitaApi = require("kavitahl_api")
local Map = require("kavitahl_mapping")

local STATE_KEY = "kavita_highlights"
local SEARCH_FLAGS = 0x00FF -- KOReader's default: case/space/quote-insensitive matching

local KavitaHL = WidgetContainer:extend{
    name = "kavitahl",
    is_doc_only = true,
}

function KavitaHL:init()
    self.settings_obj = LuaSettings:open(DataStorage:getSettingsDir() .. "/kavitahl.lua")
    self.settings = self.settings_obj:readSetting("settings", {
        server_url = nil,
        api_key = nil,
        auto_sync = false,
    })
    self.ui.menu:registerToMainMenu(self)
end

function KavitaHL:saveSettings()
    self.settings_obj:saveSetting("settings", self.settings)
    self.settings_obj:flush()
end

-- Configuration ---------------------------------------------------------------------

--- Reads server and key from KOReader's Progress sync settings when they point at Kavita
-- (custom server "https://host/api/koreader/<apiKey>").
local function fromKosync()
    local ok, kosync = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/kosync.lua")
    if not ok or not kosync then return end
    local s = kosync:readSetting("settings") or {}
    local url = s.custom_server
    if type(url) ~= "string" then return end
    local base, key = url:match("^(https?://.-)/api/koreader/([^/%?]+)/?$")
    return base, key
end

function KavitaHL:getConfig()
    local base, key = self.settings.server_url, self.settings.api_key
    if not (base and key) then
        local kb, kk = fromKosync()
        base, key = base or kb, key or kk
    end
    if base and key and base ~= "" and key ~= "" then
        return base, key
    end
end

function KavitaHL:showConfigDialog()
    local kb, kk = fromKosync()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Kavita server"),
        fields = {
            { description = _("Server URL"), text = self.settings.server_url or kb or "", hint = "https://kavita.example.com" },
            { description = _("API / auth key"), text = self.settings.api_key or kk or "", hint = _("From Kavita user settings") },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local f = dialog:getFields()
                self.settings.server_url = util.trim(f[1] or ""):gsub("/+$", "")
                self.settings.api_key = util.trim(f[2] or "")
                if self.settings.server_url == "" then self.settings.server_url = nil end
                if self.settings.api_key == "" then self.settings.api_key = nil end
                self:saveSettings()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Menu ----------------------------------------------------------------------------

function KavitaHL:addToMainMenu(menu_items)
    menu_items.kavita_highlights = {
        text = _("Kavita highlight sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync highlights now"),
                enabled_func = function() return self:isSupported() end,
                callback = function()
                    NetworkMgr:runWhenOnline(function() self:sync{ interactive = true } end)
                end,
            },
            {
                text = _("Sync automatically on open and close"),
                help_text = _("Only runs when Wi-Fi is already on. On close, only your local changes are sent."),
                checked_func = function() return self.settings.auto_sync end,
                callback = function()
                    self.settings.auto_sync = not self.settings.auto_sync
                    self:saveSettings()
                end,
            },
            {
                text = _("Server settings"),
                keep_menu_open = true,
                callback = function() self:showConfigDialog() end,
                separator = true,
            },
            {
                text = _("Re-match this book with Kavita"),
                help_text = _("Forget the linked Kavita chapter and sync history for this book. Existing highlights are matched again by their text on the next sync, so nothing is duplicated."),
                enabled_func = function() return self.ui.doc_settings:readSetting(STATE_KEY) ~= nil end,
                callback = function()
                    self.ui.doc_settings:delSetting(STATE_KEY)
                    UIManager:show(Notification:new{ text = _("Kavita link cleared for this book") })
                end,
            },
        },
    }
end

function KavitaHL:isSupported()
    return self.ui.rolling ~= nil and self.ui.document and self.ui.document.file
        and self.ui.document.file:lower():match("%.epub$") ~= nil
end

-- Events --------------------------------------------------------------------------

function KavitaHL:onReaderReady()
    if self.settings.auto_sync and self:isSupported() and self:getConfig() then
        UIManager:scheduleIn(3, function()
            if NetworkMgr:isOnline() then self:sync{ interactive = false } end
        end)
    end
end

function KavitaHL:onCloseDocument()
    if self.settings.auto_sync and self:isSupported() and self:getConfig() and NetworkMgr:isOnline() then
        self:sync{ interactive = false, push_only = true }
        -- Doc settings were already saved before CloseDocument, so persist our state now.
        self.ui.doc_settings:flush()
    end
end

-- Local side ----------------------------------------------------------------------

local function itemKey(item)
    return item.pos0 .. "|" .. item.pos1
end

function KavitaHL:localItems()
    local list = {}
    for _, item in ipairs(self.ui.annotation.annotations) do
        if item.drawer and type(item.pos0) == "string" and type(item.pos1) == "string" then
            list[#list + 1] = {
                key = itemKey(item),
                text = item.text or "",
                note = item.note,
                color = item.color,
                item = item,
            }
        end
    end
    return list
end

function KavitaHL:findLocalIndex(key)
    for i, item in ipairs(self.ui.annotation.annotations) do
        if item.drawer and type(item.pos0) == "string" and type(item.pos1) == "string"
                and itemKey(item) == key then
            return i, item
        end
    end
end

--- Finds where a Kavita highlight's text sits in the open book.
function KavitaHL:locate(r)
    local doc = self.ui.document
    local prefix, frag = Map.kavitaToXPointerPrefix(r.page, r.xpath)
    local loose_prefix = prefix and Map.looseXPath(prefix)
    local head, tail = Map.searchPatterns(r.text)
    if head == "" then return nil end

    local function inFrag(xp)
        return xp:sub(1, #frag + 1) == frag .. "/" or xp:sub(1, #frag + 1) == frag .. "."
    end

    local hits = doc:findAllText(head, true, 0, 1000, false, SEARCH_FLAGS) or {}
    local best, fallback
    for _, h in ipairs(hits) do
        if inFrag(h.start) then
            if loose_prefix and Map.looseXPath(h.start):sub(1, #loose_prefix) == loose_prefix then
                best = h
                break
            end
            fallback = fallback or h
        end
    end
    best = best or fallback or (#hits == 1 and hits[1]) or nil
    if not best then return nil end

    local pos0, pos1 = best.start, best["end"]
    if tail then
        pos1 = nil
        local tail_hits = doc:findAllText(tail, true, 0, 1000, false, SEARCH_FLAGS) or {}
        for _, h in ipairs(tail_hits) do
            local order = doc:compareXPointers(pos0, h.start)
            if order and order >= 0 then
                pos1 = h["end"]
                break
            end
        end
        if not pos1 then return nil end
    end
    return pos0, pos1
end

function KavitaHL:createLocal(r)
    local pos0, pos1 = self:locate(r)
    if not pos0 then return nil end
    local doc = self.ui.document
    local text = r.text
    local ok, res = pcall(doc.getTextFromXPointers, doc, pos0, pos1)
    if ok and type(res) == "string" and res ~= "" then text = res end
    local item = {
        pos0 = pos0,
        pos1 = pos1,
        page = pos0,
        text = util.cleanupSelectedText(text),
        drawer = self.view.highlight.saved_drawer or "lighten",
        color = Map.slotToColor(r.slot),
        note = r.note,
    }
    if self.ui.highlight.getHighlightChapter then
        item.chapter = self.ui.highlight:getHighlightChapter(pos0)
    else
        item.chapter = self.ui.toc:getTocTitleByPage(pos0)
    end
    if doc.getEPubCFIRangeFromXPointers then
        local ok_cfi, cfi = pcall(doc.getEPubCFIRangeFromXPointers, doc, pos0, pos1)
        if ok_cfi then item.epubcfi = cfi end
    end
    local index = self.ui.annotation:addItem(item)
    self.ui:handleEvent(Event:new("AnnotationsModified", {
        item,
        nb_highlights_added = item.note and 0 or 1,
        nb_notes_added = item.note and 1 or 0,
        index_modified = index,
    }))
    return itemKey(item)
end

function KavitaHL:updateLocal(key, r)
    local _, item = self:findLocalIndex(key)
    if not item then return false end
    local had_note, has_note = item.note ~= nil, r.note ~= nil
    item.note = r.note
    -- Only recolor when the Kavita slot really differs (keeps e.g. red vs. orange intact)
    if r.slot ~= nil and Map.colorToSlot(item.color) ~= r.slot then
        item.color = Map.slotToColor(r.slot)
    end
    local ev = { item }
    if had_note ~= has_note then
        ev.nb_highlights_added = has_note and -1 or 1
        ev.nb_notes_added = has_note and 1 or -1
    end
    self.ui:handleEvent(Event:new("AnnotationsModified", ev))
    return true
end

function KavitaHL:deleteLocal(key)
    local index = self:findLocalIndex(key)
    if index then self.ui.bookmark:removeItemByIndex(index) end
    return true
end

-- Remote side ---------------------------------------------------------------------

local function remoteItem(dto)
    return {
        id = dto.id,
        text = dto.selectedText or "",
        note = Map.remoteNote(dto),
        slot = tonumber(dto.selectedSlotIndex) or 0,
        page = tonumber(dto.pageNumber) or 0,
        xpath = dto.xPath,
        raw = dto,
    }
end

function KavitaHL:newRemoteDto(l, link)
    local page, xpath = Map.xpointerToKavita(l.item.pos0)
    local _, end_xpath = Map.xpointerToKavita(l.item.pos1)
    if not page then return nil end
    local comment, comment_html = Map.noteToKavita(l.note)
    return {
        id = 0,
        xPath = xpath,
        endingXPath = end_xpath or xpath,
        selectedText = l.text,
        comment = comment,
        commentHtml = comment_html,
        highlightCount = Map.utf8len(l.text),
        containsSpoiler = false,
        pageNumber = page,
        selectedSlotIndex = Map.colorToSlot(l.color),
        chapterTitle = type(l.item.chapter) == "string" and l.item.chapter or nil,
        chapterId = link.chapter_id,
        volumeId = link.volume_id or 0,
        seriesId = link.series_id or 0,
        libraryId = link.library_id or 0,
        ownerUserId = 0,
    }
end

function KavitaHL:updateRemoteDto(r, note, slot)
    local dto = {}
    for k, v in pairs(r.raw) do dto[k] = v end
    dto.likes = nil -- an empty Lua table would be sent as {} instead of []
    dto.comment, dto.commentHtml = Map.noteToKavita(note)
    dto.commentPlainText = nil
    dto.selectedSlotIndex = slot
    return dto
end

-- Sync ----------------------------------------------------------------------------

function KavitaHL:getHash()
    local hash = self.ui.doc_settings:readSetting("partial_md5_checksum")
    if not hash and util.partialMD5 then
        hash = util.partialMD5(self.ui.document.file)
    end
    return hash
end

function KavitaHL:resolveLink(api, state)
    local hash = self:getHash()
    if not hash then return nil, _("Could not compute this book's hash.") end
    if state.chapter_id and state.hash == hash then
        if not state.library_id then -- links made by older plugin versions
            local lib, err = api:getLibraryId(state.series_id)
            if not lib then return nil, err or _("Could not read the book's Kavita library.") end
            state.library_id = lib
        end
        return state
    end

    local props = self.ui.doc_props or {}
    local _, filename = util.splitFilePathName(self.ui.document.file)
    local stem = filename:gsub("%.[^.]+$", "")
    local found = api:findChapterByHash(hash, { props.title, props.display_title, stem })
    if not found then
        return nil, _("This book wasn't found in Kavita. Make sure the file on this device is the same file Kavita has (Kavita matches books by file hash).")
    end
    local library_id, lib_err = api:getLibraryId(found.series_id)
    if not library_id then return nil, lib_err or _("Could not read the book's Kavita library.") end
    return {
        hash = hash,
        library_id = library_id,
        chapter_id = found.chapter_id,
        volume_id = found.volume_id,
        series_id = found.series_id,
        items = (state.hash == hash) and state.items or {},
    }
end

function KavitaHL:sync(opts)
    opts = opts or {}
    if not self:isSupported() then return end
    local base, key = self:getConfig()
    if not base then
        if opts.interactive then self:showConfigDialog() end
        return
    end

    local progress
    if opts.interactive then
        progress = InfoMessage:new{ text = _("Syncing highlights with Kavita…") }
        UIManager:show(progress)
        UIManager:forceRePaint()
    end

    local ok, result = pcall(self._sync, self, KavitaApi.new(base, key), opts)
    if progress then UIManager:close(progress) end

    if not ok then
        logger.err("KavitaHL: sync failed", result)
        result = { error = tostring(result) }
    end
    if result.error then
        if opts.interactive then
            UIManager:show(InfoMessage:new{ text = T(_("Kavita sync failed:\n%1"), result.error) })
        end
        return
    end
    if result.confirm then
        UIManager:show(ConfirmBox:new{
            text = result.confirm,
            ok_text = _("Delete"),
            ok_callback = function() self:sync{ interactive = true, allow_mass_delete = true } end,
        })
        return
    end
    UIManager:setDirty(self.dialog, "ui")
    local s = result.stats
    local summary = T(_("Kavita: ↑%1 sent, ↓%2 received, %3 updated, %4 deleted"),
        s.sent, s.received, s.updated, s.deleted)
    if s.unplaced > 0 then
        summary = summary .. "\n" .. T(_("%1 Kavita highlights couldn't be placed in this book."), s.unplaced)
    end
    if s.failed > 0 then
        summary = summary .. "\n" .. T(_("%1 changes failed; they'll be retried next time."), s.failed)
        if s.first_error then
            summary = summary .. "\n\n" .. T(_("First error: %1"), s.first_error)
        end
    end
    if opts.interactive then
        UIManager:show(InfoMessage:new{ text = summary, timeout = s.failed > 0 and nil or 4 })
    elseif s.sent + s.received + s.updated + s.deleted > 0 then
        UIManager:show(Notification:new{ text = summary })
    end
end

function KavitaHL:_sync(api, opts)
    local username, err = api:whoami()
    if not username then return { error = err or _("Could not authenticate with Kavita.") } end

    local state = self.ui.doc_settings:readSetting(STATE_KEY) or {}
    local link, link_err = self:resolveLink(api, state)
    if not link then return { error = link_err } end
    state = link
    state.items = state.items or {}

    local dtos, get_err = api:getAnnotations(state.chapter_id)
    if type(dtos) ~= "table" then return { error = get_err or _("Could not read Kavita annotations.") } end
    local remotes, remote_by_id = {}, {}
    for _, dto in ipairs(dtos) do
        if type(dto.ownerUsername) == "string" and dto.ownerUsername:lower() == username:lower() then
            local r = remoteItem(dto)
            remotes[#remotes + 1] = r
            remote_by_id[tostring(r.id)] = r
        end
    end
    local locals = self:localItems()
    local local_by_key = {}
    for _, l in ipairs(locals) do local_by_key[l.key] = l end

    local plan = Map.plan(locals, remotes, state.items)

    -- Guard against wiping highlights after something odd (e.g. the book file changed)
    local n_state = 0
    for _ in pairs(state.items) do n_state = n_state + 1 end
    local n_del = Map.countDeletions(plan)
    if n_del > 3 and n_del * 2 > n_state and not opts.allow_mass_delete then
        if opts.interactive then
            return { confirm = T(_("This sync would delete %1 highlights (on this device or in Kavita). Continue?"), n_del) }
        end
        plan.delete_local, plan.delete_remote = {}, {}
    end

    local stats = { sent = 0, received = 0, updated = 0, deleted = 0, unplaced = 0, failed = 0 }
    local items = state.items
    local function snap(k, note, slot) return { key = k, note = note, slot = slot } end

    local function failed(err)
        stats.failed = stats.failed + 1
        stats.first_error = stats.first_error or err
    end

    for _, d in ipairs(plan.delete_remote) do
        local res, err = api:deleteAnnotation(d)
        if res then
            items[tostring(d)] = nil
            stats.deleted = stats.deleted + 1
        else
            failed(err)
        end
    end
    -- Snapshot entries whose two sides are both gone are dropped
    for id, s in pairs(items) do
        if not local_by_key[s.key] and not remote_by_id[id] then items[id] = nil end
    end

    for _, u in ipairs(plan.update_remote) do
        local slot = Map.colorToSlot(u.l.color)
        local res, err = api:updateAnnotation(self:updateRemoteDto(remote_by_id[tostring(u.id)], u.l.note, slot))
        if res then
            items[tostring(u.id)] = snap(u.l.key, u.l.note, slot)
            stats.updated = stats.updated + 1
        else
            failed(err)
        end
    end

    local unconfirmed = {} -- creates that timed out: Kavita may have saved them anyway
    for _, l in ipairs(plan.create_remote) do
        local dto = self:newRemoteDto(l, state)
        local res, err, code
        if dto then
            res, err, code = api:createAnnotation(dto)
        else
            err = T(_("Unsupported position: %1"), tostring(l.item.pos0))
        end
        if type(res) == "table" and res.id then
            items[tostring(res.id)] = snap(l.key, l.note, dto.selectedSlotIndex)
            stats.sent = stats.sent + 1
        elseif KavitaApi.isTimeout(code) then
            unconfirmed[#unconfirmed + 1] = { l = l, slot = dto.selectedSlotIndex, err = err }
        else
            failed(err or _("Kavita returned no annotation"))
        end
    end
    if #unconfirmed > 0 then
        -- Check what actually arrived instead of re-sending, which could duplicate
        local fresh = api:getAnnotations(state.chapter_id)
        local known = {}
        for id in pairs(items) do known[id] = true end
        for _, u in ipairs(unconfirmed) do
            local match
            for _, dto in ipairs(type(fresh) == "table" and fresh or {}) do
                local id = tostring(dto.id)
                if not known[id] and type(dto.ownerUsername) == "string"
                        and dto.ownerUsername:lower() == username:lower()
                        and Map.normalize(dto.selectedText) == Map.normalize(u.l.text) then
                    match = id
                    break
                end
            end
            if match then
                known[match] = true
                items[match] = snap(u.l.key, u.l.note, u.slot)
                stats.sent = stats.sent + 1
            else
                failed(u.err)
            end
        end
    end

    for _, k in ipairs(opts.push_only and {} or plan.link) do
        -- Same highlight on both sides but no history: merge (a local note wins over a remote one)
        local note = k.l.note or k.r.note
        local slot = Map.colorToSlot(k.l.color)
        local good, err = true, nil
        if Map.normalize(note or "") ~= Map.normalize(k.r.note or "") or slot ~= k.r.slot then
            local res
            res, err = api:updateAnnotation(self:updateRemoteDto(k.r, note, slot))
            good = res and true or false
        end
        if good and note ~= k.l.note then
            self:updateLocal(k.l.key, { note = note })
        end
        if good then
            items[tostring(k.id)] = snap(k.l.key, note, slot)
        else
            failed(err)
        end
    end

    if not opts.push_only then
        for _, d in ipairs(plan.delete_local) do
            self:deleteLocal(d.key)
            items[tostring(d.id)] = nil
            stats.deleted = stats.deleted + 1
        end
        for _, u in ipairs(plan.update_local) do
            if self:updateLocal(u.key, u.r) then
                items[tostring(u.r.id)] = snap(u.key, u.r.note, u.r.slot)
                stats.updated = stats.updated + 1
            end
        end
        for _, r in ipairs(plan.create_local) do
            local new_key = self:createLocal(r)
            if new_key then
                items[tostring(r.id)] = snap(new_key, r.note, r.slot)
                stats.received = stats.received + 1
            else
                stats.unplaced = stats.unplaced + 1
            end
        end
    end

    self.ui.doc_settings:saveSetting(STATE_KEY, state)
    return { stats = stats }
end

return KavitaHL
