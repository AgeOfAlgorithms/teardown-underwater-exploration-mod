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
| `dive.swim.speed` | float, m/s | 3 | diving swim speed |
| `dive.blowtorch` | bool | true | false: diving doesn't swap the sledgehammer for the blowtorch |
| `dive.buoyancy.disabled` | bool | false | the game's own floating instead of Dive's per-object buoyancy |

The tank lasts 60 s under water and refills in 4 s with the head above water. The game drowns a player whose head
has been under water for about 10 s; while their tank has air, Dive undoes it.

## Settings for each player

| key | water tag | type | default | what it does |
|---|---|---|---|---|
| `dive.visibility` | `visibility=<m>` | float, m | 5 | how far you see under water, for Dive's light, bubbles, fish and plants (see below) |
| `dive.fish` | `fish=<x>` | float, x | 1 | how many fish (1 = six schools around each player); 0 = none |
| `dive.seaweed` | `seaweed=<x>` | float, x | 1 | how much kelp and seagrass; 0 = none |
| `dive.corals` | `corals=<x>` | float, x | 1 | how many corals and sponges; 0 = none |
| `dive.caustics` | - | float, x | 1 | the brightness of the rippling light on the floor; 0 = off |
| `dive.look` | - | float, x | 1 | how fast it gets darker (and bluer) with depth: 1 = half the light at 5.5 m, a tenth at 18 m, flashlight only past ~25 m; 2 = twice as fast; 0 = the game's own look only |

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

## Map tags

- On a loose body: `buoyancy=<m/s>` (up is positive; 0 hangs still).
- `<location tags="fishschool=<count> fish=<silver|gold>"/>`: a school that stays at that spot.
