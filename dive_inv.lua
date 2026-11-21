-- With the McPuppet Inventory System (a separate global mod) running, Dive's gear becomes its items (the user,
-- 2026-11-21: "the mod should work as normal without the inventory mod. When inventory mod is turned on, those items
-- should turn into inventory items", as Humans vs Clickers does with its tools). Without it nothing here does anything.
--   - The oxygen tank: an Inventory garment for the BACK slot (the user), add-only and rigid on the chest bone
--     (vox/inv_airtank.vox, tools/make_inventory_tank.py; layer 3: over vests). Worn, the diver's tank holds
--     dive.gear.start seconds (210) - Dive's own diver-gear tool is never handed out then, and its own tank isn't drawn.
--     Given once at the start and after a respawn when the player has none (as Dive's gear is), from divergear
--     pickups, from dive.give.gear.<p>.
--   - The harpoon gun: Dive's own tool, declared an Inventory tool (6 spears inside it). harpoon.lua routes gifts,
--     racks and takes through the Inventory's keys.
--   - Guns under water: put away through inventory.stow.<p> (the Inventory's key, 2026-11-21) instead of the wheel.
--   - The blowtorch swap and the gear tool's wheel writes stand down (the Inventory owns the wheel: a write fight).
-- The Inventory's keys (its MODDING.md; the Inventory session's answers 2026-11-21): inventory.present,
-- inventory.give.<p> "id[:n[:ammo]] ...", inventory.take.<p>, inventory.count.<p>.<id>, inventory.wear.<p> (the
-- host's worn ids), inventory.load.<p>.<tool>, inventory.stow.<p>; the garment through inventory_api.lua (the
-- Wardrobe session's wear engine; rigid = true added for this tank).

DiveInv = {}
INV_TANK = "dive_airtank"

InventoryClothing({id = INV_TANK, name = "Oxygen tank", slot = "back", layer = 3, rigid = true,
	vox = "MOD/vox/inv_airtank.vox", parts = "chest", covers = "", tint = true,
	armor = 0, mobility = 0, noise = 0, type = "equipment.back.airtank", price = 300,
	icon = "images/dive_airtank.png", drop = "vox/airtank_pickup.vox"})

-- The flippers (the user, 2026-11-21: a feet-slot item, faster in water, slower on land): in place of shoes, worn
-- with the foot (vox/inv_flippers.vox, tools/make_inventory_flippers.py). Their stats are the Inventory's: mobility
-- (walking and jumps, applied on land) and swim (in water) - the Inventory sums them; Dive's diving speed takes
-- inventory.stat.<p>.swim (invSwim). (Key names agreed with the Inventory and Wardrobe sessions.)
INV_FLIPPERS = "dive_flippers"
InventoryClothing({id = INV_FLIPPERS, name = "Flippers", slot = "feet", layer = 1,
	vox = "MOD/vox/inv_flippers.vox", parts = "foot_l foot_r toes_l toes_r", covers = "foot_l foot_r toes_l toes_r",
	tint = true, armor = 0, mobility = -0.4, swim = 0.5, noise = 0.1, type = "equipment.feet.flippers", price = 150,
	icon = "images/dive_flippers.png", drop = "vox/flipper_pickup.vox"})

-- this diver's swimming factor from the Inventory (1 = normal; its flippers 1.5)
function invSwim(p)
	local k = "inventory.stat." .. p .. ".swim"
	return HasKey(k) and math.max(0.3, GetFloat(k)) or 1
end

function invOn()
	return GetBool("inventory.present")
end

local function words(s)
	local t = {}
	for w in string.gmatch(s or "", "%S+") do t[#t + 1] = w end
	return t
end

function invAppendKey(key, w)
	local cur = GetString(key)
	SetString(key, cur == "" and w or (cur .. " " .. w))
end

-- does player p wear (or carry) item id, by the host's keys
function invWears(p, id)
	for _, w in ipairs(words(GetString("inventory.wear." .. p))) do
		if w == id then return true end
	end
	return false
end

function invHas(p, id)
	return invWears(p, id) or GetInt("inventory.count." .. p .. "." .. id) > 0
end

-- the harpoon as an Inventory tool, on every machine (its store, icons and names): 6 spears inside it, refilled at
-- racks (inventory.load), sold in the store
local function declare()
	local k = "inventory.tools." .. HARPOON
	SetBool(k, true)
	SetInt(k .. ".ammo", SPEARS)
	SetInt(k .. ".price", 400)
	SetString(k .. ".icon", "images/harpoon.png")
	local mod = wbModId and wbModId({vox = "MOD/vox/inv_airtank.vox"}) or ""
	if mod ~= "" then SetString(k .. ".mod", mod) end
	SetString(k .. ".tip", "Fires spears under water|Spear racks refill it (E)")
end

function DiveInv.serverInit()
	declare()
	invStowed = {}                       -- player -> the stow list we last wrote
end

function DiveInv.clientInit()
	declare()
end

function DiveInv.clientTick(dt)
	InventoryClientTick()                -- (registers the garment, spawns the worn tanks; harmless without the Inventory)
end

-- the guns that don't work under water: the Inventory's tools with ammo items (.takes: the Guns Pack's, a mode's) and
-- the game's own firearms when a pack declared them
function invGunList()
	local out, seen = {}, {}
	for _, id in ipairs(ListKeys("inventory.tools") or {}) do
		if HasKey("inventory.tools." .. id .. ".takes") and not seen[id] then out[#out + 1] = id; seen[id] = true end
	end
	for _, id in ipairs(GUNS) do
		if not seen[id] and HasKey("inventory.tools." .. id) then out[#out + 1] = id; seen[id] = true end
	end
	return table.concat(out, " ")
end

-- head under: the guns stowed; at the surface: back (written on change only)
function invStow(p, stow)
	local want = stow and invGunList() or ""
	if invStowed[p] == want then return end
	invStowed[p] = want
	if want == "" then ClearKey("inventory.stow." .. p) else SetString("inventory.stow." .. p, want) end
end

-- the tank, per player each tick (host): worn -> the diver's tank time; handed out at the start and after a respawn
-- when they have none (dive.gear.start > 0; 0 = only pickups); a script's dive.give.gear.<p> gives or takes it
function invGearTick(p, d)
	if HasKey("dive.give.gear." .. p) then
		local seconds = GetFloat("dive.give.gear." .. p)
		ClearKey("dive.give.gear." .. p)
		d.gearRevoked = seconds <= 0
		if seconds > 0 then
			if not invHas(p, INV_TANK) then invAppendKey("inventory.give." .. p, INV_TANK) end
		else
			invAppendKey("inventory.take." .. p, INV_TANK)
		end
	end
	-- (the start's gift is repeated every 3 s until the player has the tank, at most 30 s: a gift before the Inventory
	-- has read our garment is lost - seen in-game, 2026-11-21: no tank on the back after the start)
	local alive = GetPlayerHealth(p) > 0
	local now = GetTime()
	if alive and not d.gearRevoked and (not d.invStarted or d.wasDead) then
		d.invStarted, d.invGiveUntil, d.invGiveAt = true, now + 30, 0
	end
	if d.invGiveUntil then
		if invHas(p, INV_TANK) or now > d.invGiveUntil or not alive or setting("dive.gear.start", GEAR_START) <= 0 then
			d.invGiveUntil = nil
		elseif now >= d.invGiveAt then
			d.invGiveAt = now + 3
			invAppendKey("inventory.give." .. p, INV_TANK)
		end
	end
	d.wasDead = not alive
	d.invTank = alive and invWears(p, INV_TANK)
	if d.gearLen or d.worn then d.gearLen, d.worn = nil, false end   -- (Dive's own gear tool: not with the Inventory)
end

-- seconds of air in a worn Inventory tank
function invTankTime()
	local s = setting("dive.gear.start", GEAR_START)
	return s > 0 and s or GEAR_START
end
