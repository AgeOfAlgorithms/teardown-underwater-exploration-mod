-- Schools of fish, drawn by each player for themselves (client side: nothing is synced, players needn't see the same
-- fish). Schools appear in water around the camera (at least MIN_DEPTH deep), wander, keep off the floor, the surface
-- and walls, scatter from divers, and move to a new spot when the camera has left them behind. A map can also place
-- fixed schools: <location tags="fishschool=<count> fish=<silver|gold>"/> (these stay at their home).
-- Each fish is a small static body (5 cm voxels) spawned on this client only, not physical (collide='false': no
-- tool or shot hits it) and on collision layer FISH_LAYER, mask 0; only the fish within sight of the camera are moved.
--
-- How many: dive.fish (API.md: times SCHOOLS roaming schools; 0 = none). Set here: dive.fish.mode ("vox", or "none"
-- when this client can't spawn).

Fish = {}

SCHOOLS = 6         -- schools around the camera
SCHOOL_SIZE = {10, 28}
NEAR, FAR = 12, 35  -- a new school appears this far from the camera ...
LEAVE = 55          -- ... and is moved on when the camera is this far away
MIN_DEPTH = 3
ROAM = 18           -- metres a school may wander from its home
SPEED = 1.1         -- cruising speed, m/s
FLEE_SPEED = 3.0
FLEE_RANGE = 4.0    -- a player's head this close to the school makes it scatter
SPREAD = 1.1        -- the school's radius, metres
SIGHT = 30          -- fish farther from the camera than this aren't moved
FISH_LAYER = 128    -- (dive.lua's caustic rays skip this layer)

function Fish.clientInit()
	fishSchools = {}
	fishFree = {}       -- spawned fish bodies not in a school
	fishCanSpawn = "?"         -- (not known until the first fish is spawned)
	fishLookAt = 0
	for _, loc in ipairs(FindLocations("fishschool", true)) do
		local home = GetLocationTransform(loc).pos
		local kind = GetTagValue(loc, "fish")
		newSchool(home, tonumber(GetTagValue(loc, "fishschool")) or 12, kind ~= "" and kind or "silver", true)
	end
end

function spawnFish(kind, at)
	local made = Spawn("<body tags='fish'><vox file='MOD/vox/fish_" .. kind .. ".vox' scale='0.5' collide='false'/></body>", Transform(at), true)
	for _, e in ipairs(made) do
		if GetEntityType(e) == "body" then
			for _, sh in ipairs(GetBodyShapes(e)) do SetShapeCollisionFilter(sh, FISH_LAYER, 0) end
			return e
		end
	end
	return nil
end

function newSchool(home, n, kind, fixed)
	local s = {home = home, pos = VecCopy(home), dir = VecNormalize(Vec(math.random() - 0.5, 0, math.random() - 0.5)),
		speed = SPEED, fear = 0, fish = {}, seed = math.random() * 100, checkAt = 0, avoid = Vec(0, 0, 0), fixed = fixed}
	for _ = 1, n do
		local body = spawnFish(kind, home)
		if fishCanSpawn == "?" then
			fishCanSpawn = body ~= nil
			SetString("dive.fish.mode", fishCanSpawn and "vox" or "none")
		end
		if not body then break end
		-- a slot in the school: spread over an ellipsoid flattened in height, each with its own wiggle
		local a, b = math.random() * 6.283, math.acos(2 * math.random() - 1)
		local r = SPREAD * (0.35 + 0.65 * math.random() ^ 0.5)
		s.fish[#s.fish + 1] = {body = body, ph = math.random() * 6.283,
			slot = Vec(r * math.sin(b) * math.cos(a), r * 0.45 * math.cos(b), r * math.sin(b) * math.sin(a))}
	end
	fishSchools[#fishSchools + 1] = s
	return s
end

-- A spot in open water around the camera, MIN_DEPTH deep or more, or nil.
function waterSpot(cam)
	local a = math.random() * 6.283
	local d = NEAR + (FAR - NEAR) * math.random()
	local x, z = cam[1] + math.cos(a) * d, cam[3] + math.sin(a) * d
	local wet, _, surf = QueryRaycastWater(Vec(x, cam[2] + 200, z), Vec(0, -1, 0), 400)
	if not wet then return nil end
	QueryCollisionMask(255 - FISH_LAYER)
	local hit, dist = QueryRaycast(Vec(x, surf[2] - 0.05, z), Vec(0, -1, 0), 200)
	local depth = hit and dist or 200
	if depth < MIN_DEPTH then return nil end
	local lo, hi = 1.2, math.min(depth - 1.5, 25)       -- above the floor, below the surface, not too deep
	return Vec(x, surf[2] - 0.05 - depth + lo + (hi - lo) * math.random() ^ 0.7, z)
end

function fishRay(from, dir, dist)
	QueryCollisionMask(255 - FISH_LAYER)
	QueryRequire("physical")
	return QueryRaycast(from, dir, dist)
end

-- Steering, a few rays a second: walls ahead, the floor below, the surface above, and the way home.
function steer(s, now)
	if now < s.checkAt then return end
	s.checkAt = now + 0.25 + math.random() * 0.1
	local avoid = Vec(0, 0, 0)
	local hit, dist, normal = fishRay(s.pos, s.dir, 4)
	if hit then avoid = VecAdd(avoid, VecScale(normal, (4 - dist) * 1.2)) end
	local below, bd = fishRay(s.pos, Vec(0, -1, 0), 2.5)
	if below then avoid = VecAdd(avoid, Vec(0, (2.5 - bd) * 0.8, 0)) end
	local under, depth = IsPointInWater(VecAdd(s.pos, Vec(0, 1.2, 0)))
	if not under or depth < 0.5 then avoid = VecAdd(avoid, Vec(0, -0.8, 0)) end
	local home = VecSub(s.home, s.pos)
	local far = VecLength(home) / ROAM
	if far > 0.7 then avoid = VecAdd(avoid, VecScale(VecNormalize(home), (far - 0.7) * 2)) end
	s.avoid = avoid
end

-- Schools around the camera: top up to the wanted number (one a frame), move left-behind ones somewhere new.
function manageSchools(cam, now)
	if fishCanSpawn == false or now < fishLookAt then return end
	fishLookAt = now + 0.2
	local want = math.max(0, math.floor(SCHOOLS * setting("dive.fish", 1) + 0.5))
	local roaming = 0
	for _, s in ipairs(fishSchools) do
		if not s.fixed then
			roaming = roaming + 1
			if roaming > want or VecLength(VecSub(s.pos, cam)) > LEAVE then
				local spot = roaming <= want and waterSpot(cam)
				if spot then
					s.home, s.pos = spot, VecCopy(spot)
				else
					s.parked = true                       -- (no spot this time, or too many: park it out of sight)
				end
			end
		end
	end
	if roaming < want then
		local spot = waterSpot(cam)
		if spot then
			local kinds = {"silver", "gold"}
			newSchool(spot, math.random(SCHOOL_SIZE[1], SCHOOL_SIZE[2]), kinds[math.random(2)], false)
		end
	end
end

-- School centres and radii for the caustics' shadows (dive.lua).
function Fish.centres()
	local out = {}
	for _, s in ipairs(fishSchools or {}) do
		if not s.parked then out[#out + 1] = s.pos end
	end
	return out
end

function Fish.clientTick(dt)
	local now = GetTime()
	local cam = GetCameraTransform().pos
	manageSchools(cam, now)
	local heads = {}
	for _, p in ipairs(GetAllPlayers()) do heads[#heads + 1] = VecAdd(GetPlayerTransform(p).pos, Vec(0, 1.6, 0)) end
	for _, s in ipairs(fishSchools) do
		if s.parked then
			if not s.hidden then
				for _, f in ipairs(s.fish) do SetBodyTransform(f.body, Transform(Vec(0, -1000, 0))) end
				s.hidden = true
			end
			if VecLength(VecSub(s.pos, cam)) < LEAVE then s.parked, s.hidden = false, false end
		elseif VecLength(VecSub(s.pos, cam)) < SIGHT + 10 then
			steer(s, now)
			-- wander: a slow, smooth turn from two sine waves, plus the steering and fleeing
			local t = now * 0.23 + s.seed
			local want = VecAdd(s.dir, VecScale(Vec(math.sin(t * 1.3) + 0.5 * math.sin(t * 3.1), 0.35 * math.sin(t * 2.2),
				math.cos(t * 1.1) + 0.5 * math.cos(t * 2.7)), 0.35))
			want = VecAdd(want, s.avoid)
			local scared = false
			for _, h in ipairs(heads) do
				local away = VecSub(s.pos, h)
				local d = VecLength(away)
				if d < FLEE_RANGE then
					scared = true
					want = VecAdd(want, VecScale(VecNormalize(away), (FLEE_RANGE - d) * 1.5))
				end
			end
			s.fear = math.max(0, math.min(1, s.fear + (scared and dt * 4 or -dt * 0.5)))
			want[2] = want[2] * 0.6
			s.dir = VecNormalize(VecLerp(s.dir, VecNormalize(want), math.min(1, dt * (1.2 + 3 * s.fear))))
			s.speed = SPEED + (FLEE_SPEED - SPEED) * s.fear
			s.pos = VecAdd(s.pos, VecScale(s.dir, s.speed * dt))
			if VecLength(VecSub(s.pos, cam)) < SIGHT then
				local frame = QuatLookAt(Vec(0, 0, 0), s.dir)
				local spread = 1 + 0.8 * s.fear
				for _, f in ipairs(s.fish) do
					local wig = math.sin(now * (7 + 6 * s.fear) + f.ph)
					local drift = Vec(math.sin(now * 0.7 + f.ph) * 0.25, math.sin(now * 0.9 + f.ph * 2) * 0.12, math.cos(now * 0.6 + f.ph) * 0.25)
					local pos = VecAdd(s.pos, TransformToParentVec(Transform(Vec(), frame), VecAdd(VecScale(f.slot, spread), drift)))
					-- the model's head is +x: turn it onto -z, then point -z along the swim direction; the tail swishes
					SetBodyTransform(f.body, Transform(pos, QuatRotateQuat(frame, QuatEuler(0, 90 + wig * 12, 0))))
				end
			end
		end
	end
end
