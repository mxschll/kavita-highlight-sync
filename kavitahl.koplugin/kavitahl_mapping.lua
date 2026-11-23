--[[--
Pure helpers for converting between KOReader annotations and Kavita annotations,
and for planning a two-way sync. No KOReader dependencies, so it can be unit-tested
with any Lua 5.1+ interpreter.
]]

local M = {}

-- Kavita's default highlight slots (Defaults.DefaultHighlightSlots):
-- 0 cyan, 1 green, 2 yellow, 3 orange, 4 magenta
M.SLOT_TO_COLOR = { [0] = "cyan", [1] = "green", [2] = "yellow", [3] = "orange", [4] = "purple" }
M.COLOR_TO_SLOT = {
    cyan = 0, blue = 0,
    green = 1, olive = 1,
    yellow = 2, gray = 2,
    orange = 3, red = 3,
    purple = 4,
}
M.DEFAULT_SLOT = 2

function M.colorToSlot(color)
    return M.COLOR_TO_SLOT[color or ""] or M.DEFAULT_SLOT
end

function M.slotToColor(slot)
    return M.SLOT_TO_COLOR[tonumber(slot) or -1] or "yellow"
end

-- Same list as Kavita's AnnotationHelper.InlineTags
local INLINE = {}
for tag in ([[em strong i b span a cite sup sub small mark code kbd samp var q abbr dfn u s del ins
    strike font big tt nobr ruby rt rp bdi bdo time label]]):gmatch("%S+") do
    INLINE[tag] = true
end

--- Collapse whitespace and trim, like Kavita's NormalizeWhitespace.
function M.normalize(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- Converts a CREngine xpointer into (Kavita PageNumber, Kavita XPath).
-- "/body/DocFragment[5]/body/div/p[3]/span/text()[2].12" -> 4, "//body/div[1]/p[3]"
function M.xpointerToKavita(xp)
    if type(xp) ~= "string" then return nil end
    local frag, rest = xp:match("^/body/DocFragment%[(%d+)%](.*)$")
    if not frag then return nil end
    local page = tonumber(frag) - 1
    rest = rest:gsub("^/body", "", 1)
    rest = rest:gsub("/text%(%).*$", "")   -- drop text node + offset
    rest = rest:gsub("%.%d+$", "")         -- drop element offset (".0")
    local steps = {}
    for step in rest:gmatch("[^/]+") do
        local name, idx = step:match("^([%w_%-]+)%[(%d+)%]$")
        if not name then
            name = step:match("^([%w_%-]+)$")
            idx = "1"
        end
        if not name then return page, "//body" end -- something exotic; fall back to body
        steps[#steps + 1] = { name = name:lower(), idx = idx }
    end
    while #steps > 0 and INLINE[steps[#steps].name] do
        steps[#steps] = nil
    end
    local parts = { "//body" }
    for _, s in ipairs(steps) do
        parts[#parts + 1] = string.format("%s[%s]", s.name, s.idx)
    end
    return page, table.concat(parts, "/")
end

--- Converts a plain Kavita XPath into a CREngine element xpointer prefix (no offset).
-- Returns nil for id(...) xpaths, which CREngine xpointers cannot express.
function M.kavitaToXPointerPrefix(page_number, xpath)
    local frag = string.format("/body/DocFragment[%d]", (tonumber(page_number) or 0) + 1)
    if type(xpath) ~= "string" or xpath:find("id%(") then return nil, frag end
    local rel = xpath:lower():gsub("^//body", "")
    -- CREngine omits [1] when an element is the only one of its name: compare loosely
    return frag .. "/body" .. rel, frag
end

--- Removes [1] indexes so two paths can be compared regardless of CREngine's omissions.
function M.looseXPath(xp)
    return (xp:gsub("%[1%]", ""))
end

--- True when xpointer `xp` is the element at `prefix` or inside it, ignoring [1] indexes.
-- A plain string prefix test would let ".../p" (from p[1]) match ".../p[3]" and ".../pre".
function M.underPath(xp, prefix)
    local lx, lp = M.looseXPath(xp), M.looseXPath(prefix)
    if lx:sub(1, #lp) ~= lp then return false end
    local nxt = lx:sub(#lp + 1, #lp + 1)
    return nxt == "" or nxt == "/" or nxt == "."
end

--- DocFragment number of an xpointer (1-based spine index), or nil.
function M.fragmentOf(xp)
    return tonumber(type(xp) == "string" and xp:match("^/body/DocFragment%[(%d+)%]"))
end

--- Splits a long selected text into a head and tail search pattern (UTF-8 safe at spaces).
-- Patterns never cross a line break, because a selection spanning paragraphs is joined
-- with newlines and search engines don't reliably match across block boundaries.
function M.searchPatterns(text, max_len)
    max_len = max_len or 80
    local lines = {}
    for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
        local n = M.normalize(line)
        if n ~= "" then lines[#lines + 1] = n end
    end
    if #lines == 0 then return "", nil end
    local first, last = lines[1], lines[#lines]
    if #lines == 1 and #first <= max_len then return first, nil end
    local head, tail = first, last
    if #head > max_len then
        head = head:sub(1, max_len):gsub("%s+%S*$", "")
        if head == "" then head = first:sub(1, max_len):gsub("[\192-\255][\128-\191]*$", "") end
    end
    if #tail > max_len then
        tail = tail:sub(-max_len):gsub("^%S*%s+", "")
        if tail == "" then tail = last:sub(-max_len):gsub("^[\128-\191]+", "") end
    end
    return head, tail
end

function M.utf8len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

-- Notes -------------------------------------------------------------------

local function json_escape(s)
    return (s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format("\\u%04x", c:byte())
    end))
end

local function html_escape(s)
    return (s:gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

--- Builds Kavita's Comment (Quill delta) and CommentHtml from a plain note, like Kavita's Kobo sync.
function M.noteToKavita(note)
    if type(note) ~= "string" or note:match("^%s*$") then return nil, nil end
    local delta = '{"ops":[{"insert":"' .. json_escape(note .. "\n") .. '"}]}'
    local paras = {}
    for line in (note .. "\n"):gmatch("(.-)\n") do
        paras[#paras + 1] = "<p>" .. html_escape(line) .. "</p>"
    end
    return delta, table.concat(paras)
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

function M.htmlToText(html)
    if type(html) ~= "string" then return nil end
    local s = html:gsub("<br%s*/?>", "\n"):gsub("</p>%s*<p[^>]*>", "\n"):gsub("<[^>]+>", "")
    s = s:gsub("&(#?%w+);", function(e)
        if e:sub(1, 1) == "#" then
            local n = tonumber(e:sub(2)) or tonumber(e:sub(3), 16)
            return n and n < 128 and string.char(n) or ""
        end
        return ENTITIES[e] or ("&" .. e .. ";")
    end)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- Plain-text note of a Kavita annotation.
function M.remoteNote(r)
    local plain = r.commentPlainText
    if type(plain) == "string" and plain:match("%S") then
        return (plain:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return M.htmlToText(r.commentHtml)
end

local function note_eq(a, b)
    return M.normalize(a or "") == M.normalize(b or "")
end

-- Sync planning ------------------------------------------------------------

--- Plans a two-way sync.
-- locals:  array of { key, text, note, color, page }
-- remotes: array of { id, text, note, slot, page }   (already filtered to the current user)
-- state:   map tostring(id) -> { key, note, slot } from the last successful sync
-- Returns a table of actions. Conflicts (changed on both sides) go to the local side.
-- A highlight deleted on one side is deleted on the other, even if it was edited there.
-- A local highlight whose key changed but whose text and page did not is re-keyed, not recreated.
function M.plan(locals, remotes, state)
    state = state or {}
    local actions = {
        create_remote = {}, create_local = {},
        delete_remote = {}, delete_local = {},
        update_remote = {}, update_local = {},
        link = {}, rekey = {},
    }
    local local_by_key, remote_by_id = {}, {}
    for _, l in ipairs(locals) do local_by_key[l.key] = l end
    for _, r in ipairs(remotes) do remote_by_id[tostring(r.id)] = r end

    local function diff(l, r, snap)
        local l_slot = M.colorToSlot(l.color)
        local local_changed = not note_eq(l.note, snap.note) or l_slot ~= snap.slot
        local remote_changed = not note_eq(r.note, snap.note) or r.slot ~= snap.slot
        if local_changed then
            table.insert(actions.update_remote, { id = r.id, l = l })
        elseif remote_changed then
            table.insert(actions.update_local, { key = l.key, r = r })
        end
    end

    local linked_keys, linked_ids = {}, {}
    local orphans = {}
    for id, snap in pairs(state) do
        local l, r = local_by_key[snap.key], remote_by_id[id]
        if l and r then
            linked_keys[l.key], linked_ids[id] = true, true
            diff(l, r, snap)
        elseif l and not r then
            linked_keys[l.key] = true
            table.insert(actions.delete_local, { id = id, key = l.key })
        elseif r and not l then
            linked_ids[id] = true
            orphans[#orphans + 1] = { r = r, snap = snap }
        end
        -- neither: both deleted, the entry is simply dropped
    end

    local function unlinkedByText(items, linked, keyOf)
        local by_text = {}
        for _, it in ipairs(items) do
            if not linked[keyOf(it)] then
                local t = M.normalize(it.text)
                by_text[t] = by_text[t] or {}
                table.insert(by_text[t], it)
            end
        end
        return by_text
    end

    -- The key is the highlight's position, which KOReader rewrites when its DOM version
    -- changes. Pair such a remote with the moved local by text before treating it as deleted.
    -- The pages must be close, or a re-highlighted short phrase in another chapter would keep
    -- the remote's old position.
    local unlinked_local_by_text = unlinkedByText(locals, linked_keys, function(l) return l.key end)
    table.sort(orphans, function(a, b) return tostring(a.r.id) < tostring(b.r.id) end)
    for _, o in ipairs(orphans) do
        local l
        for i, cand in ipairs(unlinked_local_by_text[M.normalize(o.r.text)] or {}) do
            if cand.page and o.r.page and math.abs(cand.page - o.r.page) <= 1 then
                l = table.remove(unlinked_local_by_text[M.normalize(o.r.text)], i)
                break
            end
        end
        if l then
            linked_keys[l.key] = true
            table.insert(actions.rekey, { id = o.r.id, key = l.key })
            diff(l, o.r, o.snap)
        else
            table.insert(actions.delete_remote, o.r.id)
        end
    end

    -- Pair up unlinked items with identical text (e.g. after the sync state was lost)
    local unlinked_remote_by_text = unlinkedByText(remotes, linked_ids, function(r) return tostring(r.id) end)
    for _, l in ipairs(locals) do
        if not linked_keys[l.key] then
            local bucket = unlinked_remote_by_text[M.normalize(l.text)]
            local r = bucket and table.remove(bucket, 1)
            if r then
                linked_ids[tostring(r.id)] = true
                table.insert(actions.link, { id = r.id, l = l, r = r })
            else
                table.insert(actions.create_remote, l)
            end
        end
    end
    for _, r in ipairs(remotes) do
        if not linked_ids[tostring(r.id)] then
            table.insert(actions.create_local, r)
        end
    end
    return actions
end

function M.countDeletions(actions)
    return #actions.delete_local + #actions.delete_remote
end

return M
