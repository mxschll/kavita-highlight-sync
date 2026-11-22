package.path = "../kavitahl.koplugin/?.lua;" .. package.path
-- Stub KOReader modules ----------------------------------------------------
local function stub(name, v) package.preload[name] = function() return v end end
local Widget = { extend = function(self, o) o = o or {}; setmetatable(o, { __index = self }); o.__index = o; return o end }
stub("ui/widget/confirmbox", {}); stub("datastorage", { getSettingsDir = function() return "/tmp" end })
stub("ui/event", { new = function(_, name, args) return { name = name, args = args } end })
stub("ui/widget/infomessage", {}); stub("ui/widget/multiinputdialog", {}); stub("ui/network/manager", {})
stub("ui/widget/notification", {}); stub("ui/uimanager", { show = function() end, setDirty = function() end })
stub("ui/widget/container/widgetcontainer", Widget)
stub("logger", { warn = print, err = print, dbg = function() end })
stub("util", { cleanupSelectedText = function(t) return t end, trim = function(s) return s end,
  splitFilePathName = function(p) return "/", p:match("[^/]+$") end })
stub("ffi/util", { template = function(s, ...) local a = { ... }; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end })
stub("gettext", function(s) return s end)
local settings_store = {}
stub("luasettings", { open = function() return { readSetting = function(_, k, d) settings_store[k] = settings_store[k] or d; return settings_store[k] end, saveSetting = function() end, flush = function() end } end })
stub("kavitahl_api", {})

local KavitaHL = require("main")
local Map = require("kavitahl_mapping")

-- Fake book: paragraphs in fragments -------------------------------------
local paras = {
  { frag = 2, path = "/div/p[1]", text = "It was a bright cold day in April, and the clocks were striking thirteen." },
  { frag = 2, path = "/div/p[2]", text = "Winston Smith slipped quickly through the glass doors." },
  { frag = 3, path = "/p",        text = "The hallway smelt of boiled cabbage and old rag mats." },
}
local function xp(i, off) return string.format("/body/DocFragment[%d]/body%s/text().%d", paras[i].frag, paras[i].path, off) end
local function parse(x) for i = 1, #paras do local pre = xp(i, 0):gsub("%.0$", "") if x:sub(1, #pre) == pre then return i, tonumber(x:sub(#pre + 2)) end end end
local doc = { file = "/books/1984.epub" }
function doc:findAllText(pat)
  local hits = {}
  for i, p in ipairs(paras) do
    local s, e = p.text:lower():find(pat:lower(), 1, true)
    if s then hits[#hits + 1] = { start = xp(i, s - 1), ["end"] = xp(i, e) } end
  end
  return hits
end
function doc:compareXPointers(a, b)
  local ia, oa = parse(a); local ib, ob = parse(b)
  if ia == ib and oa == ob then return 0 end
  return (ia < ib or (ia == ib and oa < ob)) and 1 or -1
end
function doc:getTextFromXPointers(a, b)
  local ia, oa = parse(a); local ib, ob = parse(b)
  if ia == ib then return paras[ia].text:sub(oa + 1, ob) end
  return paras[ia].text:sub(oa + 1) .. "\n" .. paras[ib].text:sub(1, ob)
end

local events = {}
local function newUI()
  local ui = { rolling = {}, document = doc, doc_props = { title = "1984" }, annotation = { annotations = {} },
    doc_settings = { data = { partial_md5_checksum = "abc123" } }, highlight = {}, toc = { getTocTitleByPage = function() return "Ch" end } }
  function ui.doc_settings:readSetting(k) return self.data[k] end
  function ui.doc_settings:saveSetting(k, v) self.data[k] = v end
  function ui.annotation:addItem(item) table.insert(self.annotations, item); return #self.annotations end
  ui.bookmark = { removeItemByIndex = function(_, i) table.remove(ui.annotation.annotations, i) end }
  function ui:handleEvent(e) events[#events + 1] = e end
  ui.menu = { registerToMainMenu = function() end }
  return ui
end

-- Fake Kavita ---------------------------------------------------------------
local server = { anns = {}, next_id = 100 }
local api = {}
function api:whoami() return "joe" end
function api:findChapterByHash(hash) assert(hash:upper() == "ABC123"); return { chapter_id = 7, volume_id = 3, series_id = 1 } end
function api:getAnnotations(ch) assert(ch == 7); local out = {}; for _, a in pairs(server.anns) do out[#out + 1] = a end; table.sort(out, function(x, y) return x.id < y.id end); return out end
function api:createAnnotation(dto)
  assert(dto.chapterId == 7 and dto.xPath and dto.highlightCount > 0, "bad create dto")
  server.next_id = server.next_id + 1; dto.id = server.next_id; dto.ownerUsername = "joe"
  dto.commentPlainText = dto.commentHtml and Map.htmlToText(dto.commentHtml)
  server.anns[dto.id] = dto; return dto
end
function api:updateAnnotation(dto) assert(dto.likes == nil); dto.commentPlainText = dto.commentHtml and Map.htmlToText(dto.commentHtml); server.anns[dto.id] = dto; return dto end
function api:deleteAnnotation(id) server.anns[id] = nil; return true end

local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print("FAIL " .. msg) end end
local function count(t) local c = 0; for _ in pairs(t) do c = c + 1 end; return c end

-- Device A highlights something; Kavita has one highlight (by joe) and one by someone else
local uiA = newUI()
local pA = setmetatable({ ui = uiA, view = { highlight = { saved_drawer = "lighten" } } }, { __index = KavitaHL }); pA:init()
uiA.annotation.annotations[1] = { drawer = "lighten", color = "red", pos0 = xp(1, 0), pos1 = xp(1, 33), text = "It was a bright cold day in April", note = "opening" }
server.anns[1] = { id = 1, ownerUsername = "joe", selectedText = "slipped quickly through the glass doors", selectedSlotIndex = 1, pageNumber = 1, xPath = "//body/div[1]/p[2]", commentPlainText = "from web", likes = {} }
server.anns[2] = { id = 2, ownerUsername = "someone", selectedText = "boiled cabbage", selectedSlotIndex = 0, pageNumber = 2, xPath = "//body/p[1]" }

local r = pA:_sync(api, {})
ok(r.stats, "sync 1 ran: " .. tostring(r.error))
ok(r.stats.sent == 1 and r.stats.received == 1, "sent/received 1 each")
ok(#uiA.annotation.annotations == 2, "local now has 2")
local got = uiA.annotation.annotations[2]
ok(got.text == "slipped quickly through the glass doors" and got.note == "from web" and got.color == "green", "remote placed with note+color")
ok(got.pos0 == xp(2, 14), "remote placed at right offset " .. got.pos0)
local created = server.anns[101]
ok(created and created.xPath == "//body/div[1]/p[1]" and created.pageNumber == 1 and created.selectedSlotIndex == 3, "remote dto mapped")
ok(created.commentHtml == "<p>opening</p>", "note sent")
ok(server.anns[2] ~= nil and count(server.anns) == 3, "other user's highlight untouched")

-- Second sync: steady state
r = pA:_sync(api, {})
ok(r.stats.sent + r.stats.received + r.stats.updated + r.stats.deleted == 0, "steady state no-op")

-- Kavita edits note on 1, deletes 101; device adds a long cross-paragraph highlight
server.anns[1].commentPlainText = "edited on web"; server.anns[1].commentHtml = "<p>edited on web</p>"
server.anns[101] = nil
r = pA:_sync(api, {})
ok(r.stats.updated == 1 and r.stats.deleted == 1, "remote edit+delete applied")
ok(#uiA.annotation.annotations == 1 and uiA.annotation.annotations[1].note == "edited on web", "local reflects remote")

-- Device B (fresh, state lost) with the same highlight already present: should link, not duplicate
local uiB = newUI()
local pB = setmetatable({ ui = uiB, view = { highlight = {} } }, { __index = KavitaHL }); pB:init()
uiB.annotation.annotations[1] = { drawer = "lighten", color = "green", pos0 = xp(2, 15), pos1 = xp(2, 54), text = "slipped quickly through the glass doors" }
r = pB:_sync(api, {})
ok(r.stats.sent == 0 and r.stats.received == 0 and #uiB.annotation.annotations == 1, "linked without duplicates")
ok(uiB.annotation.annotations[1].note == "edited on web", "link pulled remote note")

-- Long highlight spanning paragraphs created in Kavita
server.anns[5] = { id = 5, ownerUsername = "joe", selectedText = paras[1].text .. "\n\n" .. paras[2].text, selectedSlotIndex = 2, pageNumber = 1, xPath = "//body/div[1]/p[1]" }
r = pB:_sync(api, {})
ok(r.stats.received == 1, "long highlight placed")
local long = uiB.annotation.annotations[#uiB.annotation.annotations]
ok(long.pos0 == xp(1, 0) and long.pos1 == xp(2, #paras[2].text), "long highlight spans paragraphs")

-- Mass-deletion guard: give B a few more synced highlights, then wipe the server
server.anns[6] = { id = 6, ownerUsername = "joe", selectedText = "bright cold day", selectedSlotIndex = 2, pageNumber = 1, xPath = "//body/div[1]/p[1]" }
server.anns[7] = { id = 7, ownerUsername = "joe", selectedText = "boiled cabbage", selectedSlotIndex = 2, pageNumber = 2, xPath = "//body/p[1]" }
server.anns[8] = { id = 8, ownerUsername = "joe", selectedText = "old rag mats", selectedSlotIndex = 2, pageNumber = 2, xPath = "//body/p[1]" }
r = pB:_sync(api, {})
ok(r.stats.received == 3 and #uiB.annotation.annotations == 5, "B has 5 synced")
server.anns = {}
r = pB:_sync(api, { interactive = true })
ok(r.confirm ~= nil, "mass delete asks for confirmation")
r = pB:_sync(api, {})
ok(#uiB.annotation.annotations == 5, "silent sync skips mass deletion")

-- Push-only (on close) never touches local
server.anns[9] = { id = 9, ownerUsername = "joe", selectedText = "boiled cabbage", selectedSlotIndex = 0, pageNumber = 2, xPath = "//body/p[1]" }
local before = #uiA.annotation.annotations
pA:_sync(api, { push_only = true })
ok(#uiA.annotation.annotations == before, "push-only leaves local alone")

print(string.format("%d/%d passed", n - fails, n))
os.exit(fails == 0 and 0 or 1)
