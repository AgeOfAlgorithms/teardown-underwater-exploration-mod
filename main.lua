#version 2
-- Dive: underwater play on any map with water. Nothing happens on dry land; in water: scuba diving with the air, the
-- diver gear and the underwater look (dive.lua), the harpoon gun (harpoon.lua), every loose object with its own
-- buoyancy (buoyancy.lua), schools of fish drawn by each player for themselves (fish.lua), seaweed and corals on the
-- floor, also each player's own (flora.lua).
-- One script, its parts as modules (each a table of callbacks). If another copy of this script is loaded too (an old
-- map that still ships one), only one runs (claim).

#include "dive.lua"
#include "buoyancy.lua"
#include "fish.lua"
#include "flora.lua"
#include "script/toolanimation.lua"
#include "harpoon.lua"
#include "inventory_api.lua"     -- (the McPuppet Inventory System's API copy: the tank as its garment; unchanged copy)
#include "dive_inv.lua"

MODULES = {Dive, Buoyancy, Fish, Flora, Harpoon, DiveInv}
-- (test builds add their modules here)

-- The API for other mods and maps (API.md): a setting is the registry key if any script has written it, else the
-- map's tag on its water (WATER_TAGS), else the default.
WATER_TAGS = {["dive.visibility"] = "visibility"}   -- (fish / seaweed / corals: only the host's options since 2026-11-21)

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
-- first frame runs. That decides the server side; a copy's client side runs only if its own server side won (its
-- shared.diveOwner, which only the winner sets): the two sides each claiming for themselves could end up in different
-- copies (one copy's swimming and air with the other's drawing, which then had no state to draw).
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
			shared.diveOwner = true
			readWaterTags()
			call("serverInit")
		end
	end
	if serverOn then
		call("serverTick", dt)
		publishOptions(dt)
	end
end

-- The host's choices in the Mod Manager (options.lua: fish, seaweed, corals) -> synced amounts every machine's fish
-- and plants use (dive.opt.fish / .seaweed / .corals). The ONLY control of those amounts: maps and other mods can't set
-- them (the user, 2026-11-21: "remove this API and leave it to the mod menu only"). Looked at once a second, written only when changed
-- (a value rewritten every tick would flood the clients).
OPTION_STEPS = {fish = {0, 0.5, 1, 2, 4, 8}, seaweed = {0, 0.5, 1, 2, 3}, corals = {0, 0.5, 1, 2, 3}}
local optT, optSent = 0, {}
function publishOptions(dt)
	optT = optT - dt
	if optT > 0 then return end
	optT = 1
	for key, steps in pairs(OPTION_STEPS) do
		local i = GetInt("savegame.mod." .. key)
		if i < 1 or i > #steps then i = 3 end
		if optSent[key] ~= steps[i] then
			optSent[key] = steps[i]
			SetFloat("dive.opt." .. key, steps[i], true)
		end
	end
end

-- a host option's multiplier on this machine (1 until the host's arrives)
function hostOption(key)
	if HasKey("dive.opt." .. key) then return GetFloat("dive.opt." .. key) end
	return 1
end

function server.update(dt)
	if serverOn then call("serverUpdate", dt) end
end

function client.init()
	clientOn = false
end

function client.tick(dt)
	if not clientOn and shared.diveOwner then
		clientOn = true
		readWaterTags()
		call("clientInit")
	end
	if clientOn then call("clientTick", dt) end
end

function client.update(dt)
	if clientOn then call("clientUpdate", dt) end
end

function client.render(dt)
	if clientOn then call("clientRender", dt) end
end

function client.draw()
	if clientOn then call("clientDraw") end
end
