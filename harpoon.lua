-- The harpoon gun (moved here from the Titanic Wreck map, 2026-11-03: maps carry no gameplay of their own). A tool with
-- SPEARS spears, from a pickup: anything tagged harpoon (the spawn menu's Harpoon gun is one; with the tag remain it
-- stays for the next player), taken with E (Dive's own aim and prompt: dive.lua, pickupInView), or handed out by a
-- script: dive.give.harpoon.<player> = spears (0 takes it). It stays with the player, as the diver gear does (a game
-- mode taking the tool away takes it). Spear racks (anything tagged spearrack: a map's) refill it with E, then are
-- spent RACK_REFILL seconds (tagged spent meanwhile).
--
-- The server owns the spears: a shot spawns a thin static spear body (it touches nothing: collision layer 0, mask 0)
-- at the muzzle and flies it along the aim, a step per tick with a gentle drop and a little drag in water. Each step
-- is a raycast against the world (mask 63: past a worm's hit boxes on layer 64 and Dive's fish on 128) and a test
-- against the Abyssipede's published hit points (its registry API, ../worm/PROJECT.md: abyssipede.hitpoints, a chain
-- of points per worm read as capsules). A worm hit queues damage in abyssipede.damage (appended, never overwritten)
-- and the spear vanishes in a dark cloud; a world hit leaves it stuck there for STUCK_T seconds (at most STUCK_MAX,
-- the oldest goes first; on a loose object it rides along). Past RANGE metres it sinks and is gone.
-- Clients only draw: the tool in the hands (the game's toolanimation.lua, included by main.lua), the loaded spear
-- hidden while reloading, sounds and particles from one ClientCall per event.

Harpoon = {}

HARPOON = "harpoon"
HARPOON_NAME = "Harpoon gun"
SPEARS = 6                   -- spears in a full gun
RELOAD = 1.2                 -- s between shots
SPEED = 28                   -- m/s at the muzzle
G_WATER = 1.6                -- m/s^2: the drop in water (gentle) ...
G_AIR = 5                    -- ... and in air
DRAG_WATER = 0.25            -- 1/s: in water the spear slows a bit (28 -> ~24 m/s over the range)
RANGE = 40                   -- m flown before it gives out, sinks ...
SPENT_T = 2.5                -- ... and is gone this long after
SPEAR_LEN = 1.2              -- m (the model: 24 voxels of 0.05 m, the body's origin at its middle)
STUCK_T = 20                 -- s a spear stays where it struck
STUCK_MAX = 12
FLYING_MAX = 16
PENETRATE = 0.1              -- m the point sinks into what it strikes
IMPULSE = 12                 -- kg m/s given to a loose object it strikes
DMG = 25                     -- to the worm (abyssipede.damage) ...
DMG_HEAD = 50                -- ... on the head
QUERY_MASK = 63
RACK_REFILL = 20             -- s a spear rack is spent after use
SPEAR_XML = "<body tags='harpoonspear nocull'><vox tags='unbreakable nocull' file='MOD/vox/harpoon_spear.vox' scale='0.5' pos='-0.025 -0.025 0'/></body>"
-- client event kinds (client.harpoonFx)
FX_FIRE, FX_METAL, FX_HIT, FX_WORM, FX_DRY, FX_SPENT, FX_RACK = 1, 2, 3, 4, 5, 6, 7

----- server -----

function Harpoon.serverInit()
	RegisterTool(HARPOON, HARPOON_NAME, "MOD/prefab/harpoon.xml", 6)
	for _, b in ipairs(FindBodies("harpoonspear", true) or {}) do Delete(b) end
	flying = {}
	stuck = {}
	gunners = {}                 -- player -> {readyAt}: the players who carry the gun
	wormPtsStr = false          -- (the last abyssipede.hitpoints parsed)
	wormChains = {}
	rackReady = {}               -- rack body -> the time it is back in service
	spearSound = LoadSound("tool_pickup.ogg")
end

function harpoonGive(p, spears)
	local held = GetPlayerTool(p)
	gunners[p] = gunners[p] or {readyAt = 0}
	SetToolEnabled(HARPOON, true, p)
	SetToolAmmo(HARPOON, spears, p)
	if held ~= HARPOON then SetPlayerTool(HARPOON, p) end
end

function harpoonTake(p)
	gunners[p] = nil
	SetToolEnabled(HARPOON, false, p)
end

-- E on a harpoon pickup gives the gun (or fills it); on a ready spear rack, with spears missing, refills it
function harpoonPickups(now)
	for b, at in pairs(rackReady) do
		if now >= at then
			rackReady[b] = nil
			if IsHandleValid(b) then RemoveTag(b, "spent") end
		end
	end
	for _, p in ipairs(GetAllPlayers()) do
		if HasKey("dive.give.harpoon." .. p) then                    -- another mod hands out (or takes) the gun
			local n = GetInt("dive.give.harpoon." .. p)
			ClearKey("dive.give.harpoon." .. p)
			if n > 0 then harpoonGive(p, n) else harpoonTake(p) end
		end
		if gunners[p] and not IsToolEnabled(HARPOON, p) then gunners[p] = nil end   -- (a game mode took it)
		if pressed("interact", p) and GetPlayerHealth(p) > 0 then
			local b, kind, value = pickupInView(p)
			if kind == "harpoon" then
				harpoonGive(p, value > 0 and math.floor(value) or SPEARS)
				PlaySound(spearSound, GetBodyTransform(b).pos, 1)
				local remain = HasTag(b, "remain")
				for _, sh in ipairs(GetBodyShapes(b)) do remain = remain or HasTag(sh, "remain") end
				if not remain then
					letGo(b)
					Delete(b)
				end
			elseif kind == "spearrack" and gunners[p] and not rackReady[b] and GetToolAmmo(HARPOON, p) < SPEARS then
				SetToolAmmo(HARPOON, SPEARS, p)
				rackReady[b] = now + RACK_REFILL
				SetTag(b, "spent")
				local lo, hi = GetBodyBounds(b)
				harpoonFx(FX_RACK, VecLerp(lo, hi, 0.5), Vec(0, 1, 0), p)
			end
		end
	end
end

-- the worm's hit points (abyssipede.hitpoints, "id x y z r head;"), as chains per worm id; parsed again only when changed
function harpoonWormChains()
	local s = GetString("abyssipede.hitpoints")
	if s == wormPtsStr then return wormChains end
	wormPtsStr = s
	wormChains = {}
	local byId = {}
	for id, x, y, z, r, h in string.gmatch(s, "(%-?%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+([01])%s*;") do
		x, y, z, r = tonumber(x), tonumber(y), tonumber(z), tonumber(r)
		if x and y and z and r and r > 0 and r < 5 then
			local c = byId[id]
			if not c then
				c = {}
				byId[id] = c
				wormChains[#wormChains + 1] = c
			end
			c[#c + 1] = {p = Vec(x, y, z), r = r, head = h == "1"}
		end
	end
	return wormChains
end

local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end

-- closest points of the segments p1-q1 and p2-q2 (a point when p2 == q2): fractions s, t and the squared distance
function harpoonSegSeg(p1, q1, p2, q2)
	local d1, d2, r = VecSub(q1, p1), VecSub(q2, p2), VecSub(p1, p2)
	local a, e, f = VecDot(d1, d1), VecDot(d2, d2), VecDot(d2, r)
	local s, t
	if a < 1e-9 and e < 1e-9 then
		s, t = 0, 0
	elseif a < 1e-9 then
		s, t = 0, clamp01(f / e)
	else
		local c = VecDot(d1, r)
		if e < 1e-9 then
			s, t = clamp01(-c / a), 0
		else
			local b = VecDot(d1, d2)
			local den = a * e - b * b
			s = den > 1e-9 and clamp01((b * f - c * e) / den) or 0
			t = (b * s + f) / e
			if t < 0 then t, s = 0, clamp01(-c / a)
			elseif t > 1 then t, s = 1, clamp01((b - c) / a) end
		end
	end
	local w = VecSub(VecAdd(p1, VecScale(d1, s)), VecAdd(p2, VecScale(d2, t)))
	return s, t, VecDot(w, w)
end

-- the spear's point moving a -> b against the worms: nil, or the fraction along a-b and whether it was the head
function harpoonWormHit(a, b)
	local best, head = nil, false
	for _, c in ipairs(harpoonWormChains()) do
		for i = 1, #c do
			local e = c[i]
			local s, _, d2 = harpoonSegSeg(a, b, e.p, e.p)
			if d2 <= e.r * e.r then
				if not best or s < best then best = s end
				if e.head then head = true end
			end
			local n = c[i + 1]
			if n then
				local s2, t2, dd = harpoonSegSeg(a, b, e.p, n.p)
				local r = e.r + (n.r - e.r) * t2
				if dd <= r * r and (not best or s2 < best) then best = s2 end
			end
		end
	end
	return best, head
end

function harpoonDamage(p, amount)
	local q = GetString("abyssipede.damage")                       -- (append: other scripts may have queued hits)
	SetString("abyssipede.damage", q .. string.format("%.2f %.2f %.2f %d;", p[1], p[2], p[3], amount))
end

function harpoonFx(kind, p, dir, who)
	ClientCall(0, "client.harpoonFx", kind, p[1], p[2], p[3], dir[1], dir[2], dir[3], who or 0)
end

function harpoonSpearTransform(tip, dir)
	local c = VecSub(tip, VecScale(dir, SPEAR_LEN * 0.5))
	return Transform(c, QuatLookAt(c, tip))
end

function harpoonSpawnSpear(tip, dir)
	local body = 0
	for _, e in ipairs(Spawn(SPEAR_XML, harpoonSpearTransform(tip, dir), true) or {}) do
		local kind = GetEntityType(e)
		if kind == "body" then body = e
		elseif kind == "shape" then SetShapeCollisionFilter(e, 0, 0) end
	end
	return body
end

function harpoonFire(p, g, now)
	local eye = GetPlayerEyeTransform(p)
	local fwd = TransformToParentVec(eye, Vec(0, 0, -1))
	local mt = GetToolLocationWorldTransform("muzzle", p)
	local muzzle = mt and mt.pos or TransformToParentPoint(eye, Vec(0.22, -0.25, -1.4))
	local _, start, _, dir = GetPlayerAimInfo(muzzle, RANGE, p)
	start = start or muzzle
	if not dir or VecLength(dir) < 0.5 then dir = fwd end
	dir = VecNormalize(dir)
	SetToolAmmo(HARPOON, math.max(0, GetToolAmmo(HARPOON, p) - 1), p)
	g.readyAt = now + RELOAD
	harpoonFx(FX_FIRE, start, dir, p)
	-- point blank: the worm between the eye and the muzzle
	local s, head = harpoonWormHit(eye.pos, start)
	if s then
		local hp = VecLerp(eye.pos, start, s)
		harpoonDamage(hp, head and DMG_HEAD or DMG)
		harpoonFx(FX_WORM, hp, dir)
		return
	end
	if #flying >= FLYING_MAX then harpoonRemoveFlying(1) end
	local body = harpoonSpawnSpear(start, dir)
	if body ~= 0 then
		flying[#flying + 1] = {body = body, tip = VecCopy(start), vel = VecScale(dir, SPEED), travel = 0, t0 = now,
			spentAt = nil, shooter = p}
	end
end

function harpoonRemoveFlying(i)
	local s = flying[i]
	if IsHandleValid(s.body) then Delete(s.body) end
	table.remove(flying, i)
end

function harpoonStick(s, tip, dir, shape)
	local host = shape and shape ~= 0 and GetShapeBody(shape) or 0
	if host ~= 0 and not IsBodyDynamic(host) then host = 0 end
	local t = harpoonSpearTransform(tip, dir)
	SetBodyTransform(s.body, t)
	local e = {body = s.body, untilT = GetTime() + STUCK_T, host = host}
	if host ~= 0 then
		e.lt = TransformToLocalTransform(GetBodyTransform(host), t)
		ApplyBodyImpulse(host, tip, VecScale(dir, IMPULSE))
	end
	if #stuck >= STUCK_MAX then
		local o = table.remove(stuck, 1)
		if IsHandleValid(o.body) then Delete(o.body) end
	end
	stuck[#stuck + 1] = e
end

function harpoonFly(dt, now)
	for i = #flying, 1, -1 do
		local s = flying[i]
		local v = s.vel
		local water = IsPointInWater(s.tip)
		local g = water and G_WATER or G_AIR
		if s.spentAt then
			v = VecScale(v, math.max(0, 1 - 2.5 * dt))
			g = 3
		elseif water then
			v = VecScale(v, math.max(0, 1 - DRAG_WATER * dt))
		end
		v = VecAdd(v, Vec(0, -g * dt, 0))
		s.vel = v
		local step = VecScale(v, dt)
		local len = VecLength(step)
		local gone = not IsHandleValid(s.body) or now - s.t0 > 12 or (s.spentAt and now - s.spentAt > SPENT_T)
		if gone then
			if s.spentAt and IsHandleValid(s.body) then harpoonFx(FX_SPENT, s.tip, Vec(0, 1, 0)) end
			harpoonRemoveFlying(i)
		elseif len > 1e-4 then
			local dir = VecScale(step, 1 / len)
			local nextTip = VecAdd(s.tip, step)
			QueryRequire("physical")
			QueryCollisionMask(QUERY_MASK)
			local hit, d, _, shape = QueryRaycast(s.tip, dir, len)
			local ws, head
			if not s.spentAt then ws, head = harpoonWormHit(s.tip, nextTip) end
			if ws and (not hit or ws * len <= d) then
				local hp = VecLerp(s.tip, nextTip, ws)
				harpoonDamage(hp, head and DMG_HEAD or DMG)
				harpoonFx(FX_WORM, hp, dir)
				harpoonRemoveFlying(i)
			elseif hit then
				local hp = VecAdd(s.tip, VecScale(dir, d))
				local mat = GetShapeMaterialAtPosition(shape, hp)
				local metal = mat == "metal" or mat == "heavymetal" or mat == "hardmetal"
				harpoonFx(metal and FX_METAL or FX_HIT, hp, dir)
				harpoonStick(s, VecAdd(hp, VecScale(dir, PENETRATE)), dir, shape)
				table.remove(flying, i)
			else
				s.tip = nextTip
				s.travel = s.travel + len
				if not s.spentAt and s.travel > RANGE then s.spentAt = now end
				SetBodyTransform(s.body, harpoonSpearTransform(s.tip, dir))
			end
		end
	end
end

function harpoonStuckTick(now)
	for i = #stuck, 1, -1 do
		local e = stuck[i]
		local valid = IsHandleValid(e.body)
		if not valid or now > e.untilT or (e.host ~= 0 and not IsHandleValid(e.host)) then
			if valid then Delete(e.body) end
			table.remove(stuck, i)
		elseif e.host ~= 0 and IsBodyActive(e.host) then
			SetBodyTransform(e.body, TransformToParentTransform(GetBodyTransform(e.host), e.lt))
		end
	end
end

function Harpoon.serverTick(dt)
	local now = GetTime()
	dt = math.min(dt, 0.05)
	for _, p in ipairs(GetRemovedPlayers()) do gunners[p] = nil end
	harpoonPickups(now)
	for p, g in pairs(gunners) do
		if GetPlayerHealth(p) > 0 and GetPlayerTool(p) == HARPOON and pressed("usetool", p) and GetPlayerVehicle(p) == 0
			and GetPlayerCanUseTool(p) and now >= g.readyAt then
			if GetToolAmmo(HARPOON, p) >= 1 then
				harpoonFire(p, g, now)
			else
				g.readyAt = now + 0.3
				harpoonFx(FX_DRY, GetPlayerEyeTransform(p).pos, Vec(0, 1, 0), p)
			end
		end
	end
	if #flying > 0 then harpoonFly(dt, now) end
	if #stuck > 0 then harpoonStuckTick(now) end
end

----- client -----

function Harpoon.clientInit()
	Harpoon.clientOn = true
	fireSnd = {}
	for i = 0, 3 do fireSnd[#fireSnd + 1] = LoadSound("silenced" .. i .. ".ogg") end
	metalSnd = {}
	for i = 0, 5 do metalSnd[#metalSnd + 1] = LoadSound("metal/hit-s" .. i .. ".ogg") end
	hitSnd = {}
	for i = 0, 5 do hitSnd[#hitSnd + 1] = LoadSound("wood/hit-s" .. i .. ".ogg") end
	fleshSnd = {}
	for i = 0, 4 do fleshSnd[#fleshSnd + 1] = LoadSound("flesh-impact" .. i .. ".ogg") end
	drySnd = LoadSound("tools/dryfire0.ogg")
	readySnd = LoadSound("clickup.ogg")
	animators = {}
	reloadUntil = {}
	recoil = {}
	spearShape = {}
	spearHidden = {}
end

local function rnd(a, b) return a + math.random() * (b - a) end
local function oneOf(list) return list[math.random(1, #list)] end

function client.harpoonFx(kind, x, y, z, dx, dy, dz, who)
	if not Harpoon.clientOn then return end                   -- (this copy's client side isn't running)
	local p, dir = Vec(x, y, z), Vec(dx, dy, dz)
	local water = IsPointInWater(p)
	if kind == FX_FIRE then
		-- the shot: loud enough for the worm to hear it (registered)
		PlaySound(oneOf(fireSnd), p, 0.8, true, rnd(0.6, 0.7))
		reloadUntil[who] = GetTime() + RELOAD
		recoil[who] = 1
		ParticleReset()
		if water then                                         -- a burst of bubbles off the muzzle
			ParticleType("plain")
			ParticleColor(0.75, 0.85, 0.9)
			ParticleRadius(0.015, 0.035)
			ParticleAlpha(0.7, 0)
			ParticleGravity(2.5)
			ParticleDrag(0.6)
			for _ = 1, 10 do
				SpawnParticle(VecAdd(p, VecScale(dir, rnd(0, 0.8))), VecAdd(VecScale(dir, rnd(0.5, 2)), Vec(rnd(-0.3, 0.3), rnd(0, 0.4), rnd(-0.3, 0.3))), rnd(0.8, 1.6))
			end
		else
			ParticleType("smoke")
			ParticleColor(0.8, 0.8, 0.8)
			ParticleRadius(0.05, 0.2)
			ParticleAlpha(0.3, 0)
			SpawnParticle(p, VecScale(dir, 1), 0.6)
		end
	elseif kind == FX_METAL or kind == FX_HIT then
		PlaySound(oneOf(kind == FX_METAL and metalSnd or hitSnd), p, 0.9, true, rnd(0.85, 1.0))
		ParticleReset()                                       -- silt and rust knocked off
		ParticleType("smoke")
		ParticleColor(0.32, 0.26, 0.2, 0.2, 0.17, 0.14)
		ParticleRadius(0.08, 0.35)
		ParticleAlpha(0.45, 0)
		ParticleGravity(water and -0.2 or -1)
		ParticleDrag(0.8)
		for _ = 1, 4 do SpawnParticle(VecSub(p, VecScale(dir, 0.1)), VecAdd(VecScale(dir, -0.5), Vec(rnd(-0.3, 0.3), rnd(0, 0.3), rnd(-0.3, 0.3))), rnd(1.5, 2.5)) end
	elseif kind == FX_WORM then
		PlaySound(oneOf(fleshSnd), p, 1.0, true, rnd(0.6, 0.75))
		ParticleReset()                                       -- (the worm mod puffs its green ichor there itself)
		ParticleType("plain")
		ParticleColor(0.02, 0.03, 0.03)
		ParticleRadius(0.02, 0.04)
		ParticleGravity(water and -0.5 or -8)
		ParticleDrag(0.4)
		for _ = 1, 10 do SpawnParticle(p, VecAdd(VecScale(dir, rnd(0.5, 2)), Vec(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1))), rnd(0.8, 1.6)) end
	elseif kind == FX_RACK then                               -- spears taken from a rack
		PlaySound(oneOf(metalSnd), p, 0.5, false, rnd(1.1, 1.3))
		PlaySound(readySnd, p, 0.6, false)
	elseif kind == FX_DRY then
		if IsPlayerLocal(who) then PlaySound(drySnd, p, 0.6, false) end
	elseif kind == FX_SPENT then
		ParticleReset()
		ParticleType("plain")
		ParticleColor(0.75, 0.85, 0.9)
		ParticleRadius(0.015, 0.03)
		ParticleAlpha(0.6, 0)
		ParticleGravity(2)
		for _ = 1, 5 do SpawnParticle(p, Vec(rnd(-0.2, 0.2), rnd(0.2, 0.6), rnd(-0.2, 0.2)), rnd(0.8, 1.4)) end
	end
end

function harpoonAnimator(p)
	local a = animators[p]
	if not a then
		a = ToolAnimator()
		animators[p] = a
	end
	return a
end

-- the loaded spear on the gun (the prefab's shape tagged harpoonspear): hidden while reloading and when empty
function harpoonShowLoaded(p, show)
	local b = GetToolBody(p)
	if b == 0 then return end
	local sh = spearShape[p]
	if not sh or sh.body ~= b then
		sh = {body = b, shape = 0}
		for _, s in ipairs(GetBodyShapes(b)) do if HasTag(s, "harpoonspear") then sh.shape = s end end
		spearShape[p] = sh
		spearHidden[p] = nil
	end
	if sh.shape ~= 0 and spearHidden[p] ~= not show then
		spearHidden[p] = not show
		if show then RemoveTag(sh.shape, "invisible") else SetTag(sh.shape, "invisible") end
	end
end

function Harpoon.clientTick(dt)
	local now = GetTime()
	for _, p in ipairs(GetRemovedPlayers()) do
		animators[p], reloadUntil[p], recoil[p], spearShape[p], spearHidden[p] = nil, nil, nil, nil, nil
	end
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerTool(p) == HARPOON then
			local a = harpoonAnimator(p)
			local r = recoil[p] or 0
			a.offsetTransform = Transform(Vec(0, 0.02 * r, 0.09 * r))     -- kicks back, settles in ~0.25 s
			recoil[p] = math.max(0, r - dt * 4)
			tickToolAnimator(a, dt, nil, p)
			local reloading = reloadUntil[p] and now < reloadUntil[p] - 0.2
			local empty = IsPlayerLocal(p) and GetToolAmmo(HARPOON, p) < 1
			harpoonShowLoaded(p, not reloading and not empty)
			if reloadUntil[p] and now >= reloadUntil[p] then
				reloadUntil[p] = nil
				if IsPlayerLocal(p) and not empty then PlaySound(readySnd, GetPlayerEyeTransform(p).pos, 0.4, false) end
			end
		end
	end
end
