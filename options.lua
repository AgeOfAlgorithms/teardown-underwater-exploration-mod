-- Underwater Exploration's options (Mod Manager). The host's choices count for everyone in a session (main.lua
-- publishOptions sends them to every machine as dive.opt.fish / .seaweed / .corals); they are the only control of
-- the amounts (maps and other mods can't set them: the user, 2026-11-21).
-- savegame.mod.fish (1..6), .seaweed and .corals (1..5): the steps are main.lua's OPTION_STEPS.

local ROWS = {
	{key = "fish", label = "Schools of fish", names = {"Off", "Few", "Normal", "More", "Lots", "Swarm"},
		hints = {"no roaming fish", "half the schools", "six schools around each player", "twice as many",
			"four times as many", "eight times as many"}},
	{key = "seaweed", label = "Kelp and seagrass", names = {"Off", "Less", "Normal", "More", "Lots"},
		hints = {"none", "half as much", "the usual amount", "twice as much", "three times as much"}},
	{key = "corals", label = "Corals and sponges", names = {"Off", "Less", "Normal", "More", "Lots"},
		hints = {"none", "half as many", "the usual amount", "twice as many", "three times as many"}},
}

local function row(r, y)
	local cur = GetInt("savegame.mod." .. r.key)
	if cur < 1 or cur > #r.names then cur = 3 end
	UiPush()
	UiTranslate(0, y)
	UiFont("regular.ttf", 28)
	UiColor(1, 1, 1)
	UiText(r.label)
	UiTranslate(0, 52)
	UiFont("bold.ttf", 30)
	for i, name in ipairs(r.names) do
		UiPush()
		UiTranslate((i - (#r.names + 1) / 2) * 150, 0)
		if i == cur then UiColor(0.45, 0.85, 1) else UiColor(0.55, 0.55, 0.55) end
		if UiTextButton(name, 135, 46) then SetInt("savegame.mod." .. r.key, i) end
		UiPop()
	end
	UiTranslate(0, 45)
	UiFont("regular.ttf", 22)
	UiColor(0.8, 0.8, 0.8)
	UiText(r.hints[cur])
	UiPop()
end

function draw()
	UiTranslate(UiCenter(), 70)
	UiAlign("center middle")
	UiFont("bold.ttf", 48)
	UiColor(1, 1, 1)
	UiText("Underwater Exploration")
	for n, r in ipairs(ROWS) do row(r, 90 + (n - 1) * 170) end
	UiTranslate(0, 600)
	UiFont("regular.ttf", 22)
	UiColor(0.7, 0.7, 0.7)
	UiText("In multiplayer the host's choices count for everyone, on every map.")
	UiTranslate(0, 30)
	UiText("Lots and Swarm can cost frame rate under water.")
	UiTranslate(0, 80)
	UiColor(1, 1, 1)
	UiFont("bold.ttf", 32)
	if UiTextButton("Close", 200, 50) then Menu() end
end
