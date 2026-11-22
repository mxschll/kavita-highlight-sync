package.path = "../kavitahl.koplugin/?.lua;" .. package.path
-- Fake transport: http://kavita redirects everything to https://kavita, which then works
local calls = {}
local NULL = setmetatable({}, { __tostring = function() return "null" end })
package.loaded["socket.http"] = (function() return { request = function(req)
  local body = req.source and req.source() or nil
  calls[#calls + 1] = { url = req.url, method = req.method, body = body, redirect = req.redirect }
  if req.url:match("^http://") then
    return 1, 308, { location = req.url:gsub("^http://", "https://") }, "HTTP/1.1 308"
  end
  if req.url:match("/annotation/create$") then
    if not body then return 1, 400, {}, "HTTP/1.1 400" end
    req.sink('{"id":42,"comment":null}'); return 1, 200, {}, "HTTP/1.1 200"
  end
  if req.url:match("/fail") then req.sink("Annotation failed to create"); return 1, 400, {}, "HTTP/1.1 400" end
  return 1, 200, {}, "HTTP/1.1 200"
end } end)()
package.loaded["ltn12"] = (function() return {
  source = { string = function(s) local done; return function() if done then return nil end; done = true; return s end end },
  sink = { table = function(t) return function(c) if c then t[#t + 1] = c end; return 1 end end } } end)()
package.loaded["rapidjson"] = (function() return { null = NULL,
  encode = function(t) return '{"x":1}' end,
  decode = function(s) if s:sub(1, 1) ~= "{" then return nil end; return { id = tonumber(s:match('"id":(%d+)')), comment = NULL } end } end)()
package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }
package.loaded["logger"] = { warn = function() end, info = function() end }

local A = require("kavitahl_api")
local fails, n = 0, 0
local function ok(c, m) n = n + 1; if not c then fails = fails + 1; print("FAIL " .. m) end end

local api = A.new("http://kavita", "secret")
local res, err = api:createAnnotation({ a = 1 })
ok(type(res) == "table" and res.id == 42, "POST follows redirect: " .. tostring(err))
ok(res.comment == nil, "json null cleaned")
ok(api.base_url == "https://kavita", "base rebased")
ok(calls[2].method == "POST" and calls[2].body == '{"x":1}', "body resent after redirect")
ok(calls[1].redirect == false, "auto redirect disabled")
res, err = api:request("POST", "/api/fail?apiKey=secret")
ok(res == nil and err:find("400") and err:find("Annotation failed to create") and not err:find("secret"), "error has status+body, no key: " .. tostring(err))
print(string.format("%d/%d passed", n - fails, n))
os.exit(fails == 0 and 0 or 1)
