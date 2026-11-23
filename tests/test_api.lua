package.path = "../kavitahl.koplugin/?.lua;" .. package.path
-- Fake transport: http://kavita redirects everything to https://kavita, which then works.
-- `redirects` maps a URL prefix to the Location the server answers with.
local calls = {}
local redirects = {}
local NULL = setmetatable({}, { __tostring = function() return "null" end })
package.loaded["socket.http"] = (function() return { request = function(req)
  local body = req.source and req.source() or nil
  calls[#calls + 1] = { url = req.url, method = req.method, body = body, redirect = req.redirect, headers = req.headers }
  for from, to in pairs(redirects) do
    if req.url:sub(1, #from) == from then return 1, 308, { location = to .. req.url:sub(#from + 1) }, "HTTP/1.1 308" end
  end
  if req.url:match("^http://") then
    return 1, 308, { location = req.url:gsub("^http://", "https://") }, "HTTP/1.1 308"
  end
  if req.url:match("/annotation/create$") then
    if not body then return 1, 400, {}, "HTTP/1.1 400" end
    req.sink('{"id":42,"comment":null}'); return 1, 200, {}, "HTTP/1.1 200"
  end
  if req.url:match("/fail") then req.sink("Annotation failed to create"); return 1, 400, {}, "HTTP/1.1 400" end
  if req.url:match("/users/auth$") then req.sink("Unauthorized"); return 1, 401, {}, "HTTP/1.1 401" end
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

-- The key is a path segment for whoami; the error must not show it
res, err = api:whoami()
ok(res == nil and err:find("401") and not err:find("secret") and err:find("/api/koreader/…/users/auth", 1, true), "whoami error redacts key in path: " .. tostring(err))

-- Redirects that would hand the key to another host, or send it over plain http, are not followed
local function refused(base, to, m)
  calls = {}
  redirects = { [base] = to }
  local a = A.new(base, "secret")
  local r, e = a:createAnnotation({ a = 1 })
  ok(r == nil and e and e:find("not followed") and e:find(to, 1, true), m .. " refused: " .. tostring(e))
  ok(#calls == 1, m .. " not followed")
  ok(a.base_url == base, m .. " base unchanged")
  for _, c in ipairs(calls) do ok(c.url:sub(1, #base) == base, m .. " key only sent to origin") end
  redirects = {}
end
refused("https://kavita", "https://evil.example", "cross-host")
refused("https://kavita", "http://kavita", "https->http")
refused("https://kavita:5000", "https://kavita:5001", "port change")
refused("https://kavita", "https://kavita:443@evil.example", "userinfo with port")
refused("https://kavita", "https://kavita:@evil.example", "userinfo without port")
refused("https://[fd00::1]", "https://[fd00::2]", "other ipv6 host")

-- A relative Location is not followed either, and the error says so
calls = {}
local rel = A.new("https://kavita", "secret")
local saved = package.loaded["socket.http"].request
package.loaded["socket.http"].request = function(req) calls[#calls + 1] = req; return 1, 308, { location = "/api/annotation/create/" }, "HTTP/1.1 308" end
res, err = rel:createAnnotation({ a = 1 })
ok(res == nil and err:find("not followed") and err:find("/api/annotation/create/", 1, true) and #calls == 1, "relative redirect reported: " .. tostring(err))
package.loaded["socket.http"].request = saved

ok(A.redirectAllowed("http://kavita", "https://kavita"), "http->https default ports allowed")
ok(A.redirectAllowed("http://kavita:5000", "https://kavita:5000"), "http->https same port allowed")
ok(A.redirectAllowed("https://Kavita", "https://kavita"), "host case-insensitive")
ok(A.redirectAllowed("https://[fd00::1]:5000", "https://[fd00::1]:5000"), "same ipv6 host allowed")
ok(not A.redirectAllowed("http://kavita:5000", "https://kavita"), "http:5000->https:443 refused")
ok(not A.redirectAllowed("https://kavita", "ftp://kavita"), "non-http scheme refused")
ok(not A.redirectAllowed("https://kavita", "https://user@kavita"), "userinfo refused even on same host")
print(string.format("%d/%d passed", n - fails, n))
os.exit(fails == 0 and 0 or 1)
