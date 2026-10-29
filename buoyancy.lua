-- Buoyancy per object under water. The engine floats every loose body up, even steel. Here each submerged body
-- gets its own vertical speed instead: a body tagged buoyancy=<m/s> uses that (up > 0, 0 = hangs where it is,
-- down < 0); an untagged one gets a speed from its density (light things rise, heavy things sink), varied a little
-- per body so a pile doesn't move as one.
-- How: set the vertical velocity every update, less the drift the water adds. Like the player (dive.lua), a body
-- in the water moves differently from the velocity it reports (seen in-game: a crate reporting -0.08 m/s sank at
-- -0.25), so the drift is learned from how far its centre of mass really moved. Only fully submerged bodies (the
-- surface itself is left to the engine's floating), and a sinker that has settled on the floor is left to sleep.
-- Debris (small broken-off pieces) drifts for DEBRIS_DRIFT seconds and then hangs where it is: put to sleep, it costs
-- nothing (no physics, no buoyancy) until something knocks it. Debris that has been in the water and that no player
-- has come within KEEP_NEAR of for CLEANUP seconds is deleted.
-- Parking: a body moving at its own speed with no player near enough to see it (the water's visibility + PARK_MARGIN)
-- is put to sleep, and is a formula from then on: where it started, when, its speed, and where its path ends (one ray
-- along it: the surface, the underside of something, the floor). Every SCAN its position now is worked out; when a
-- player comes near that position or the spot where it sleeps, it is moved there and woken before they can see it.
-- One that gets to the surface is put there and woken whoever is near (above water you see far): the engine's
-- floating settles it. One that gets to the floor or a ceiling is put there, asleep.
-- A body that has stopped (on the floor, under a ceiling, a knocked one that hangs still again) is put to sleep.
--
-- Off: dive.buoyancy.disabled (API.md; the old name buoyancy.disabled too). Logged for tests: buoyancy.log (bool) logs each body's density once.

Buoyancy = {}

SCAN = 0.5          -- seconds between looking for bodies around the players
RANGE = 40          -- metres around each player
MAX_BODIES = 200
DEBRIS_VOXELS = 300 -- a broken body this small is debris
DEBRIS_DRIFT = 3    -- seconds debris moves before it hangs still
KEEP_NEAR = 20      -- metres
CLEANUP = 60        -- seconds
LEARN = 0.1         -- share of the newly measured drift taken each update
MAX_DRIFT = 1.5     -- m/s
DRAG = 0.6          -- horizontal water drag (1/s)
PARK_MARGIN = 10    -- metres past the visibility
PARK_AFTER = 1      -- seconds a body moves at its own speed before it may be parked

function Buoyancy.serverInit()
	bodies = {}         -- handle -> state
	list = {}
	scanAt = 0
	debris = {}         -- handle -> last time a player was near (debris that has been in the water)
	debrisCount = 0
	sweepAt = 0
	parked = {}         -- handle -> {s = state, t0, y0, x, z, v, stopY, kind}
	rested = {}         -- handles that came to rest while parked (on the floor, under a ceiling): don't wake them
	parkedTotal, parkWoken = 0, 0  -- (counted for the tests)
end

function hash(n)
	local x = math.sin(n * 12.9898) * 43758.5453
	return x - math.floor(x)
end

-- Wanted vertical speed for a body, m/s, from its density (mass / volume; measured in-game, kg/m^3: plastic 350,
-- wood 400, masonry 1000, metal 1500), and whether it is debris.
function targetSpeed(body)
	if HasTag(body, "buoyancy") then return tonumber(GetTagValue(body, "buoyancy")) or 0 end
	local voxels = 0
	for _, s in ipairs(GetBodyShapes(body)) do voxels = voxels + GetShapeVoxelCount(s) end
	if voxels == 0 then return nil end
	local isDebris = IsBodyBroken(body) and voxels < DEBRIS_VOXELS
	local density = GetBodyMass(body) / (voxels * 0.001)
	local r = hash(body)
	local v
	if density < 380 then v = 0.25 + 0.4 * r           -- plastic: rises
	elseif density < 700 then v = (r - 0.3) * 0.35     -- wood: drifts slowly up, some hang still, a few sink
	elseif density < 1200 then v = -0.2 - 0.4 * r      -- masonry: sinks slowly
	else v = -0.6 - 0.6 * r end                        -- metal: sinks
	if math.abs(v) < 0.06 then v = 0 end
	if GetBool("buoyancy.log") then
		local e = Spawn(string.format("<body tags='divelog density body=%d mass=%.1f voxels=%d rho=%.0f target=%.2f'/>",
			body, GetBodyMass(body), voxels, density, v), Transform(Vec(0, -500, 0)))
		for i = 1, #e do Delete(e[i]) end
	end
	return v, isDebris
end

function scan()
	local seen = {}
	list = {}
	for _, p in ipairs(GetAllPlayers()) do
		local at = GetPlayerTransform(p).pos
		QueryRequire("physical dynamic")
		for _, b in ipairs(QueryAabbBodies(VecAdd(at, Vec(-RANGE, -RANGE, -RANGE)), VecAdd(at, Vec(RANGE, RANGE, RANGE)))) do
			if not seen[b] and #list < MAX_BODIES and IsBodyDynamic(b) and GetBodyPlayer(b) == 0 and GetBodyVehicle(b) == 0 then
				seen[b] = true
				list[#list + 1] = b
			end
		end
	end
	for b, s in pairs(bodies) do
		if not seen[b] then
			bodies[b] = nil
			-- out of range while moving at its own speed (its player went away, teleported): park it, or the engine's
			-- floating would take it over
			-- (a sinker that can't be parked, on the floor already or over a bottomless sea, is left asleep instead)
			if s.lastY and s.target and s.target ~= 0 and not s.debris and IsHandleValid(b) and IsBodyActive(b) then
				if not park(b, s, TransformToParentPoint(GetBodyTransform(b), GetBodyCenterOfMass(b)), GetTime())
					and s.target < 0 then
					SetBodyActive(b, false)
				end
			end
		end
	end
end

-- Where a body's path ends, as the height of its centre of mass: the underside of whatever is above it, else just
-- under the surface (a riser), or the top of what is below it (a sinker), or nil (nothing below: the bottomless sea
-- of some maps). The rays start at the centre (the body itself skipped): from the edge of its box, a body resting
-- on a one-voxel floor started below it and "fell" through (seen in-game).
function pathEnd(b, c, v)
	local lo, hi = GetBodyBounds(b)
	if v > 0 then
		local _, _, surf = QueryRaycastWater(Vec(c[1], c[2] + 300, c[3]), Vec(0, -1, 0), 600)
		local top = surf[2] - (hi[2] - c[2]) - 0.05
		QueryRequire("physical")
		QueryRejectBody(b)
		local hit, dist = QueryRaycast(c, Vec(0, 1, 0), math.max(0.1, surf[2] - c[2]))
		local under = hit and c[2] + dist - (hi[2] - c[2]) - 0.02
		if under and under < top then return math.max(c[2], under), "ceiling" end
		return top, "surface"
	end
	QueryRequire("physical")
	QueryRejectBody(b)
	local hit, dist = QueryRaycast(c, Vec(0, -1, 0), 200)
	if hit then return math.min(c[2], c[2] - dist + (c[2] - lo[2]) + 0.02), "floor" end
	return nil
end

-- Park a body (true), unless it is already where its path ends (a floater at the surface, a sinker on the floor) or
-- its path has no end.
function park(b, s, c, now)
	local stopY, kind = pathEnd(b, c, s.target)
	if not stopY or math.abs(stopY - c[2]) < 0.3 then return false end
	parked[b] = {s = s, t0 = now, y0 = c[2], x = c[1], z = c[3], v = s.target, stopY = stopY, kind = kind}
	parkedTotal = parkedTotal + 1
	SetBodyVelocity(b, Vec(0, 0, 0))
	SetBodyAngularVelocity(b, Vec(0, 0, 0))
	bodies[b] = nil
	SetBodyActive(b, false)
	return true
end

function nobodyNear(heads, x, y, z, far)
	for _, h in ipairs(heads) do
		if (h[1] - x) ^ 2 + (h[2] - y) ^ 2 + (h[3] - z) ^ 2 < far * far then return false end
	end
	return true
end

-- Something right above (up) or below a body: what blocks a riser or a sinker (asked only of bodies that barely move).
function touching(b, up)
	local lo, hi = GetBodyBounds(b)
	local y0, y1 = hi[2], hi[2] + 0.08
	if not up then y0, y1 = lo[2] - 0.08, lo[2] end
	QueryRequire("physical")
	QueryRejectBody(b)
	return #QueryAabbShapes(Vec(lo[1] + 0.05, y0, lo[3] + 0.05), Vec(hi[1] - 0.05, y1, hi[3] - 0.05)) > 0
end

-- Where a parked body can go without landing inside another loose body (several end their paths at one spot: a
-- column of risers at the surface): its box at the new place, else beside it (8 directions), as an offset.
function freeSpot(b, lo, hi)
	local inset = Vec(0.05, 0.05, 0.05)
	local step = math.max(hi[1] - lo[1], hi[3] - lo[3]) + 0.1
	for i = 0, 8 do
		local off = i == 0 and Vec(0, 0, 0) or Vec(math.cos(i * 0.785) * step, 0, math.sin(i * 0.785) * step)
		QueryRequire("physical dynamic")
		QueryRejectBody(b)
		if #QueryAabbBodies(VecAdd(VecAdd(lo, off), inset), VecSub(VecAdd(hi, off), inset)) == 0 then return off end
	end
	return Vec(0, 0, 0)
end

-- Bodies asleep against one that is moved away (a sinker on top of it, a riser stuck under it) would hang in the
-- water: wake them.
function wakeNeighbours(b, lo, hi)
	QueryRequire("physical dynamic")
	QueryRejectBody(b)
	for _, o in ipairs(QueryAabbBodies(VecSub(lo, Vec(0.1, 0.15, 0.1)), VecAdd(hi, Vec(0.1, 0.15, 0.1)))) do
		if not IsBodyActive(o) and not parked[o] then SetBodyActive(o, true) end
	end
end

-- The parked bodies (every SCAN): where each is now; bring it back if a player is near it, or it got somewhere.
function checkParked(now, heads, far)
	for b, k in pairs(parked) do
		if not IsHandleValid(b) then
			parked[b] = nil
		elseif IsBodyActive(b) then
			parked[b] = nil                               -- something woke it (a hit): it is where it is
			parkWoken = parkWoken + 1
		else
			local y = k.y0 + k.v * (now - k.t0)
			local arrived = (k.v > 0 and y >= k.stopY) or (k.v < 0 and y <= k.stopY)
			if arrived then y = k.stopY end
			local near = not (nobodyNear(heads, k.x, y, k.z, far) and nobodyNear(heads, k.x, k.y0, k.z, far))
			if near or arrived then
				local t = GetBodyTransform(b)
				local lo, hi = GetBodyBounds(b)
				local move = Vec(0, y - k.y0, 0)
				if math.abs(y - k.y0) > 0.3 then             -- (moved: a free spot there; one woken in place stays put)
					move = VecAdd(move, freeSpot(b, VecAdd(lo, move), VecAdd(hi, move)))
				end
				wakeNeighbours(b, lo, hi)
				SetBodyTransform(b, Transform(VecAdd(t.pos, move), t.rot))
				parked[b] = nil
				if (near and not arrived) or k.kind == "surface" then
					k.s.cmd, k.s.lastY, k.s.still, k.s.woken = nil, nil, 0, true
					bodies[b] = k.s
					SetBodyActive(b, true)
				else
					rested[b] = true
				end
			end
		end
	end
end

-- Delete debris nobody has been near for a while (every 2 s; the players' positions against each piece).
function sweepDebris(now)
	if now < sweepAt then return end
	sweepAt = now + 2
	local heads = {}
	for _, p in ipairs(GetAllPlayers()) do heads[#heads + 1] = GetPlayerTransform(p).pos end
	for b, last in pairs(debris) do
		if not IsHandleValid(b) then
			debris[b] = nil
			debrisCount = debrisCount - 1
		else
			local at = GetBodyTransform(b).pos
			local near = false
			for _, h in ipairs(heads) do
				if VecLength(VecSub(at, h)) < KEEP_NEAR then near = true end
			end
			if near then
				debris[b] = now
			elseif now - last > CLEANUP then
				Delete(b)
				debris[b] = nil
				debrisCount = debrisCount - 1
			end
		end
	end
end

function Buoyancy.serverUpdate(dt)
	if GetBool("dive.buoyancy.disabled") or GetBool("buoyancy.disabled") then return end
	local now = GetTime()
	local heads = {}
	for _, p in ipairs(GetAllPlayers()) do heads[#heads + 1] = GetPlayerTransform(p).pos end
	local far = math.max(15, setting("dive.visibility", VISIBILITY) + PARK_MARGIN)
	scanAt = scanAt - dt
	if scanAt <= 0 then
		scanAt = SCAN
		scan()
		checkParked(now, heads, far)
	end
	sweepDebris(now)
	for _, b in ipairs(list) do
		local s = bodies[b]
		local active = s and IsHandleValid(b) and IsBodyActive(b)
		if parked[b] then
			-- parked: a formula now (checkParked), not to be woken like a map's sleeping body
		elseif s and s.woken and not active then
			s.age = 0                                     -- asleep (hanging, settled, frozen debris): nothing to do
		elseif IsHandleValid(b) then
			if not s then
				local target, isDebris = targetSpeed(b)
				s = {target = target, debris = isDebris, drift = 0, still = 0, age = 0, woken = IsBodyActive(b) or rested[b],
					nearAt = 0}
				bodies[b] = s
			end
			local c = TransformToParentPoint(GetBodyTransform(b), GetBodyCenterOfMass(b))
			local under, depth = IsPointInWater(c)
			local lo, hi = GetBodyBounds(b)
			local submerged = s.target and under and depth > (hi[2] - lo[2]) * 0.5 + 0.1
			if not IsBodyActive(b) then
				-- a map's loose bodies start asleep, and the engine's floating doesn't wake them: wake the ones that
				-- should move, once (one that hangs still stays asleep; so does a sinker after it has settled)
				if submerged and not s.woken and s.target ~= 0 then SetBodyActive(b, true) end
				s.woken = true
			elseif submerged then
				s.age = s.age + dt
				if s.debris and not debris[b] and debrisCount < 3000 then
					debris[b] = now
					debrisCount = debrisCount + 1
				end
				if s.cmd and s.lastY then
					local moved = (c[2] - s.lastY) / dt
					local drift = moved - s.cmd
					-- a knock or a contact is far bigger than the water's drift: don't learn from that (and a contact that
					-- holds it, a ceiling over a riser, a floor under a sinker for the 0.5 s before it sleeps, is capped);
					-- nor from one that is blocked: meant to move but barely moving, it says nothing about the water (learning
					-- from it pressed sinkers ever harder into a pile, which kept waking their neighbours)
					local blocked = math.abs(s.target) > 0.05 and math.abs(moved) < 0.3 * math.abs(s.target) and
						touching(b, s.target > 0)
					if math.abs(drift - s.drift) < 2 and not blocked then
						s.drift = math.max(-MAX_DRIFT, math.min(MAX_DRIFT, s.drift + (drift - s.drift) * LEARN))
					end
					-- stopped (a sinker on the floor, a riser under a ceiling, a knocked one that hangs again): put it to
					-- sleep (the engine would float it up again)
					-- (a hanger after a second of being driven: one knocked takes a moment to stop)
					local stopped = blocked or (s.age > 1 and math.abs(s.target) <= 0.05 and math.abs(moved) < 0.03)
					if stopped then s.still = s.still + dt else s.still = 0 end
				end
				local alone = false
				if not s.debris and s.target ~= 0 and s.age > PARK_AFTER and now >= s.nearAt then
					s.nearAt = now + SCAN
					alone = nobodyNear(heads, c[1], c[2], c[3], far)
				end
				if alone and s.still == 0 and park(b, s, c, now) then
					-- (parked: a formula now)
				elseif s.still >= 0.5 or (s.debris and s.age > DEBRIS_DRIFT) then
					SetBodyActive(b, false)
					s.still, s.cmd, s.woken = 0, nil, true
				else
					local v = GetBodyVelocity(b)
					local k = math.max(0, 1 - DRAG * dt)
					s.cmd = s.target - s.drift
					SetBodyVelocity(b, Vec(v[1] * k, s.cmd, v[3] * k))
				end
				s.lastY = c[2]
			else
				s.cmd, s.lastY = nil, nil
				-- floating at the surface (the engine's floating keeps it bobbing on the waves for ever): with nobody near,
				-- let it sleep where it floats; parked as a formula that stays put, so it wakes when someone comes near
				if (under or IsPointInWater(Vec(c[1], lo[2], c[3]))) and now >= s.nearAt then
					s.nearAt = now + SCAN
					if nobodyNear(heads, c[1], c[2], c[3], far) then
						parked[b] = {s = s, t0 = now, y0 = c[2], x = c[1], z = c[3], v = 0, stopY = c[2], kind = "floating"}
						parkedTotal = parkedTotal + 1
						bodies[b] = nil
						SetBodyActive(b, false)
					end
				end
			end
		end
	end
end
