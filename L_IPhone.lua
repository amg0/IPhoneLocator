local mime = require('mime')
local json = require('L_IPhoneJson')		-- or json_dm for those who use Dataminer plugin
local iPhoneEnc = require('L_IPhoneEnc')	-- to test what we can do with encrypted files
local socket = require("socket")
local https = require ("ssl.https")
local ltn12 = require("ltn12")
local MSG_CLASS = "IPhoneLocator"
local service = "urn:upnp-org:serviceId:IPhoneLocator1"
local devicetype = "urn:schemas-upnp-org:device:IPhoneLocator:1"
local UI7_JSON_FILE= "D_IPhone_UI7.json"
local DEBUG_MODE = false
local version = "v2.40"
local prefix = "child_"
local PRIVACY_MODE = "Privacy mode"
local RAND_DELAY = 4						-- random delay from period to avoid all devices going at the same time
local EXTRA_POLLING_PERIOD = 4000			-- extra polling wait time in ms
local MIN_PERIOD = 10						-- poll cannot be less than this in sec
local MAX_PERIOD = 3600						-- poll cannot be more than this in sec
local ETA_LATENCY = 30						-- ETA Latency, removes this from ETA to compensate for iCloud latency
local MIN_SPEED = 5/3600					-- 5km/h (in km/s)
local MIN_DISTANCE_GOOGLE = 0.1				-- do not call google if it did not move since at least this distance
local NOMOVE_SPEED = 60/3600				-- in km / s, when speed is null or <Min, taking this to calculate polling based on distance
local MAP_URL = "http://maps.google.com/?q={0}@{1},{2}"	-- {0}:name {1}:lat {2}:long
local ambiantLanguage = ""							-- Ambiant Language
local DEFAULT_ROOT_PREFIX = "(*)"

------------------------------------------------
-- Tasks
------------------------------------------------
local taskHandle = -1
local TASK_ERROR = 2
local TASK_ERROR_PERM = -2
local TASK_SUCCESS = 4
local TASK_BUSY = 1

--calling a function from HTTP in the device context
--http://192.168.1.5/port_3480/data_request?id=lu_action&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&action=RunLua&DeviceNum=81&Code=getMapUrl(81)

------------------------------------------------
-- Debug --
------------------------------------------------
local function log(text, level)
	luup.log(string.format("%s: %s", MSG_CLASS, text), (level or 50))
end

local function debug(text)
	if (DEBUG_MODE) then
		log("debug: " .. text)
	end
end

-- WATCH "Debug" variable
-- as soon as one devices turns its debug variable to "1"
-- it enables debug mode

-- NOT USED any more
-- function debug_watch(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	-- log("Debug setting changed to:"..lul_value_new)
	-- DEBUG_MODE = (tonumber(lul_value_new) >0) and true or false
-- end

function getDebugMode()
	--debug(string.format("forEachChildren(%s,func,%s)",parent,param))
	local result = 0
	for k,v in pairs(luup.devices) do
		if( v.device_type == devicetype ) then
			if (luup.variable_get(service, "Debug", k)=="1") then
				result=1
			end
		end
	end
	return result
end

------------------------------------------------
-- setDebugMode(lul_device,newMuteStatus)
-- uPNP action setDebugMode from I_IPhone.xml file
------------------------------------------------
function setDebugMode(lul_device,newDebugMode)
	debug(string.format("calling uPNP setDebugMode(%s,%s)",lul_device,newDebugMode))
	local newDebugMode=tonumber(newDebugMode)
	DEBUG_MODE = (newDebugMode>0) and true or false
	UserMessage("Set DEBUG_MODE to "..tostring(DEBUG_MODE), TASK_BUSY)
	for k,v in pairs(luup.devices) do
		if( v.device_type == devicetype ) then
			luup.variable_set(service,"Debug",newDebugMode,k)
		end
	end
	return newDebugMode
end

------------------------------------------------
-- VERA System Utils
------------------------------------------------

local function getSetVariable(serviceId, name, deviceId, default)
	local curValue = luup.variable_get(serviceId, name, deviceId)
	if (curValue == nil) then
		curValue = default
		luup.variable_set(serviceId, name, curValue, deviceId)
	end
	return curValue
end

local function setVariableIfChanged(serviceId, name, value, deviceId)
	debug(string.format("setVariableIfChanged(%s,%s,%s,%s)",serviceId, name, value, deviceId))
	local curValue = luup.variable_get(serviceId, name, deviceId) or ""
	value = value or ""
	if (tostring(curValue)~=tostring(value)) then
		luup.variable_set(serviceId, name, value, deviceId)
	end
end

local function getIP()
	-- local stdout = io.popen("GetNetworkState.sh ip_wan")
	-- local ip = stdout:read("*a")
	-- stdout:close()
	-- return ip
	local mySocket = socket.udp ()  
	mySocket:setpeername ("42.42.42.42", "424242")  -- arbitrary IP/PORT  
	local ip = mySocket:getsockname ()  
	mySocket: close()  
	return ip or "127.0.0.1" 
end


local function getSysinfo(ip)
	--http://192.168.1.5/cgi-bin/cmh/sysinfo.sh
	log(string.format("getSysinfo(%s)",ip))
	-- TODO , on vera => this line ==> local url=string.format("http://%s/cgi-bin/cmh/sysinfo.sh",ip)
	local url=string.format("http://%s:3480/cgi-bin/sysinfo.sh",ip)
	local timeout = 30
	local httpcode,content = luup.inet.wget(url,timeout)
	if (httpcode==0) then
		local obj = json.decode(content)
		debug("sysinfo="..content)
		return obj
	end
	return nil
end

local function getAmbiantLanguage(lul_device)
	--http://192.168.1.5/cgi-bin/cmh/sysinfo.sh
	-- log(string.format("getAmbiantLanguage(%s)",lul_device))
	-- if (ambiantLanguage=="") then
		-- local obj = getSysinfo( getIP() )
		-- if (obj~=nil) then
			-- debug("language="..obj.ui_language)
			-- ambiantLanguage = obj.ui_language
		-- else
			-- ambiantLanguage = "en"
		-- end
	-- end
	return getSetVariable(service, "UILanguage", lul_device, "en") --ambiantLanguage
end

-- 1 = Home
-- 2 = Away
-- 3 = Night
-- 4 = Vacation
local HModes = { "Home", "Away", "Night", "Vacation" ,"Unknown" }

local function setHouseMode( newmode ) 
	log(string.format("HouseMode, setHouseMode( %s )",newmode))
	newmode = tonumber(newmode)
	if (newmode>=1) and (newmode<=4) then
		UserMessage("SetHouseMode to "..newmode)
		luup.call_action('urn:micasaverde-com:serviceId:HomeAutomationGateway1', 'SetHouseMode', { Mode=newmode }, 0)
	end
end

local function getMode() 
	log("HouseMode, getMode()")
	-- local url_req = "http://" .. getIP() .. ":3480/data_request?id=variableget&DeviceNum=0&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&Variable=Mode"
	local url_req = "http://127.0.0.1:3480/data_request?id=variableget&DeviceNum=0&serviceId=urn:micasaverde-com:serviceId:HomeAutomationGateway1&Variable=Mode"
	local req_status, req_result = luup.inet.wget(url_req)
	-- ISSUE WITH THIS CODE=> ONLY WORKS WITHIN GLOBAL SCOPE LUA, not in PLUGIN context
	-- debug("calling getMode()...")
	-- local req_result =  luup.attr_get("Mode")
	-- debug("getMode() = "..req_result)
	req_result = tonumber( req_result or (#HModes) )
	log(string.format("HouseMode, getMode() returns: %s, %s",req_result or "", HModes[req_result]))
	return req_result 
end

------------------------------------------------
-- Check UI7
------------------------------------------------
local function checkVersion(lug_device)
	-- log(string.format("IPhone : checking if we run on UI7"))
	local ui7Check = luup.variable_get(service, "UI7Check", lug_device) or ""
	-- log(string.format("IPhone : ui7Check : %s",ui7Check))
	if ui7Check == "" then
		luup.variable_set(service, "UI7Check", "false", lug_device)
		ui7Check = "false"
	end
	-- log(string.format("IPhone : ui7Check : %s",ui7Check))
	if( luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
		luup.variable_set(service, "UI7Check", "true", lug_device)
		luup.attr_set("device_json", UI7_JSON_FILE, lug_device)
		-- log(string.format("IPhone : setting  UI7 json file and reloading"))
		luup.reload()
	end
end

------------------------------------------------
-- Tasks
------------------------------------------------

--
-- Has to be "non-local" in order for MiOS to call it :(
--
function clearTask()
	task("Clearing...", TASK_SUCCESS)
end

function task(text, mode)
	--luup.log("task " .. text)
	if (mode == TASK_ERROR_PERM) then
		taskHandle = luup.task(text, TASK_ERROR, MSG_CLASS, taskHandle)
	else
		taskHandle = luup.task(text, mode, MSG_CLASS, taskHandle)

		-- Clear the previous error, since they're all transient
		if (mode ~= TASK_SUCCESS) then
			luup.call_delay("clearTask", 30, "", false)
		end
	end
end

function UserMessage(text, mode)
	mode = (mode or TASK_ERROR)
	log(text)
	task(text,mode)
end

------------------------------------------------
-- LUA Utils
------------------------------------------------
function string:split(sep) -- from http://lua-users.org/wiki/SplitJoin
	local sep, fields = sep or ":", {}
	local pattern = string.format("([^%s]+)", sep)
	self:gsub(pattern, function(c) fields[#fields+1] = c end)
	return fields
end

function string:mytemplate(variables)
	return (self:gsub('{(.-)}', 
		function (key) 
			return tostring(variables[key] or '') 
		end))
end

function string:trim()
  return self:match "^%s*(.-)%s*$"
end

------------------------------------------------
-- Escape quote characters (for string comp)
------------------------------------------------
function escapeQuotes( str )
	return str:gsub("'", "\\'"):gsub("?", '\\%?'):gsub('"','\\"') -- escape quote characters
end
function escapePattern(str)
	return escapeQuotes( str )
end

-- example: iterateTbl( t , luup.log )
function forEach( tbl, func, param )
	for k,v in pairs(tbl) do
		func(k,v,param)
	end
end

function round(val, decimal)
  local exp = decimal and 10^decimal or 1
  return math.ceil(val * exp - 0.5) / exp
end

local function url_encode(str)
  if (str) then
	str = string.gsub (str, "\n", "\r\n")
	str = string.gsub (str, "([^%w %-%_%.%~])",
		function (c) return string.format ("%%%02X", string.byte(c)) end)
	str = string.gsub (str, " ", "+")
  end
  return str	
end

local function url_decode(str)
  str = string.gsub (str, "+", " ")
  str = string.gsub (str, "%%(%x%x)",
      function(h) return string.char(tonumber(h,16)) end)
  str = string.gsub (str, "\r\n", "\n")
  return str
end
------------------------------------------------
-- VERA Device Utils
------------------------------------------------

-----------------------------------
-- from a altid, find a child device
-- returns 2 values
-- a) the index === the device ID
-- b) the device itself luup.devices[id]
-----------------------------------
function findChild( parent, altid )
	for k,v in pairs(luup.devices) do
		if( getParent(k)==parent) then
			if( v.id==altid) then
				return k,v
			end
		end
	end
	return nil,nil
end

function getParent(lul_device)
	return luup.devices[lul_device].device_num_parent
end

function getRoot(lul_device)
	while( getParent(lul_device)>0 ) do
		lul_device = getParent(lul_device)
	end
	return lul_device
end

function forEachChildren(parent, func, param )
	--debug(string.format("forEachChildren(%s,func,%s)",parent,param))
	for k,v in pairs(luup.devices) do
		if( getParent(k)==parent) then
			func(k, param)
		end
	end
end

function getForEachChildren(parent, func, param )
	--debug(string.format("forEachChildren(%s,func,%s)",parent,param))
	local result = {}
	for k,v in pairs(luup.devices) do
		if( getParent(k)==parent) then
			result[#result+1] = func(k, param)
		end
	end
	return result
end

------------------------------------------------
-- Device Properties Utils
------------------------------------------------

-- getDistance(d) : in (km or nm or m) 
function getDistance(lul_device)
	local Distance = luup.variable_get(service,"Distance", lul_device)
	Distance = tonumber(Distance or 0)
	return Distance
end

-- getPresent(d) : 0 or 1
function getPresent(lul_device)
	local Present = luup.variable_get(service,"Present", lul_device) 
	Present = tonumber(Present or 0)
	return Present
end

-- getSpeed(d) : in (km or nm or m) per seconds
function getSpeed(lul_device)
	local DistDiff = math.abs( 
		tonumber( luup.variable_get(service,"Distance", lul_device) or 0 ) - 
		tonumber( luup.variable_get(service,"PrevDistance", lul_device) or 0 ) )
		
	local s1=luup.variable_get("urn:micasaverde-com:serviceId:HaDevice1","LastUpdate", lul_device)
	local d1=tonumber(s1)
	local s2=luup.variable_get(service,"PrevUpdate", lul_device)
	local d2=tonumber(s2)
	local TimeDiff = math.abs( os.difftime(d1,d2) )

	if (TimeDiff<=0) then
		debug("LastUpdate-PrevUpdate is null, returning speed:0")
		return 0
	end
	local speed = DistDiff/TimeDiff
	debug(string.format("Speed(%d):%f , Ddist:%f Dtime:%f",lul_device,speed,DistDiff,TimeDiff))
	
	if (speed<MIN_SPEED) then	-- 1kmh
		speed=0
	end
	return speed
end

------------------------------------------------
-- HTTP Handlers
------------------------------------------------
-- http://192.168.1.5:3480/data_request?id=lr_IPhone_Handler
 
function switch( command, actiontable)
	-- check if it is in the table, otherwise call default
	if ( actiontable[command]~=nil ) then
		return actiontable[command]
	end
	return 	function(params) 
				log("myIPhone_Handler:Unknown command received:"..command.." was called. NOP function")
			end
end

function myIPhone_Handler(lul_request, lul_parameters, lul_outputformat)
	local command=''
	log('myIPhone_Handler: request is: '..tostring(lul_request))
	for k,v in pairs(lul_parameters) do debug ('myIPhone_Handler: parameters are: '..tostring(k)..'='..tostring(v)) end
	debug('myIPhone_Handler: outputformat is: '..tostring(lul_outputformat))
	local lul_html = "";	-- empty return by default
	
	-- find a parameter called "command"
	if ( lul_parameters["command"] ~= nil ) then
		command =lul_parameters["command"]
	else
	    log("myIPhone_Handler:no command specified, taking default")
		command ="default"
	end
	
	local deviceID = tonumber(lul_parameters["DeviceNum"] or -1)
	
	-- switch table
	local action = {
		["SetCredentials"] = function(params)
				local email = url_decode(lul_parameters["email"] or "")
				local pwd = url_decode(lul_parameters["pwd"] or "")
				debug("Implementation of SetCredentials(): deviceID:"..deviceID..", email:"..email..", pwd:"..pwd)
				luup.variable_set(service,"Email",email,deviceID)
				iPhoneEnc.setPassword(deviceID,pwd)
				local iCloudNames={}
				local devicemap = getAppleDeviceMap(email, pwd, 0)	-- no extra polling
				if (devicemap~=nil) then
					-- match it against the pattern matching defined by the user
					for key,value in pairs(devicemap) do
						value.name = value.name:trim()
						iCloudNames[#iCloudNames+1]=value.name
					end
				end
				luup.variable_set(service, "ICloudDevices", table.concat(iCloudNames,","),deviceID)
				return json.encode( iCloudNames )
			end,
			
		["echo"] = function(params)	
				return "echo was called."
				-- return "<head>\n" ..
				-- "<script type="text/javascript">var NREUMQ=NREUMQ||[];NREUMQ.push(["mark","firstbyte",new Date().getTime()]);</script><title>Main</title>\n" ..
				-- "</head>\n" ..
				-- "<body>\n" ..
				-- "Choose a room:<br/>\n"
			end,
			
		["default"] = function(params)	
				return "default was called."
			end
	}
	-- actual call
	lul_html = switch(command,action)(lul_parameters) or ""
	return lul_html,"text/html"
end

------------------------------------------------
-- GPS
------------------------------------------------
function convertDistance(dist,distance_unit)
	--if distance_unit == "Km"  then
	--		dist = d
	if (distance_unit == "Nm") then
			dist = dist * 0.5399568034557
	elseif (distance_unit == "Mm") then
			dist = dist * 0.6213711922373
	end
	return dist
end
--[[
  Passed to function:
lat1, lon1 = Latitude and Longitude of point 1 (in decimal degrees)
lat2, lon2 = Latitude and Longitude of point 2 (in decimal degrees)
unit = the unit you desire for results
	   where: 'Mm' is statute miles
			  'Km' is kilometers (default)                          
			  'Nm' is nautical miles                                 
this function is from: GeoDataSource.com (C) All Rights Reserved 2013
 ]] 
-- function distanceBetween(lat1, lon1, lat2, lon2, distance_unit)           
	-- local radlat1 = math.pi * lat1/180
	-- local radlat2 = math.pi * lat2/180
	-- local radlon1 = math.pi * lon1/180
	-- local radlon2 = math.pi * lon2/180
	-- local theta = lon1-lon2
	-- local radtheta = math.pi * theta/180
	-- local dist = math.sin(radlat1) * math.sin(radlat2) + math.cos(radlat1) * math.cos(radlat2) * math.cos(radtheta);
	-- dist = math.acos(dist)
	-- dist = dist * 180/math.pi
	-- dist = dist * 60 * 1.1515
	-- if distance_unit == "Km"  then
		-- dist = dist * 1.609344
	-- elseif (distance_unit == "Nm") then
		-- dist = dist * 0.8684
	-- end
	-- return dist
-- end
-- Updated code from @duiffie , http://forum.micasaverde.com/index.php/topic,16907.msg136038.html#msg136038
function distanceBetween(lat1, lon1, lat2, lon2, distance_unit)
        local dist
		local R = 6378.137
        local dLat = (lat2 - lat1) * math.pi / 180
        local dLon = (lon2 - lon1) * math.pi / 180
        local a = math.sin(dLat/2) * math.sin(dLat/2) +
                math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) *
                math.sin(dLon/2) * math.sin(dLon/2)
        local c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        local d = R * c
		dist = convertDistance(d,distance_unit)
        return dist
end

function getAddressFromLatLong( lat, long, language, prevlat, prevlong )
	local timeout = 30
	local lang = language or "en"
	if (prevlat ~=nil) and (prevlong ~=nil) then
		local distance = distanceBetween(lat, long, prevlat, prevlong, "Km")
		if (distance < MIN_DISTANCE_GOOGLE) then
			debug("device moved by a distance of km:"..distance)
			return -1,""
		end
	end
	local url = string.format("http://maps.googleapis.com/maps/api/geocode/json?latlng=%f,%f&language=%s&sensor=false",lat,long,lang)
	debug("Sending GET to Google url:"..url)
	local httpcode,content = luup.inet.wget(url,timeout)
	--debug("result httpcode:"..httpcode)
	--debug("result content:"..content)
	return httpcode,content
end


function getDistancesAddressesMatrix(origins,destinations,distancemode,language)
	debug("getDistancesAddressesMatrix")
	local timeout = 30
	local distances={}
	local addresses={}
	local durations={}
	local orgs = {}
	local dests = {}
	for key,value in pairs(origins) do orgs[#orgs+1]=(value.lat..","..value.lon) end
	for key,value in pairs(destinations) do dests[#dests+1]=(value.lat..","..value.lon) end
	local url = string.format(
		"http://maps.googleapis.com/maps/api/distancematrix/json?origins=%s&destinations=%s&mode=%s&language=%s&sensor=false",
		table.concat(orgs,"|"),
		table.concat(dests,"|"),
		distancemode,
		language)
	debug("Sending GET to Google distance matrix url:"..url)
	local httpcode,content = luup.inet.wget(url,timeout)
	debug("result httpcode:"..httpcode)
	debug("result content:"..content)
	if (httpcode==0) then
		-- "status" : "OVER_QUERY_LIMIT"
		if ( string.find(content, "OVER_QUERY_LIMIT") ~= nil ) then
			addresses[1]="Google Quota exceeded"
			UserMessage(addresses[1])
		else
			local res,obj = xpcall( function () local obj = json.decode(content) return obj end , log )						
			if (res==true) then
				if (obj.status=="OK") then  -- google success
					addresses = obj["origin_addresses"]
					-- Each row corresponds to an origin, and each element within that row corresponds to a pairing of the origin with a destination value.
					-- nth device is to be mapped from its position ( origin ) to its destination ( the nth destinatoin )
					for key,value in pairs(obj["rows"]) do 
						if (value["elements"][key]["status"] =="OK") then
							distances[key]=value["elements"][key]["distance"]["value"]/1000	-- google provides it in meters
							durations[key]=value["elements"][key]["duration"]["value"]	-- google provides it in seconds
						else
							UserMessage("Google could not calculate a route")
							-- TODO google returned something like
							-- "elements": [
								-- {
									-- "status": "ZERO_RESULTS"
								-- }
							-- ]
						end
					end
				else
					addresses[1]="Google returned an error"
					UserMessage(addresses[1])
					debug("getDistancesAddressesMatrix obj.status is not ok. json string was:"..content)
				end
			else
				-- pcall returned false
				addresses[1]="Invalid google return format"
				UserMessage(addresses[1])
				log("Exception: json.decode("..content..") failed")		
			end
		end
	end
	return distances, durations, addresses
end

function getAppleStage2(stage2server,username,commonheaders,pollingextra)
	local pollingextra = pollingextra or 0
	local data = ""
	local response_body = {}
	local response, status, headers = https.request{
		method="POST",
		url="https://" .. stage2server .. "/fmipservice/device/" .. username .."/initClient",
		headers = commonheaders,
		source = ltn12.source.string(data),
		sink = ltn12.sink.table(response_body)
	}
	if (response==1) then
		debug("*** after send stage2. Response=" .. json.encode({res=response,sta=status,hea=headers}) )	
		local completestring = table.concat(response_body)
		local output = json.decode( completestring)
		debug("iCloud Response:"..completestring)
		if (output.statusCode=="200") then
			--debug("*** stage2 output.content:"..json.encode(output.content))				
			if (pollingextra==0) then
				return output.content
			else
				debug("stage2: Waiting for extra polling")
				luup.sleep(EXTRA_POLLING_PERIOD)	-- wait 2 sec
				return getAppleStage2(stage2server,username,commonheaders,0)
			end
		end
		log("Bad response from iCloud stage2, Response=" .. json.encode({res=response,sta=status,hea=headers}) )	
	end
	return nil
end
			
function getAppleDeviceMap(username, password, pollingextra)
	local data = ""
	local response_body = {}
	debug("getAppleDeviceMap for: ".. username)
	-- encode credentials for Basic authentication
	local b64credential = "Basic ".. mime.b64(username..":"..password)
	local pollingextra = pollingextra or 0
	
	-- prepare headers
	local commonheaders = {
			["Authorization"]=b64credential, --"Basic " + b64 encoded string of user:pwd
			["Content-Type"] = "application/json; charset=utf-8",
			["X-Apple-Find-Api-Ver"] = "2.0",
			["X-Apple-Authscheme"] = "UserIdGuest",
			["X-Apple-Realm-Support"] = "1.0",
			["User-agent"] = "Find iPhone/1.3 MeKit (iPad: iPhone OS/4.2.1)",
			["X-Client-Name"]= "iPad",
			["X-Client-UUID"]= "0cf3dc501ff812adb0b202baed4f37274b210853",
			["Accept-Language"]= "en-us",
			["Connection"]= "keep-alive"
		}
	--
	-- stage1 : to find server name 
	--
	local response, status, headers = https.request{
		method="POST",
		url="https://fmipmobile.icloud.com/fmipservice/device/" .. username .."/initClient",
		headers = commonheaders,
		source = ltn12.source.string(data),
		sink = ltn12.sink.table(response_body)
	}
	if (response==1) then
		if (status==330) then
			debug("*** after send stage1. Response=" .. json.encode({res=response,sta=status,hea=headers}) )	
			--
			-- stage2 : get server name and continue the process
			--
			local stage2server=headers["x-apple-mme-host"]
			local contentobj = getAppleStage2(stage2server,username,commonheaders,pollingextra)
			if (contentobj ~= nil) then
				return contentobj	-- can be nil in case of error
			end
			UserMessage("Bad response from https://" .. stage2server .. "/fmipservice/device/" .. username .."/initClient")
		else
			UserMessage("iCloud refused access, Check credentials ?")	
			debug("***Response=" .. json.encode({res=response,sta=status,hea=headers}) )	
		end
	else
		UserMessage("failed to call fmipservice device",TASK_ERROR_PERM)	
	end
	return nil
end

--function findDeviceInAppleMap(device,map)
--	for key,value in pairs(map) do
--		local ed = escapeQuotes(device)
--		local ev = escapeQuotes(value.name)
--		debug(string.format("comparing device:%s (escaped to:%s) with map name:%s (escaped to:%s)",device,ed,value.name,ev))
--		if (ev == ed) then
--			return value
--		end 
--	end
--	log("Did NOT find device "..device.." in map "..json.encode(map))
--	return nil
--end

-- if all participating devices are away, and mode is home or night then set mode to away  ( meaning vacation is ignored )
-- if 1 participating devices are present, and mode is away then set mode to home ( meaning vacation or night is left unchanged )
local function updateHouseMode(ui7)
	log(string.format("updateHouseMode(%s)",ui7))
	if (ui7=="true") then
		local curMode = getMode()
		local nAway,nPresent,nParticipating = 0,0,0
		for k,v in pairs(luup.devices) do
			if( v.device_type == devicetype ) then
				--luup.variable_set(service,"Debug",newDebugMode,k)
				local bParticipate = getSetVariable(service, "HouseModeActor", k, "0")
				if (bParticipate=="1") then
					nParticipating = nParticipating+1
					if ( getPresent(k) == 1 ) then
						nPresent = nPresent+1
					else
						nAway = nAway+1
					end
				end
			end
		end

		-- 1 = Home
		-- 2 = Away
		-- 3 = Night
		-- 4 = Vacation		
		-- if all participating devices are away, and mode is home or night then set mode to away  ( meaning vacation is ignored )
		debug(string.format("HouseMode: Participating devices:%d , present:%d , away:%d, cur HouseMode:%d", nParticipating, nPresent, nAway, curMode))
		if (nParticipating>0) then
			if (nParticipating==nAway) and ( (curMode==1) or (curMode==3) ) then
				setHouseMode( 2 ) 
			elseif (nPresent>=1) and (curMode==2) then
				setHouseMode( 1 ) 
			end
		else
			debug("HouseMode: No participant in calculation")
		end
	end
end

-- opt_distance is optional, it can be passed for precalculate distance ( google distance matrix api for instance )
-- if is null, the function will calculate the distance
function updateDevice(lul_device,location_obj,timestamp, address,opt_distance,opt_duration)
	local lat,long = 0,0
	if (location_obj ~= nil) then
		long = location_obj.longitude
		lat = location_obj.latitude
		debug(string.format("device:%d location:%s",lul_device,json.encode(location_obj)))
	end
	debug(string.format("updateDevice(%d) saving lat:%f long:%f time:%s addr:%s dist:%s dur:%s",lul_device,lat, long,timestamp or "",address or "",  opt_distance or "", opt_duration or ""))
	local iconcode = 0		-- for now, we think we are stable & away
	local privacymode =  (luup.variable_get(service,"AddrFormat", lul_device)=="0")
	local muted = luup.variable_get(service,"Muted", lul_device)
	local unit = luup.variable_get(service,"Unit", lul_device)
	local timestamp = timestamp or os.time()
	
	-- if lat and long are zero, it means update has not really worked, keep values unchanged
	if (lat~=0) or (long~=0) then
		-- update last update
		luup.variable_set(service, "PrevUpdate", luup.variable_get("urn:micasaverde-com:serviceId:HaDevice1","LastUpdate", lul_device), lul_device)
		luup.variable_set("urn:micasaverde-com:serviceId:HaDevice1", "LastUpdate", timestamp, lul_device)

		-- save position
		local curlatitude = luup.variable_get(service,"CurLat", lul_device) 
		local curlongitude = luup.variable_get(service,"CurLong", lul_device) 

		setVariableIfChanged(service, "PrevLat", curlatitude, lul_device)
		setVariableIfChanged(service, "PrevLong", curlongitude, lul_device)
		setVariableIfChanged(service, "CurLat", lat, lul_device)
		setVariableIfChanged(service, "CurLong", long, lul_device)
		
		-- calculate distance
		local homelatitude = luup.variable_get(service,"HomeLat", lul_device) 
		local homelongitude = luup.variable_get(service,"HomeLong", lul_device) 
		local olddistance = luup.variable_get(service,"Distance", lul_device)
		local newdistance = opt_distance
		if (newdistance ~= nil) then
			newdistance = 	round(convertDistance(newdistance, unit ),3)
		else
			newdistance = round(distanceBetween(homelatitude, homelongitude, lat, long, unit),3)
		end
		setVariableIfChanged(service, "PrevDistance", olddistance, lul_device)
		setVariableIfChanged(service, "Distance", newdistance, lul_device)
		
		local isHomeDistance = luup.variable_get(service,"Range", lul_device) -- 0.2 
		isHomeDistance = tonumber(isHomeDistance)

		-- estimated time of arrival, in seconds
		local speed = getSpeed(lul_device)
		setVariableIfChanged(service, "RTSpeed", speed*3600, lul_device)	-- speed in Unit Per Hour
		
		-- set or calculate ETA
		-- estimated time of arrival, in seconds
		if (opt_duration==nil) then
			debug("opt_duration is nil")
			if (speed==0) then
				opt_duration=newdistance/NOMOVE_SPEED
				debug("speed == 0, taking default:"..NOMOVE_SPEED)
			else
				opt_duration=newdistance/speed
			end
		end
		log("ETA set to =>"..opt_duration)
		setVariableIfChanged(service,"ETA",opt_duration,lul_device)

		-- calculate accuracy tolerance
		-- and save exta info coming from iCloud
		-- accuracy is assumed to be in meters
		local accuracy = 0		
		if (location_obj ~= nil) then
			setVariableIfChanged(service, "LocationExtraInfo", string.format("%s:%s:%s",location_obj.positionType,location_obj.horizontalAccuracy,tostring(location_obj.isInaccurate)), lul_device)
			accuracy = convertDistance(location_obj.horizontalAccuracy/1000, unit )	-- meter to km, then km to unit
		end
		debug("Accuracy taken into account  =>"..accuracy)
		
		--
		-- Calculate presence flag ,  Update Device Object
		--		
		local ui7check = luup.variable_get(service, "UI7Check", lul_device) or ""
		if (muted=="1") then
			log("Device Status("..lul_device.."): muted")
			iconcode = 50	--Away and not moving
		elseif ( math.max(0,newdistance-accuracy) < isHomeDistance) then
			log("Device Status("..lul_device.."): in Home")
			setVariableIfChanged(service, "Present",1, lul_device) --present
			iconcode = 100
			updateHouseMode(ui7check)
		else
			setVariableIfChanged(service, "Present",0, lul_device) --present
			updateHouseMode(ui7check)
			local delta = newdistance - olddistance
			if (math.abs(delta)<isHomeDistance) then
				log("Device Status("..lul_device.."): away stable")
				iconcode = 0	--Away and not moving
			elseif (delta>0) then
				log("Device Status("..lul_device.."): going away")
				iconcode = 25	--Away and going away
			else
				log("Device Status("..lul_device.."): coming back")
				iconcode = 75	--Away but coming home
			end
		end
		
		
		--- Generating Msg for User Interface
		if (privacymode==true) then
			setVariableIfChanged(service, "Location", PRIVACY_MODE, lul_device)
			setVariableIfChanged(service, "MsgText",string.format("Poll: %s",os.date("%F %R")) , lul_device)	
			setVariableIfChanged(service, "MsgText2","on "+os.date("%F %R",timestamp), lul_device)	
		else
			setVariableIfChanged(service, "Location", address, lul_device)
			setVariableIfChanged(service, "MsgText",string.format("Poll: %s",os.date("%F %R")) , lul_device)	
			setVariableIfChanged(service, "MsgText2",
				string.format("%0.2f %s @ %0.2f %s/h on %s",
					newdistance,
					unit,
					speed*3600,
					unit,
					os.date("%F %R",timestamp)), 
				lul_device)	
		end

		--- Update Map Url
		getsetMapUrl(lul_device)
		
		--- Update Icon Code
		setVariableIfChanged(service, "IconCode",iconcode , lul_device) --0:away, 25:going away 50:muted 75:approach 100:there
	else
		--- update failed for some reasons
		setVariableIfChanged(service, "Location", address, lul_device)
		setVariableIfChanged(service, "MsgText",string.format("%s",os.date("%F %R")) , lul_device)	
	end

end

function fillinVariablesFromGoogle(tbl)
	local res={}
	for key,value in pairs(tbl) do
		res[ value.types[1] ] = value.long_name
	end
	return res
end

------------------------------------------------
-- formatAddress2(lul_device,address)
-- json_obj is the return of google for a request like 
-- http://maps.googleapis.com/maps/api/geocode/json?latlng=44.22583333,4.777222222&sensor=false
-- it takes a AddrFormat string from the device parameters
-- and construct a final address accordingly
------------------------------------------------
function formatAddress2(lul_device,address)
	local addrFormat = luup.variable_get(service,"AddrFormat", lul_device)
	debug("addrFormat:"..addrFormat.." device:"..lul_device)
	if (addrFormat=="0") then
		result =PRIVACY_MODE
	end
	return address
end

------------------------------------------------
-- formatAddress(lul_device,json_obj)
-- json_obj is the return of google for a request like 
-- http://maps.googleapis.com/maps/api/geocode/json?latlng=44.22583333,4.777222222&sensor=false
-- it takes a AddrFormat string from the device parameters
-- and construct a final address accordingly
------------------------------------------------
function formatAddress(lul_device,json_obj)
	local result = json_obj.results[1].formatted_address 
	local addrFormat = luup.variable_get(service,"AddrFormat", lul_device)
	local pieces = {}
	debug("addrFormat:"..addrFormat.." device:"..lul_device)
	if (addrFormat~="") then
		--
		-- user is chosing a custom address format
		--
		if (addrFormat=="0") then
			result =PRIVACY_MODE
		else		
			debug("json_obj.results[1].address_components:"..json.encode(json_obj.results[1].address_components))
			local tmp = json_obj.results[1].address_components
			--
			-- user is choosing the new templatized address format
			--
			if (string.sub(addrFormat, 1, 1)=="~") then
				local variables = fillinVariablesFromGoogle(tmp)
				debug("Variables="..json.encode(variables))
				result = addrFormat:mytemplate(variables)	-- variable substitution
				result = result:sub(1-result:len())		-- all chars except first one ( the ~ )
				debug("Result="..result)
			else
				--
				-- user is choosing classical index based format
				--
				local tbl = addrFormat:split(",")
				for i,v in pairs(tbl) do 
					v = tonumber(v)
					if (v~=nil) and (v<= #tmp) then
						pieces[i]=tmp[v].long_name
					else
						pieces[i]="undef"
					end
					debug("google element idx:"..v.."/"..#tmp..", pieces["..i.."]="..pieces[i])
				end
				--debug("pieces:"..json.encode(pieces))
				result=table.concat(pieces,", ")
			end
		end
		debug("result:"..result)
	end
	return result
end

function deviceShouldBeReported(name, pattern)
	-- Pattern is a CSV list of LUA patterns
	log("iCloud device detected:"..name.." pattern:"..pattern)
	-- name = escapeQuotes(name)
	-- pattern= escapePattern(pattern)
	--debug("ESCAPED versions -->iCloud device detected:"..name.." pattern:"..pattern)
	local tblpattern = pattern:split(",")
	for key,value in pairs(tblpattern) do
		local match = string.match(name,value)
		if (match~=nil) then
			debug("iCloud device kept:"..name)
			return name
		end
	end
	debug("iCloud device ignored, name:"..name.." pattern:"..pattern)
	return nil
end


------------------------------------------------
-- setPresent(lul_device,newPresentStatus)
-- uPNP action setDebugMode from I_IPhone.xml file
------------------------------------------------
function setPresent(lul_device,newPresentStatus)
	debug(string.format("calling uPNP setPresent(%s,%s)",lul_device,newPresentStatus))
	luup.variable_set(service,"Present",newPresentStatus,lul_device)
	if (newPresentStatus=="0") then
		luup.variable_set(service,"IconCode","0",lul_device)
	else
		luup.variable_set(service,"IconCode","100",lul_device)
	end
	local ui7check = luup.variable_get(service, "UI7Check", lul_device) or ""
	updateHouseMode(ui7check)
end

------------------------------------------------
-- setMute(lul_device,newMuteStatus)
-- uPNP action SetMute from I_IPhone.xml file
-- no output, just update the device variables
------------------------------------------------
function setMute(lul_device,newMuteStatus)
	-- Since refreshed are managed by the device holding the iCloud account
	-- we need to ask the root device to do the refresh
	debug(string.format("calling uPNP setMute(%s,%s)",lul_device,newMuteStatus))
	lul_device = tonumber(lul_device)

	--  update root & update each children
	local root_device = getRoot(lul_device)
	local muted = luup.variable_get(service,"Muted", root_device)
	if (muted ~= newMuteStatus) then
		updateMuteIcon(root_device, newMuteStatus)
		forEachChildren(root_device, updateMuteIcon, newMuteStatus )

		-- forces a refresh but does not change the timer which is already running and scheduled
		if (tonumber(newMuteStatus) == 0) then
			-- Disable muted state
			debug("Refreshing device after unmute")		
			-- restartDevice(root_device) // move it to a timer to avoid taking too long
			luup.call_delay("restartDevice", 2, tostring(root_device))		
		end
	else
		debug(string.format("Ignoring setMute(%s,%s)",lul_device,newMuteStatus))
	end
end

function updateMuteIcon(device,newMuteStatus)
	luup.variable_set(service,"Muted",newMuteStatus,device)
	local present = luup.variable_get(service, "Present", device) --present
	if (newMuteStatus=="1") then
		luup.variable_set(service,"IconCode","50",device)
	else
		if (present=="1") then
			luup.variable_set(service,"IconCode","100",device)
		else
			luup.variable_set(service,"IconCode","0",device)
		end
	end
end

------------------------------------------------
-- whichVeraDeviceToUpdate(appledevicename)
-- need to find which LUA device is hosting 
-- the information for the apple device
-- it can be the root device if IPhoneName
-- or a children with prefix..appledevicename 
------------------------------------------------
function whichVeraDeviceToUpdate(appledevicename,lul_device)
	-- if (appledevicename==luup.attr_get ('id', lul_device)) then
		-- return lul_device
	-- end
	local child_device = findChild( lul_device, prefix..appledevicename )
	if (child_device~=nil) then
		return child_device
	end
	return lul_device
end

------------------------------------------------
-- Get Map Url based on template & location
-- Also used for uPNP action GetMapUrl
-- output  :the Url 
------------------------------------------------
function getsetMapUrl(lul_device)
	lul_device = tonumber(lul_device)
	local variables = {}
	variables["0"]= url_encode(luup.attr_get ('name', lul_device))
	variables["1"]= (luup.variable_get(service,"CurLat", lul_device) or "")
	variables["2"]= (luup.variable_get(service,"CurLong", lul_device) or "")
	debug("getsetMapUrl("..lul_device..") Variables="..json.encode(variables))
	result = MAP_URL:mytemplate(variables)	-- variable substitution

	-- store result here as this is the only way to return value for the uPNP action ( at least it seems )
	luup.variable_set(service,"MapUrl",result,lul_device)	
	return result
end

------------------------------------------------
-- Unitary device refresh
-- outside of any loop/timer
-- Also used for uPNP action refresh
-- no output, just update the device variables
------------------------------------------------
function forceRefresh(lul_device)
	log("forceRefresh action is called on behalf of device:"..lul_device)
	lul_device = tonumber(lul_device)
	
	-- Since refreshed are managed by the device holding the iCloud account
	-- we need to ask the root device to do the refresh
	lul_device = getRoot(lul_device)

	-- now we are sure we are on a root device, so these Apple Credentials are valid
	local email = 	luup.variable_get(service,"Email", lul_device)
	local password = iPhoneEnc.getPassword(lul_device)
	local pattern = luup.variable_get(service,"IPhoneName", lul_device)
	local distancemode = luup.variable_get(service,"DistanceMode", lul_device)
	local pollingextra = luup.variable_get(service,"PollingExtra", lul_device)
	pollingextra = tonumber(pollingextra)
	
	-- get the device map from apple
	local iCloudNames={}
	local devicemap = getAppleDeviceMap(email, password, pollingextra) -- extra polling if requested
	local language = getAmbiantLanguage(lul_device)

	if (devicemap~=nil) then
		-- Get the list of all iDevices in the iCloud account
		for key,value in pairs(devicemap) do
			value.name = value.name:trim()
			iCloudNames[#iCloudNames+1]=value.name
		end

		if (#iCloudNames>0) and (distancemode~="direct") then
			-- http://maps.googleapis.com/maps/api/distancematrix/json?origins=50.848714,4.351710|48.864999,2.316602&destinations=52.370989,4.895136&mode=driving&sensor=false
			-- orings = pairs of lat|lon
			-- destinations = pairs of lat|lon
			-- Results are returned in rows, each row containing one origin paired with each destination.
			local origins={}
			local dests={}
			local devices={}
			local timestamps={}
			
			for key,value in pairs(devicemap) do
				value.name = value.name:trim()
				local devicename = deviceShouldBeReported(value.name,pattern)
				-- if matching ( otherwise device is ignored )
				if (devicename~=nil) then
					local device = value 
					local targetdevice = whichVeraDeviceToUpdate(devicename,lul_device)
					if (device ~= nil) and (device.location~=nil) then
						local homelatitude = luup.variable_get(service,"HomeLat", targetdevice) 
						local homelongitude = luup.variable_get(service,"HomeLong", targetdevice) 
						origins[ #origins+1 ]={}
						origins[ #origins ].location_obj = device.location
						origins[ #origins ].lat = device.location.latitude
						origins[ #origins ].lon = device.location.longitude
						timestamps[ #timestamps+1 ] = device.location.timeStamp/1000
						dests[ #dests+1 ]={}
						dests[ #dests ].lat = homelatitude
						dests[ #dests ].lon = homelongitude
						devices[ #devices+1 ] = targetdevice
					else
						--- Generating Msg for User Interface
						updateDevice(targetdevice,nil,nil,"No Location Information for that device") --present
						UserMessage("Bad or No device found:"..json.encode(device))
					end
				end
			end			
			local distances,durations,addresses = getDistancesAddressesMatrix(origins,dests,distancemode,language)
			for key,value in pairs(devices) do 
				updateDevice(
					value,	-- deviceid
					origins[key].location_obj,
					timestamps[key],
					formatAddress2(value,addresses[key]),	-- does not support {variable} so specific method
					distances[key],durations[key]) 
			end
		else	
			-- distance mode == 'direct'
			-- match it against the pattern matching defined by the user
			for key,value in pairs(devicemap) do
				value.name = value.name:trim()
				local devicename = deviceShouldBeReported(value.name,pattern)
				-- if matching ( otherwise device is ignored )
				if (devicename~=nil) then
					local device = value 
					--
					-- now the question is which device we need to update
					-- a) find it  b) update it
					--
					local targetdevice = whichVeraDeviceToUpdate(devicename,lul_device)

					if (device ~= nil) and (device.location~=nil) then
						-- find the geographic address and save it if possible
						local address="undefined"
						local prevlatitude = luup.variable_get(service,"PrevLat", lul_device) 
						local prevlongitude = luup.variable_get(service,"PrevLong", lul_device) 
						local prevlocation = luup.variable_get(service,"Location", lul_device) or ""
						if (prevlocation=="") or (prevlocation==PRIVACY_MODE) then
							prevlatitude,prevlongitude = 0,0	-- force a call to google to refresh address
						end
						local httpcode, str = getAddressFromLatLong(device.location.latitude, device.location.longitude,language,prevlatitude,prevlongitude)
						if (httpcode==0) then -- http success
						
							-- "status" : "OVER_QUERY_LIMIT"
							if ( string.find(str, "OVER_QUERY_LIMIT") ~= nil ) then
								address="Google Quota exceeded"
								UserMessage("Google Quota exceeded")
							else
								--local obj = json.decode(str) ==> can crash, call it in protected mode. Thx @sjolshagen for the hint !
								local res,obj = xpcall( function () local obj = json.decode(str) return obj end , log )						
								if (res==true) then
									if (obj.status=="OK") then  -- google success
										address=formatAddress(targetdevice,obj)
									else
										address="Google returned an error"
										debug("getAddressFromLatLong obj.status is not ok. json string was:"..str)
									end
								else
									-- pcall returned false
									address="Invalid google return format"
									UserMessage(address)
									log("Exception: json.decode("..str..") failed")
								end
							end
						elseif (httpcode==-1) then	-- device did not move significantly
							debug("did not call google, device did not move enough")
							address=luup.variable_get(service, "Location", lul_device) or ""
						else
							UserMessage("warning, could not find address from GPS coordinate")
						end
						updateDevice(targetdevice, device.location, device.location.timeStamp/1000, address) --present
					else
						--- Generating Msg for User Interface
						updateDevice(targetdevice,nil,nil,"No Location Information for that device") --present
						UserMessage("Bad or No device found:"..json.encode(device))
					end
				end
			end
		end
	else
		UserMessage("apple device map is empty")
		updateDevice(lul_device,nil,nil,"No Devices for this account, check network/credentials") --present
	end
	luup.variable_set(service, "ICloudDevices", table.concat(iCloudNames,","),lul_device)
	return luup.variable_get(service, "Present", lul_device)
end

------------------------------------------------------------------------------------------
-- Calculate the polling period to take for this device
-- it is either
-- - manual
-- - auto if "PollingAuto" is set
--		a) with a default algo ( version <=1.23 )
--		b) with a configurable map
--         MAP should be dd:pp,dd:pp,dd:pp with ordered distance from lowest to greatest
----------------------------------------------------------------------------------------
function getPeriodForDistanceAndMap( period, distance, pollingMap )
	------------------------------------------------
	-- pollingMap is a csv list of pairs dist:time
	------------------------------------------------
	local tbl = pollingMap:split(",")
	debug("Polling map: "..json.encode(tbl))
	for i,v in pairs(tbl) do 	
		local distandpoll = v:split(":")	
		local distmin = distandpoll[1]+0	-- convert to number
		local periodmin= tonumber(distandpoll[2])
		if (distance>=distmin) then
			period = periodmin
		else
			break
		end
	end
	return period
end

function getPeriodForDevice(lul_device)
	local distance=getDistance(lul_device)
	
	local root  = getRoot(lul_device)
	local base = luup.variable_get(service,"PollingBase", root)
	base = tonumber(base)
	local period = base
	local auto =	luup.variable_get(service,"PollingAuto", root)
	if (auto=="1") then
		------------------------------
		-- Dynamic polling
		------------------------------
		local pollingMap = 	luup.variable_get(service,"PollingMap", root)
		if (pollingMap=="_") then
			pollingMap=""
		end
		
		if (pollingMap~="") then
			period = getPeriodForDistanceAndMap( period, distance, pollingMap )
		else
			------------------------------------------------
			-- Default dynamic polling behavior as in v1.23
			------------------------------------------------
			local Present = luup.variable_get(service,"Present", lul_device)
			local divider = luup.variable_get(service,"PollingDivider", root)
			divider = tonumber(divider)
			if (Present=="1") then
				period=base
			else
				local Eta = luup.variable_get(service,"ETA", lul_device)
				Eta = tonumber(Eta)
				debug("ETA considered :"..Eta)			
				if (Eta>ETA_LATENCY) then
					debug("reducing _LATENCY :"..ETA_LATENCY)			
					Eta = Eta - ETA_LATENCY
				end
				-- local speed = getSpeed(lul_device)
				period=math.floor(Eta/divider)
				debug("period Eta/divider:"..period)			
				if (period == 0 ) then
					period = base
				end
			end
			if (period < MIN_PERIOD) then
				period = MIN_PERIOD
			end
			if (period > MAX_PERIOD) then
				period = MAX_PERIOD
			end
			debug("period polling no map:"..period)			
		end
	else
		------------------------------
		-- Manual polling
		------------------------------
		debug("static period polling:"..period)
	end
	log(string.format("getPeriodForDevice(%s) - Distance:%s Auto:%s Base:%s==>%s",lul_device,distance, auto, base,period))
	return period
end

function getPeriod(lul_device)
	debug("calculate period for device:"..lul_device)
	local period=getPeriodForDevice(lul_device)
	
	-- for all children, take smallest needed period
	for k,v in pairs(luup.devices) do
		if( getParent(k)==lul_device) then
			local p = getPeriodForDevice(k)
			if (period>p) then
				period=p
			end
		end
	end

	log("Period chosen for device:"..lul_device.." = "..period)
	return period
end

-----------------------------------
-- The Main engine
-----------------------------------
function buildParams(str1,str2)
	return string.format("%s:%s",str1,str2)
end

function decodeParams(p)
	return p:split()
end

function loop(params)
	log("Entering loop:"..params)
	
	local lul_device = tonumber( decodeParams(params)[1] )
	if (getParent(lul_device)>0) then
		log("Critical error: a child object should not enter the Timer Loop()")
		return
	end
	
	local timerid =	luup.variable_get(service,"TimerID", lul_device)
	timerid = tonumber(timerid)
	
	-- if the timerid received is not the expected one, it measn this is an old timer, let's ignore and NOT repeat it
	if (timerid==tonumber( decodeParams(params)[2] )) then
		local period =	luup.variable_get(service,"PollingBase", lul_device)
		period = tonumber(period)
		
		local Muted = luup.variable_get(service,"Muted", lul_device)
		if (Muted=="1") then
			log("Device Muted, ignoring timer")
		else
			local res,err = pcall(forceRefresh,lul_device)
			period = getPeriod(lul_device)	-- get new polling period
			if (res==false) then		-- get new values
				log("loop: an error occurred during execution of forceRefresh():"..err)
				luup.variable_set(service, "MsgText", "forceRefresh error, check logs / "..string.format("%s s",period) , lul_device)	
			else
				local MsgText = luup.variable_get(service, "MsgText", lul_device)	
				luup.variable_set(service, "MsgText", MsgText .." / "..string.format("%s s",period) , lul_device)	
			end
		end
		
		-- Even if mute keep going on, not too much CPU and cleaner as I am not sure 
		-- how to interrupt an already programmed one, neither how to retrigger it properly
		if (period>0) then
			local delay = math.random(RAND_DELAY)	-- delaying  refresh by 0-RAND_DELAY seconds
			debug("rescheduling for period:"..period.." + delay of:"..delay)
			luup.call_timer("loop", 1, period+delay, "",buildParams(lul_device,timerid))
		else
			UserMessage("device is in manual refresh mode, period:"..period)
		end
	else
		log("Exit loop for invalid timer:"..timerid)
	end
end

---------------------------------------------------------------
-- restartDevice(lul_device) : really starts the looping engine
---------------------------------------------------------------
function restartDevice(lul_device)
	lul_device = tonumber(lul_device)
	local root_device = getRoot(lul_device)
	
	local timerid =	luup.variable_get(service,"TimerID", root_device)
	timerid = tonumber( timerid ) +1
	luup.variable_set(service,"TimerID", timerid, root_device)
	luup.variable_set(service,"Location","",lul_device)	-- force a refresh of location also
	-- start the engine, with a timerID
	loop(buildParams(root_device,timerid))
end

---------------------------------------------------------------
-- create the child devices. in luup.devices[DevID] it will be
  -- {
	-- "mac": "",
	-- "category_num": 3,
	-- "description": "xx iPhone",
	-- "user": "",
	-- "id": "child_xx iPhone",
	-- "pass": "",
	-- "ip": "",
	-- "room_num": 11,
	-- "udn": "uuid:4d494342-5342-5645-0058-000002179bbb",
	-- "subcategory_num": 0,
	-- "invisible": false,
	-- "hidden": false,
	-- "embedded": true,
	-- "device_num_parent": PARENT_ID,
	-- "device_type": "urn:schemas-upnp-org:device:BinaryLight:1"
  -- }
------------------------------------------------------------
function createChildDevices(lul_device)
	lul_device = tonumber(lul_device)
	log("createChildDevices()")
	local firstdevice = nil
	local email = 	luup.variable_get(service,"Email", lul_device)
	local password = iPhoneEnc.getPassword(lul_device)
	local pattern = luup.variable_get(service,"IPhoneName", lul_device) or ""
	local homelat = luup.variable_get(service,"HomeLat", lul_device)
	local homelong = luup.variable_get(service,"HomeLong", lul_device)
	local unit = luup.variable_get(service,"Unit", lul_device)
	local rootprefix = luup.variable_get(service,"RootPrefix", lul_device) or DEFAULT_ROOT_PREFIX
	
	local params = string.format("%s,HomeLat=%s\n%s,HomeLong=%s\n%s,Unit=%s",service,homelat,service,homelong,service,unit)
	--
	-- new with 1.25
	-- use "IPhoneName" as a regular expression to match names in apple device map
	-- and create these as child objects
	-- 
	local devicemap = getAppleDeviceMap(email, password,0)	-- no extra polling
	if (devicemap~=nil) then
		local handle = luup.chdev.start(lul_device);
		
		--- search first device of pattern as this is the prefered root device
		local firstpatternname = pattern:split(",")[1]
		if (firstpatternname~=nil) then
			debug("looking for firstpatternname ="..firstpatternname)
			for key,value in pairs(devicemap) do
				local devicename = deviceShouldBeReported(value.name, firstpatternname)
				if (devicename~=nil) then
					debug(string.format("Setting firstdevice => value.name:%s pattern:%s match:%s",value.name,firstpatternname,devicename))
						-- do not create a child for the first device, we use our own top device
						-- this is better for people who have only once device to report
					firstdevice=value.name		
					luup.variable_set(service, "ICloudName", value.name, lul_device)
					local attrname = luup.attr_get ('name', lul_device)
					if (attrname=="") then
						luup.attr_set ('name', rootprefix..devicename, lul_device)
					end
					break
				end
			end
		end
		--- first device has been found ( maybe ) so ignore it now
		for key,value in pairs(devicemap) do
			local devicename = deviceShouldBeReported(value.name, pattern)
			if (value.name~=firstdevice) then
				if (devicename~=nil) then
				--if (false) then  ==> use this to kill all children devices
					debug(string.format("value.name:%s pattern:%s match:%s",value.name,pattern,devicename))
					if (firstdevice==nil) then
						-- do not create a child for the first device, we use our own top device
						-- this is better for people who have only once device to report
						firstdevice=value.name		
						luup.variable_set(service, "ICloudName", devicename, lul_device)
						local attrname = luup.attr_get ('name', lul_device)
						if (attrname=="") then
							luup.attr_set ('name', devicename, lul_device)
						end
					else
						local newparams = params..string.format("\n%s,ICloudName=%s",service,devicename)
						-- local child,childdevice = findChild( lul_device, prefix..devicename )
						-- if (child ~= nil) then
							-- luup.variable_set(service, "ICloudName", devicename, child)
							-- local attrname = luup.attr_get ('name', child)
							-- if (attrname:trim()=="") then
								-- luup.attr_set ('name', devicename, child)
							-- end
						-- else
							luup.chdev.append(
								lul_device, handle, 		-- parent device and handle
								prefix..devicename, devicename, 		-- id and description
								devicetype, 	-- device type
								"D_IPhone.xml", "I_IPhone.xml", -- device filename and implementation filename
								newparams, 						-- uPNP child device parameters: "service,variable=value\nservice..."
								true,							-- embedded
								false							-- invisible
								)
						-- end
					end
				else
					debug(string.format("no matching device, value.name:%s pattern:%s no match",value.name,pattern))
				end
			end
		end
		if (firstdevice==nil) then
			luup.attr_set ('name', "Not Configured", lul_device)
			luup.variable_set(service, "ICloudName", "Not Configured", lul_device)
		end
		luup.chdev.sync(lul_device, handle)
	end

	--
	-- foreach child device find the device id and call its initialize function
	--
	forEachChildren(lul_device, startupDeferred, "" )
	
end
	
function startupDeferred(lul_device)
	lul_device = tonumber(lul_device)
	log("startupDeferred, called on behalf of device:"..lul_device)
		
	-------------------------------------------------------
	-- Set DEBUG_MODE
	-- contribution sjolshag,  but cannot work with many devices 
	-- Start with value of DEBUG_MODE
	-- eventually override in DEBUG mode if a device variable asks for it
	-- register a watch to be able to change it later
	-------------------------------------------------------
	local debugmode = luup.variable_get(service,"Debug", lul_device)
	if (debugmode== nil) then
		luup.variable_set(service,"Debug","0",lul_device)
	elseif (debugmode=="1") then
		DEBUG_MODE = true
		UserMessage("Enabling debug mode as Debug variable is set to 1 for device:"..lul_device,TASK_BUSY)
	end
	
	local oldversion = luup.variable_get(service,"Version", lul_device)
	local major,minor = 0,0
	if (oldversion~=nil) then
		major,minor = string.match(oldversion,"v(%d+)%.(%d+)")
		major,minor = tonumber(major),tonumber(minor)
		debug ("Plugin version: "..version.." Device's Version is major:"..major.." minor:"..minor)
	end
	
	-------------------------------------------------------
	-- Some variable only make sense on the root device
	-------------------------------------------------------
	if (getParent(lul_device)==0) then

		local lang = getAmbiantLanguage(lul_device)
		debug("UIlang="..lang)
		
		getSetVariable(service, "RootPrefix", lul_device, "(*)")	-- by default, does not participate in HouseMode Calculation
		local email = luup.variable_get(service,"Email", lul_device)
		if email == nil then
			luup.variable_set(service,"Email","noname@dot.com",lul_device)
		end

		-- new with 1.57, encrypt password		
		debug("Plugin version: "..version.." old device Version major:"..major.." minor:"..minor)
		if ((major==1) and (minor<57)) then
			-- this is an upgrade, so we read password unencrypted and we encrypt it
			UserMessage("Upgrading raw password to encrypted value",TASK_BUSY)
			local password = luup.variable_get(service,"Password", lul_device) or ""
			iPhoneEnc.setPassword(lul_device,password)
		elseif ((major==1) and (minor<59)) then
			UserMessage("Upgrading v158 password to encrypted value",TASK_BUSY)
			local password = iPhoneEnc.getv158Password(lul_device)
			iPhoneEnc.setPassword(lul_device,password)
		end

		local password = iPhoneEnc.getPassword(lul_device)
		if password == nil then
			iPhoneEnc.setPassword(lul_device,"pwd")
		end
		
		local iCloudDevices = getSetVariable(service,"ICloudDevices", lul_device,"")
		
		local IPhoneName= luup.variable_get(service,"IPhoneName", lul_device)
		if IPhoneName == nil then
			luup.variable_set(service,"IPhoneName","",lul_device)
		end    
		local polling = luup.variable_get(service,"PollingBase", lul_device)
		if (polling == nil) or (polling=="") then
			luup.variable_set(service,"PollingBase","60",lul_device)
		end
		local pollingauto = luup.variable_get(service,"PollingAuto", lul_device)
		if (pollingauto == nil) or (pollingauto == "")  then
			luup.variable_set(service,"PollingAuto","0",lul_device)
		end
		local pollingdivider = luup.variable_get(service,"PollingDivider", lul_device)
		if (pollingdivider == nil) or (pollingdivider == "")  then
			luup.variable_set(service,"PollingDivider","3",lul_device)
		end
		local pollingmap = luup.variable_get(service,"PollingMap", lul_device)
		if pollingmap=="_" then
			pollingmap=""
		end
		if pollingmap== nil then
			luup.variable_set(service,"PollingMap","",lul_device)
		end
		local pollingextra = luup.variable_get(service,"PollingExtra", lul_device)
		if pollingextra== nil then
			luup.variable_set(service,"PollingExtra","0",lul_device)
		end
		local distancemode = luup.variable_get(service,"DistanceMode", lul_device)
		if (distancemode == nil) then
			luup.variable_set(service,"DistanceMode","direct",lul_device)
		elseif ( (distancemode~="direct") and (distancemode~="driving") and (distancemode~="walking") and (distancemode~="bicycling") ) then
			luup.variable_set(service,"DistanceMode","direct",lul_device)
		end
		
		local HomeLat= luup.variable_get(service,"HomeLat", lul_device)
		if (HomeLat == nil) or (HomeLat == "")  then
			luup.variable_set(service,"HomeLat",luup.latitude,lul_device)
			luup.variable_set(service,"CurLat",luup.latitude,lul_device)
			luup.variable_set(service,"PrevLat",luup.latitude,lul_device)
		else
			luup.variable_set(service,"CurLat",HomeLat,lul_device)
			luup.variable_set(service,"PrevLat",HomeLat,lul_device)
		end    
		
		local HomeLong= luup.variable_get(service,"HomeLong", lul_device)
		if (HomeLong == nil) or (HomeLong == "")  then
			luup.variable_set(service,"HomeLong",luup.longitude,lul_device)
			luup.variable_set(service,"CurLong",luup.longitude,lul_device)
			luup.variable_set(service,"PrevLong",luup.longitude,lul_device)
		else
			luup.variable_set(service,"CurLong",HomeLong,lul_device)
			luup.variable_set(service,"PrevLong",HomeLong,lul_device)
		end 
		
		local PrevUpdate = luup.variable_get(service,"PrevUpdate", lul_device)
		if (PrevUpdate == nil) or (PrevUpdate=="") then
			luup.variable_set(service, "PrevUpdate", os.time(), lul_device)
		end
		local LastUpdate = luup.variable_get("urn:micasaverde-com:serviceId:HaDevice1","LastUpdate", lul_device)
		if (LastUpdate == nil) or (LastUpdate=="") then
			luup.variable_set("urn:micasaverde-com:serviceId:HaDevice1", "LastUpdate", os.time(), lul_device)
		end
		
		-- timerID starts at 0
		luup.variable_set(service, "TimerID", 0, lul_device)
	end
	
	-------------------------------------------------------
	-- All other variable are for both kind root & child 
	-------------------------------------------------------
	luup.variable_set(service,"RTSpeed",0,lul_device)
	luup.variable_set(service,"Version",version,lul_device)
	getSetVariable(service, "HouseModeActor", lul_device, "0")	-- by default, does not participate in HouseMode Calculation
	getSetVariable(service, "ICloudName", lul_device, "")	    
	
	local iconcode = luup.variable_get(service,"IconCode", lul_device)
	if (iconcode==nil) or (iconcode=="") then
		luup.variable_set(service,"IconCode",0,lul_device)
	end
	
	local unit = luup.variable_get(service,"Unit", lul_device)
	if (unit== nil) or (unit=="") or (unit=="K") or (unit=="M") or (unit=="N") then
		luup.variable_set(service,"Unit","Km",lul_device)
	end
	local msgText = luup.variable_get(service,"MsgText", lul_device)
	if msgText== nil then
		luup.variable_set(service,"MsgText","",lul_device)
	end
	local msgText2 = luup.variable_get(service,"MsgText2", lul_device)
	if msgText2== nil then
		luup.variable_set(service,"MsgText2","",lul_device)
	end
	local addrFormat = luup.variable_get(service,"AddrFormat", lul_device)
	if addrFormat== nil then
		luup.variable_set(service,"AddrFormat","",lul_device)
	end
	local Muted = luup.variable_get(service,"Muted", lul_device)
	if Muted == nil then
		luup.variable_set(service,"Muted",0,lul_device)
	else
		if (Muted=="1") then
			luup.variable_set(service,"IconCode",50,lul_device)
		end
	end
	local Present = luup.variable_get(service,"Present", lul_device)
	if Present == nil then
		luup.variable_set(service,"Present",0,lul_device)
	end
	local Location = luup.variable_get(service,"Location", lul_device)
	if Location == nil then
		luup.variable_set(service,"Location","none",lul_device)
	end
	local Eta = luup.variable_get(service,"ETA", lul_device)
	if Eta == nil then
		luup.variable_set(service,"ETA","0",lul_device)
	end    
	local Distance = luup.variable_get(service,"Distance", lul_device)
	if Distance == nil then
		luup.variable_set(service,"Distance","0",lul_device)
	end    
	local PrevDistance = luup.variable_get(service,"PrevDistance", lul_device)
	if PrevDistance == nil then
		luup.variable_set(service,"PrevDistance","0",lul_device)
	end    
	local HomeLat= luup.variable_get(service,"HomeLat", lul_device)
	if (HomeLat == nil) or  (HomeLat == "") then
		local parentlat = luup.variable_get(service,"HomeLat", getParent(lul_device))
		luup.variable_set(service,"HomeLat",parentlat,lul_device)
		luup.variable_set(service,"CurLat",parentlat,lul_device)
		luup.variable_set(service,"PrevLat",parentlat,lul_device)
	else
		luup.variable_set(service,"CurLat",HomeLat,lul_device)
		luup.variable_set(service,"PrevLat",HomeLat,lul_device)
	end    
	
	local HomeLong= luup.variable_get(service,"HomeLong", lul_device)
	if (HomeLong == nil) or (HomeLong == "")  then
		local parentlong = luup.variable_get(service,"HomeLong", getParent(lul_device))
		luup.variable_set(service,"HomeLong",parentlong,lul_device)
		luup.variable_set(service,"CurLong",parentlong,lul_device)
		luup.variable_set(service,"PrevLong",parentlong,lul_device)
	else
		luup.variable_set(service,"CurLong",HomeLong,lul_device)
		luup.variable_set(service,"PrevLong",HomeLong,lul_device)
	end    
	
	local Range= luup.variable_get(service,"Range", lul_device)
	if Range == nil then
		luup.variable_set(service,"Range",tostring(0.2),lul_device)
	end    

	local MapUrl = luup.variable_get(service,"MapUrl", lul_device)
	if MapUrl == nil then
		luup.variable_set(service,"MapUrl","",lul_device)
	end
	
	luup.register_handler("myIPhone_Handler","IPhone_Handler")

	---------------------------------------------------------------------------------------
	-- ONLY if this is the parent/root device we create child and start the refresh engine
	-- otherwise, we are a child device and we are a slave, nothing to do
	---------------------------------------------------------------------------------------
	if (getParent(lul_device)==0) then
		-- create child device
		createChildDevices(lul_device)
		
		-- start the engine, with a timerID 0
		restartDevice(lul_device)
		debug("startup completed for root device, called on behalf of device:"..lul_device)
		luup.set_failure(false,lul_device)	-- should be 0 in UI7
	else
		debug("startup completed for child device, called on behalf of device:"..lul_device)
	end
end
		
function initstatus(lul_device)
	lul_device = tonumber(lul_device)
	UserMessage("starting version "..version.." lul_device:"..lul_device)
	checkVersion(lul_device)
	local delay = 2	-- delaying first refresh by x seconds

	if (getParent(lul_device)==0) then
		debug("initstatus("..lul_device..") startup for Root device, delay:"..delay)
	else
		debug("initstatus("..lul_device..") startup for Child device, delay:"..delay)
	end
	luup.call_delay("startupDeferred", delay, tostring(lul_device))		
end

-- do not delete, last line must be a CR according to MCV wiki page

 
