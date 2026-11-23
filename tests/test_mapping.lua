package.path = "../kavitahl.koplugin/?.lua;" .. package.path
local M = require("kavitahl_mapping")
local fails, n = 0, 0
local function eq(a, b, msg)
  n = n + 1
  if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": got " .. tostring(a) .. " want " .. tostring(b)) end
end

-- xpointer -> kavita
local p, x = M.xpointerToKavita("/body/DocFragment[5]/body/div/p[3]/span/text()[2].12")
eq(p, 4, "page"); eq(x, "//body/div[1]/p[3]", "xpath inline strip")
p, x = M.xpointerToKavita("/body/DocFragment[12]/body/section[2]/p[7]/text().0")
eq(p, 11, "page2"); eq(x, "//body/section[2]/p[7]", "xpath2")
p, x = M.xpointerToKavita("/body/DocFragment[3]/body/p[1].0")
eq(x, "//body/p[1]", "element offset")
p, x = M.xpointerToKavita("/body/DocFragment[3].0")
eq(p, 2, "frag only page"); eq(x, "//body", "frag only")
p, x = M.xpointerToKavita("/body/DocFragment[2]/body/DIV/em/strong/text().3")
eq(x, "//body/div[1]", "nested inline + case")
eq(M.xpointerToKavita("garbage"), nil, "garbage")

-- kavita -> prefix
local pre, frag = M.kavitaToXPointerPrefix(4, "//body/div[1]/p[3]")
eq(pre, "/body/DocFragment[5]/body/div[1]/p[3]", "prefix"); eq(frag, "/body/DocFragment[5]", "frag")
pre, frag = M.kavitaToXPointerPrefix(0, 'id("c1")/p[2]')
eq(pre, nil, "id xpath"); eq(frag, "/body/DocFragment[1]", "id frag")
eq(M.looseXPath("/body/DocFragment[5]/body/div[1]/p[3]"), M.looseXPath("/body/DocFragment[5]/body/div/p[3]"), "loose")
-- underPath: [1] may be omitted, but a prefix must end at an element boundary
local p1 = "/body/DocFragment[5]/body/div[1]/p[1]"
eq(M.underPath("/body/DocFragment[5]/body/div/p/text().4", p1), true, "underPath omitted [1]")
eq(M.underPath("/body/DocFragment[5]/body/div/p.0", p1), true, "underPath element offset")
eq(M.underPath("/body/DocFragment[5]/body/div/p[3]/text().4", p1), false, "underPath sibling p[3]")
eq(M.underPath("/body/DocFragment[5]/body/div/pre/text().4", p1), false, "underPath pre vs p")
eq(M.underPath("/body/DocFragment[5]/body/div/p/span/text().4", p1), true, "underPath descendant")
eq(M.underPath("/body/DocFragment[12]/body/p.0", "/body/DocFragment[1]"), false, "underPath fragment 1 vs 12")
eq(M.fragmentOf("/body/DocFragment[12]/body/p/text().3"), 12, "fragmentOf")
eq(M.fragmentOf("garbage"), nil, "fragmentOf garbage")
-- round trip through KOReader-style path
local xp = "/body/DocFragment[7]/body/div/p[4]/text().9"
local pg, kx = M.xpointerToKavita(xp)
local pre2 = M.kavitaToXPointerPrefix(pg, kx)
eq(M.underPath(xp, pre2), true, "round trip prefix match")

-- colors
eq(M.colorToSlot("red"), 3, "red"); eq(M.colorToSlot(nil), 2, "default"); eq(M.slotToColor(0), "cyan", "slot0")
for slot = 0, 4 do eq(M.colorToSlot(M.slotToColor(slot)), slot, "slot roundtrip " .. slot) end

-- text
eq(M.normalize("  a \n\n b\t c "), "a b c", "normalize")
local h, t = M.searchPatterns("short text")
eq(h, "short text", "short head"); eq(t, nil, "short tail")
local long = string.rep("word ", 60)
h, t = M.searchPatterns(long, 30)
eq(#h <= 30, true, "head len"); eq(h:sub(-1) ~= " ", true, "head trimmed"); eq(#t <= 30, true, "tail len")
eq(M.utf8len("héllo"), 5, "utf8len")

-- notes
local delta, html = M.noteToKavita('a "b" <c>\nline2')
eq(delta, '{"ops":[{"insert":"a \\"b\\" <c>\\nline2\\n"}]}', "delta")
eq(html, "<p>a &quot;b&quot; &lt;c&gt;</p><p>line2</p>", "html")
eq(select(1, M.noteToKavita("   ")), nil, "empty note")
eq(M.htmlToText("<p>a &amp; b</p><p>c</p>"), "a & b\nc", "html->text")
eq(M.remoteNote({ commentPlainText = " hi " }), "hi", "remote plain")
eq(M.remoteNote({ commentHtml = "<p>x</p>" }), "x", "remote html")
eq(M.remoteNote({}), nil, "remote none")

-- planning
local function count(a) return #a.create_remote, #a.create_local, #a.delete_remote, #a.delete_local, #a.update_remote, #a.update_local, #a.link, #a.rekey end
local function sig(a) return table.concat({ count(a) }, ",") end

-- first sync: one local, one remote, one shared text
local locals = { { key = "k1", text = "Local only" }, { key = "k2", text = "Shared  text", color = "yellow" } }
local remotes = { { id = 10, text = "Remote only", slot = 0 }, { id = 11, text = "Shared text", slot = 2, note = "n" } }
eq(sig(M.plan(locals, remotes, {})), "1,1,0,0,0,0,1,0", "first sync")

local state = { ["11"] = { key = "k2", slot = 2 }, ["12"] = { key = "k3", slot = 2 }, ["13"] = { key = "k4", slot = 2 } }
locals = { { key = "k2", text = "Shared", color = "yellow", note = "new local note" }, { key = "k4", text = "x" } }
remotes = { { id = 11, text = "Shared", slot = 2, note = "remote changed" }, { id = 12, text = "y", slot = 2 } }
-- 11: both changed -> local wins (update_remote); 12: local gone -> delete_remote; 13: remote gone -> delete_local
local a = M.plan(locals, remotes, state)
eq(sig(a), "0,0,1,1,1,0,0,0", "changes")
eq(a.delete_remote[1], 12, "delete remote id"); eq(a.delete_local[1].key, "k4", "delete local key"); eq(a.delete_local[1].id, "13", "delete local id")

-- remote-only change
a = M.plan({ { key = "k2", text = "S", color = "yellow" } }, { { id = 11, text = "S", slot = 4 } }, { ["11"] = { key = "k2", slot = 2 } })
eq(sig(a), "0,0,0,0,0,1,0,0", "remote change")
-- nothing changed; local red vs slot 3 snapshot -> no change
a = M.plan({ { key = "k2", text = "S", color = "red" } }, { { id = 11, text = "S", slot = 3 } }, { ["11"] = { key = "k2", slot = 3 } })
eq(sig(a), "0,0,0,0,0,0,0,0", "steady state")
-- both deleted -> nothing
a = M.plan({}, {}, { ["11"] = { key = "k2", slot = 3 } })
eq(sig(a), "0,0,0,0,0,0,0,0", "both gone")
eq(M.countDeletions(M.plan({}, {}, {})), 0, "countDeletions")

-- local keys changed (xpointer migration), text and page unchanged -> rekey, no delete/create
state = { ["11"] = { key = "old1", slot = 2 }, ["12"] = { key = "old2", slot = 2, note = "n" } }
locals = { { key = "new1", text = "One", color = "yellow", page = 3 }, { key = "new2", text = "Two", color = "yellow", note = "n", page = 4 } }
remotes = { { id = 11, text = "One", slot = 2, page = 3 }, { id = 12, text = "Two", slot = 4, note = "n", page = 3 } }
a = M.plan(locals, remotes, state)
eq(sig(a), "0,0,0,0,0,1,0,2", "rekey keeps remotes")
eq(a.rekey[1].id, 11, "rekey id"); eq(a.rekey[1].key, "new1", "rekey new key")
eq(a.update_local[1].key, "new2", "rekeyed remote change applies to new key")
-- key changed and text changed (boundaries moved) -> delete + create as before
a = M.plan({ { key = "new1", text = "One more word", color = "yellow", page = 3 } }, { { id = 11, text = "One", slot = 2, page = 3 } }, { ["11"] = { key = "old1", slot = 2 } })
eq(sig(a), "1,0,1,0,0,0,0,0", "changed text is not rekeyed")
-- same short phrase highlighted again in another chapter -> the old remote is not reused
a = M.plan({ { key = "new1", text = "One", color = "yellow", page = 9 } }, { { id = 11, text = "One", slot = 2, page = 3 } }, { ["11"] = { key = "old1", slot = 2 } })
eq(sig(a), "1,0,1,0,0,0,0,0", "same text on a distant page is not rekeyed")
a = M.plan({ { key = "new1", text = "One", color = "yellow" } }, { { id = 11, text = "One", slot = 2, page = 3 } }, { ["11"] = { key = "old1", slot = 2 } })
eq(sig(a), "1,0,1,0,0,0,0,0", "unknown page is not rekeyed")

print(string.format("%d/%d passed", n - fails, n))
os.exit(fails == 0 and 0 or 1)
