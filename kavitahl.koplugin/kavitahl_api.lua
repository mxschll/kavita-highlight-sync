--[[--
Minimal Kavita REST client. Authenticates every call with the same API key
that Kavita's KOReader progress-sync URL uses (x-api-key header).
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local KavitaApi = {}
KavitaApi.__index = KavitaApi

function KavitaApi.new(base_url, api_key)
    local o = setmetatable({}, KavitaApi)
    o.base_url = (base_url or ""):gsub("/+$", "")
    o.api_key = api_key
    return o
end

--- Turns JSON nulls into nil, recursively.
local function clean(v)
    if v == rapidjson.null then return nil end
    if type(v) == "table" then
        for k, x in pairs(v) do v[k] = clean(x) end
    end
    return v
end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end
KavitaApi.urlencode = urlencode

--- Older Kavita versions only accept a JWT on most endpoints: trade the key for one.
function KavitaApi:login()
    local res = self:_raw("POST", "/api/plugin/authenticate?pluginName=KOReaderHighlights&apiKey=" .. urlencode(self.api_key))
    if type(res) == "table" and type(res.token) == "string" then
        self.token = res.token
        return true
    end
end

function KavitaApi:redact(path)
    local key = urlencode(self.api_key or "")
    if key == "" then return path end
    return (path:gsub(key:gsub("%W", "%%%0"), "…"))
end

function KavitaApi:request(method, path, body)
    local res, err, code = self:_raw(method, path, body)
    if code == 401 and not self.token and self:login() then
        res, err = self:_raw(method, path, body)
    end
    return res, err
end

function KavitaApi:_raw(method, path, body)
    local encoded
    if body ~= nil then
        local err
        encoded, err = rapidjson.encode(body)
        if not encoded then return nil, "encode failed: " .. tostring(err) end
    end
    local code, resp_headers, status, raw
    -- LuaSocket only follows redirects for GET, so a reverse proxy redirecting
    -- http -> https (or adding a slash) silently breaks POST/DELETE. Follow them here.
    for _ = 1, 4 do
        local sink = {}
        local headers = {
            ["x-api-key"] = self.api_key,
            ["Accept"] = "application/json",
        }
        if self.token then headers["Authorization"] = "Bearer " .. self.token end
        if encoded then
            headers["Content-Type"] = "application/json"
            headers["Content-Length"] = tostring(#encoded)
        end
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        code, resp_headers, status = socket.skip(1, http.request{
            url = self.base_url .. path,
            method = method,
            headers = headers,
            source = encoded and ltn12.source.string(encoded) or nil,
            sink = ltn12.sink.table(sink),
            redirect = false,
        })
        socketutil:reset_timeout()
        raw = table.concat(sink)
        local location = type(resp_headers) == "table" and resp_headers.location
        if not (type(code) == "number" and code >= 300 and code < 400 and location) then break end
        -- Rebase on the redirect target so later calls go straight there
        local new_base = location:match("^(https?://.-)/api/")
        if not new_base then break end
        logger.info("KavitaHL: following redirect to", new_base)
        self.base_url = new_base
    end
    if type(code) ~= "number" or code < 200 or code >= 300 then
        local detail = (raw or ""):gsub("%s+", " "):sub(1, 160)
        logger.warn("KavitaHL:", method, self:redact(path), code, detail)
        local msg = string.format("%s %s → %s", method, (self:redact(path):gsub("%?.*$", "")), tostring(code or status))
        if detail ~= "" then msg = msg .. ": " .. detail end
        return nil, msg, code
    end
    if raw == "" then return true end
    local decoded = rapidjson.decode(raw)
    if decoded == nil then return true end -- plain text body
    return clean(decoded)
end

-- Identity ------------------------------------------------------------------

--- The username tied to the API key (Kavita's KOReader auth endpoint returns it).
function KavitaApi:whoami()
    local res, err = self:request("GET", "/api/koreader/" .. urlencode(self.api_key) .. "/users/auth")
    if not res then return nil, err end
    return res.username
end

-- Locating the book ------------------------------------------------------------

--- Finds Kavita's chapter for a KOReader partial-MD5 hash by searching titles/filenames
-- and checking the KoreaderHash Kavita stores for every file.
function KavitaApi:findChapterByHash(hash, queries)
    hash = hash:upper()
    local tried_series = {}
    for _, q in ipairs(queries) do
        if q and q ~= "" then
            local res = self:request("GET", "/api/search/search?includeChapterAndFiles=true&queryString=" .. urlencode(q))
            if type(res) == "table" then
                -- Direct file hits (filename search) tell us the series immediately
                for _, f in ipairs(res.files or {}) do
                    if f.koreaderHash and f.koreaderHash:upper() == hash then
                        local s = self:request("GET", "/api/search/series-for-mangafile?mangaFileId=" .. f.id)
                        if type(s) == "table" and s.id then
                            local found = self:_scanSeries(s.id, hash)
                            if found then return found end
                            tried_series[s.id] = true
                        end
                    end
                end
                for i, s in ipairs(res.series or {}) do
                    if i > 8 then break end
                    if s.seriesId and not tried_series[s.seriesId] then
                        tried_series[s.seriesId] = true
                        local found = self:_scanSeries(s.seriesId, hash)
                        if found then return found end
                    end
                end
            end
        end
    end
    return nil
end

function KavitaApi:_scanSeries(series_id, hash)
    local volumes = self:request("GET", "/api/series/volumes?seriesId=" .. series_id)
    if type(volumes) ~= "table" then return nil end
    for _, v in ipairs(volumes) do
        for _, c in ipairs(v.chapters or {}) do
            for _, f in ipairs(c.files or {}) do
                if f.koreaderHash and f.koreaderHash:upper() == hash then
                    return { chapter_id = c.id, volume_id = v.id, series_id = series_id }
                end
            end
        end
    end
end

-- Annotations ------------------------------------------------------------------

function KavitaApi:getAnnotations(chapter_id)
    return self:request("GET", "/api/annotation/all?chapterId=" .. chapter_id)
end

function KavitaApi:createAnnotation(dto)
    return self:request("POST", "/api/annotation/create", dto)
end

function KavitaApi:updateAnnotation(dto)
    return self:request("POST", "/api/annotation/update", dto)
end

function KavitaApi:deleteAnnotation(id)
    return self:request("DELETE", "/api/annotation?annotationId=" .. id)
end

return KavitaApi
