-- Seaweed and corals on the sea floor, placed by each player for themselves (client side: nothing is synced). The
-- floor around the camera is filled one FLORA_CELL square at a time and emptied again behind it, out to a little
-- past what the water lets you see. Where a plant grows comes from a hash of its position, so a place always gets
-- the same plants (and every player sees the same ones, without sending anything): meadows of seagrass, kelp
-- where it's deep enough, corals in patches (more of them on rock and concrete than on sand). Kelp and seagrass
-- sway in a slow current near the camera. A plant whose floor has been blown away is removed.
-- Each plant is a small static body (5 cm voxels, MOD/vox/flora_*.vox by tools/make_flora.py), not physical
-- (collide='false') and on FISH_LAYER, so nothing collides with it and the caustics' rays pass it.
--
-- How many: dive.seaweed (kelp and seagrass) and dive.corals (API.md: times the normal amount; 0 = none); a change
-- regrows the floor around the camera. Set here: dive.flora.count (plants alive).

Flora = {}

FLORA_CELL = 6       -- metres
FLORA_TRIES = 18     -- candidate spots per cell
FLORA_CELLS = 2      -- cells filled per frame at most (2 rays per candidate)
FLORA_MAX = 900
SWAY_RANGE = 14      -- seaweed nearer the camera than this sways

-- {file, height in m at scale 0.5, sways}
FLORA = {
	kelp = {{"kelp_a", 2.8, true}, {"kelp_b", 2.15, true}},
	grass = {{"grass_a", 0.75, true}, {"grass_b", 0.5, true}},
	coral = {{"branch_orange", 1.1}, {"branch_pink", 1.1}, {"brain", 0.4}, {"fan", 1.3}, {"tubes_red", 0.75},
		{"tubes_yellow", 0.8}},
}
HARD = {rock = true, masonry = true, concrete = true, plaster = true, brick = true, metal = true, heavymetal = true,
	hardmasonry = true, hardmetal = true}

function Flora.clientInit()
	floraCells = {}
	floraQueue = {}
	floraScanAt = 0
	floraCount = 0
	floraCheck = 0
	floraRound = {}
	floraWanted = ""
end

-- A repeatable random number in [0, 1) for a place (no bit operations in Lua 5.1: the sine hash).
function spotHash(a, b, c)
	local s = math.sin(a * 127.1 + b * 311.7 + c * 74.7) * 43758.5453
	return s - math.floor(s)
end

-- Smooth value noise in [0, 1] over the floor, features about `size` metres across.
function floorNoise(x, z, size, salt)
	local gx, gz = x / size, z / size
	local ix, iz = math.floor(gx), math.floor(gz)
	local fx, fz = gx - ix, gz - iz
	fx, fz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
	local a = spotHash(ix, iz, salt) + (spotHash(ix + 1, iz, salt) - spotHash(ix, iz, salt)) * fx
	local b = spotHash(ix, iz + 1, salt) + (spotHash(ix + 1, iz + 1, salt) - spotHash(ix, iz + 1, salt)) * fx
	return a + (b - a) * fz
end

function floorRay(from, dist)
	QueryCollisionMask(255 - FISH_LAYER)
	QueryRequire("physical")
	return QueryRaycast(from, Vec(0, -1, 0), dist)
end

-- The plant for candidate k of a cell, or nil: where the sea floor is (static, under water, not steep), how deep,
-- and what grows there.
function floraAt(ix, iz, k, weed, coral)
	local x = (ix + spotHash(ix, iz, k * 2 + 1)) * FLORA_CELL
	local z = (iz + spotHash(ix, iz, k * 2 + 2)) * FLORA_CELL
	local meadow = floorNoise(x, z, 16, 5)
	local keep = 0.1 + 0.75 * math.max(0, math.min(1, (meadow - 0.45) / 0.3))
	local most = math.max(weed, coral)
	if spotHash(ix, iz, k + 40) >= keep * most then return nil end
	local wet, _, surf = QueryRaycastWater(Vec(x, 300, z), Vec(0, -1, 0), 600)
	if not wet then return nil end
	local hit, dist, normal, shape = floorRay(Vec(x, surf[2] + 3, z), 200)
	if not hit or dist < 3.05 or normal[2] < 0.7 then return nil end   -- (land or a pier at the surface; no floor)
	if IsBodyDynamic(GetShapeBody(shape)) then return nil end
	local depth = dist - 3
	local pos = Vec(x, surf[2] - depth, z)
	local hard = HARD[GetShapeMaterialAtPosition(shape, VecAdd(pos, Vec(0, -0.05, 0)))]
	-- what grows: weights from a second noise (reefs where it's high, kelp where it's low, seagrass everywhere), so
	-- the kinds come in patches but mix at their edges
	local zone = floorNoise(x, z, 12, 9)
	local wCoral = math.max(0, math.min(1, (zone - 0.45) / 0.25)) * (hard and 1 or 0.6)
	local wKelp = math.max(0, math.min(1, (0.55 - zone) / 0.25))
	-- (the amounts asked for: scale each kind's weight, and how many grow by the weights' total against the normal one)
	local normal = wCoral + wKelp + 0.5
	wCoral, wKelp = wCoral * coral, wKelp * weed
	local total = wCoral + wKelp + 0.5 * weed
	if spotHash(ix, iz, k + 60) >= total / (normal * most) then return nil end
	local pick = spotHash(ix, iz, k + 80) * total
	local kind = pick < wCoral and "coral" or (pick < wCoral + wKelp and "kelp" or "grass")
	local list = FLORA[kind]
	local m = list[1 + math.floor(spotHash(ix, iz, k + 100) * #list)]
	local scale = 0.4 + 0.2 * spotHash(ix, iz, k + 120)
	if m[2] * scale * 2 > depth - 0.3 then                          -- too tall for the water here
		if weed <= 0 then return nil end
		m = FLORA.grass[2]
		if m[2] * scale * 2 > depth - 0.2 then return nil end
	end
	pos[2] = pos[2] - 0.08                                          -- (into the floor a little: slopes)
	return {pos = pos, rot = QuatEuler(0, spotHash(ix, iz, k + 160) * 360, 0), file = m[1], scale = scale, sway = m[3],
		ph = spotHash(ix, iz, k + 200) * 6.283, height = m[2] * scale * 2}
end

-- (the game centres a model on its shape's position: raised by half its height, the body's origin is its base, and
-- the sway turns it about the base)
function spawnPlant(p)
	local made = Spawn(string.format("<body tags='flora'><vox file='MOD/vox/flora_%s.vox' pos='0 %.3f 0' scale='%.2f'"
		.. " collide='false'/></body>", p.file, p.height / 2, p.scale), Transform(p.pos, p.rot), true)
	for _, e in ipairs(made) do
		if GetEntityType(e) == "body" then
			for _, sh in ipairs(GetBodyShapes(e)) do SetShapeCollisionFilter(sh, FISH_LAYER, 0) end
			p.body = e
		end
	end
	return p.body ~= nil
end

function fillCell(c, weed, coral)
	c.plants = {}
	for k = 1, FLORA_TRIES do
		if floraCount >= FLORA_MAX then break end
		local p = floraAt(c.ix, c.iz, k, weed, coral)
		if p and spawnPlant(p) then
			c.plants[#c.plants + 1] = p
			floraCount = floraCount + 1
		end
	end
end

function emptyCell(c)
	for _, p in ipairs(c.plants or {}) do
		Delete(p.body)
		floraCount = floraCount - 1
	end
	c.plants = nil
end

-- A few plants a frame: is their floor still there?
function checkFloors(cam)
	for _ = 1, 4 do
		if floraCheck >= #floraRound then          -- a new round over the plants alive now
			floraRound, floraCheck = {}, 0
			for _, c in pairs(floraCells) do
				for _, p in ipairs(c.plants or {}) do floraRound[#floraRound + 1] = {c, p} end
			end
			if #floraRound == 0 then return end
		end
		floraCheck = floraCheck + 1
		local c, p = floraRound[floraCheck][1], floraRound[floraCheck][2]
		if c.plants and VecLength(VecSub(p.pos, cam)) < 30 and not floorRay(VecAdd(p.pos, Vec(0, 0.35, 0)), 0.6) then
			for i, q in ipairs(c.plants) do
				if q == p then
					table.remove(c.plants, i)
					Delete(p.body)
					floraCount = floraCount - 1
					break
				end
			end
		end
	end
end

function Flora.clientTick(dt)
	local now = GetTime()
	local cam = GetCameraTransform().pos
	local weed, coral = math.max(0, setting("dive.seaweed", 1)), math.max(0, setting("dive.corals", 1))
	local wanted = weed .. "/" .. coral
	if wanted ~= floraWanted then                    -- new amounts: grow the floor again
		floraWanted = wanted
		for key, c in pairs(floraCells) do emptyCell(c); floraCells[key] = nil end
		floraScanAt = 0
		SetInt("dive.flora.count", floraCount)
	end
	if weed + coral <= 0 then return end
	local vis = setting("dive.visibility", VISIBILITY)
	local reach = math.max(12, math.min(40, vis + 8))
	if now >= floraScanAt then                       -- the cells to fill, nearest first; forget those far behind
		floraScanAt = now + 0.25
		local cx, cz = cam[1] / FLORA_CELL, cam[3] / FLORA_CELL
		local n = math.ceil(reach / FLORA_CELL) + 1
		floraQueue = {}
		for ix = math.floor(cx) - n, math.floor(cx) + n do
			for iz = math.floor(cz) - n, math.floor(cz) + n do
				local d = math.sqrt((ix + 0.5 - cx) ^ 2 + (iz + 0.5 - cz) ^ 2) * FLORA_CELL
				if d < reach and not floraCells[ix .. "," .. iz] then floraQueue[#floraQueue + 1] = {ix, iz, d} end
			end
		end
		table.sort(floraQueue, function(a, b) return a[3] < b[3] end)
		for key, c in pairs(floraCells) do
			if math.sqrt((c.ix + 0.5 - cx) ^ 2 + (c.iz + 0.5 - cz) ^ 2) * FLORA_CELL > reach + 10 then
				emptyCell(c)
				floraCells[key] = nil
			end
		end
		SetInt("dive.flora.count", floraCount)
	end
	for _ = 1, FLORA_CELLS do
		local q = table.remove(floraQueue, 1)
		if not q then break end
		local c = {ix = q[1], iz = q[2]}
		floraCells[q[1] .. "," .. q[2]] = c
		fillCell(c, weed, coral)
	end
	checkFloors(cam)
	-- the sway: a slow current that turns now and then; each plant leans with it and back, out of step
	local ca = now * 0.05
	local axis = Vec(math.cos(ca), 0, math.sin(ca))
	for _, c in pairs(floraCells) do
		for _, p in ipairs(c.plants or {}) do
			if p.sway and math.abs(p.pos[1] - cam[1]) < SWAY_RANGE and math.abs(p.pos[3] - cam[3]) < SWAY_RANGE then
				local a = 3 + 5 * math.sin(now * 0.9 + p.ph) + 2 * math.sin(now * 2.3 + p.ph * 3)
				SetBodyTransform(p.body, Transform(p.pos, QuatRotateQuat(QuatAxisAngle(axis, a), p.rot)))
				p.moved = true
			elseif p.moved then
				SetBodyTransform(p.body, Transform(p.pos, p.rot))
				p.moved = false
			end
		end
	end
end
