-- LibBenisScore: stat weights and item scores, shared by BenisAH and BenisUI.
--
-- Embedded in every addon that uses it; LibStub runs the newest copy only, so
-- keep the API backward compatible and raise MINOR with every change.
--
-- An item's score is the sum of its stats times the weights, plus weapon DPS
-- times the DPS weight (melee and ranged apart) and (speed - 2.0) times the
-- speed weight. The weights come from per spec presets and can be edited.
--
-- Settings live in the hosts' per character saved variables: every host
-- registers a table, every change is written to all of them with a time, and
-- at login the newest one wins. So the hosts agree, and any one alone works.
--
-- API
--   lib:Register(store)          a SavedVariablesPerCharacter table of the host
--   lib:Score(link)              score, info ({ usable, dps, speed, ranged })
--   lib:Compare(link)            what the item would replace, see Compare
--   lib:GetWeights()             [stat key] = weight (read only)
--   lib:SetWeight(key, value)
--   lib:ApplyPreset(key) / lib:ApplyWeaponChoice(choice)
--   lib:RegisterCallback(owner, fn) / lib:UnregisterCallback(owner)
--                                fn() runs after any change of the weights
--   lib:CreateWeightsPanel(parent) a frame with presets, weapon buttons, weights
--   lib:ToggleWindow()           the same panel in a window of its own (/bscore)
--   tooltip owners with .benisScoreNoLine = true get no upgrade line

local MAJOR, MINOR = 'LibBenisScore-1.0', 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.stores = lib.stores or {}
lib.callbacks = lib.callbacks or {}
lib.cache = {} -- [item link] = { score, info }, dropped on every change
lib.panels = lib.panels or {}

local EPSILON = 0.001
local BASE_SPEED = 2.0 -- weapons slower than this get a bonus, faster ones a malus
local WEAPON_CLASS = 2
local WAND_SUBCLASS = 19
-- bow, gun, thrown, crossbow, wand: scored with the ranged DPS weight
local RANGED_SUBCLASSES = { [2] = true, [3] = true, [16] = true, [18] = true, [19] = true }

local GetItemStats = C_Item and C_Item.GetItemStats or GetItemStats
local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant

--------------------------------------------------------------------------------
-- Stats
--------------------------------------------------------------------------------

-- `mods` are the keys GetItemStats uses for the stat; when an item has several
-- of them, the biggest counts. Spell power counts items that raise damage and
-- healing, or damage only; healing power counts items that raise healing, or
-- damage and healing. So a healer weighs healing power and a caster spell
-- power, never both.
lib.STATS = {
	{ key = 'dps', label = 'Weapon DPS',
		tip = 'DPS of melee weapons. Ranged weapons and wands use Ranged DPS.' },
	{ key = 'rdps', label = 'Ranged/wand DPS',
		tip = 'DPS of bows, guns, crossbows, thrown weapons and wands.' },
	{ key = 'speed', label = 'Speed over 2.0s',
		tip = 'Added per second of weapon speed above 2.0 (taken off below it), so slow weapons win at similar DPS. Wands do not count.' },
	{ key = 'hit', label = 'Hit',
		mods = { 'ITEM_MOD_HIT_RATING_SHORT', 'ITEM_MOD_HIT_MELEE_RATING_SHORT', 'ITEM_MOD_HIT_SPELL_RATING_SHORT',
			'ITEM_MOD_HIT_RANGED_RATING_SHORT' } },
	{ key = 'crit', label = 'Crit',
		mods = { 'ITEM_MOD_CRIT_RATING_SHORT', 'ITEM_MOD_CRIT_MELEE_RATING_SHORT', 'ITEM_MOD_CRIT_SPELL_RATING_SHORT',
			'ITEM_MOD_CRIT_RANGED_RATING_SHORT' } },
	{ key = 'haste', label = 'Haste',
		mods = { 'ITEM_MOD_HASTE_RATING_SHORT', 'ITEM_MOD_HASTE_MELEE_RATING_SHORT', 'ITEM_MOD_HASTE_SPELL_RATING_SHORT',
			'ITEM_MOD_HASTE_RANGED_RATING_SHORT' } },
	{ key = 'expertise', label = 'Expertise', mods = { 'ITEM_MOD_EXPERTISE_RATING_SHORT' } },
	{ key = 'str', label = 'Strength', mods = { 'ITEM_MOD_STRENGTH_SHORT' } },
	{ key = 'agi', label = 'Agility', mods = { 'ITEM_MOD_AGILITY_SHORT' } },
	{ key = 'int', label = 'Intellect', mods = { 'ITEM_MOD_INTELLECT_SHORT' } },
	{ key = 'spi', label = 'Spirit', mods = { 'ITEM_MOD_SPIRIT_SHORT' } },
	{ key = 'sta', label = 'Stamina', mods = { 'ITEM_MOD_STAMINA_SHORT' } },
	{ key = 'ap', label = 'Attack power',
		mods = { 'ITEM_MOD_ATTACK_POWER_SHORT', 'ITEM_MOD_MELEE_ATTACK_POWER_SHORT',
			'ITEM_MOD_RANGED_ATTACK_POWER_SHORT', 'ITEM_MOD_FERAL_ATTACK_POWER_SHORT' } },
	{ key = 'arp', label = 'Armor pen.', mods = { 'ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT' } },
	{ key = 'sp', label = 'Spell power',
		mods = { 'ITEM_MOD_SPELL_POWER_SHORT', 'ITEM_MOD_SPELL_DAMAGE_DONE_SHORT' } },
	{ key = 'hp', label = 'Healing power',
		mods = { 'ITEM_MOD_SPELL_HEALING_DONE_SHORT', 'ITEM_MOD_SPELL_POWER_SHORT' } },
	{ key = 'pierce', label = 'Spell pierce', mods = { 'ITEM_MOD_SPELL_PENETRATION_SHORT' } },
	{ key = 'mp5', label = 'Mana per 5',
		mods = { 'ITEM_MOD_MANA_REGENERATION_SHORT', 'ITEM_MOD_POWER_REGEN0_SHORT' } },
	{ key = 'armor', label = 'Armor', mods = { 'RESISTANCE0_NAME' } },
	{ key = 'def', label = 'Defense', mods = { 'ITEM_MOD_DEFENSE_SKILL_RATING_SHORT' } },
	{ key = 'dodge', label = 'Dodge', mods = { 'ITEM_MOD_DODGE_RATING_SHORT' } },
	{ key = 'parry', label = 'Parry', mods = { 'ITEM_MOD_PARRY_RATING_SHORT' } },
	{ key = 'block', label = 'Block', mods = { 'ITEM_MOD_BLOCK_RATING_SHORT' } },
	{ key = 'blockval', label = 'Block value', mods = { 'ITEM_MOD_BLOCK_VALUE_SHORT' } },
}

--------------------------------------------------------------------------------
-- Presets
--------------------------------------------------------------------------------

-- Source: the pre-raid EP tables of wowforeverbislist.com (2026-11-18), which
-- come from WoWSims Forever; Holy Paladin, Restoration Shaman and Restoration
-- Druid are that site's own estimates. The site gives Hit, Crit, Haste and
-- Expertise per 1%, items give rating, so those are divided by the rating that
-- makes 1% at level 60: 10 hit, 14 crit, 12 dodge, 15 parry, 5 block (from
-- comparing Forever items with their classic versions; not confirmed in game).
-- Haste and expertise conversions are not published; they are taken as 10 per
-- 1%, the level 60 values of the same rating table. Defense is per point.
-- Caps (8% hit melee, 17% spell hit, 6.5% expertise, 440 defense) are not
-- modeled: past them those stats are worth about nothing.
--
-- No source weighs weapon DPS. `weapon` is the DPS weight the weapon buttons
-- use: 14 attack power make 1 DPS, so 14 times the spec's attack power weight
-- (derived from Strength where the table has no attack power row), and 0 for
-- casters, healers and druids, whose forms ignore the weapon. `ranged` is the
-- weight of ranged weapon DPS: a hunter's bow, or a caster's wand, where 1
-- is a judgement call (a wand point of DPS against a point of spell power).
-- `speed` is the weapon button the preset picks.

local function Spec(class, spec, speed, weapon, ranged, weights)
	weights.dps = weapon
	weights.rdps = ranged
	return { key = (class .. spec):gsub('%W', ''):lower(), class = class, spec = spec,
		speed = speed, weapon = weapon, weights = weights }
end

-- per rating point, see above
local HIT, CRIT, HASTE, EXP = 10, 14, 10, 10

lib.PRESETS = {
	Spec('Warrior', 'Arms', 'slow', 14, 0, { hit = 47 / HIT, crit = 31.22 / CRIT, str = 2.2, agi = 1.71,
		expertise = 14.6 / EXP, haste = 11.9 / HASTE, ap = 1, arp = 0.45 }),
	Spec('Warrior', 'Fury', 'slow', 14, 0, { expertise = 23.5 / EXP, crit = 31.64 / CRIT, str = 2.2,
		haste = 17.6 / HASTE, agi = 1.7, hit = 16.9 / HIT, ap = 1, arp = 0.39 }),
	Spec('Warrior', 'Protection', 'any', 3.2, 0, { def = 15, expertise = 19.3 / EXP, sta = 1, str = 0.54,
		blockval = 0.53, agi = 0.44, crit = 5.24 / CRIT, ap = 0.23, hit = 0.35 / HIT }),

	Spec('Paladin', 'Holy', 'none', 0, 0, { hp = 1, mp5 = 0.7, crit = 7 / CRIT, haste = 5 / HASTE,
		int = 0.45, spi = 0.15, sta = 0.1 }),
	Spec('Paladin', 'Protection', 'none', 0, 0, { def = 15, block = 5.63 / 5, sta = 1, dodge = 10.62 / 12,
		parry = 10.99 / 15, agi = 0.71, blockval = 0.56, expertise = 3.04 / EXP, hit = 0.73 / HIT }),
	-- 1 Strength is 2 attack power for paladins: attack power about 1.2
	Spec('Paladin', 'Retribution', 'slow', 16.8, 0, { hit = 68.3 / HIT, expertise = 51 / EXP,
		crit = 43.12 / CRIT, str = 2.4, sp = 2.36, agi = 2.23, int = 2.06, ap = 1.2 }),

	Spec('Hunter', 'Beast Mastery', 'slow', 0, 14, { crit = 34.63 / CRIT, hit = 20.53 / HIT, agi = 2.95,
		haste = 18.95 / HASTE, int = 1.21, ap = 1 }),
	Spec('Hunter', 'Marksmanship', 'slow', 0, 14, { crit = 34.53 / CRIT, hit = 19 / HIT, agi = 2.93,
		haste = 24.67 / HASTE, int = 1.23, ap = 1 }),
	Spec('Hunter', 'Survival', 'slow', 0, 14, { crit = 35 / CRIT, hit = 19.17 / HIT, agi = 3.38,
		haste = 20.83 / HASTE, int = 1.71, ap = 1 }),

	Spec('Rogue', 'Assassination', 'any', 14, 0, { hit = 28 / HIT, expertise = 27.7 / EXP, agi = 2.06,
		crit = 28.28 / CRIT, haste = 19.3 / HASTE, str = 1.1, ap = 1, pierce = 0.65 }),
	Spec('Rogue', 'Combat', 'slow', 14, 0, { expertise = 25.5 / EXP, hit = 24.2 / HIT, agi = 1.96,
		haste = 17.2 / HASTE, crit = 23.8 / CRIT, str = 1.1, ap = 1, arp = 0.41 }),
	Spec('Rogue', 'Subtlety', 'slow', 14, 0, { expertise = 24.2 / EXP, hit = 21.2 / HIT, agi = 1.93,
		crit = 22.82 / CRIT, haste = 14.3 / HASTE, str = 1.1, ap = 1, arp = 0.33 }),

	Spec('Priest', 'Discipline', 'none', 0, 1, { hp = 1, crit = 9.8 / CRIT, mp5 = 0.4, int = 0.2,
		spi = 0.15, haste = 1.5 / HASTE, sta = 0.1 }),
	Spec('Priest', 'Holy', 'none', 0, 1, { hp = 1, mp5 = 0.6, haste = 5 / HASTE, int = 0.35, spi = 0.3,
		crit = 4.2 / CRIT, sta = 0.1 }),
	Spec('Priest', 'Shadow', 'none', 0, 1, { pierce = 2.28, hit = 11.4 / HIT, sp = 1, crit = 11.76 / CRIT,
		haste = 7.3 / HASTE, mp5 = 0.3, int = 0.24 }),

	Spec('Shaman', 'Elemental', 'none', 0, 0, { pierce = 1.81, haste = 12.3 / HASTE, hit = 11.8 / HIT,
		sp = 1, crit = 8.54 / CRIT, int = 0.19 }),
	-- 1 Strength is 2 attack power for shamans: attack power about 1.1
	Spec('Shaman', 'Enhancement', 'slow', 15.4, 0, { hit = 52 / HIT, expertise = 35 / EXP,
		haste = 28.1 / HASTE, pierce = 2.52, crit = 33.88 / CRIT, str = 2.2, int = 1.99, agi = 1.32, ap = 1.1 }),
	Spec('Shaman', 'Restoration', 'none', 0, 0, { hp = 1, mp5 = 0.6, haste = 5 / HASTE, crit = 6 / CRIT,
		int = 0.4, spi = 0.35, sta = 0.1 }),

	Spec('Mage', 'Arcane', 'none', 0, 1, { pierce = 2.63, haste = 22.61 / HASTE, hit = 17.14 / HIT, sp = 1,
		int = 0.97, crit = 10.83 / CRIT, mp5 = 0.4 }),
	Spec('Mage', 'Fire', 'none', 0, 1, { pierce = 2.15, hit = 16.11 / HIT, sp = 1, crit = 11.71 / CRIT,
		haste = 5.93 / HASTE, int = 0.31 }),
	Spec('Mage', 'Frost', 'none', 0, 1, { pierce = 2.25, hit = 16.18 / HIT, haste = 10.9 / HASTE, sp = 1,
		crit = 9.78 / CRIT, int = 0.22, sta = 0.1 }),

	Spec('Warlock', 'Affliction', 'none', 0, 1, { pierce = 1.06, sp = 1, crit = 10 / CRIT, hit = 6.88 / HIT,
		int = 0.36, mp5 = 0.31, haste = 2.82 / HASTE }),
	Spec('Warlock', 'Demonology', 'none', 0, 1, { pierce = 1.39, hit = 11.67 / HIT, sp = 1,
		crit = 7.86 / CRIT, haste = 5.34 / HASTE, mp5 = 0.36, int = 0.35 }),
	Spec('Warlock', 'Destruction', 'none', 0, 1, { pierce = 1.45, hit = 12.18 / HIT, sp = 1,
		crit = 9.39 / CRIT, haste = 4.58 / HASTE, mp5 = 0.34 }),

	Spec('Druid', 'Balance', 'none', 0, 0, { pierce = 2.07, hit = 14.5 / HIT, sp = 1, haste = 9.5 / HASTE,
		crit = 10.64 / CRIT, int = 0.2 }),
	Spec('Druid', 'Feral (Cat)', 'none', 0, 0, { agi = 2.69, str = 2.44, hit = 21.38 / HIT,
		crit = 29.04 / CRIT, expertise = 20.12 / EXP, haste = 16.12 / HASTE, ap = 1 }),
	Spec('Druid', 'Feral (Bear)', 'none', 0, 0, { def = 15, expertise = 17.71 / EXP, sta = 1,
		hit = 6.86 / HIT, str = 0.48, agi = 0.43, crit = 5.07 / CRIT, haste = 3.57 / HASTE }),
	Spec('Druid', 'Restoration', 'none', 0, 0, { hp = 1, mp5 = 0.6, spi = 0.45, int = 0.35,
		haste = 3.5 / HASTE, crit = 3 / CRIT, sta = 0.1 }),
}

-- class token of UnitClass -> preset class name, and the spec a fresh
-- character starts with
lib.PRESET_CLASSES = {
	WARRIOR = 'Warrior', PALADIN = 'Paladin', HUNTER = 'Hunter', ROGUE = 'Rogue', PRIEST = 'Priest',
	SHAMAN = 'Shaman', MAGE = 'Mage', WARLOCK = 'Warlock', DRUID = 'Druid',
}
lib.DEFAULT_PRESETS = {
	WARRIOR = 'warriorarms', PALADIN = 'paladinretribution', HUNTER = 'hunterbeastmastery',
	ROGUE = 'roguecombat', PRIEST = 'priestshadow', SHAMAN = 'shamanenhancement', MAGE = 'magefrost',
	WARLOCK = 'warlockaffliction', DRUID = 'druidferalcat',
}

-- speed weight per second over 2.0, as a share of the DPS weight: one second
-- slower is worth 1.5 DPS
lib.SPEED_SHARE = 1.5

function lib:FindPreset(key)
	for _, preset in ipairs(self.PRESETS) do
		if preset.key == key then return preset end
	end
end

-- round to 3 significant digits, so the boxes stay readable
local function Round(value)
	if value == 0 then return 0 end
	local scale = 10 ^ (2 - math.floor(math.log10(math.abs(value))))
	return math.floor(value * scale + 0.5) / scale
end

-- Weapon DPS and speed weights for a weapon choice: 'slow', 'fast', 'any'
-- or 'none'. `dps` is the DPS weight to use, `rdps` the ranged one, which
-- slow and fast also follow (a hunter's bow).
function lib:WeaponSpeedWeights(choice, dps, rdps)
	if choice == 'none' then return { dps = 0, speed = 0 } end
	local base = math.max(dps or 0, rdps or 0)
	local share = choice == 'slow' and self.SPEED_SHARE or choice == 'fast' and -self.SPEED_SHARE or 0
	return { dps = Round(dps or 0), speed = Round(base * share) }
end

-- the weights of a preset, every stat the preset leaves out at 0
function lib:PresetWeights(preset)
	local weights = {}
	for _, stat in ipairs(self.STATS) do
		weights[stat.key] = Round(preset.weights[stat.key] or 0)
	end
	local speed = self:WeaponSpeedWeights(preset.speed, preset.weapon, preset.weights.rdps)
	weights.dps, weights.speed = speed.dps, speed.speed
	return weights
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

local function CopyTable(source)
	local copy = {}
	for key, value in pairs(source) do copy[key] = value end
	return copy
end

-- settings: { weights, preset, weaponChoice, showTooltip, updated }
local function Save()
	local settings = lib.settings
	for _, store in ipairs(lib.stores) do
		store.weights = CopyTable(settings.weights)
		store.preset = settings.preset
		store.weaponChoice = settings.weaponChoice
		store.showTooltip = settings.showTooltip
		store.updated = settings.updated
	end
end

local function Changed(save)
	wipe(lib.cache)
	if save then
		lib.settings.updated = time()
		Save()
	end
	for _, panel in ipairs(lib.panels) do
		if panel:IsVisible() then panel:Refresh() end
	end
	for _, callback in pairs(lib.callbacks) do
		local ok, err = pcall(callback)
		if not ok then geterrorhandler()(err) end
	end
end

-- a fresh character: the default preset of its class, at time 0 so any saved
-- settings registered later win
local function EnsureSettings()
	if not lib.settings then
		lib.settings = { weights = {}, showTooltip = true, updated = 0 }
		local preset = lib:FindPreset(lib.DEFAULT_PRESETS[select(2, UnitClass('player'))])
		if preset then
			lib.settings.weights = lib:PresetWeights(preset)
			lib.settings.preset = preset.key
			lib.settings.weaponChoice = preset.speed
		end
	end
	local weights = lib.settings.weights
	for _, stat in ipairs(lib.STATS) do
		if type(weights[stat.key]) ~= 'number' then weights[stat.key] = 0 end
	end
end

-- `store` is a table in the host's SavedVariablesPerCharacter, loaded already
-- (call it from ADDON_LOADED or later). The lib owns its fields.
function lib:Register(store)
	if type(store) ~= 'table' then return end
	for _, known in ipairs(self.stores) do
		if known == store then return end
	end
	self.stores[#self.stores + 1] = store
	local current = self.settings
	if type(store.weights) == 'table' and (not current or (store.updated or 0) > (current.updated or 0)) then
		self.settings = { weights = CopyTable(store.weights), preset = store.preset,
			weaponChoice = store.weaponChoice, showTooltip = store.showTooltip ~= false,
			updated = store.updated or 0 }
	end
	EnsureSettings()
	Save()
	Changed(false)
end

function lib:GetSettings()
	EnsureSettings()
	return self.settings
end

function lib:GetWeights()
	return self:GetSettings().weights
end

function lib:SetWeight(key, value)
	local weights = self:GetWeights()
	if type(value) ~= 'number' or weights[key] == value then return end
	weights[key] = value
	Changed(true)
end

function lib:SetShowTooltip(show)
	self:GetSettings().showTooltip = show and true or false
	Changed(true)
end

function lib:ApplyPreset(key)
	local preset = self:FindPreset(key)
	if not preset then return end
	local settings = self:GetSettings()
	settings.weights = self:PresetWeights(preset)
	settings.preset = key
	settings.weaponChoice = preset.speed
	Changed(true)
end

-- The weapon buttons: keep the DPS weight there is, or take the preset's (or
-- 14, one attack power's worth) when there is none yet.
function lib:ApplyWeaponChoice(choice)
	local settings = self:GetSettings()
	local weights = settings.weights
	local dps = weights.dps or 0
	if dps <= 0 and choice ~= 'none' then
		local preset = self:FindPreset(settings.preset)
		dps = preset and preset.weapon or 0
		-- hunters and casters keep 0: their weapon is the ranged one
		if dps <= 0 and (weights.rdps or 0) <= 0 then dps = 14 * math.max(weights.ap or 0, 1) end
	end
	local result = self:WeaponSpeedWeights(choice, dps, weights.rdps)
	weights.dps, weights.speed = result.dps, result.speed
	settings.weaponChoice = choice
	Changed(true)
end

-- true when a weight differs from the preset (weapon DPS and speed follow the
-- weapon buttons, so they only count when they differ from what those give)
function lib:IsEdited()
	local settings = self:GetSettings()
	local preset = self:FindPreset(settings.preset)
	if not preset then return false end
	local current = settings.weights
	local weights = self:PresetWeights(preset)
	local speed = self:WeaponSpeedWeights(settings.weaponChoice or preset.speed, current.dps, current.rdps)
	weights.dps, weights.speed = current.dps, speed.speed
	for key, value in pairs(weights) do
		if math.abs((current[key] or 0) - value) > 0.0001 then return true end
	end
	return false
end

function lib:RegisterCallback(owner, callback)
	self.callbacks[owner] = callback
end

function lib:UnregisterCallback(owner)
	self.callbacks[owner] = nil
end

--------------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------------

-- turns a format string like "Requires Level %d" into a Lua pattern
local function FormatToPattern(format)
	local pattern = format:gsub('%%[ds]', '\001')
	pattern = pattern:gsub('[%(%)%.%+%-%*%?%[%]%^%$%%]', '%%%0')
	return (pattern:gsub('\001', '([%%d%%.,]+)'))
end

local LEVEL_PATTERN = FormatToPattern(ITEM_MIN_LEVEL or 'Requires Level %d')
local DPS_PATTERN = FormatToPattern(DPS_TEMPLATE or '(%s damage per second)')
local SPEED_PATTERN = '^' .. FormatToPattern(WEAPON_SPEED or 'Speed') .. '%s*([%d%.,]+)'

local function ToNumber(text)
	return text and tonumber((text:gsub(',', '.')))
end

local function IsRed(color)
	return color and color.r > 0.95 and color.g < 0.2 and color.b < 0.2
end

-- the tooltip's text lines as { text, red } pairs, from C_TooltipInfo where
-- the client has it, else from a hidden tooltip
lib.scanTip = lib.scanTip or CreateFrame('GameTooltip', 'LibBenisScoreScanTooltip', nil, 'GameTooltipTemplate')
local function TooltipLines(link)
	local lines = {}
	if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
		local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
		if ok and data and data.lines then
			for _, line in ipairs(data.lines) do
				if line.leftText then lines[#lines + 1] = { line.leftText, IsRed(line.leftColor) } end
				if line.rightText then lines[#lines + 1] = { line.rightText, IsRed(line.rightColor) } end
			end
			return lines
		end
	end
	local tip = lib.scanTip
	tip:SetOwner(WorldFrame, 'ANCHOR_NONE')
	tip:ClearLines()
	if pcall(tip.SetHyperlink, tip, link) then
		for index = 1, tip:NumLines() do
			for _, side in ipairs({ 'Left', 'Right' }) do
				local fontString = _G['LibBenisScoreScanTooltipText' .. side .. index]
				local text = fontString and fontString:IsShown() and fontString:GetText()
				if text and text ~= '' then
					local r, g, b = fontString:GetTextColor()
					lines[#lines + 1] = { text, IsRed({ r = r, g = g, b = b }) }
				end
			end
		end
	end
	tip:Hide()
	return lines
end

-- Red text in a tooltip means the character cannot use the item (weapon type,
-- class, reputation...). The level requirement is red too while the item is
-- above the character's level, but callers check the level on their own.
local function ScanTooltip(link)
	local info = { usable = true }
	for _, line in ipairs(TooltipLines(link)) do
		local text, red = line[1], line[2]
		red = red or text:lower():find('|cffff2020', 1, true)
		text = text:gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', '')
		if red and not text:match(LEVEL_PATTERN) then
			info.usable = false
		end
		info.speed = info.speed or ToNumber(text:match(SPEED_PATTERN))
		info.dps = info.dps or ToNumber(text:match(DPS_PATTERN))
	end
	return info
end

-- score, info of an item link; info.usable is false for items the class
-- cannot use. Not cached while the item's data is still loading.
function lib:Score(link)
	if not link then return 0, { usable = false } end
	local known = self.cache[link]
	if known then return known.score, known.info end

	local stats = GetItemStats(link) or {}
	local info = ScanTooltip(link)
	local weights = self:GetWeights()
	local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(link)
	local ranged = classID == WEAPON_CLASS and RANGED_SUBCLASSES[subClassID] or false
	local wand = ranged and subClassID == WAND_SUBCLASS
	info.ranged = ranged

	local dps = tonumber(stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT) or 0
	if dps == 0 then dps = info.dps or 0 end
	info.dps = dps
	local score = 0
	for _, stat in ipairs(self.STATS) do
		local value = 0
		if stat.key == 'dps' then
			value = ranged and 0 or dps
		elseif stat.key == 'rdps' then
			value = ranged and dps or 0
		elseif stat.key == 'speed' then
			value = (info.speed and not wand) and (info.speed - BASE_SPEED) or 0
		else
			for _, mod in ipairs(stat.mods or {}) do
				value = math.max(value, tonumber(stats[mod]) or 0)
			end
		end
		score = score + value * (weights[stat.key] or 0)
	end

	if GetItemInfo(link) then
		self.cache[link] = { score = score, info = info }
	end
	return score, info
end

--------------------------------------------------------------------------------
-- Comparing with what is equipped
--------------------------------------------------------------------------------

local SLOT_LABELS = {
	[1] = 'Head', [2] = 'Neck', [3] = 'Shoulder', [5] = 'Chest', [6] = 'Waist', [7] = 'Legs', [8] = 'Feet',
	[9] = 'Wrist', [10] = 'Hands', [11] = 'Ring', [12] = 'Ring', [13] = 'Trinket', [14] = 'Trinket',
	[15] = 'Back', [16] = 'Main hand', [17] = 'Off hand', [18] = 'Ranged',
}

-- armor and jewelry: the slots the item competes for (the weaker one counts)
local ARMOR_SLOTS = {
	INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 },
	INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 },
	INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
	INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
}
local OFF_HAND_LOCS = { INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true }
local RANGED_LOCS = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }

-- Forever has a ranged slot; retail keeps ranged weapons in the main hand
local hasRangedSlot
do
	local ok, slot = pcall(GetInventorySlotInfo, 'RangedSlot')
	hasRangedSlot = ok and slot == 18
end
lib.hasRangedSlot = hasRangedSlot

local function Equipped(invSlot)
	local link = GetInventoryItemLink('player', invSlot)
	return link, link and (lib:Score(link)) or 0
end

local function EquipLoc(invSlot)
	local link = GetInventoryItemLink('player', invSlot)
	return link and select(4, GetItemInfoInstant(link)) or nil
end

-- What the item would replace: { label, score, equippedScore, gain,
-- equippedLink, usable }, or nil for items that are not gear.
--   * rings and trinkets, and one-handers while dual wielding, replace the
--     weaker of the two
--   * a two-hander replaces main hand and off hand together
--   * an off-hand item replaces an equipped two-hander
function lib:Compare(link)
	if not link then return nil end
	local equipLoc = select(4, GetItemInfoInstant(link))
	if not equipLoc or equipLoc == '' then return nil end

	local slots, label
	local mainLoc = EquipLoc(16)
	local twoHandEquipped = mainLoc == 'INVTYPE_2HWEAPON'
	if ARMOR_SLOTS[equipLoc] then
		slots = ARMOR_SLOTS[equipLoc]
	elseif equipLoc == 'INVTYPE_2HWEAPON' then
		if twoHandEquipped or not GetInventoryItemLink('player', 17) then
			slots = { 16 }
		else
			slots, label = { 16, 17 }, 'Main hand + Off hand'
		end
	elseif equipLoc == 'INVTYPE_WEAPON' then
		local offLoc = EquipLoc(17)
		if not twoHandEquipped and (offLoc == 'INVTYPE_WEAPON' or offLoc == 'INVTYPE_WEAPONOFFHAND') then
			slots = { 16, 17 }
		else
			slots = { 16 }
		end
	elseif equipLoc == 'INVTYPE_WEAPONMAINHAND' then
		slots = { 16 }
	elseif OFF_HAND_LOCS[equipLoc] then
		slots = twoHandEquipped and { 16 } or { 17 }
	elseif RANGED_LOCS[equipLoc] then
		slots = { hasRangedSlot and 18 or 16 }
	else
		return nil
	end

	local score, info = self:Score(link)
	local equippedLink, equippedScore, slot
	if label then -- both hands at once
		local mainLink, mainScore = Equipped(16)
		local _, offScore = Equipped(17)
		equippedLink, equippedScore = mainLink, mainScore + offScore
	else
		for _, invSlot in ipairs(slots) do
			local otherLink, otherScore = Equipped(invSlot)
			if not equippedScore or otherScore < equippedScore then
				equippedLink, equippedScore, slot = otherLink, otherScore, invSlot
			end
		end
		label = SLOT_LABELS[slot]
	end
	return { label = label, score = score, equippedScore = equippedScore, gain = score - equippedScore,
		equippedLink = equippedLink, usable = info.usable }
end

--------------------------------------------------------------------------------
-- Tooltip line
--------------------------------------------------------------------------------

local function IsEquipped(link)
	for invSlot = 1, 19 do
		if GetInventoryItemLink('player', invSlot) == link then return true end
	end
	return false
end

function lib:OnItemTooltip(tooltip)
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
	if not self:GetSettings().showTooltip then return end
	local owner = tooltip.GetOwner and tooltip:GetOwner()
	if owner and owner.benisScoreNoLine then return end
	local _, link = tooltip:GetItem()
	if not link or IsEquipped(link) then return end
	local result = self:Compare(link)
	if not result or not result.usable then return end
	if math.abs(result.gain) < EPSILON and result.score < EPSILON then return end -- no weighted stats
	if result.gain > EPSILON then
		tooltip:AddLine(('Upgrade for %s: score %.1f -> %.1f (+%.1f)'):format(
			result.label, result.equippedScore, result.score, result.gain), 0.25, 1, 0.25)
	else
		tooltip:AddLine(('Not an upgrade for %s: score %.1f -> %.1f (%.1f)'):format(
			result.label, result.equippedScore, result.score, result.gain), 0.6, 0.6, 0.6)
	end
end

-- hooked once; the call looks the method up, so a newer copy takes over
if not lib.tooltipHooked then
	lib.tooltipHooked = true
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
			lib:OnItemTooltip(tooltip)
		end)
	else
		for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
			tooltip:HookScript('OnTooltipSetItem', function(self) lib:OnItemTooltip(self) end)
		end
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- what the class can use changes with level and with learned weapon skills
lib.frame = lib.frame or CreateFrame('Frame')
lib.frame:UnregisterAllEvents()
lib.frame:RegisterEvent('PLAYER_LEVEL_UP')
lib.frame:RegisterEvent('SPELLS_CHANGED')
lib.frame:SetScript('OnEvent', function()
	wipe(lib.cache)
end)

--------------------------------------------------------------------------------
-- Weights panel
--------------------------------------------------------------------------------

local function CreateLabel(parent, text, font)
	local label = parent:CreateFontString(nil, 'OVERLAY', font or 'GameFontNormal')
	label:SetText(text)
	return label
end

local function CreateButton(parent, text, width)
	local button = CreateFrame('Button', nil, parent, 'UIPanelButtonTemplate')
	button:SetSize(width, 22)
	button:SetText(text)
	return button
end

local function CreateEditBox(parent, width)
	local box = CreateFrame('EditBox', nil, parent, 'InputBoxTemplate')
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetMaxLetters(6)
	box:SetJustifyH('RIGHT')
	box:SetScript('OnEscapePressed', box.ClearFocus)
	box:SetScript('OnEnterPressed', box.ClearFocus)
	return box
end

local function SetTooltip(frame, title, text)
	frame:SetScript('OnEnter', function()
		GameTooltip:SetOwner(frame, 'ANCHOR_RIGHT')
		GameTooltip:SetText(title)
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	frame:SetScript('OnLeave', function() GameTooltip:Hide() end)
end

local function FormatWeight(value)
	return ('%g'):format(value or 0)
end

local WEAPON_CHOICES = {
	{ key = 'slow', text = 'Slow', width = 58,
		tip = 'Slow weapons win at a similar DPS (two-handers, main hand of most melee, hunter bows).' },
	{ key = 'fast', text = 'Fast', width = 58, tip = 'Fast weapons win at a similar DPS.' },
	{ key = 'any', text = 'Any speed', width = 74, tip = 'Only the weapon\'s DPS and stats count, not its speed.' },
	{ key = 'none', text = 'Ignore', width = 58,
		tip = 'Weapon DPS and speed count for nothing, only stats (casters, healers, druids). Ranged/wand DPS is kept.' },
}

local PANEL_WIDTH = 330
local ROW = 24

-- A frame with the preset menu, the weapon buttons, a box per weight and the
-- tooltip switch; PANEL_WIDTH wide, as high as its content. Edits apply at once.
function lib:CreateWeightsPanel(parent)
	local panel = CreateFrame('Frame', nil, parent)
	panel:SetWidth(PANEL_WIDTH)

	local presetLabel = CreateLabel(panel, 'Preset')
	presetLabel:SetPoint('TOPLEFT', 4, -4)
	local presetButton = CreateButton(panel, '', 200)
	presetButton:SetPoint('LEFT', presetLabel, 'RIGHT', 10, 0)
	SetTooltip(presetButton, 'Spec presets', 'Fills every weight from WoWSims Forever pre-raid stat weights '
		.. '(wowforeverbislist.com, November 2026). Hit and crit are per rating point '
		.. '(10 hit, 14 crit = 1%). Caps are not modeled: once you reach the hit, '
		.. 'expertise or defense cap, lower those weights yourself.')

	local weaponLabel = CreateLabel(panel, 'Weapon')
	weaponLabel:SetPoint('TOPLEFT', 4, -34)
	local weaponButtons = {}
	local anchor = weaponLabel
	for _, choice in ipairs(WEAPON_CHOICES) do
		local button = CreateButton(panel, choice.text, choice.width)
		button:SetPoint('LEFT', anchor, 'RIGHT', anchor == weaponLabel and 10 or 2, 0)
		SetTooltip(button, choice.text, choice.tip)
		button:SetScript('OnClick', function()
			panel:ClearFocus()
			lib:ApplyWeaponChoice(choice.key)
		end)
		weaponButtons[choice.key] = button
		anchor = button
	end

	local TOP = -66
	local weightsLabel = CreateLabel(panel, 'Stat weights (score = stat x weight)')
	weightsLabel:SetPoint('TOPLEFT', 4, TOP)

	local boxes, weightBoxes = {}, {}
	local perColumn = math.ceil(#self.STATS / 2)
	for index, stat in ipairs(self.STATS) do
		local column = math.floor((index - 1) / perColumn)
		local line = (index - 1) % perColumn
		local label = CreateLabel(panel, stat.label, 'GameFontHighlightSmall')
		label:SetPoint('TOPLEFT', 4 + column * 164, TOP - 26 - line * ROW)
		label:SetWidth(100)
		label:SetJustifyH('LEFT')

		local box = CreateEditBox(panel, 44)
		box:SetPoint('LEFT', label, 'RIGHT', 4, 0)
		box:SetScript('OnTextChanged', function(edit, userInput)
			if not userInput then return end
			local value = tonumber((edit:GetText():gsub(',', '.')))
			if value then lib:SetWeight(stat.key, value) end
		end)
		box:SetScript('OnEditFocusLost', function(edit)
			edit:HighlightText(0, 0)
			edit:SetText(FormatWeight(lib:GetWeights()[stat.key]))
		end)
		if stat.tip then SetTooltip(box, stat.label, stat.tip) end
		weightBoxes[stat.key] = box
		boxes[#boxes + 1] = box
	end
	for index, box in ipairs(boxes) do
		box:SetScript('OnTabPressed', function()
			local nextBox = boxes[index % #boxes + 1]
			nextBox:SetFocus()
			nextBox:HighlightText()
		end)
	end

	local bottom = TOP - 26 - perColumn * ROW
	local tooltipCheck = CreateFrame('CheckButton', nil, panel, 'UICheckButtonTemplate')
	tooltipCheck:SetSize(24, 24)
	tooltipCheck:SetPoint('TOPLEFT', 0, bottom)
	local tooltipLabel = CreateLabel(tooltipCheck, 'Show the upgrade line in item tooltips', 'GameFontHighlightSmall')
	tooltipLabel:SetPoint('LEFT', tooltipCheck, 'RIGHT', 0, 1)
	tooltipCheck:SetHitRectInsets(0, -tooltipLabel:GetStringWidth() - 2, 0, 0)
	tooltipCheck:SetScript('OnClick', function(check) lib:SetShowTooltip(check:GetChecked()) end)

	panel:SetHeight(-bottom + 28)

	function panel:Refresh()
		local settings = lib:GetSettings()
		for key, box in pairs(weightBoxes) do
			if not box:HasFocus() then box:SetText(FormatWeight(settings.weights[key])) end
		end
		local preset = lib:FindPreset(settings.preset)
		if preset then
			presetButton:SetText(('%s %s%s'):format(preset.spec, preset.class, lib:IsEdited() and ' (edited)' or ''))
		else
			presetButton:SetText('Choose a spec...')
		end
		for key, button in pairs(weaponButtons) do
			if key == settings.weaponChoice then button:LockHighlight() else button:UnlockHighlight() end
		end
		tooltipCheck:SetChecked(settings.showTooltip)
	end

	function panel:ClearFocus()
		for _, box in ipairs(boxes) do box:ClearFocus() end
	end

	presetButton:SetScript('OnClick', function()
		panel:ClearFocus()
		MenuUtil.CreateContextMenu(presetButton, function(_, root)
			root:CreateTitle('Stat weights of a spec')
			local own = lib.PRESET_CLASSES[select(2, UnitClass('player'))]
			local function IsSelected(key) return lib:GetSettings().preset == key end
			local function Select(key) lib:ApplyPreset(key) end
			local menus, order = {}, {}
			for _, preset in ipairs(lib.PRESETS) do
				if not menus[preset.class] then
					order[#order + 1] = preset.class
					menus[preset.class] = {}
				end
				table.insert(menus[preset.class], preset)
			end
			-- the character's own class first and open, the others as submenus
			if own and menus[own] then
				for _, preset in ipairs(menus[own]) do
					root:CreateRadio(('%s %s'):format(preset.spec, preset.class), IsSelected, Select, preset.key)
				end
				root:CreateDivider()
			end
			for _, class in ipairs(order) do
				if class ~= own then
					local sub = root:CreateButton(class)
					for _, preset in ipairs(menus[class]) do
						sub:CreateRadio(preset.spec, IsSelected, Select, preset.key)
					end
				end
			end
		end)
	end)

	panel:SetScript('OnShow', panel.Refresh)
	self.panels[#self.panels + 1] = panel
	return panel
end

-- the panel in a window of its own, for addons without a settings window
function lib:ToggleWindow()
	local window = self.window
	if not window then
		window = CreateFrame('Frame', 'LibBenisScoreWindow', UIParent, 'BasicFrameTemplateWithInset')
		window:SetPoint('CENTER')
		window:SetFrameStrata('DIALOG')
		window:SetClampedToScreen(true)
		window:SetMovable(true)
		window:EnableMouse(true)
		window:RegisterForDrag('LeftButton')
		window:SetScript('OnDragStart', window.StartMoving)
		window:SetScript('OnDragStop', window.StopMovingOrSizing)
		window:Hide()
		tinsert(UISpecialFrames, 'LibBenisScoreWindow')
		local title = CreateLabel(window, 'Stat weights', 'GameFontHighlight')
		title:SetPoint('TOP', 0, -5)
		local panel = self:CreateWeightsPanel(window)
		panel:SetPoint('TOPLEFT', 12, -32)
		window:SetSize(PANEL_WIDTH + 24, panel:GetHeight() + 44)
		window:SetScript('OnHide', function() panel:ClearFocus() end)
		self.window = window
	end
	window:SetShown(not window:IsShown())
end

SLASH_LIBBENISSCORE1 = '/bscore'
SlashCmdList.LIBBENISSCORE = function() lib:ToggleWindow() end
