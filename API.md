# Underwater Exploration: settings for other mods and maps

Underwater Exploration ("Dive" in its keys and below: the mod's working name) reads its settings from the game's
registry, so any mod or map script can change them while the game runs,
with a plain `SetFloat` / `SetBool`. Every setting is optional: if no script has written a key, Dive uses the map's
tag on its `<water>` (where one is listed), else the default.

## Where to set them

- **Host settings** (air, swimming, buoyancy) are read by Dive's server script: set them from your **server** script.
- **Settings for each player** (visibility, fish, seaweed, corals, caustics) are read on every player's machine: set
  them from your server script with `sync = true` (the third argument), and every player gets them:

```lua
SetFloat("dive.visibility", 8, true)   -- murky water for everyone
SetFloat("dive.fish", 3, true)         -- three times the fish
```

  A client script can also set them for its own player only (no `sync`).

To go back to the default, `ClearKey(key)` (with the sync on every machine: clear it from a client script too).

## Host settings

| key | type | default | what it does |
|---|---|---|---|
| `dive.disabled` | bool | false | no diving (the game's own swimming only) |
| `dive.drown.time` | float, s | the game's (~5 s) | out of air: seconds until dead (from full health); 0 = never drowns |
| `dive.give.air.<player>` | float, 0..1 | - | sets that player's tank once (an air pickup), then Dive clears the key |
| `dive.air.time` | float, s | 45 | how long the air lasts under water (without diver gear) |
| `dive.air.time.<player>` | float, s | - | that player's tank only (a class, a perk); beats the diver gear they wear. `ClearKey` to go back |
| `dive.give.harpoon.<player>` | int, spears | - | gives that player the Harpoon gun with that many spears (or fills theirs); 0 takes it away. Dive clears the key |
| `dive.guns` | bool | false | true: the game's guns (pistol, shotgun, rifle, rocket launcher) work under water; false: they leave the wheel while the head is under and come back at the surface |
| `dive.gear.start` | float, s | 180 | the diver gear everyone has in the wheel from the start and after a respawn; 0 = only from pickups |
| `dive.give.gear.<player>` | float, s | - | gives that player Diver gear whose tank holds that many seconds of air (into their tool wheel, held, not yet worn); 0 takes theirs away. Dive clears the key |
| `dive.gear.swim.speed` | float, x | 1.5 | swimming speed with the gear worn, diving and at the surface; 1 = no boost |
| `dive.gear.land.speed` | float, x | 0.6 | walking speed with the gear worn out of the water (x the game's); jumps are cut half as much; 1 = no penalty |
| `dive.swim.speed` | float, m/s | 3 | diving swim speed |
| `dive.blowtorch` | bool | true | false: diving doesn't swap the sledgehammer for the blowtorch |
| `dive.buoyancy.disabled` | bool | false | the game's own floating instead of Dive's per-object buoyancy |

The tank lasts 45 s under water (`dive.air.time`) and refills in 4 s with the head above water. The game drowns a player whose head
has been under water for about 10 s; while their tank has air, Dive undoes it.

## Diver gear

Every player has **Diver gear** (an air tank and flippers) in their tool wheel from the start and after every respawn,
not worn: `dive.gear.start` seconds (180; 0 = none: a map that wants it found sets 0). More (or bigger tanks) come
from pickups: any object tagged `divergear=<seconds>` is one:
looking at it from up to about 2.5 m, players see "E: pick up Diver gear, 4 min", on land and under water (Dive's own
prompt: the game offers no interact to a swimming player). Taking it puts a **Diver gear** tool in their wheel, in
their hands. Holding it, the left mouse button puts it on or takes it off; it stays on whatever they hold. Worn:

- a full tank lasts that many seconds (not worn: `dive.air.time`, 45 s);
- they swim faster, diving and at the surface (`dive.gear.swim.speed`, x 1.5);
- out of the water the flippers slow them down (`dive.gear.land.speed`: walking x 0.6, jumps x 0.8).

Everyone sees the tank on the diver's back and the flippers on their feet.

The gear stays with the player: there is no dropping, not even on death. A newer pickup replaces it (its tank's air time). If
another script takes the tool away (the game's multiplayer modes take every tool on death), the gear goes with it.

The object can be anything: put the tag on a `<vox>` or a `<body>` in your map
(`<vox tags="divergear=240" prop="true" file="MOD/vox/bottle.vox"/>`), or spawn one from a script. Taking it deletes
it; with the tag `remain` too, it stays for the next player (a station that hands out gear). (A loose object needs
full-size voxels: a `<vox scale="0.5">` makes its body static.)

The spawn menu has one ready to use: **Underwater > Diver gear (3 min)**, a yellow scuba cylinder with a pair of
flippers, that sinks to the floor.

## Harpoon gun, spear racks, air stations

The **Harpoon gun** is the gun that works under water (the game's own guns don't: `dive.guns`). Players get it from a
pickup: anything tagged `harpoon=<spears>` (the spawn menu's **Underwater > Harpoon gun** holds 6; with `remain` it
stays for the next player), taken with E, or from a script (`dive.give.harpoon.<player>`). It stays with the player,
as the diver gear does. A map that wants every diver armed gives it from its script when a player joins and when
they respawn. It fires spears (6 a gun, 1.2 s apart, 40 m) that stick in what they hit for 20 s, and it hurts the
Abyssipede (the Bobbit Worm mod's `abyssipede.hitpoints` / `abyssipede.damage`).

- **Spear racks**: anything tagged `spearrack`. E with spears missing fills the gun; the rack is then tagged `spent`
  for 20 s.
- **Air stations**: anything tagged `airfill=<seconds>`. E fills the tank and the blowtorch's fuel (to 30: a cutting
  torch needs oxygen); the station is tagged `spent` for that many seconds ("Air station: empty for now").

Both work under water (Dive's own aim and prompt, as for the gear).

## Settings for each player

| key | water tag | type | default | what it does |
|---|---|---|---|---|
| `dive.visibility` | `visibility=<m>` | float, m | 5 | how far you see under water, for Dive's light, bubbles, fish and plants (see below) |
| `dive.fish` | `fish=<x>` | float, x | 1 | how many fish (1 = six schools around each player); 0 = none |
| `dive.seaweed` | `seaweed=<x>` | float, x | 1 | how much kelp and seagrass; 0 = none |
| `dive.corals` | `corals=<x>` | float, x | 1 | how many corals and sponges; 0 = none |
| `dive.caustics` | - | float, x | 1 | the brightness of the rippling light on the floor; 0 = off |
| `dive.look` | - | float, x | 1 | how fast it gets darker (and bluer) with depth: 1 = half the light at 5.5 m, a tenth at 18 m, flashlight only past ~25 m; 2 = twice as fast; 0 = the game's own look only |
| `dive.filter` | - | float, x | 0 | the old darkening of the whole picture by the camera's depth on top (1 = on; it darkens a flashlight's light too, made up for by a stronger flashlight); off, the depth sheets darken only what you look down at |

A change to the seaweed or corals regrows the floor around each player within about a second.

**Visibility:** the game's real underwater fog is the `visibility` attribute of the map's `<water>`, and a script
can't change it on an existing water (nor read it). Dive's `dive.visibility` makes Dive's own effects match the water.
A map that wants murkier or clearer water at runtime can spawn a replacement `<water>` with the new `visibility`
(same shape) and delete the old one: that works. A map should also tag its water with the same value:
`<water tags="visibility=15" visibility="15" ...>`.

## What Dive tells other mods (host)

| key | type | |
|---|---|---|
| `dive.diving.<player>` | bool | the player is diving |
| `dive.air.<player>` | float, 0..1 | air left in the tank |
| `dive.air.tank.<player>` | float, s | how long that player's full tank lasts (seconds of air left = this x `dive.air.<player>`) |
| `dive.gear.<player>` | float, s | the air time of the diver gear they carry (its tank, s); 0 = none |
| `dive.gear.worn.<player>` | bool | they wear it |

## Map tags

- On a loose body: `buoyancy=<m/s>` (up is positive; 0 hangs still).
- On a body or shape: `divergear=<seconds>` (and `remain`): a diver gear pickup (above).
- On a body or shape: `harpoon=<spears>` (and `remain`): a harpoon gun pickup; `spearrack`: a spear rack;
  `airfill=<seconds>`: an air station (above).
- `<location tags="fishschool=<count> fish=<silver|gold>"/>`: a school that stays at that spot.
