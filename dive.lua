-- Scuba diving for any water. At the surface the game's own swimming carries you; crouch to dive. Diving, you swim
-- where you look (forward/back/strafe follow the camera, pitch included), jump/crouch go straight up/down, and with
-- no input you hang still. The dive ends when your head comes out of the water.
-- The air lasts AIR_TIME seconds under water and refills at the surface. The engine drowns a player whose head has
-- been under for ~10 s (~0.2 health/s, seen in-game); while there is air that damage is undone.
-- Diver gear (an air tank and flippers): any body or shape tagged divergear=<seconds> (the spawn menu's Diver gear is
-- one) is picked up with E (our own prompt; with the tag remain, the body stays), which puts the Diver gear tool in the
-- wheel for good. Holding it, LMB puts it on or takes it off (it stays on whatever tool is held); worn, a full tank
-- lasts that many seconds and you swim faster, but on land the flippers slow you. Everyone sees it on the diver
-- (clientRender, on the bone bodies).
-- Diving, the sledgehammer is put away for the game's blowtorch (and given back at the surface).
-- Client side: caustic light on whatever the sun reaches under water, bubbles (a diver's breath, streams from the
-- floor, and a burst with a bubbling sound where a loud noise happens in the water: an explosion, a shot), and the
-- deeper you are the darker, bluer and greyer it gets. (The engine itself muffles every sound while the camera is
-- under water: the highs go, measured from the game's audio output.)
--
-- Settings other mods can write and what they can read: API.md (setting() in main.lua). The water's visibility for
-- the caustics, bubbles, fish and plants (a script can't read it from the water): dive.visibility, or the map's tag
-- on its <water>, visibility=<m> (as its visibility attribute); else VISIBILITY.
-- Test hook: dive.test.<input> (bool) holds that input for every player (autotests only).

Dive = {}

SWIM = 3.0          -- swim speed, m/s
ACCEL = 3.0         -- how fast the swim speed follows the input (1/s): water has some inertia
AIR_TIME = 45       -- seconds of air in a full tank
GEAR_REACH = 3.5    -- metres from the eye to diver gear you can take (a swimmer's eye is the upright capsule's: the
                    -- swim pose draws the head ~1.6 m further on, verified in-game 2026-11-03)
GEAR_TOOL = "divergear"
GUNS = {"gun", "shotgun", "rifle", "rocket"}
TORCH_FUEL = 30     -- the blowtorch's fuel when diving lends it empty, and what an air station fills it to   -- the game's firearms: stowed under water (stowGuns)
GEAR_START = 180    -- seconds of the diver gear everyone has in the wheel (dive.gear.start; 0 = only from pickups)
GEAR_LAND_SPEED = 0.6  -- worn, out of the water: walking speed (x the game's); jumps: halfway to it
GEAR_SWIM_SPEED = 1.5  -- worn, in the water: swimming speed, diving and at the surface (x)
FIN_AHEAD = 0.12    -- metres a flipper's centre lies past the toes, ...
FIN_DOWN = 0.04     -- ... and below them (the shoe sits in its pocket)
FIN_SLOPE = 0.35    -- how much of the foot's slope a flipper keeps
GEAR_SPEEDS = {walkingSpeed = 7.0, jumpSpeed = 4.0}   -- the game's own on land (read in-game, 2026-11-03)
-- the tank on the back, in the chest bone body's frame as the game poses it: x up the spine from the chest's base, y
-- FORWARD (measured in-game 2026-11-03: the bind pose's axes put the tank through the face); the tank's centre level
-- with the chest's base puts the valve at the neck
BACK = Transform(Vec(0, -0.22, 0), QuatEuler(0, 0, -90))
BACK_OUT = 0.22     -- metres the tank's centre lies behind the chest (clientRender)
REFILL_TIME = 4     -- seconds to refill an empty tank at the surface

CAUSTIC_FRAMES = 24
CAUSTIC_FPS = 8
PERIOD = 6          -- the caustic texture repeats every PERIOD 1 m cells (tools/make_caustics.py)
REACH = 9           -- caustic cells drawn out to this many metres around the camera
REFRESH = 3         -- seconds before a cell's surface is looked up again (0.5 s on a moving body)
LOOKUPS = 40        -- cell look-ups per frame at most
LOUD = 0.6          -- GetLastSound volume of a noise that gets a bubble burst
BIG = 3             -- ... and of a big one (an explosion): a big burst, a deep boom of bubbles
VISIBILITY = 5      -- metres, when the map doesn't say (the built-in maps' seas are murky: Isla Estocastica 5.3)
FISH_LAYER = 128    -- fish.lua puts its fish on this collision layer: the caustics' rays pass through them
DARK_DEPTH = 8      -- metres: the light under water falls off as exp(-depth / DARK_DEPTH)
DARK_MIN = 0.03     -- the darkest the picture gets (and so at most 33 x the flashlight)
LAYER_STEP = 2      -- metres between the dark sheets under the surface (depthLayers), ...
LAYER_DEPTH = 60    -- ... down to this depth, ...
LAYER_SIZE = 160    -- ... each this many metres across, under the camera
LAYER_OFFSET = 0.37 -- (off whole metres: a sheet level with a flat floor flickers)

function held(name, p)
	return InputDown(name, p) or GetBool("dive.test." .. name)
end

function pressed(name, p)
	return InputPressed(name, p) or GetBool("dive.test." .. name)
end

function axis(plus, minus, p)
	return (held(plus, p) and 1 or 0) - (held(minus, p) and 1 or 0)
end

function Dive.serverInit()
	divers = {}
	publishAt = 0
	seq = 0
	pickupSound = LoadSound("tool_pickup.ogg")
	wearSound = LoadSound("clickup.ogg")
	hissSound = LoadSound("MOD/snd/breath1.ogg")
	airReady = {}                                      -- air station body -> the time it is back in service
	RegisterTool(GEAR_TOOL, "Diver gear", "MOD/prefab/divergear_tool.xml")
end

-- seconds of air in this player's full tank: a script's dive.air.time.<player>, else the diver gear they wear, else
-- dive.air.time
function tankTime(p, d)
	local own = GetFloat("dive.air.time." .. p)
	if own > 0 then return own end
	if d.worn and d.gearLen then return d.gearLen end
	return setting("dive.air.time", AIR_TIME)
end

-- Diving: the blowtorch instead of the sledgehammer (TORCH_FUEL if empty; air stations fill it again: a cutting torch
-- needs oxygen). Remembers what it changed, so the surface puts it back.
function swapTools(d, p, diving)
	if diving then
		if IsToolEnabled("sledge", p) then
			SetToolEnabled("sledge", false, p)
			d.hadSledge = true
		end
		if not IsToolEnabled("blowtorch", p) then
			SetToolEnabled("blowtorch", true, p)
			if GetToolAmmo("blowtorch", p) <= 0 then SetToolAmmo("blowtorch", TORCH_FUEL, p) end
			d.gaveTorch = true
		end
		if d.hadSledge and GetPlayerTool(p) == "sledge" then SetPlayerTool("blowtorch", p) end
	else
		if d.hadSledge then
			SetToolEnabled("sledge", true, p)
			if GetPlayerTool(p) == "blowtorch" then SetPlayerTool("sledge", p) end
		end
		if d.gaveTorch then SetToolEnabled("blowtorch", false, p) end
		d.hadSledge, d.gaveTorch = false, false
	end
end

-- Guns don't fire under water: with the head under, the game's firearms leave the wheel (the ones the player had) and
-- come back at the surface; dive.guns = true lets them be. (Bombs and pipebombs still work: under water a blast boils.)
function stowGuns(d, p, stow)
	if stow then
		d.stowed = {}
		local held = GetPlayerTool(p)
		for _, t in ipairs(GUNS) do
			if IsToolEnabled(t, p) then
				d.stowed[#d.stowed + 1] = t
				SetToolEnabled(t, false, p)
			end
		end
		for _, t in ipairs(d.stowed) do
			if held == t then                                      -- (something else in the hands)
				SetPlayerTool(IsToolEnabled(HARPOON, p) and HARPOON or IsToolEnabled("blowtorch", p) and "blowtorch" or "none", p)
			end
		end
	else
		for _, t in ipairs(d.stowed or {}) do SetToolEnabled(t, true, p) end
		d.stowed = nil
	end
end

function Dive.serverUpdate(dt)
	for _, p in ipairs(GetAllPlayers()) do
		local d = divers[p]
		if not d then
			d = {diving = false, air = 1, v = Vec(0, 0, 0), drift = 0.8}
			divers[p] = d
			SetToolEnabled(GEAR_TOOL, false, p)                         -- (only from a pickup)
		end
		local was = d.diving
		if HasKey("dive.give.air." .. p) then                        -- another mod refills (or empties) the tank
			d.air = math.max(0, math.min(1, GetFloat("dive.give.air." .. p)))
			ClearKey("dive.give.air." .. p)
		end
		if GetPlayerHealth(p) <= 0 or GetPlayerVehicle(p) ~= 0 or GetBool("dive.disabled") then
			d.diving = false
			d.headIn = false
			d.bodyIn = false
		else
			local feet = GetPlayerTransform(p).pos
			local bodyIn = IsPointInWater(VecAdd(feet, Vec(0, 0.8, 0)))   -- the chest point the game's swim animation uses
			local headIn = IsPointInWater(GetPlayerEyeTransform(p).pos)
			d.headIn = headIn
			d.bodyIn = bodyIn
			if not bodyIn then
				d.diving = false
			elseif held("crouch", p) then
				d.diving = true
			elseif d.diving and not headIn then
				d.diving = false                                            -- surfaced: the game's swimming again
			end
			if d.diving then
				local cam = GetPlayerCameraTransform(p)
				local fwd = TransformToParentVec(cam, Vec(0, 0, -1))
				local right = TransformToParentVec(cam, Vec(1, 0, 0))
				right[2] = 0
				local wish = VecAdd(VecAdd(VecScale(fwd, axis("up", "down", p)), VecScale(VecNormalize(right), axis("right", "left", p))),
					Vec(0, axis("jump", "crouch", p), 0))
				local n = VecLength(wish)
				if n > 1 then wish = VecScale(wish, 1 / n) end
				if not was then d.v = GetPlayerVelocity(p) end
				local fins = d.worn and setting("dive.gear.swim.speed", GEAR_SWIM_SPEED) or 1
				d.v = VecLerp(d.v, VecScale(wish, setting("dive.swim.speed", SWIM) * fins), math.min(1, dt * ACCEL))
				-- The engine floats a submerged player up ~0.8 m/s on top of the velocity a script sets, and it moves the
				-- position: GetPlayerVelocity doesn't show it (measured in-game). Learn that drift from how far the
				-- player really moved last step and set that much less. Contacts (the floor, a crate) and teleports are
				-- bigger than any drift: don't learn from those. With no up/down swimming, hold the depth.
				-- (Fly mode would hover without this, but it ignores a velocity set by script: seen in-game.)
				if d.cmd and d.lastY then
					local drift = (feet[2] - d.lastY) / dt - d.cmd
					if math.abs(drift) < 1.5 and not IsPlayerGrounded(p) then
						d.drift = d.drift + (drift - d.drift) * 0.1
					end
				end
				if math.abs(d.v[2]) > 0.3 or not d.holdY then d.holdY = feet[2] end
				local hold = math.abs(d.v[2]) <= 0.3 and math.abs(wish[2]) < 0.1 and (d.holdY - feet[2]) * 2 or 0
				d.cmd = d.v[2] + hold - d.drift
				SetPlayerVelocity(Vec(d.v[1], d.cmd, d.v[3]), p)
			else
				d.cmd, d.holdY = nil, nil
			end
			d.lastY = feet[2]
			d.ownHurt = nil
			if headIn then
				d.air = math.max(0, d.air - dt / math.max(1, tankTime(p, d)))
				-- out of air, with dive.drown.time set: dead that many seconds after the tank ran out (from full health);
				-- the engine's own drowning is undone then (serverTick)
				local drown = setting("dive.drown.time", 0)
				if d.air <= 0 and drown > 0 then
					d.ownHurt = math.max(0, GetPlayerHealth(p) - dt / drown)
					SetPlayerHealth(d.ownHurt, p)
				end
			else
				d.air = math.min(1, d.air + dt / REFILL_TIME)
			end
		end
		local torch = d.diving and settingOn("dive.blowtorch", true)
		if torch ~= (d.torch or false) then
			swapTools(d, p, torch)
			d.torch = torch
		end
		local stow = d.headIn and GetPlayerHealth(p) > 0 and not settingOn("dive.guns", false)
		if stow ~= (d.stowed ~= nil) then stowGuns(d, p, stow) end
		SetBool("dive.diving." .. p, d.diving)
		SetFloat("dive.air." .. p, d.air)
		SetFloat("dive.air.tank." .. p, tankTime(p, d))
		SetFloat("dive.gear." .. p, d.gearLen or 0)
		SetBool("dive.gear.worn." .. p, d.worn == true)
	end
	publishAt = publishAt - dt
	if publishAt <= 0 then
		publishAt = 0.1
		seq = seq + 1
		local air, diving, worn, gear = {}, {}, {}, {}
		for p, d in pairs(divers) do
			air[p] = d.air
			diving[p] = d.diving
			if d.worn then worn[p] = true end
			gear[p] = d.gearLen
		end
		shared.dive = {seq = seq, air = air, diving = diving, worn = worn, gear = gear}
	end
end

function Dive.serverTick(dt)
	for _, p in ipairs(GetRemovedPlayers()) do
		divers[p] = nil
	end
	-- the engine's drowning: no attacker, no push, head under water. The tank breathes for you while it has air; empty,
	-- the engine drowns you, unless dive.drown.time is set (serverUpdate drowns you then, 0 = never). Our own damage
	-- comes back here as an event too: keep it (d.ownHurt), undo only what goes below it.
	local own = HasKey("dive.drown.time")
	for i = 1, GetEventCount("playerhurt") do
		local victim, before, after, attacker, _, impulse = GetEvent("playerhurt", i)
		local d = divers[victim]
		if d and d.headIn and attacker == 0 and after < before and (not impulse or VecLength(impulse) < 0.001)
			and (d.air > 0 or own) then
			local keep = d.ownHurt and d.ownHurt < before and d.ownHurt or before
			if after < keep - 0.0001 then SetPlayerHealth(keep, victim) end
		end
	end
	tickGear(dt)
end

function gearLabel(seconds)
	if seconds >= 60 and seconds % 60 == 0 then return "Diver gear, " .. seconds / 60 .. " min" end
	return "Diver gear, " .. math.floor(seconds + 0.5) .. " s"
end

-- (hold: put it in the hands too - a pickup; the gear everyone starts with just goes into the wheel)
function giveGear(p, d, seconds, hold)
	d.gearLen = seconds
	SetToolEnabled(GEAR_TOOL, true, p)
	if hold ~= false then
		local held = GetPlayerTool(p)
		if held ~= GEAR_TOOL then d.toolBefore = held end
		SetPlayerTool(GEAR_TOOL, p)
	end
end

function takeGear(p, d)
	d.gearLen, d.worn = nil, false
	SetToolEnabled(GEAR_TOOL, false, p)
	if GetPlayerTool(p) == GEAR_TOOL then                         -- back to what they held before (if they still can)
		local back = d.toolBefore
		SetPlayerTool(back and back ~= "" and back ~= "none" and IsToolEnabled(back, p) and back or "none", p)
	end
end

-- What a player looks at to pick up (PICKUPS: diver gear, a harpoon gun, a spear rack, an air station): a body or shape tagged with one
-- (or one of its body's shapes), on the camera's ray (over the shoulder in third person) within GEAR_REACH of the eye.
-- Returns the body, the tag and its value (0, nil, 0 if none). Our own aim, prompt and E: the engine offers no
-- interact to a swimming player (verified in-game, 2026-11-03: GetPlayerInteractBody stayed 0 with the crosshair on
-- it). Server (the pickup) and client (the prompt) alike.
PICKUPS = {"divergear", "harpoon", "spearrack", "airfill"}

function pickupInView(p)
	local cam = GetPlayerCameraTransform(p)
	local dir = TransformToParentVec(cam, Vec(0, 0, -1))
	local eye = GetPlayerEyeTransform(p).pos
	QueryRejectPlayer(p)
	QueryRequire("physical")                                   -- (through the plants and fish: they don't collide)
	-- (as far as the eye plus the reach: a third-person camera can be metres behind)
	local hit, dist, _, shape = QueryRaycast(cam.pos, dir, VecLength(VecSub(eye, cam.pos)) + GEAR_REACH + 0.5)
	if not hit then return 0, nil, 0 end
	local b = GetShapeBody(shape)
	if b == 0 then return 0, nil, 0 end
	if VecLength(VecSub(VecAdd(cam.pos, VecScale(dir, dist)), eye)) > GEAR_REACH then return 0, nil, 0 end
	local shapes = GetBodyShapes(b)
	for _, tag in ipairs(PICKUPS) do
		local h = HasTag(b, tag) and b or HasTag(shape, tag) and shape
		for _, sh in ipairs(h and {} or shapes) do h = h or HasTag(sh, tag) and sh end
		if h then return b, tag, tonumber(GetTagValue(h, tag)) or 0 end
	end
	return 0, nil, 0
end

-- the diver gear a player looks at: its body and its tank's air time, s (0, 0 if none)
function gearInView(p)
	local b, tag, seconds = pickupInView(p)
	if tag ~= "divergear" or seconds <= 0 then return 0, 0 end
	return b, seconds
end

-- worn, a speed the game sets each frame (walking: also its swimming, which the game makes ~0.4 of it in water; jumps)
-- times k, from the game's own on land (GEAR_SPEEDS). A value set applies for one frame, so every frame. (The game's
-- own can't be read back reliably: GetPlayerParam gives 0 or an old value of ours after a set, and the speed after the
-- water's factor when wading or swimming - seen in-game, 2026-11-03)
function scaleParam(p, name, k)
	SetPlayerParam(name, GEAR_SPEEDS[name] * k, p)
end

-- The diver gear: taking it (E on it) puts the Diver gear tool in the wheel, for good (no dropping, not even on death:
-- few mods would expect a player to drop equipment); in the hands, the tool's use (LMB) puts it on or takes it off.
-- Worn (the tank on the back, flippers on the feet): the tank's air, faster swimming, slower on land.
function tickGear(dt)
	for b, at in pairs(airReady) do                              -- air stations back in service
		if GetTime() >= at then
			airReady[b] = nil
			if IsHandleValid(b) then RemoveTag(b, "spent") end
		end
	end
	for _, p in ipairs(GetAllPlayers()) do
		local d = divers[p]
		if d then
			if HasKey("dive.give.gear." .. p) then                       -- another mod hands out (or takes) diver gear
				local seconds = GetFloat("dive.give.gear." .. p)
				ClearKey("dive.give.gear." .. p)
				d.gearRevoked = seconds <= 0                              -- (taken away by a script: not given back)
				if seconds > 0 then giveGear(p, d, seconds) else takeGear(p, d) end
			end
			-- everyone has diver gear in the wheel (not worn) from the start and after every respawn: dive.gear.start
			-- seconds, 0 = none (a map that wants it found sets 0 and places pickups)
			local alive = GetPlayerHealth(p) > 0
			if alive and not d.gearLen and not d.gearRevoked and (not d.gearStarted or d.wasDead) then
				local start = setting("dive.gear.start", GEAR_START)
				if start > 0 then giveGear(p, d, start, false) end
			end
			if alive then d.gearStarted = true end
			d.wasDead = not alive
			if d.gearLen and GetPlayerTool(p) == GEAR_TOOL and GetPlayerHealth(p) > 0 then
				if pressed("usetool", p) then
					d.worn = not d.worn
					PlaySound(wearSound, GetPlayerTransform(p).pos, 0.8)
				end
			end
			-- the tool gone (a game mode takes every tool on death, or another mod took it): the gear too
			if d.gearLen and not IsToolEnabled(GEAR_TOOL, p) then d.gearLen, d.worn = nil, false end
			if d.worn and GetPlayerHealth(p) > 0 then
				if d.bodyIn then
					scaleParam(p, "walkingSpeed", setting("dive.gear.swim.speed", GEAR_SWIM_SPEED))
				else
					local k = setting("dive.gear.land.speed", GEAR_LAND_SPEED)
					scaleParam(p, "walkingSpeed", k)
					scaleParam(p, "jumpSpeed", 0.5 + 0.5 * k)
				end
			end
			if pressed("interact", p) and GetPlayerHealth(p) > 0 then
				local fb, fkind, fval = pickupInView(p)                  -- an air station (airfill=<seconds> spent after)
				if fkind == "airfill" and not airReady[fb] then
					d.air = 1
					if IsToolEnabled("blowtorch", p) and GetToolAmmo("blowtorch", p) < TORCH_FUEL then
						SetToolAmmo("blowtorch", TORCH_FUEL, p)                -- (and the cutting torch's oxygen)
					end
					airReady[fb] = GetTime() + math.max(1, fval)
					SetTag(fb, "spent")
					local lo, hi = GetBodyBounds(fb)
					PlaySound(hissSound, VecLerp(lo, hi, 0.5), 0.9, false, 0.7)
				end
				local b, seconds = gearInView(p)
				if b ~= 0 then
					local remain = HasTag(b, "remain")
					for _, sh in ipairs(GetBodyShapes(b)) do remain = remain or HasTag(sh, "remain") end
					giveGear(p, d, seconds)
					PlaySound(pickupSound, GetBodyTransform(b).pos, 1)
					if not remain then Delete(b) end
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- client

function Dive.clientInit()
	gearBodies = {}                                    -- player -> {tank, l, r}: the bodies of the gear they wear
	gearPivots = {}                                    -- body -> {off = its model's middle off its origin}: gearPart
	gearAnimators = {}                                 -- player -> the game's ToolAnimator for the gear in the hands
	frames = {}
	for f = 0, CAUSTIC_FRAMES - 1 do
		local fr = {}
		for a = 0, PERIOD - 1 do
			fr[a] = {}
			for b = 0, PERIOD - 1 do
				fr[a][b] = LoadSprite("MOD/images/caustic/" .. f .. "_" .. a .. "_" .. b .. ".png")
			end
		end
		frames[f + 1] = fr
	end
	cells = {}
	-- the sun's direction under water (Snell: refracted steeper). A map whose sun is "auto" (from its sky: most
	-- built-in maps) reads 0,0,0 here: then straight up for what blocks a cell (a roof, an overhang), and no live
	-- shadows of players and fish (the engine draws their real shadows; ours would land in the wrong place).
	local sx, sy, sz = GetEnvironmentProperty("sunDir")
	sun = Vec(0, 1, 0)
	sunKnown = false
	if type(sx) == "number" and type(sz) == "number" and math.abs(sy or 0) > 0.05 then
		local d = VecNormalize(Vec(sx, sy, sz))
		if d[2] < 0 then d = VecScale(d, -1) end
		local h = math.sqrt(d[1] * d[1] + d[3] * d[3])
		if h > 0.001 then
			local sinW = h / 1.33
			sun = Vec(d[1] / h * sinW, math.sqrt(1 - sinW * sinW), d[3] / h * sinW)
		end
		sunKnown = true
	end
	SetString("dive.sun", string.format("%.2f,%.2f,%.2f", sun[1], sun[2], sun[3]))
	others = {}
	bubbleSprite = LoadSprite("MOD/images/bubble.png")
	plainSprite = LoadSprite("MOD/images/plain.png")
	snd = {}
	for _, name in ipairs({"boom", "burst", "breath"}) do
		snd[name] = {}
		for i = 1, 3 do snd[name][i] = LoadSound("MOD/snd/" .. name .. i .. ".ogg") end
	end
	noiseAt = 0
	bubbles = {}
	breathAt = {}
	streams = {}
	streamAt = 0
	look = {
		brightness = GetPostProcessingProperty("brightness"),
		saturation = GetPostProcessingProperty("saturation"),
		colorbalance = {GetPostProcessingProperty("colorbalance")},
	}
	tinted = false
	lamp = false        -- the flashlight's own intensity (underwaterLook)
	camDepth = 0
	camUnder = false
	camTop = 200
	lastSweep = 0
end

-- The caustics' rays: not the fish, not the players (they cast their shadows live, in drawCaustics).
function causticRay(from, dir, dist)
	QueryCollisionMask(255 - FISH_LAYER)
	for _, p in ipairs(others) do QueryRejectPlayer(p) end
	return QueryRaycast(from, dir, dist)
end

function down(x, y, z, dist)
	return causticRay(Vec(x, y, z), Vec(0, -1, 0), dist)
end

-- What the sun reaches in a 1 m cell: the first thing straight below the water surface (a roof, not the room below
-- it; a crate top, not the floor beside it). The cell's sprite lies on the plane through its four corners, so it
-- follows slopes and sits on top of things; a cell across an edge (corners at different heights) gets none.
function lookupCell(ix, iz, now)
	local c = {at = now + REFRESH * (0.75 + 0.5 * math.random()), ix = ix, iz = iz}
	local x, z = ix + 0.5, iz + 0.5
	local wet, _, surf = QueryRaycastWater(Vec(x, camTop, z), Vec(0, -1, 0), 400)
	if not wet then return c end
	local y0 = surf[2] - 0.05
	local h = {}
	for i, o in ipairs({{-0.45, -0.45}, {0.45, -0.45}, {-0.45, 0.45}, {0.45, 0.45}}) do
		local hit, dist, _, shape = down(x + o[1], y0, z + o[2], 80)
		if not hit then return c end
		h[i] = y0 - dist
		if IsBodyDynamic(GetShapeBody(shape)) then c.at = now + 0.5 end
	end
	local hx = (h[2] + h[4] - h[1] - h[3]) / 1.8      -- slope along x and z
	local hz = (h[3] + h[4] - h[1] - h[2]) / 1.8
	local mid = (h[1] + h[2] + h[3] + h[4]) / 4
	if math.abs(h[1] + h[4] - h[2] - h[3]) > 0.1 or math.abs(hx) > 1 or math.abs(hz) > 1 then return c end
	local n = VecNormalize(Vec(-hx, 1, -hz))
	local ex = VecNormalize(Vec(1, hx, 0))
	c.pos = VecAdd(Vec(x, mid, z), VecScale(n, 0.02))
	c.rot = QuatAlignXZ(ex, VecScale(n, -1))          -- (flat: the same as QuatEuler(90, 0, 0))
	c.depth = surf[2] - mid
	-- in the shadow of something between it and the sun (a wall, a hull, an overhang): only a little light
	c.shade = causticRay(VecAdd(c.pos, VecScale(n, 0.05)), sun, (surf[2] - mid) / sun[2]) and 0.15 or 1
	return c
end

-- Sprites skip the engine's underwater fog, so fade them the way it fogs: fully gone at the visibility distance,
-- along its square-root curve. Deeper floors get less light (and fewer, softer caustics). Shadows: what stands in
-- the sun is found when a cell is looked up; players and fish schools move, so their shadows are worked out every
-- frame: each caster's shadow centre on a cell's height, along the sun.
function drawCaustics(cam, now, vis)
	local light = 0.45 * setting("dive.caustics", 1)
	local fr = frames[math.floor(now * CAUSTIC_FPS) % CAUSTIC_FRAMES + 1]
	local cx, cz = math.floor(cam[1]), math.floor(cam[3])
	local casters = {}
	for _, p in ipairs(sunKnown and others or {}) do
		local feet = GetPlayerTransform(p).pos
		casters[#casters + 1] = {feet[1], feet[2] + 0.5, feet[3], 0.5, 0.2}      -- {x, y, z, radius, light left}
		casters[#casters + 1] = {feet[1], feet[2] + 1.3, feet[3], 0.45, 0.2}
	end
	for _, f in ipairs(sunKnown and Fish.centres() or {}) do
		casters[#casters + 1] = {f[1], f[2], f[3], 1.3, 0.55}
	end
	local tx, tz = sun[1] / sun[2], sun[3] / sun[2]
	local budget = LOOKUPS
	for ix = cx - REACH, cx + REACH do
		for iz = cz - REACH, cz + REACH do
			local hx, hz = ix + 0.5 - cam[1], iz + 0.5 - cam[3]
			local flat = math.sqrt(hx * hx + hz * hz)
			if flat < REACH then
				local key = ix .. "," .. iz
				local c = cells[key]
				if (not c or c.at < now) and budget > 0 then
					budget = budget - 1
					c = lookupCell(ix, iz, now)
					cells[key] = c
				end
				if c and c.pos then
					local dy = c.pos[2] - cam[2]
					local d = math.sqrt(flat * flat + dy * dy)
					local fog = 1 - math.sqrt(math.min(1, d / vis))
					local edge = math.min(1, (1 - flat / REACH) * 3)
					local a = light * math.exp(-c.depth / 12) * fog * edge * c.shade
					local y = c.pos[2]
					for i = 1, #casters do
						local k = casters[i]
						local up = k[2] - y
						if up > 0 then
							local ddx, ddz = c.pos[1] - (k[1] - tx * up), c.pos[3] - (k[3] - tz * up)
							local d2 = ddx * ddx + ddz * ddz
							if d2 < k[4] * k[4] then a = a * (k[5] + (1 - k[5]) * d2 / (k[4] * k[4])) end
						end
					end
					if a > 0.01 then
						DrawSprite(fr[ix % PERIOD][iz % PERIOD], Transform(c.pos, c.rot), 1, 1, 0.75, 0.93, 1.0, a, true, true)
					end
				end
			end
		end
	end
end

-- Bubbles: a diver breathes out every few seconds; now and then a thin stream rises from the floor near the camera.
function addBubble(pos, size)
	if #bubbles < 300 then
		bubbles[#bubbles + 1] = {pos = pos, size = size, vy = 0.4 + math.random() * 0.4, ph = math.random() * 6.28, t = 0}
	end
end

-- Our own sounds don't register as noise (registerVolume false): no burst set off by a burst.
function play(name, pos, vol)
	local list = snd[name]
	PlaySound(list[math.random(#list)], pos, vol, false, 0.9 + math.random() * 0.2)
end

-- A loud noise in the water (the loudest sound the engine played last frame) bursts into bubbles there.
function noises(now)
	local vol, pos = GetLastSound()
	if vol < LOUD or now < noiseAt or not IsPointInWater(pos) then return end
	noiseAt = now + 0.25
	local big = vol >= BIG
	local r = big and 0.9 or 0.25
	for _ = 1, big and 60 or 14 do
		addBubble(VecAdd(pos, Vec((math.random() - 0.5) * r, (math.random() - 0.5) * r, (math.random() - 0.5) * r)),
			big and 0.03 + math.random() * 0.1 or 0.02 + math.random() * 0.05)
	end
	if camUnder then play(big and "boom" or "burst", pos, big and 1 or 0.7) end
end

function updateBubbles(dt, cam, camRot, now, vis)
	local d = shared.dive
	if d and d.diving then
		for p, diving in pairs(d.diving) do
			if diving then
				breathAt[p] = breathAt[p] or now + math.random() * 3
				if now > breathAt[p] then
					breathAt[p] = now + 2.5 + math.random() * 2
					local head = TransformToParentPoint(GetPlayerEyeTransform(p), Vec(0, 0.05, -0.25))
					if camUnder then play("breath", head, 0.6) end
					for _ = 1, 6 + math.random(6) do
						addBubble(VecAdd(head, Vec((math.random() - 0.5) * 0.15, math.random() * 0.2, (math.random() - 0.5) * 0.15)),
							0.02 + math.random() * 0.05)
					end
				end
			end
		end
	end
	if camUnder and now > streamAt then
		streamAt = now + 0.6 + math.random() * 1.2
		local x, z = cam[1] + (math.random() - 0.5) * 24, cam[3] + (math.random() - 0.5) * 24
		local wet, _, surf = QueryRaycastWater(Vec(x, camTop, z), Vec(0, -1, 0), 400)
		if wet then
			local hit, dist = down(x, surf[2] - 0.05, z, 80)
			if hit then
				streams[#streams + 1] = {pos = Vec(x, surf[2] - 0.05 - dist + 0.05, z), left = 1 + math.random() * 2.5, at = 0}
			end
		end
	end
	for i = #streams, 1, -1 do
		local s = streams[i]
		s.left = s.left - dt
		s.at = s.at - dt
		if s.at <= 0 then
			s.at = 0.06 + math.random() * 0.12
			addBubble(VecAdd(s.pos, Vec((math.random() - 0.5) * 0.06, 0, (math.random() - 0.5) * 0.06)), 0.015 + math.random() * 0.03)
		end
		if s.left <= 0 then table.remove(streams, i) end
	end
	for i = #bubbles, 1, -1 do
		local b = bubbles[i]
		b.t = b.t + dt
		b.vy = math.min(1.6, b.vy + dt * 0.6)
		local wob = math.sin(b.t * 9 + b.ph) * 0.25
		b.pos = VecAdd(b.pos, Vec(wob * dt, b.vy * dt, math.cos(b.t * 7 + b.ph) * 0.25 * dt))
		if b.t > 30 or not IsPointInWater(b.pos) then
			table.remove(bubbles, i)
		else
			local dist = VecLength(VecSub(b.pos, cam))
			local fog = 1 - math.sqrt(math.min(1, dist / vis))
			if fog > 0 and camUnder then
				local s = b.size * (1 + 0.15 * math.sin(b.t * 13 + b.ph))
				DrawSprite(bubbleSprite, Transform(b.pos, camRot), s * 2, s * 2, 0.85, 0.95, 1, 0.8 * fog, true, true)
			end
		end
	end
end

-- Deeper is darker and bluer: red goes first, then the light. (Auto-exposure undoes darkening the sky; this is after it.)
-- Deeper is darker: the light falls off as exp(-depth / DARK_DEPTH) (half at 5.5 m, a tenth at 18 m, black but for a
-- flashlight past ~25 m), bluer, a little greyer (not much: the engine already blurs the view under water, and more
-- murk on top read as haze). The whole picture is darkened (a client can't dim the sun for one player), so the
-- flashlight is made brighter by as much: it lights things as it would on land.
function underwaterLook()
	local fl = GetFlashlight()
	if camUnder then
		local strength = math.max(0, setting("dive.look", 1))
		local k = (1 - math.exp(-camDepth / 18)) * strength
		-- (the brightness filter: dive.filter, off by default since the depth sheets - the user's choice, 2026-11-03)
		local filter = math.max(0, setting("dive.filter", 0))
		local dark = math.max(DARK_MIN, math.exp(-camDepth * strength * filter / DARK_DEPTH))
		local cb = look.colorbalance
		SetPostProcessingProperty("brightness", look.brightness * dark)
		SetPostProcessingProperty("saturation", look.saturation * (1 - 0.15 * k))
		SetPostProcessingProperty("colorbalance", cb[1] * (1 - 0.6 * k), cb[2] * (1 - 0.25 * k), cb[3])
		if fl ~= 0 then
			if not lamp or lamp.handle ~= fl then
				lamp = {handle = fl, intensity = GetProperty(fl, "intensity")}
			end
			SetLightIntensity(fl, lamp.intensity / dark)
		end
		tinted = true
	elseif tinted then
		local cb = look.colorbalance
		SetPostProcessingProperty("brightness", look.brightness)
		SetPostProcessingProperty("saturation", look.saturation)
		SetPostProcessingProperty("colorbalance", cb[1], cb[2], cb[3])
		if lamp and IsHandleValid(lamp.handle) then SetLightIntensity(lamp.handle, lamp.intensity) end
		tinted = false
	end
end

-- Deeper is darker for what you look DOWN at, too: dark see-through sheets lie flat under the surface every LAYER_STEP,
-- each as dark as that much water (exp(-step / DARK_DEPTH), as the picture's own darkening by the camera's depth),
-- drawn only below the camera (the one just below thinner by how far it is: no pop when you pass it). So from the
-- surface, or looking down from mid-water, the floor is as dark as its own depth; looking ahead they are edge-on, and
-- a flashlight's beam doesn't cross them. (The real light can't be shaped: a shape tagged invisible doesn't block it,
-- verified 2026-11-03.) The surface: the camera's depth, or a ray down to the water from above it.
function depthLayers(cam, under, depth)
	local strength = math.max(0, setting("dive.look", 1))
	if strength <= 0 then return end
	local surf
	if under then
		surf = cam[2] + depth
	else
		local hit, d = QueryRaycastWater(cam, Vec(0, -1, 0), 60)
		if hit then surf = cam[2] - d end
	end
	if not surf then return end
	local flat = QuatEuler(-90, 0, 0)
	for i = 1, math.floor(LAYER_DEPTH / LAYER_STEP) do
		local y = surf - i * LAYER_STEP + LAYER_OFFSET
		local thick = math.min(LAYER_STEP, cam[2] - y)
		if thick > 0 then
			local a = 1 - math.exp(-thick * strength / DARK_DEPTH)
			DrawSprite(plainSprite, Transform(Vec(cam[1], y, cam[3]), flat), LAYER_SIZE, LAYER_SIZE, 0, 0.015, 0.03, a, true, false)
		end
	end
end

function Dive.clientTick(dt)
	local now = GetTime()
	-- the Diver gear in the hands: posed by the game's toolanimation.lua from its prefab (carried at the side, hanging
	-- down: barely following the view's pitch)
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerTool(p) == GEAR_TOOL then
			local a = gearAnimators[p]
			if not a then
				a = ToolAnimator()
				a.armPitchScale, a.toolPitchScale = 0.25, 0
				gearAnimators[p] = a
			end
			tickToolAnimator(a, dt, nil, p)
		end
	end
	local camT = GetCameraTransform()
	local cam = camT.pos
	camTop = cam[2] + 200
	camUnder, camDepth = IsPointInWater(cam)
	others = GetAllPlayers()
	local vis = math.max(0.5, setting("dive.visibility", VISIBILITY))
	if camUnder and setting("dive.caustics", 1) > 0 then drawCaustics(cam, now, vis) end
	noises(now)
	updateBubbles(dt, cam, camT.rot, now, vis)
	underwaterLook()
	depthLayers(cam, camUnder, camDepth)
	if math.floor(now) ~= lastSweep then             -- forget cells far behind
		lastSweep = math.floor(now)
		local cx, cz = math.floor(cam[1]), math.floor(cam[3])
		for key, c in pairs(cells) do
			if math.abs(c.ix - cx) > REACH + 4 or math.abs(c.iz - cz) > REACH + 4 then cells[key] = nil end
		end
	end
end

-- the diver gear worn: the tank on the back, a flipper on each foot. Each machine draws its own, on the character as it
-- is drawn: the bone bodies, right before the frame (GetBoneWorldTransform gives the upright pose, not the swim pose's:
-- the tank went through a swimmer's head, 2026-11-03). A flipper lies along foot -> toes, past the toes
-- t is where the part's middle goes. An odd-width model is drawn half a voxel off its body's origin (the tank sat 2.5 cm
-- to one side, measured in-game 2026-11-03): that offset is read off the part as drawn (its shape's middle, in the
-- body's frame, from the frame before) and taken back
function gearPart(p, key, file, t)
	local g = gearBodies[p]
	local b = g[key]
	if not b or not IsHandleValid(b) then
		b = 0
		for _, e in ipairs(Spawn("<body><vox file='MOD/vox/" .. file .. ".vox' scale='0.5' collide='false'/></body>", t, true)) do
			if GetEntityType(e) == "body" then b = e end
		end
		g[key] = b
	end
	if b == 0 then return end
	local pv = gearPivots[b]                                    -- (per body: g holds only the part bodies)
	if not pv then
		pv = {from = GetTime() + 0.1}
		gearPivots[b] = pv
	end
	if not pv.off and GetTime() > pv.from then                -- (not in its spawn frame: its shape reads wrong then)
		local sh = GetBodyShapes(b)[1]
		if sh then
			local lo, hi = GetShapeBounds(sh)
			local off = TransformToLocalPoint(GetBodyTransform(b), VecLerp(lo, hi, 0.5))
			if VecLength(off) < 0.1 then pv.off = off end
		end
	end
	local off = pv.off
	SetBodyTransform(b, off and TransformToParentTransform(t, Transform(VecScale(off, -1))) or t)
end

function Dive.clientRender()
	local worn = shared.dive and shared.dive.worn or {}
	for p, g in pairs(gearBodies) do
		if not worn[p] then
			for _, b in pairs(g) do
				if IsHandleValid(b) then Delete(b) end
				gearPivots[b] = nil
			end
			gearBodies[p] = nil
		end
	end
	for p in pairs(worn) do
		local anim = GetPlayerAnimator(p)
		local chest = anim ~= 0 and GetBoneBody(anim, "chest") or 0
		if chest ~= 0 then
			gearBodies[p] = gearBodies[p] or {}
			-- (the tank's frame from the body as drawn: up the spine, sideways along the shoulders, back square to both,
			-- centred between the shoulders. In the chest bone's own frame it hung to one side when swimming: the swim
			-- pose rolls the chest about the spine, and its "back" axis went partly sideways)
			local ct = GetBodyTransform(chest)
			local up = TransformToParentVec(ct, Vec(1, 0, 0))
			local sl, sr = GetBoneBody(anim, "shoulder_l"), GetBoneBody(anim, "shoulder_r")
			local t = TransformToParentTransform(ct, BACK)
			if sl ~= 0 and sr ~= 0 then
				local a, b = GetBodyTransform(sl).pos, GetBodyTransform(sr).pos
				local across = VecSub(b, a)
				across = VecNormalize(VecSub(across, VecScale(up, VecDot(across, up))))
				local back = VecNormalize(VecCross(across, up))
				if VecDot(back, TransformToParentVec(ct, Vec(0, -1, 0))) < 0 then back = VecScale(back, -1) end
				local mid = VecLerp(a, b, 0.5)
				local base = VecAdd(ct.pos, VecScale(across, VecDot(VecSub(mid, ct.pos), across)))
				-- the model's long axis (its local y) up the spine: local x across, z back (or x the other way round)
				local x = VecDot(VecCross(back, across), up) > 0 and across or VecScale(across, -1)
				t = Transform(VecAdd(base, VecScale(back, BACK_OUT)), QuatAlignXZ(x, back))
			end
			gearPart(p, "tank", "airtank", t)
			for _, side in ipairs({"l", "r"}) do
				local foot, toes = GetBoneBody(anim, "foot_" .. side), GetBoneBody(anim, "toes_" .. side)
				if foot ~= 0 and toes ~= 0 then
					-- (foot -> toes with most of its slope taken out: standing, the toes point ~30 degrees down and the tips
					-- dug into the floor; swimming, the feet stretch back about level anyway)
					local a, b = GetBodyTransform(foot).pos, GetBodyTransform(toes).pos
					local d = VecSub(b, a)
					local along = VecNormalize(Vec(d[1], d[2] * FIN_SLOPE, d[3]))
					local at = VecAdd(VecAdd(b, VecScale(along, FIN_AHEAD)), Vec(0, -FIN_DOWN, 0))
					-- (the model's tip, high vox y, comes out on the game's +z: look the other way - verified in-game)
					gearPart(p, side, "flipper", Transform(at, QuatLookAt(at, VecSub(at, along))))
				end
			end
		end
	end
end

function Dive.clientDraw()
	local me = GetLocalPlayer()
	local d = shared.dive
	local pb, kind, value = pickupInView(me)                  -- looking at something to pick up
	local prompt = kind == "divergear" and value > 0 and "E: pick up " .. gearLabel(value)
		or kind == "harpoon" and "E: pick up Harpoon gun"
		or kind == "spearrack" and (HasTag(pb, "spent") and "Spear rack: empty for now" or "E: take spears")
		or kind == "airfill" and (HasTag(pb, "spent") and "Air station: empty for now" or "E: fresh air")
	if prompt then
		UiPush()
			UiTranslate(UiCenter(), UiMiddle() + 60)
			UiAlign("center middle")
			UiFont("bold.ttf", 24)
			UiColor(1, 1, 1, 0.9)
			UiText(prompt)
		UiPop()
	end
	if GetPlayerTool(me) == GEAR_TOOL and d and d.gear and d.gear[me] then   -- the gear in the hands: what the keys do
		UiPush()
			UiTranslate(UiCenter(), UiHeight() - 170)
			UiAlign("center middle")
			UiFont("bold.ttf", 22)
			UiColor(1, 1, 1, 0.85)
			UiText((d and d.worn and d.worn[me]) and "LMB: take the diver gear off" or "LMB: put the diver gear on")
		UiPop()
	end
	local air = d and d.air and d.air[me] or 1
	local diving = d and d.diving and d.diving[me]
	if not (camUnder or diving or air < 0.999) then return end
	UiPush()
		UiTranslate(UiWidth() - 60, UiHeight() - 340)
		UiAlign("center bottom")
		UiColor(0, 0, 0, 0.5)
		UiRect(26, 206)
		UiTranslate(0, -3)
		if air < 0.25 then UiColor(1, 0.3, 0.2, 0.9) else UiColor(0.5, 0.85, 1, 0.9) end
		UiRect(20, 200 * air)
		UiTranslate(0, 30)
		UiFont("bold.ttf", 20)
		UiColor(1, 1, 1, 0.9)
		UiText("AIR")
		if camUnder then
			UiTranslate(0, 24)
			UiText(string.format("%.1f m", camDepth))
		end
	UiPop()
	if not diving and IsPointInWater(VecAdd(GetPlayerTransform(me).pos, Vec(0, 0.8, 0))) then
		UiPush()
			UiTranslate(UiCenter(), UiHeight() - 120)
			UiAlign("center middle")
			UiFont("bold.ttf", 22)
			UiColor(1, 1, 1, 0.8)
			UiText("Crouch to dive")
		UiPop()
	end
end
