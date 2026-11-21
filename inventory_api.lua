-- Inventory API 1: the one file a clothing or weapon pack needs. Copy it from the McPuppet Inventory System's
-- folder into your mod, unchanged, then in your main.lua:
--
--     #version 2
--     #include "inventory_api.lua"
--     InventoryClothing({id = "mymod_jacket", name = "Leather Jacket", slot = "top", layer = 1,
--                   vox = "MOD/vox/jacket.vox", parts = "chest stomach shoulder_l shoulder_r",
--                   covers = "chest stomach shoulder_l shoulder_r"})
--     function client.tick(dt) InventoryClientTick() end
--
-- The step-by-step guides are MODDING_CLOTHING.md and MODDING_WEAPONS.md in the Inventory mod's folder; "example
-- pack" there is a mod to copy.
-- slot:   head, top (upper body), back (a backpack, gear carried on the back), legs (lower body) or feet: one item
--         per slot per player.
-- vox:    one .vox, one object per body part it has, named after the part (chest, arm_upper_l ...) and painted in
--         the template grid of that part (vox/template.vox of the example pack).
-- parts:  the objects in the file. covers: the parts whose lower layers need not be drawn under it.
-- layer:  1 = skin tight (replaces the body part), 2 = worn over (default 1); a part is hidden under a worn item
--         of a higher layer that covers it, so gear worn over everything (an air tank) takes layer 3.
-- rigid:  true = the parts are not reshaped to the wearer's build (a steel tank, a helmet that must keep its shape):
--         they move with the bone at the template part's place on that player, as painted.
-- tint:   true = the file's objects are on a vox layer "$TINT" and palette 241-248 takes the wearer's skin colour.
-- type:   a descriptive tag other mods read (inventory.clothing.<id>.type), "<clothing|armor>.<slot>.<kind>",
--         e.g. "clothing.upper.jacket", "armor.head.greathelm"; made from the armor, slot and id when left out.
-- armor:  0-1, the share of a hit the item blocks (pieces multiply); the Inventory mod gives it back on the host.
-- mobility: added to the wearer's mobility factor (-0.10 = walks 10 % slower and jumps 10 % lower). noise: added to
--         the wearer's noise factor (0.35 = 35 % louder, -0.25 = quieter). swim: added to the wearer's swimming
--         factor, which takes over from mobility in water (0.5 = swims 50 % faster: flippers; mobility -0.2 makes
--         them slow on land).
-- icon, drop: file names in your mod's folder (a 128 px png; a small .vox of the item lying in the world, in
--         full-size 0.1 m voxels: a scaled-down vox makes a static body that hangs in the air). mod: your mod's id
--         (found by itself when left out).
-- price:  what the store asks for the item (an integer; -1 = not for sale; left out = the store decides).
--
-- A MELEE WEAPON (the Inventory mod swings it, follows it as the hit box, deals the damage):
--
--     InventoryWeapon({id = "mymod_pan", name = "Frying Pan", prefab = "MOD/prefab/pan.xml", hands = 1,
--                     style = "chop", length = 0.55, power = 0.3, delay = 0.35, cooldown = 0.4, knockback = 5})
--     function server.init() InventoryServerInit() end
--
-- prefab: your tool prefab (copy the example pack's: the hand on the grip at the tool's origin, the weapon
-- along +y). length: m from the grip to the tip. hands: 1 or 2. style: slash, stab, chop (one hand), smash, sweep,
-- thrust (two). power: share of full health a hit takes (0-1). delay: s from the click to the blow. cooldown: s
-- after it. knockback: m/s. Optional: hole = {soft, medium, hard} MakeHole radii (m), push (impulse on loose
-- things), multi = true (hits everyone it passes through), sound = "s" / "m" / "l" (the whoosh), price, icon, type.
-- Advanced: swing = {wind = {x, y, z, pitch, roll, yaw}, hit = {...}, thru = {...}} - your own three poses instead of
-- a style (the guide), carry = {x, y, z, pitch, roll, yaw} - the carried pose, the same as your prefab's tp_action.
--
-- Nothing is needed in client.init or anywhere else: InventoryClientTick writes your items and weapons into the
-- registry on every machine (also on one that joins later) and spawns your clothes on whoever wears them.
--
-- The McPuppet Inventory System must be enabled: it strips the player's character to an underwear body and says, in
-- this machine's registry, who wears what and where a part sits on that player (inventory.worn / inventory.fit /
-- inventory.gen). This file spawns YOUR parts from YOUR files and puts them on the character's bones.
-- A player wears an item when a server script on the host writes its id into inventory.wear.<playerId> (the
-- inventory does, when the player puts it on).

INVENTORY_API = 1

local wbItems = {}                -- my items: id -> definition
local wbState = {}                -- player -> {gen, shapes = {shape, ...}, hidden}
local wbRegAt = -100
local wbStats = {built = 0, parts = 0, failed = 0, layerFallback = 0, morphs = 0, morphCells = 0, morphGaveUp = 0, boxPlus = -1, resizes = 0, drift = 0, unmarked = 0}
local wbJobs = {}                 -- parts waiting to be reshaped to their wearer: {shape, key, m, wait, tries}
local wbContent = {}              -- "item:part" -> {sx, sy, sz, vs, cells}: the part's voxels as spawned (read once)
local wbBoxPlus = nil             -- DrawShapeBox's far corner: 0 inclusive, 1 exclusive (found out on the first draw)
local WB_MORPHS_PER_TICK = 3
local WB_MARK = 240               -- palette index of the two corner marker voxels of a part's grid
local WB_GROW = 6                 -- a reshaped part's grid grows at most this many voxels per side

local function wbWords(s)
	local t = {}
	if type(s) == "table" then
		for _, w in ipairs(s) do t[#t + 1] = w end
	else
		for w in string.gmatch(s or "", "%S+") do t[#t + 1] = w end
	end
	return t
end

local wbWeapons = {}              -- my weapons: id -> definition

function InventoryWeapon(def)
	wbWeapons[def.id] = def
	wbRegAt = -100
end

-- call from your server.init: your weapons become tools (number key 1 for one hand, 2 for two)
function InventoryServerInit()
	for id, d in pairs(wbWeapons) do
		RegisterTool(id, d.name or id, d.prefab, d.hands == 2 and 2 or 1)
	end
end

function InventoryClothing(def)
	def.parts = wbWords(def.parts)
	def.covers = wbWords(def.covers)
	def.layer = def.layer or 1
	if def.tint and not def.voxlayer then def.voxlayer = "$TINT" end
	wbItems[def.id] = def
	wbRegAt = -100
end

-- the id of the mod this script runs in (there is no call for it): the enabled mod whose folder holds this
-- item's .vox file. Found once per script.
local wbMod = nil
function wbModId(d)
	if wbMod then return wbMod end
	local file = string.match(d.vox or "", "^MOD/(.+)$")
	if not file then return "" end
	for _, id in ipairs(ListKeys("mods.available") or {}) do
		local path = GetString("mods.available." .. id .. ".path")
		if path ~= "" and GetBool("mods.available." .. id .. ".active") then
			local ok, has = pcall(HasFile, "RAW:" .. path .. "/" .. file)
			if ok and has then
				wbMod = id
				return id
			end
		end
	end
	return ""
end

local function wbRegister()
	for id, d in pairs(wbWeapons) do
		local k = "inventory.weapons." .. id .. "."
		if not HasKey(k .. "ext") then
			local hands = d.hands == 2 and 2 or 1
			SetString(k .. "name", d.name or id)
			SetInt(k .. "hands", hands)
			SetString(k .. "style", d.style or (hands == 2 and "smash" or "slash"))
			SetFloat(k .. "length", d.length or 0.7)
			-- (a host may have written its own numbers for this weapon: those stay)
			for _, s in ipairs({"power", "delay", "cooldown", "knockback"}) do
				if d[s] and not HasKey(k .. s) then SetFloat(k .. s, d[s]) end
			end
			if d.hole then
				for i = 1, 3 do SetFloat(k .. "hole" .. i, d.hole[i] or 0) end
			end
			for _, s in ipairs({"push", "bite", "kick", "extra"}) do
				if d[s] then SetFloat(k .. s, d[s]) end
			end
			SetInt(k .. "multi", d.multi and 1 or 0)
			-- (its own swing and carried pose, when it brings them: plain numbers for every machine)
			local function six(t)
				local o = {}
				for i = 1, 6 do o[i] = string.format("%.4f", tonumber(t and t[i]) or 0) end
				return table.concat(o, " ")
			end
			if type(d.swing) == "table" and d.swing.wind and d.swing.hit and d.swing.thru then
				SetString(k .. "swing", six(d.swing.wind) .. " " .. six(d.swing.hit) .. " " .. six(d.swing.thru))
			end
			if type(d.carry) == "table" then SetString(k .. "carry", six(d.carry)) end
			SetString(k .. "sound", d.sound or "")
			SetString(k .. "category", "weapon")
			SetString(k .. "type", d.type or ("weapon.melee." .. (hands == 2 and "twohanded" or "onehanded") .. "." .. id))
			if d.price and not HasKey(k .. "price") then SetInt(k .. "price", d.price) end
			SetString(k .. "icon", d.icon or "")
			SetString(k .. "mod", d.mod or wbModId({vox = d.prefab}))
			SetInt(k .. "ext", 1)                                  -- (last: Wardrobe takes the weapon in when it sees this)
		end
	end
	for id, d in pairs(wbItems) do
		local k = "inventory.clothing." .. id
		if not HasKey(k .. ".slot") then
			SetString(k .. ".name", d.name or id)
			SetString(k .. ".slot", d.slot or "")
			SetInt(k .. ".layer", d.layer)
			SetString(k .. ".parts", table.concat(d.parts, " "))
			SetString(k .. ".covers", table.concat(d.covers, " "))
			SetFloat(k .. ".armor", d.armor or 0)
			-- what kind of thing this is, for inventories: every Wardrobe item is "equipment" (worn on the body);
			-- the weapons say "weapon" (inventory.weapons.<id>.category)
			SetString(k .. ".category", "equipment")
			if d.price then SetInt(k .. ".price", d.price) end        -- (what a store asks: -1 = not for sale; none = the store's own rule)
			SetFloat(k .. ".mobility", d.mobility or 0)
			SetFloat(k .. ".noise", d.noise or 0)
			SetFloat(k .. ".swim", d.swim or 0)
			-- the type tag other mods read: <clothing|armor>.<slot>.<kind>, e.g. armor.head.greathelm
			SetString(k .. ".type", d.type or (((d.armor or 0) >= 0.1 and "armor." or "clothing.") .. (d.slot or "misc") .. "." .. id))
			-- files for other mods (an inventory's icon, the model of the item lying in the world), relative to
			-- the folder of the mod that owns the item: "RAW:" .. GetString("mods.available.<mod>.path") .. "/" .. file
			SetString(k .. ".icon", d.icon or "")
			SetString(k .. ".drop", d.drop or "")
			SetString(k .. ".mod", d.mod or wbModId(d))
			SetBool(k .. ".hidden", d.hidden or false)
		end
	end
end

-- (writes this script's items and weapons into this machine's registry now; InventoryClientTick does it by itself)
function InventoryRegister()
	wbRegister()
end

-- is this part of an item of this layer under another worn item that covers it?
local function wbCovered(part, layer, id, list)
	for _, other in ipairs(list) do
		if other ~= id and GetInt("inventory.clothing." .. other .. ".layer") > layer then
			local c = " " .. GetString("inventory.clothing." .. other .. ".covers") .. " "
			if string.find(c, " " .. part .. " ", 1, true) then return true end
		end
	end
	return false
end

local function wbRemove(st)
	for _, sh in ipairs(st.shapes) do
		if IsHandleValid(sh) then Delete(sh) end
	end
	st.shapes, st.names = {}, {}
end

local function wbBox(sh, x0, x1, y, z, want)
	SetBrush("cube", 1, want)
	if wbBoxPlus == nil then
		DrawShapeBox(sh, x0, y, z, x0, y, z)
		local _, _, _, _, _, e = GetShapeMaterialAtIndex(sh, x0, y, z)
		wbBoxPlus = ((e or 0) == want) and 0 or 1
		wbStats.boxPlus = wbBoxPlus
	end
	DrawShapeBox(sh, x0, y, z, x1 + wbBoxPlus, y + wbBoxPlus, z + wbBoxPlus)
end

WardrobeSolid = "solid"           -- (TEST copies try others: "off" = collide='false', "filter" = own collision layer)
-- The parts are SOLID (no collide='false'): the character's own shapes on these bones are emptied, so without
-- solid clothes the bones had no weight and nothing to hit - a dead player's ragdoll stayed standing (the user saw
-- it) and the body could not be shot.
local function wbSpawnPart(def, part, fit, anim, skin)
	local f = wbWords(fit)
	if #f < 7 then return false end
	local bone = GetBoneBody(anim, f[1])
	if not bone or bone == 0 then return false end
	local xml = "<body><vox tags='unbreakable nocull invclothing=" .. def.id .. " invtype=" ..
		GetString("inventory.clothing." .. def.id .. ".type") .. "' pos='" .. f[2] .. " " .. f[3] .. " " .. f[4] .. "' rot='" .. f[5] .. " " ..
		f[6] .. " " .. f[7] .. "' file='" .. def.vox .. "' object='" .. part .. "' scale='0.5'" .. (WardrobeSolid == "off" and " collide='false'" or "") .. "/></body>"
	local at = GetBodyTransform(bone)
	local ents
	if def.voxlayer and def.voxlayer ~= "" then
		local ok, e = pcall(SpawnLayer, xml, def.voxlayer, at, true, false, skin)
		if ok then ents = e end
	end
	local shape, holder = 0, 0
	local function find()
		shape, holder = 0, 0
		for _, e in ipairs(ents or {}) do
			local t = GetEntityType(e)
			if t == "shape" then shape = e elseif t == "body" then holder = e end
		end
	end
	find()
	if shape == 0 then
		if def.voxlayer and def.voxlayer ~= "" then wbStats.layerFallback = wbStats.layerFallback + 1 end
		for _, e in ipairs(ents or {}) do if IsHandleValid(e) then Delete(e) end end
		ents = Spawn(xml, at, true)
		find()
	end
	if shape == 0 then
		if holder ~= 0 then Delete(holder) end
		return false
	end
	SetShapeBody(shape, bone, GetShapeLocalTransform(shape))
	if WardrobeSolid == "filter" then SetShapeCollisionFilter(shape, 2, 253) end
	if holder ~= 0 and IsHandleValid(holder) then Delete(holder) end
	-- the two corner markers of a template grid (palette WB_MARK) have done their work: the engine kept the whole
	-- grid, so the part sits where its grid says. Out they go.
	-- (which two corners: that depends on how the model is turned - all eight are looked at)
	local sx, sy, sz = GetShapeSize(shape)
	local found = 0
	for cx = 0, 1 do
		for cy = 0, 1 do
			for cz = 0, 1 do
				local x, y, z = cx * (sx - 1), cy * (sy - 1), cz * (sz - 1)
				local _, _, _, _, _, e = GetShapeMaterialAtIndex(shape, x, y, z)
				if e == WB_MARK then
					wbBox(shape, x, x, y, z, 0)
					found = found + 1
				end
			end
		end
	end
	if found < 2 then wbStats.unmarked = wbStats.unmarked + 1 end
	return shape
end

-- Reshape a clothing part to its wearer. Clothes are painted round the template body; Wardrobe gives, per body
-- part of this player, the template body's box and the player's own body's box on the bone (inventory.morph.<p>.
-- <part> = "t0 t1 c0 c1", metres in the bone body's frame). Every cell of the part takes the voxel the template
-- has at the matching place: inside the body's box the template's box is stretched onto it, outside it the
-- distance to the box is kept (a jacket stays one voxel thick on a fat character, a shoulder plate keeps its
-- size). The part's voxels are read once per item part (cached), then only the cells that change are drawn, in runs.
-- Returns true when the job is done (or given up).
local function wbMorph(job)
	local sh = job.shape
	if not IsHandleValid(sh) then return true end
	local c = wbContent[job.key]
	if not c then
		local sx, sy, sz, vs = GetShapeSize(sh)
		local cells, n = {}, 0
		local b = {sx, sy, sz, -1, -1, -1}                         -- the box of the solid cells
		for z = 0, sz - 1 do
			for y = 0, sy - 1 do
				for x = 0, sx - 1 do
					local _, _, _, _, _, e = GetShapeMaterialAtIndex(sh, x, y, z)
					if e and e ~= 0 then
						cells[x + sx * (y + sy * z)] = e
						n = n + 1
						if x < b[1] then b[1] = x end
						if y < b[2] then b[2] = y end
						if z < b[3] then b[3] = z end
						if x > b[4] then b[4] = x end
						if y > b[5] then b[5] = y end
						if z > b[6] then b[6] = z end
					end
				end
			end
		end
		if n == 0 then                                             -- (a shape can read empty in its first frames)
			job.tries = job.tries + 1
			if job.tries > 5 then
				wbStats.morphGaveUp = wbStats.morphGaveUp + 1
				return true
			end
			return false
		end
		c = {sx = sx, sy = sy, sz = sz, vs = vs or 0.05, cells = cells, box = b}
		wbContent[job.key] = c
	end
	local v = {}
	for w in string.gmatch(job.m, "%S+") do v[#v + 1] = tonumber(w) end
	if #v < 12 then return true end
	local k = {}
	for a = 1, 3 do
		local d = v[9 + a] - v[6 + a]
		k[a] = d > 0.001 and (v[3 + a] - v[a]) / d or 1
		if k[a] < 0.05 then k[a] = 1 end
	end
	-- the part's own frame on the bone body: origin and axes of its voxel grid (as spawned: the cached cells' frame)
	local L = GetShapeLocalTransform(sh)
	local o = L.pos
	local ex = TransformToParentVec(L, Vec(1, 0, 0))
	local ey = TransformToParentVec(L, Vec(0, 1, 0))
	local ez = TransformToParentVec(L, Vec(0, 0, 1))
	local sx, sy, sz, vs, cells, box = c.sx, c.sy, c.sz, c.vs, c.cells, c.box
	local floor = math.floor
	-- where the solid cells' box ends up on this character (its corners carried template -> character), in cells:
	-- only that box and the old one are gone through, and the grid is resized when the new box sticks out of it
	local lo = {box[1], box[2], box[3]}
	local hi = {box[4] + 1, box[5] + 1, box[6] + 1}
	for cx = 0, 1 do
		for cy = 0, 1 do
			for cz = 0, 1 do
				local px = (cx == 0 and box[1] or box[4] + 1) * vs
				local py = (cy == 0 and box[2] or box[5] + 1) * vs
				local pz = (cz == 0 and box[3] or box[6] + 1) * vs
				local q = {}
				for a = 1, 3 do
					local s = o[a] + ex[a] * px + ey[a] * py + ez[a] * pz
					local t
					if s < v[a] then t = v[6 + a] - (v[a] - s)
					elseif s > v[3 + a] then t = v[9 + a] + (s - v[3 + a])
					else t = v[6 + a] + (s - v[a]) / k[a] end
					q[a] = t - o[a]
				end
				local g = {(q[1] * ex[1] + q[2] * ex[2] + q[3] * ex[3]) / vs, (q[1] * ey[1] + q[2] * ey[2] + q[3] * ey[3]) / vs,
					(q[1] * ez[1] + q[2] * ez[2] + q[3] * ez[3]) / vs}
				for a = 1, 3 do
					lo[a] = math.min(lo[a], floor(g[a] + 0.01))
					hi[a] = math.max(hi[a], math.ceil(g[a] - 0.01))
				end
			end
		end
	end
	local dim = {sx, sy, sz}
	for a = 1, 3 do                                              -- (never far beyond the grid: a wrong box stays small)
		lo[a] = math.max(lo[a], -WB_GROW)
		hi[a] = math.min(hi[a], dim[a] + WB_GROW)
	end
	local m1, m2, m3 = 0, 0, 0                                   -- new cell + m = the cell as spawned
	if lo[1] < 0 or lo[2] < 0 or lo[3] < 0 or hi[1] > sx or hi[2] > sy or hi[3] > sz then
		-- (ResizeShape's upper corner is inclusive - seen in game)
		ResizeShape(sh, math.min(lo[1], 0), math.min(lo[2], 0), math.min(lo[3], 0), math.max(hi[1], sx) - 1, math.max(hi[2], sy) - 1,
			math.max(hi[3], sz) - 1)
		local o1 = GetShapeLocalTransform(sh).pos
		local d1, d2, d3 = o1[1] - o[1], o1[2] - o[2], o1[3] - o[3]
		m1 = floor((d1 * ex[1] + d2 * ex[2] + d3 * ex[3]) / vs + 0.5)
		m2 = floor((d1 * ey[1] + d2 * ey[2] + d3 * ey[3]) / vs + 0.5)
		m3 = floor((d1 * ez[1] + d2 * ez[2] + d3 * ez[3]) / vs + 0.5)
		wbStats.resizes = wbStats.resizes + 1
	end
	local t01, t02, t03, t11, t12, t13 = v[1], v[2], v[3], v[4], v[5], v[6]
	local c01, c02, c03, c11, c12, c13 = v[7], v[8], v[9], v[10], v[11], v[12]
	local k1, k2, k3 = k[1], k[2], k[3]
	-- the body's outline slice by slice along the bone (v[13] = that axis, v[14] = the number of slices, then the
	-- low and high edge on the two other axes per slice): across the bone a cell is mapped onto its slice's own
	-- outline, not onto one box for the whole part (that made thin characters as broad as their bounding box)
	local sa, ns = v[13] or 0, v[14] or 0
	if #v < 14 + ns * 4 then ns = 0 end
	local sc0 = ns > 0 and v[6 + sa] or 0
	local tm1, tm2, tm3 = (t01 + t11) / 2, (t02 + t12) / 2, (t03 + t13) / 2
	local changed = 0
	for oz = lo[3], hi[3] - 1 do                                 -- (cells counted in the grid as spawned)
		local pz = (oz + 0.5) * vs
		for oy = lo[2], hi[2] - 1 do
			local py = (oy + 0.5) * vs
			local b1 = o[1] + ey[1] * py + ez[1] * pz
			local b2 = o[2] + ey[2] * py + ez[2] * pz
			local b3 = o[3] + ey[3] * py + ez[3] * pz
			local inRow = oy >= 0 and oy < sy and oz >= 0 and oz < sz
			local runStart, runWant = 0, nil
			for ox = lo[1], hi[1] do                               -- (one past the end: the last run goes out)
				local ch = nil
				if ox < hi[1] then
					local px = (ox + 0.5) * vs
					-- this cell in the bone's frame -> the matching place on the template -> its cell as spawned
					local p1, p2, p3 = b1 + ex[1] * px, b2 + ex[2] * px, b3 + ex[3] * px
					local q1, q2, q3
					if ns > 0 then
						local pa = (sa == 1 and p1) or (sa == 2 and p2) or p3
						local si = floor((pa - sc0) / vs)
						if si < 0 then si = 0 elseif si >= ns then si = ns - 1 end
						local so = 14 + si * 4
						if sa == 1 then c02, c12, c03, c13 = v[so + 1], v[so + 2], v[so + 3], v[so + 4]
						elseif sa == 2 then c01, c11, c03, c13 = v[so + 1], v[so + 2], v[so + 3], v[so + 4]
						else c01, c11, c02, c12 = v[so + 1], v[so + 2], v[so + 3], v[so + 4] end
						k1 = c11 - c01 > 0.001 and (t11 - t01) / (c11 - c01) or 1
						k2 = c12 - c02 > 0.001 and (t12 - t02) / (c12 - c02) or 1
						k3 = c13 - c03 > 0.001 and (t13 - t03) / (c13 - c03) or 1
						if k1 < 0.05 then k1 = 1 end
						if k2 < 0.05 then k2 = 1 end
						if k3 < 0.05 then k3 = 1 end
					end
					if p1 < c01 then q1 = t01 - (c01 - p1) elseif p1 > c11 then q1 = t11 + (p1 - c11) else q1 = t01 + (p1 - c01) * k1 end
					if p2 < c02 then q2 = t02 - (c02 - p2) elseif p2 > c12 then q2 = t12 + (p2 - c12) else q2 = t02 + (p2 - c02) * k2 end
					if p3 < c03 then q3 = t03 - (c03 - p3) elseif p3 > c13 then q3 = t13 + (p3 - c13) else q3 = t03 + (p3 - c03) * k3 end
					-- (a point that lands on a cell border goes to the cell nearer the box's middle, on both sides
					--  alike: without this a symmetric garment came out lopsided on some characters - the user saw it)
					if q1 < tm1 then q1 = q1 + 0.0005 else q1 = q1 - 0.0005 end
					if q2 < tm2 then q2 = q2 + 0.0005 else q2 = q2 - 0.0005 end
					if q3 < tm3 then q3 = q3 + 0.0005 else q3 = q3 - 0.0005 end
					q1, q2, q3 = q1 - o[1], q2 - o[2], q3 - o[3]
					local ix = floor((q1 * ex[1] + q2 * ex[2] + q3 * ex[3]) / vs)
					local iy = floor((q1 * ey[1] + q2 * ey[2] + q3 * ey[3]) / vs)
					local iz = floor((q1 * ez[1] + q2 * ez[2] + q3 * ez[3]) / vs)
					local want = 0
					if ix >= 0 and ix < sx and iy >= 0 and iy < sy and iz >= 0 and iz < sz then
						want = cells[ix + sx * (iy + sy * iz)] or 0
					end
					local have = 0
					if inRow and ox >= 0 and ox < sx then have = cells[ox + sx * (oy + sy * oz)] or 0 end
					if want ~= have then ch = want end
				end
				if ch ~= runWant then
					if runWant ~= nil then
						wbBox(sh, runStart - m1, ox - 1 - m1, oy - m2, oz - m3, runWant)
						changed = changed + ox - runStart
					end
					runStart, runWant = ox, ch
				end
			end
		end
	end
	wbStats.morphs = wbStats.morphs + 1
	wbStats.morphCells = wbStats.morphCells + changed
	return true
end

local function wbBuild(p, st, list)
	wbRemove(st)
	local anim = GetPlayerAnimator(p)
	if not anim or anim == 0 then return end
	local s = wbWords(GetString("inventory.skin." .. p))
	local skin = Vec(tonumber(s[1]) or 1, tonumber(s[2]) or 1, tonumber(s[3]) or 1)
	for _, id in ipairs(list) do
		local def = wbItems[id]
		if def then
			for _, part in ipairs(def.parts) do
				if not wbCovered(part, def.layer, id, list) then
					-- (where the part sits: this item's own place on this player when Wardrobe gives one - the
					--  characters' own bodies - else the template part's)
					local fit = GetString("inventory.fit." .. p .. "." .. id .. "." .. part)
					if fit == "" then fit = GetString("inventory.fit." .. p .. "." .. part) end
					local sh = wbSpawnPart(def, part, fit, anim, skin)
					if sh then
						st.shapes[#st.shapes + 1] = sh
						st.names[#st.shapes] = id .. ":" .. part
						local m = def.layer >= 1 and not def.rigid and GetString("inventory.morph." .. p .. "." .. part) or ""
						if m ~= "" then
							wbJobs[#wbJobs + 1] = {shape = sh, key = id .. ":" .. part, m = m, wait = 2, tries = 0}
						end
						wbStats.parts = wbStats.parts + 1
					else
						wbStats.failed = wbStats.failed + 1
					end
				end
			end
		end
	end
	st.hidden = false
	wbStats.built = wbStats.built + 1
end

-- call every client tick
function InventoryClientTick()
	local now = GetTime()
	if now - wbRegAt > 1 then
		wbRegAt = now
		wbRegister()
	end
	-- a few waiting parts are reshaped per tick (an outfit is spread over some frames)
	local done, i = 0, 1
	while i <= #wbJobs and done < WB_MORPHS_PER_TICK do
		local job = wbJobs[i]
		if job.wait > 0 then
			job.wait = job.wait - 1
			i = i + 1
		else
			done = done + 1
			if wbMorph(job) then table.remove(wbJobs, i) else i = i + 1 end
		end
	end
	local seen = {}
	for _, p in ipairs(GetAllPlayers()) do
		seen[p] = true
		local st = wbState[p]
		if not st then
			st = {gen = -1, shapes = {}, names = {}, hidden = false}
			wbState[p] = st
		end
		local gen = GetInt("inventory.gen." .. p)
		if gen ~= st.gen then
			st.gen = gen
			wbBuild(p, st, wbWords(GetString("inventory.worn." .. p)))
		end
		if #st.shapes > 0 then
			-- your own body in first person: not drawn (as the game does with the character)
			local hide = IsPlayerLocal(p) and not GetBool("game.thirdperson") and GetPlayerHealth(p) > 0
			if hide ~= st.hidden then
				st.hidden = hide
				for _, sh in ipairs(st.shapes) do
					if IsHandleValid(sh) then
						if hide then SetTag(sh, "invisible") else RemoveTag(sh, "invisible") end
					end
				end
			end
		end
	end
	for p, st in pairs(wbState) do
		if not seen[p] then
			wbRemove(st)
			wbState[p] = nil
		end
	end
end

-- (diagnostics) how many of this script's parts the player wears now, and the totals
function WardrobeDebug(p)
	local n, vox = 0, 0
	local st = wbState[p]
	if st then
		for _, sh in ipairs(st.shapes) do
			if IsHandleValid(sh) then
				n = n + 1
				vox = vox + GetShapeVoxelCount(sh)
			end
		end
	end
	return n, wbStats, vox
end

-- (diagnostics) the shape of one of this script's parts on the player ("item:part"), or nil
function WardrobeShape(p, name)
	local st = wbState[p]
	if st then
		for i, sh in ipairs(st.shapes) do
			if st.names[i] == name and IsHandleValid(sh) then return sh end
		end
	end
end
