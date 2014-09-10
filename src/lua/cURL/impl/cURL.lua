--
--  Author: Alexey Melnichuk <mimir@newmail.ru>
--
--  Copyright (C) 2014 Alexey Melnichuk <mimir@newmail.ru>
--
--  Licensed according to the included 'LICENSE' document
--
--  This file is part of lua-lcurl library.
--

--
-- Implementation of Lua-cURL http://msva.github.io/lua-curl
--

local function wrap_function(k)
  return function(self, ...)
    local ok, err = self._handle[k](self._handle, ...)
    if ok == self._handle then return self end
    return ok, err
  end
end

local function wrap_setopt_flags(k, flags)
  k = "setopt_" .. k
  return function(self, v)
    v = assert(flags[v], "Unsupported value " .. tostring(v))
    local ok, err = self._handle[k](self._handle, v)
    if ok == self._handle then return self end
    return ok, err
  end
end

local function make_iterator(self, perform)
  local curl = require "lcurl.safe"

  local buffers = {resp = {}, _ = {}} do

  function buffers:append(e, ...)
    local resp = assert(e:getinfo_response_code())
    if not self._[e] then self._[e] = {} end

    local b = self._[e]

    if self.resp[e] ~= resp then
      b[#b + 1] = {"response", resp}
      self.resp[e] = resp
    end

    b[#b + 1] = {...}
  end

  function buffers:next()
    for e, t in pairs(self._) do
      local m = table.remove(t, 1)
      if m then return e, m end
    end
  end

  end

  local remain = #self._easy
  for _, e in ipairs(self._easy) do
    e:setopt_writefunction (function(str) buffers:append(e, "data",   str) end)
    e:setopt_headerfunction(function(str) buffers:append(e, "header", str) end)
  end

  assert(perform(self))

  return function()
    while true do
      local e, t = buffers:next()
      if t then return t[2], t[1], e end
      if remain == 0 then break end

      self:wait()

      local n, err = assert(perform(self))

      if n <= remain then
        while true do
          local e, ok, err = assert(self:info_read())
          if e == 0 then break end
          for _, a in ipairs(self._easy) do
            if e == a:handle() then e = a break end
          end
          if ok then
            ok = e:getinfo_response_code() or ok
            buffers:append(e, "done", ok)
          else buffers:append(e, "error", err) end
        end
        remain = n
      end

    end
  end
end

local function class(ctor)
  local C = {}
  C.__index = function(self, k)
    local fn = C[k]

    if not fn and self._handle[k] then
      fn = wrap_function(k)
      self[k] = fn
    end
    return fn
  end

  function C:new(...)
    local h, err = ctor()
    if not h then return nil, err end

    local o = setmetatable({
      _handle = h
    }, self)

    if self.__init then return self.__init(o, ...) end

    return o
  end

  function C:handle()
    return self._handle
  end

  return C
end

local function Load_cURLv2(cURL, curl)

-------------------------------------------
local Easy = class(curl.easy) do

local perform             = wrap_function("perform")
local setopt_share        = wrap_function("setopt_share")
local setopt_readfunction = wrap_function("setopt_readfunction")

local NONE = {}

function Easy:_call_readfunction(...)
  if self._rd_ud == NONE then
    return self._rd_fn(...)
  end
  return self._rd_fn(self._rd_ud, ...)
end

function Easy:setopt_readfunction(fn, ...)
  assert(fn)

  if select('#', ...) == 0 then
    if type(fn) == "function" then
      self._rd_fn = fn
      self._rd_ud = NONE
    else
      self._rd_fn = assert(fn.read)
      self._rd_ud = fn
    end
  else
    self._rd_fn = fn
    self._ud_fn = ...
  end

  return setopt_readfunction(self, fn, ...)
end

function Easy:perform(opt)
  opt = opt or {}

  local oerror = opt.errorfunction or function(err) return nil, err end

  if opt.readfunction then
    local ok, err = self:setopt_readfunction(opt.readfunction)
    if not ok then return oerror(err) end
  end

  if opt.writefunction then
    local ok, err = self:setopt_writefunction(opt.writefunction)
    if not ok then return oerror(err) end
  end

  if opt.headerfunction then
    local ok, err = self:setopt_headerfunction(opt.headerfunction)
    if not ok then return oerror(err) end
  end

  local ok, err = perform(self)
  if not ok then return oerror(err) end

  return self 
end

function Easy:post(data)
  local form = curl.form()
  local ok, err = true

  for k, v in pairs(data) do
    if type(v) == "string" then
      ok, err = form:add_content(k, v)
    else
      assert(type(v) == "table")
      if v.stream_length then
        local len = assert(tonumber(v.stream_length))
        assert(v.file)
        if v.stream then
          ok, err = form:add_stream(k, v.file, v.type, v.headers, len, v.stream)
        else
          ok, err = form:add_stream(k, v.file, v.type, v.headers, len, self._call_readfunction, self)
        end
      elseif v.data then
        ok, err = form:add_buffer(k, v.file, v.data, v.type, v.headers)
      else
        ok, err = form:add_file(k, v.file, v.type, v.filename, v.headers)
      end
    end
    if not ok then break end
  end

  if not ok then
    form:free()
    return nil, err
  end

  ok, err = self:setopt_httppost(form)
  if not ok then
    form:free()
    return nil, err
  end

  return self
end

function Easy:setopt_share(s)
  return setopt_share(self, s:handle())
end

Easy.setopt_proxytype = wrap_setopt_flags("proxytype", {
  ["HTTP"            ] = curl.PROXY_HTTP;
  ["HTTP_1_0"        ] = curl.PROXY_HTTP_1_0;
  ["SOCKS4"          ] = curl.PROXY_SOCKS4;
  ["SOCKS5"          ] = curl.PROXY_SOCKS5;
  ["SOCKS4A"         ] = curl.PROXY_SOCKS4A;
  ["SOCKS5_HOSTNAME" ] = curl.PROXY_SOCKS5_HOSTNAME;
})

Easy.setopt_httpauth  = wrap_setopt_flags("httpauth", {
  ["NONE"            ] = curl.AUTH_NONE;
  ["BASIC"           ] = curl.AUTH_BASIC;
  ["DIGEST"          ] = curl.AUTH_DIGEST;
  ["GSSNEGOTIATE"    ] = curl.AUTH_GSSNEGOTIATE;
  ["NEGOTIATE"       ] = curl.AUTH_NEGOTIATE;
  ["NTLM"            ] = curl.AUTH_NTLM;
  ["DIGEST_IE"       ] = curl.AUTH_DIGEST_IE;
  ["NTLM_WB"         ] = curl.AUTH_NTLM_WB;
  ["ONLY"            ] = curl.AUTH_ONLY;
  ["ANY"             ] = curl.AUTH_ANY;
  ["ANYSAFE"         ] = curl.AUTH_ANYSAFE;
  ["SSH_ANY"         ] = curl.SSH_AUTH_ANY;
  ["SSH_NONE"        ] = curl.SSH_AUTH_NONE;
  ["SSH_PUBLICKEY"   ] = curl.SSH_AUTH_PUBLICKEY;
  ["SSH_PASSWORD"    ] = curl.SSH_AUTH_PASSWORD;
  ["SSH_HOST"        ] = curl.SSH_AUTH_HOST;
  ["SSH_KEYBOARD"    ] = curl.SSH_AUTH_KEYBOARD;
  ["SSH_AGENT"       ] = curl.SSH_AUTH_AGENT;
  ["SSH_DEFAULT"     ] = curl.SSH_AUTH_DEFAULT;
})

end
-------------------------------------------

-------------------------------------------
local Multi = class(curl.multi) do

local perform       = wrap_function("perform")
local add_handle    = wrap_function("add_handle")
local remove_handle = wrap_function("remove_handle")

function Multi:__init()
  self._easy = {}
  return self
end

function Multi:perform()
  return make_iterator(self, perform)
end

function Multi:add_handle(e)
  self._easy = self._easy or {}
  self._easy[#self._easy + 1] = e
  return add_handle(self, e:handle())
end

function Multi:remove_handle(e)
  self._easy[#self._easy + 1] = e
  return remove_handle(self, e:handle())
end

end
-------------------------------------------

-------------------------------------------
local Share = class(curl.share) do

Share.setopt_share = wrap_setopt_flags("share", {
  [ "COOKIE"      ] = curl.LOCK_DATA_COOKIE;
  [ "DNS"         ] = curl.LOCK_DATA_DNS;
  [ "SSL_SESSION" ] = curl.LOCK_DATA_SSL_SESSION;
})

end
-------------------------------------------

assert(cURL.easy_init == nil)
function cURL.easy_init()  return Easy:new()  end

assert(cURL.multi_init == nil)
function cURL.multi_init() return Multi:new() end

assert(cURL.share_init == nil)
function cURL.share_init() return Share:new() end

end

local function Load_cURLv3(cURL, curl)

-------------------------------------------
local Easy = class(curl.easy) do

function Easy:__init(opt)
  if opt then return self:setopt(opt) end
  return self
end

local perform = wrap_function("perform")
function Easy:perform(opt)
  if opt then
    local ok, err = self:setopt(opt)
    if not ok then return nil, err end
  end

  return perform(self)
end

end
-------------------------------------------

-------------------------------------------
local Multi = class(curl.multi) do

function Multi:__init()
  self._easy = {}
  return self
end

function Multi:iperform()
  return make_iterator(self, self.perform)
end

local add_handle = wrap_function("add_handle")
function Multi:add_handle(e)
  self._easy[#self._easy + 1] = e
  return add_handle(self, e:handle())
end

local remove_handle = wrap_function("remove_handle")
function Multi:remove_handle(e)
  self._easy[#self._easy + 1] = e
  return remove_handle(self, e:handle())
end

end
-------------------------------------------

setmetatable(cURL, {__index = curl})

function cURL.easy(...)  return Easy:new(...)  end

function cURL.multi(...) return Multi:new(...) end

end

return function(curl)
  local cURL = {}

  Load_cURLv3(cURL, curl)

  Load_cURLv2(cURL, curl)

  return cURL
end
