module("L_IPhoneEnc", package.seeall)
local service = "urn:upnp-org:serviceId:IPhoneLocator1"
local MSG_CLASS = "IPhoneLocator"

-----------------------------------------------------------------------------
-- Imports and dependencies
-----------------------------------------------------------------------------
local math = require('math')
local string = require("string")
local table = require("table")
local mime = require('mime')
local socket=require('socket')
local json = require('L_IPhoneJson')    

local function log(text, level)
  luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

---------------------------------------------------------------------------
---- PRIVATE
-- pure b64 implementation for now. later on could get vera hw key
-- to at least encrypt to be only workable on that particular VERA box
---------------------------------------------------------------------------

local floor = math.floor
local function bxor (a,b)
  local r = 0
  for i = 0, 31 do
	local x = a / 2 + b / 2
	if x ~= floor (x) then
	  r = r + 2^i
	end
	a = floor (a / 2)
	b = floor (b / 2)
  end
  return r
end

local function smpEncrypt(text, pass)
  --log("smpEncrypt("..text..", "..pass..")")
  local keysize = pass:len()
  local textsize = text:len()
  local iT, iP = 0,0
	local out = {}
  for iT=0,textsize-1 do
	iP=(iT % keysize)
	local c = string.byte(text:sub(iT+1,iT+1))
	c = bxor( c , string.byte(pass:sub(iP+1,iP+1)) )
	c = string.format("%c",c)
		table.insert(out, c)
  end
	return table.concat(out)
end

local function smpDecrypt(text, pass)
  --log("smpDecrypt("..text..", "..pass..")")
  local keysize = pass:len()
  local textsize = text:len()
  local iT, iP = 0,0
	local out = {}
  for iT=0,textsize-1 do
	iP=(iT % keysize)
	local c = string.byte(text:sub(iT+1,iT+1))
	c = bxor( c , string.byte(pass:sub(iP+1,iP+1)) )
	c = string.char(c)
		table.insert(out, c)
  end
	return table.concat(out)
end

local function b64Encrypt(data)
  local len = data:len()
  local t = {}
  for i=1,len,384 do
	local n = math.min(384, len+1-i)
	if n > 0 then
	  local s = data:sub(i, i+n-1)
	  local enc, _ = mime.b64(s)
	  t[#t+1] = enc
	end
  end
  return table.concat(t)
end

local function b64Decrypt(data)
  local len = data:len()
  local t = {}
  for i=1,len,384 do
	local n = math.min(384, len+1-i)
	if n > 0 then
	  local s = data:sub(i, i+n-1)
	  local dec, _ = mime.unb64(s)
	  t[#t+1] = dec
	end
  end
  return table.concat(t)
end

-------------------------------------------------------------------------------------
-- Execute the command and return the stdout.
-------------------------------------------------------------------------------------
local function execute (command)

	local file = io.popen (command)
	local data = file:read ("*a")
	file:close()

	-- We want to return nil instead of the empty string.
	if data == "" then
		data = nil
	end

	return data
end

-- local function getMyIP()
  -- local ipAddr = execute ("cat /var/state/network | grep network.wan.ipaddr")
  -- ipAddr = ipAddr:match (".*=(.*)\n")
  -- return ipAddr
-- end

local function getHwKey()
  -- local ipAddr = getMyIP()
  -- local url = "http://"..ipAddr.."/cgi-bin/cmh/sysinfo.sh"
  -- local status, rss = luup.inet.wget(url,10)
  -- if ( status==0) then
	-- local obj = json.decode(rss)
	-- return obj.hwkey
  -- end
  -- return nil
  return luup.hw_key
end

---------------------------------------------------------------------------
---- PUBLIC
---------------------------------------------------------------------------
function getPassword(lul_device)
  --log("HwKey="..key)
  local pwd= luup.variable_get(service,"Password", lul_device)
  if (pwd==nil) then
	return nil
  end
  pwd = mime.unb64(pwd)
  return Decrypt(pwd)
end

function setPassword(lul_device,pwd)
  pwd = Encrypt(pwd)
  pwd = mime.b64(pwd)
  luup.variable_set(service,"Password",pwd,lul_device)
  return "ok"
end

function Encrypt(str)
  return str
end

function Decrypt(str)
  return str
end

function getv158Password(lul_device)
  --log("HwKey="..key)
  local pwd= luup.variable_get(service,"Password", lul_device)
  if (pwd==nil) then
	return nil
  end
  pwd = mime.unb64(pwd)
  return StrongDecrypt(pwd)
end

function StrongEncrypt(str)
  local key = getHwKey()
  local res= smpEncrypt(str, key)
  log(string.format("StrongEncrypt - Key:%s input:%s res:%s", key,str,res));
  return res
end

function StrongDecrypt(str)
  local key = getHwKey()
  local res =  smpDecrypt(str, key)
  log(string.format("StrongDecrypt - Key:%s input:%s res:%s", key,str,res));
  return res
end

