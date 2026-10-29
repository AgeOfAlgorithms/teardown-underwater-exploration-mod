#version 2
-- Dive: underwater play on any map with water. Nothing happens on dry land; in water: scuba diving with an air tank
-- (dive.lua), every loose object with its own buoyancy (buoyancy.lua), schools of fish drawn by each player for
-- themselves (fish.lua), seaweed and corals on the floor, also each player's own (flora.lua), caustics, bubbles and
-- the underwater look (dive.lua, client).
-- One script, its parts as modules (each a table of callbacks). A map can ship this same script (the Dive Test
-- level does): if the global mod runs too, the copy that registered last runs and the other one stays idle.

#include "dive.lua"
#include "buoyancy.lua"
#include "fish.lua"
#include "flora.lua"

MODULES = {Dive, Buoyancy, Fish, Flora}
-- (test builds add their modules here)

-- The API for other mods and maps (API.md): a setting is the registry key if any script has written it, else the
-- map's tag on its water (WATER_TAGS), else the default.
WATER_TAGS = {["dive.visibility"] = "visibility", ["dive.fish"] = "fish", ["dive.seaweed"] = "seaweed",
	["dive.corals"] = "corals"}

function readWaterTags()
	waterTags = {}
	for key, tag in pairs(WATER_TAGS) do
		local w = FindEntity(tag, true, "water")
		if w ~= 0 then waterTags[key] = tonumber(GetTagValue(w, tag)) end
	end
end

function setting(key, default)
	if HasKey(key) then return GetFloat(key) end
	return waterTags[key] or default
end

function settingOn(key, default)
	if HasKey(key) then return GetBool(key) end
	return default
end

function call(name, ...)
	for _, m in ipairs(MODULES) do
		if m[name] then m[name](...) end
	end
end

-- Two copies (a map's and the global mod's) each write a token at init; the one whose token is still there on its
-- first frame runs.
function claim(key)
	local token = tostring(math.random()) .. "/" .. tostring(GetTime())
	SetString(key, token)
	return token
end

function server.init()
	serverOn = false
	serverToken = claim("dive.owner.server")
end

function server.tick(dt)
	if serverToken then
		serverOn = GetString("dive.owner.server") == serverToken
		serverToken = false
		if serverOn then
			readWaterTags()
			call("serverInit")
		end
	end
	if serverOn then call("serverTick", dt) end
end

function server.update(dt)
	if serverOn then call("serverUpdate", dt) end
end

function client.init()
	clientOn = false
	clientToken = claim("dive.owner.client")
end

function client.tick(dt)
	if clientToken then
		clientOn = GetString("dive.owner.client") == clientToken
		clientToken = false
		if clientOn then
			readWaterTags()
			call("clientInit")
		end
	end
	if clientOn then call("clientTick", dt) end
end

function client.update(dt)
	if clientOn then call("clientUpdate", dt) end
end

function client.draw()
	if clientOn then call("clientDraw") end
end
