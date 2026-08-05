-- TalentEffects -- design doc "ABYSS Full Talents Integration". Data-driven mechanical
-- definitions for the 93-entry Traits & Talents Compendium v2. TalentManager (server) is the
-- sole caller: on grant/revoke/respawn it looks up TalentEffects[talentId] and invokes
-- onApply/onRemove; passiveModifier (static table) or getModifier (function, for FightingStyle-
-- gated Style talents and other conditional cases) feed TalentManager.getModifier's
-- multiplicative aggregation; any other named function (onDamageTake, onLowHPState, etc.) is a
-- HOOK -- TalentManager.fireHook(player, hookName, ...) calls it generically for any system
-- that chooses to consult it, per the design doc's own "add a HOOK that will trigger when that
-- system is built" instruction. Not every hook has a live caller yet; see [[project_abyss]]
-- memory / the session's final report for exactly which ones are wired into real game systems
-- versus hook-only.
--
-- NOTE: AwakenedEyes, BlindSight, BloodInsight, ColdBlood, IronNerve, Stoicism, and
-- ReinforcedMuscles are NOT defined here -- they already exist as fully-functional legacy
-- talents in TalentManager itself (attribute-mirrored, consumed by SpiritClient/
-- InjuryEffectsClient) from an earlier session. Redefining them here would either duplicate or
-- conflict with that working code, so TalentManager's generic dispatch simply won't find an
-- entry for those IDs and leaves the legacy path as sole owner.

local TalentEffects = {}

local function setAttr(name)
	return function(player)
		local char = player.Character
		if char then char:SetAttribute(name, true) end
	end
end
local function clearAttr(name)
	return function(player)
		local char = player.Character
		if char then char:SetAttribute(name, nil) end
	end
end

-- ================================================================================
-- COMMON TRAITS (12)
-- ================================================================================

TalentEffects.CallousedHands = {
	type = "Trait_Common", description = "Blocking fills your posture bar 15% slower.",
	passiveModifier = { BlockPostureFillPerHit = 0.85 },
}
TalentEffects.RoadWorn = {
	type = "Trait_Common", description = "Sprinting drains 20% less stamina.",
	passiveModifier = { SprintStaminaDrain = 0.80 },
}
TalentEffects.ThickSkin = {
	type = "Trait_Common", description = "Above 70% HP, light M1 hits no longer visibly flinch you.",
	onDamageTake = function(player, damage, hitType)
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and hum.MaxHealth > 0 and (hum.Health / hum.MaxHealth) > 0.7 and hitType == "M1" then
			return { suppressFlinch = true }
		end
		return {}
	end,
}
TalentEffects.SteadyGrip = {
	type = "Trait_Common", description = "Your weapons are 30% less likely to break.",
	passiveModifier = { WeaponBreakChance = 0.7 },
}
TalentEffects.LowCentre = {
	type = "Trait_Common", description = "You take 20% less knockback force.",
	passiveModifier = { KnockbackForceMult = 0.80 },
}
TalentEffects.QuickEyes = {
	type = "Trait_Common", description = "A sharp gaze -- pure roleplay tag, no mechanical effect.",
}
TalentEffects.IronStomach = {
	type = "Trait_Common", description = "Hunger drains 30% slower.",
	passiveModifier = { HungerDrainRate = 0.70 },
}
TalentEffects.DullPain = {
	type = "Trait_Common", description = "Light stagger duration is 30% shorter.",
	passiveModifier = { LightStaggerDuration = 0.70 },
}
TalentEffects.FieldMedicine = {
	type = "Trait_Common", description = "Potions heal 10% more.",
	passiveModifier = { PotionHealMult = 1.10 },
}
TalentEffects.HardJaw = {
	type = "Trait_Common", description = "Full stagger duration is shorter (1.0s instead of 1.2s).",
	passiveModifier = { FullStaggerDuration = 0.83 },
}
TalentEffects.LeanBuild = {
	type = "Trait_Common", description = "You can be carried from half the usual range.",
	passiveModifier = { CarryRange = 0.5 },
}
TalentEffects.SurvivorsInstinct = {
	type = "Trait_Common", description = "Below 20% HP, hunger stops draining.",
	onLowHPState = function(player, hpPercent)
		local char = player.Character; if not char then return end
		char:SetAttribute("SuppressHungerDrain", hpPercent < 0.20 or nil)
	end,
}

-- ================================================================================
-- UNCOMMON TRAITS (13)
-- ================================================================================

TalentEffects.Bloodhound = {
	type = "Trait_Uncommon", description = "Sense nearby players even out of sight.",
	onApply = setAttr("Bloodhound"), onRemove = clearAttr("Bloodhound"),
}
TalentEffects.IronBlood = {
	type = "Trait_Uncommon", description = "Post-combat stamina/HP regen delay is halved.",
	passiveModifier = { PostCombatRegenDelay = 0.5 },
}
TalentEffects.BerserkrBlood = {
	type = "Trait_Uncommon", description = "Below 30% HP, M1 damage is boosted 15%.",
	onLowHPState = function(player, hpPercent)
		local char = player.Character; if not char then return end
		char:SetAttribute("M1DamageBonus", (hpPercent < 0.30) and 1.15 or nil)
	end,
}
TalentEffects.Seafarer = {
	type = "Trait_Uncommon", description = "Rain/storms no longer slow your movement.",
	onWeatherChange = function(player, weather)
		local char = player.Character; if not char then return end
		local rainy = weather=="Rain" or weather=="HeavyRain" or weather=="Thunderstorm" or weather=="Storm"
		char:SetAttribute("IgnoreWeatherMovementPenalty", rainy or nil)
	end,
}
TalentEffects.SellswordEyes = {
	type = "Trait_Uncommon", description = "You can read the weapon type of nearby fighters at a glance.",
	onApply = setAttr("SellswordEyes"), onRemove = clearAttr("SellswordEyes"),
}
TalentEffects.SkaldBorn = {
	type = "Trait_Uncommon", description = "Your roleplay actions are flagged as canon-eligible for the lore team.",
	-- HOOK ONLY: ChatManager's /a action handler is the natural place to check this and add a
	-- canon-eligible marker to the live feed entry, but doesn't do so yet.
	onApply = setAttr("SkaldBorn"), onRemove = clearAttr("SkaldBorn"),
}
TalentEffects.NightSense = {
	type = "Trait_Uncommon", description = "Reduced vision penalty during deep night.",
	onTimeOfDayChange = function(player, timeOfDay)
		local char = player.Character; if not char then return end
		char:SetAttribute("NightSense", (timeOfDay == "DeepNight") or nil)
	end,
}
TalentEffects.WolfStance = {
	type = "Trait_Uncommon", description = "+2 frames of fist-dodge invulnerability.",
	passiveModifier = { FistDodgeIFramesAdd = 2 },
}
TalentEffects.DruidsBlood = {
	type = "Trait_Uncommon", description = "+10% stamina regen in forests and swamps.",
	onZoneEnter = function(player, zoneName)
		local char = player.Character; if not char then return end
		local wild = zoneName=="DenseForest" or zoneName=="GreatForest" or zoneName=="Swamp" or zoneName=="Forest"
		char:SetAttribute("StaminaRegenBonus", wild and 1.10 or nil)
	end,
}
TalentEffects.ThaneBorn = {
	type = "Trait_Uncommon", description = "Norse-aligned NPCs are slower to consider you a threat.",
	onApply = setAttr("ThaneBorn"), onRemove = clearAttr("ThaneBorn"),
}
TalentEffects.MerchantLine = {
	type = "Trait_Uncommon", description = "You receive 5% more currency from trades and rewards.",
	passiveModifier = { CurrencyReceiveMult = 1.05 },
}
TalentEffects.PitFighter = {
	type = "Trait_Uncommon", description = "Your own guard-break recovery is 20% faster.",
	passiveModifier = { GuardBreakDurationOnSelf = 0.8 },
}
TalentEffects.PacifistBlood = {
	type = "Trait_Uncommon", description = "You deal 10% less damage, but carrying others costs no speed.",
	passiveModifier = { AllDamageDealt = 0.90, CarrySpeedPenalty = 0 },
}

-- ================================================================================
-- RARE TRAITS (11)
-- ================================================================================

TalentEffects.PaleDescent = {
	type = "Trait_Rare", description = "Lore hook -- pale, unsettling ancestry. NPC reactions handled by the lore team.",
	onApply = setAttr("PaleDescent"), onRemove = clearAttr("PaleDescent"),
}
TalentEffects.CursedMarkMinor = {
	type = "Trait_Rare", description = "You deal and take 10% more damage.",
	passiveModifier = { AllDamageDealt = 1.10, AllDamageTaken = 1.10 },
}
TalentEffects.TheUnbrokenLine = {
	type = "Trait_Rare", description = "Your own guard-break recovery is a third faster (1.0s instead of 1.5s).",
	passiveModifier = { GuardBreakDurationOnSelf = 0.67 },
}
TalentEffects.EchoOfTheEast = {
	type = "Trait_Rare", description = "+2 frames on the perfect-parry window.",
	passiveModifier = { PerfectParryWindowFramesAdd = 2 },
}
TalentEffects.WarWidowsChild = {
	type = "Trait_Rare", description = "+2 studs of execution range.",
	passiveModifier = { ExecuteRangeAdd = 2 },
}
TalentEffects.TheAshName = {
	type = "Trait_Rare", description = "Lore hook -- a name tied to fire and ruin.",
	onApply = setAttr("AshName"), onRemove = clearAttr("AshName"),
}
TalentEffects.DisgracedNoble = {
	type = "Trait_Rare", description = "Lore hook -- fallen from a noble house.",
	onApply = setAttr("DisgracedNoble"), onRemove = clearAttr("DisgracedNoble"),
}
TalentEffects.BornKiller = {
	type = "Trait_Rare", description = "Something about you unsettles those nearby.",
	onApply = setAttr("BornKiller"), onRemove = clearAttr("BornKiller"),
}
TalentEffects.ApostlesShadow = {
	type = "Trait_Rare", description = "Lore hook -- touched by an Apostle's presence.",
	onApply = setAttr("ApostlesShadow"), onRemove = clearAttr("ApostlesShadow"),
}
TalentEffects.GreekSteel = {
	type = "Trait_Rare", description = "+1 tier of weapon quality bonus.",
	passiveModifier = { WeaponQualityBonusAdd = 1 },
}
TalentEffects.BerserkerGangBlood = {
	type = "Trait_Rare", description = "Immune to the first guard-break attempt each fight.",
	onCombatStart = function(player)
		local char = player.Character; if not char then return end
		char:SetAttribute("GuardBreakImmuneCount", 1)
	end,
	onGuardBreakAttempt = function(player)
		local char = player.Character; if not char then return { immunity = false } end
		local remaining = char:GetAttribute("GuardBreakImmuneCount") or 0
		if remaining > 0 then
			char:SetAttribute("GuardBreakImmuneCount", remaining - 1)
			return { immunity = true }
		end
		return { immunity = false }
	end,
}

-- ================================================================================
-- CURSED TRAITS (7)
-- ================================================================================

TalentEffects.TheBrand = {
	type = "Trait_Cursed", description = "A permanent mark, visible to everyone.",
	onApply = setAttr("TheBrand"), onRemove = clearAttr("TheBrand"),
}
TalentEffects.TheHollow = {
	type = "Trait_Cursed", description = "Stamina regen halved, but +2 frames on the perfect-parry window.",
	passiveModifier = { StaminaRegenMult = 0.5, PerfectParryWindowFramesAdd = 2 },
}
TalentEffects.MarkedForGrief = {
	type = "Trait_Cursed", description = "Those near you drain hunger 15% faster.",
	onApply = setAttr("MarkedForGrief"), onRemove = clearAttr("MarkedForGrief"),
}
TalentEffects.GodsMistake = {
	type = "Trait_Cursed", description = "You deal and take 25% more damage.",
	passiveModifier = { AllDamageDealt = 1.25, AllDamageTaken = 1.25 },
}
TalentEffects.TheSacrifice = {
	type = "Trait_Cursed", description = "Other players cannot heal you.",
	onExternalHealAttempt = function(player, source)
		if source == "other_player" then return { allow = false } end
		return { allow = true }
	end,
}
TalentEffects.EternalHunger = {
	type = "Trait_Cursed", description = "Hunger drains three times as fast.",
	passiveModifier = { HungerDrainRate = 3.0 },
}
TalentEffects.OmenChild = {
	type = "Trait_Cursed", description = "Your arrival in a zone is felt by everyone already there.",
	-- HOOK ONLY: ZoneManager has no "list players currently in zone X" query to call this
	-- against yet (confirmed -- no such function exists), so this stays a pure marker until
	-- that's added. Whichever system ends up owning zone-enter events should check this
	-- attribute and fire its own notification to nearby players.
	onApply = setAttr("OmenChild"), onRemove = clearAttr("OmenChild"),
}

-- ================================================================================
-- COMBAT TALENTS (10 + 2)
-- ================================================================================

TalentEffects.Riposte = {
	type = "Combat", description = "R triggers a riposte on guard-broken opponents.",
	-- HOOK ONLY: RemoteEvents.RequestRiposte exists but has never had a server listener
	-- wired to it (confirmed -- no OnServerEvent connection anywhere in the codebase). This
	-- sets the same CanRiposte attribute the design doc specifies; the actual riposte-on-R
	-- mechanic is a real new combat feature, not something safe to improvise into
	-- CombatManager as a side effect of a talent-wiring pass.
	onApply = setAttr("CanRiposte"), onRemove = clearAttr("CanRiposte"),
}
TalentEffects.FeintMaster = {
	type = "Combat", description = "Feinting costs half the usual stamina.",
	passiveModifier = { FeintStaminaCost = 0.5 },
}
TalentEffects.ParryChain = {
	type = "Combat", description = "A perfect parry opens a 1.5s window for a bonus follow-up.",
	onPerfectParry = function(player)
		local char = player.Character; if not char then return end
		char:SetAttribute("ParryChainWindow", tick() + 1.5)
	end,
}
TalentEffects.IronCurtain = {
	type = "Combat", description = "Blocking barely slows you (100% speed instead of 40%).",
	passiveModifier = { BlockSpeedMult = 2.5 },
}
TalentEffects.ClashVeteran = {
	type = "Combat", description = "Sword-clash input races give you 30% more time to react.",
	passiveModifier = { ClashInputWindow = 1.3 },
}
TalentEffects.SecondWind = {
	type = "Combat", description = "The first time you run out of stamina each fight, regain 20 instantly.",
	onStaminaZero = function(player)
		local char = player.Character; if not char then return false end
		if char:GetAttribute("SecondWindUsed") then return false end
		char:SetAttribute("SecondWindUsed", true)
		return true -- caller (StaminaManager) grants the +20 itself
	end,
	onCombatEnd = clearAttr("SecondWindUsed"),
}
TalentEffects.ExecutionersReach = {
	type = "Combat", description = "+3 studs of execution range.",
	passiveModifier = { ExecuteRangeAdd = 3 },
}
TalentEffects.AerialHunter = {
	type = "Combat", description = "Aerial M1s deal 10% more damage and fill 6 extra posture.",
	passiveModifier = { AerialM1DamageMult = 1.10, AerialM1PostureBonusAdd = 6 },
}
TalentEffects.CrushingBlow = {
	type = "Combat", description = "Your M1 chain ender hits 25% harder with a slightly bigger hitbox.",
	passiveModifier = { M1ChainEnderDamageMult = 1.25, M1ChainEnderHitboxMult = 1.1 },
}
TalentEffects.GuardBreaker = {
	type = "Combat", description = "M2 fills 5 extra posture when blocked.",
	passiveModifier = { M2PostureBonusOnBlockedAdd = 5 },
}
TalentEffects.CounterSweep = {
	type = "Combat", description = "Aerial counter-hits deal 30% more damage.",
	passiveModifier = { AirCounterBonusMult = 1.3 },
}
TalentEffects.AirRead = {
	type = "Combat", description = "A cue plays when a nearby enemy winds up an aerial critical.",
	onEnemyAirCriticalWindup = function(player, attacker)
		-- HOOK: fires when CombatManager's aerial-critical windup detection exists to call it.
	end,
}

-- ================================================================================
-- FIGHTING STYLE TALENTS (10) -- FightingStyle lives on DataManager (dm.getValue(player,
-- "FightingStyle")), NOT as a Character Attribute (confirmed live: CombatManager's own bleed-
-- tier logic reads it exactly this way) -- every getModifier below reads it from there, not
-- from Character:GetAttribute like the design doc's pseudocode assumed.
-- ================================================================================

local function currentStyle(player)
	local dm = _G.DataManager
	return dm and dm.getValue(player, "FightingStyle")
end

TalentEffects.IronwallStoneStance = {
	type = "Style", style = "Ironwall", description = "(Ironwall) Blocking fills posture 20% slower.",
	getModifier = function(player)
		if currentStyle(player) == "Ironwall" then return { BlockPostureFillPerHit = 0.80 } end
		return {}
	end,
}
TalentEffects.IronwallUnmovable = {
	type = "Style", style = "Ironwall", description = "(Ironwall) You take 25% less knockback force.",
	getModifier = function(player)
		if currentStyle(player) == "Ironwall" then return { KnockbackForceMult = 0.75 } end
		return {}
	end,
}
TalentEffects.DuelistBleedingRead = {
	type = "Style", style = "Duelist", description = "(Duelist) A perfect parry sets up bonus damage on your next M1 for 2s.",
	onPerfectParry = function(player)
		if currentStyle(player) ~= "Duelist" then return end
		local char = player.Character; if not char then return end
		char:SetAttribute("NextM1BonusUntil", tick() + 2)
	end,
}
TalentEffects.DuelistPhantomStep = {
	type = "Style", style = "Duelist", description = "(Duelist) Dash cooldown is halved.",
	getModifier = function(player)
		if currentStyle(player) == "Duelist" then return { DashCooldownMult = 0.5 } end
		return {}
	end,
}
TalentEffects.BerserkerFuryChain = {
	type = "Style", style = "Berserker", description = "(Berserker) M1 chain enders skip end lag.",
	onM1ChainEnd = function(player)
		if currentStyle(player) ~= "Berserker" then return end
		local char = player.Character; if not char then return end
		char:SetAttribute("SkipEndLag", true)
	end,
}
TalentEffects.BerserkerPainDrunk = {
	type = "Style", style = "Berserker", description = "(Berserker) Each hit taken in a fight stacks +1% M1 damage, up to 15 stacks.",
	onDamageTake = function(player)
		if currentStyle(player) ~= "Berserker" then return end
		local char = player.Character; if not char then return end
		local stacks = math.min((char:GetAttribute("PainDrunkStacks") or 0) + 1, 15)
		char:SetAttribute("PainDrunkStacks", stacks)
	end,
	getModifier = function(player)
		if currentStyle(player) ~= "Berserker" then return {} end
		local char = player.Character
		local stacks = (char and char:GetAttribute("PainDrunkStacks")) or 0
		return { M1Damage = 1 + (stacks * 0.01) }
	end,
	onCombatEnd = clearAttr("PainDrunkStacks"),
}
TalentEffects.UnarmedIronFists = {
	type = "Style", style = "Unarmed", description = "(Unarmed) Fist M1s deal 80% of weapon damage instead of the usual 60%.",
	getModifier = function(player)
		if currentStyle(player) == "Unarmed" then return { FistM1DamagePercent = 0.80 } end
		return {}
	end,
}
TalentEffects.UnarmedGrapple = {
	type = "Style", style = "Unarmed", description = "(Unarmed) Unlocks the grapple action.",
	onApply = setAttr("CanGrapple"), onRemove = clearAttr("CanGrapple"),
}
TalentEffects.SpearExtendedThreat = {
	type = "Style", style = "Spear", description = "(Spear) +1.5 studs of hitbox range.",
	getModifier = function(player)
		if currentStyle(player) == "Spear" then return { HitboxRangeAdd = 1.5 } end
		return {}
	end,
}
TalentEffects.DaggerVitalPoint = {
	type = "Style", style = "Dagger", description = "(Dagger) Critical hits deal 40% more damage.",
	getModifier = function(player)
		if currentStyle(player) == "Dagger" then return { CriticalDamageMult = 1.4 } end
		return {}
	end,
}

-- ================================================================================
-- PASSIVE TALENTS (12) -- ReinforcedMuscles already exists as a legacy ATTRIBUTE_MIRRORED
-- talent in TalentManager, but that only ever handled the Talent_ReinforcedMuscles attribute
-- bookkeeping -- the actual +15 max stamina mechanic the compendium describes was never
-- implemented anywhere. Defining it here is additive, not a redefinition: the legacy
-- attribute mirror and this passiveModifier are two independent effects of the same grant.
-- ================================================================================

TalentEffects.ReinforcedMuscles = {
	type = "Passive", description = "+15 max stamina.",
	passiveModifier = { MaxStaminaAdd = 15 },
}
TalentEffects.CallousedGuard = {
	type = "Passive", description = "Blocking fills posture 20% slower.",
	passiveModifier = { BlockPostureFillPerHit = 0.80 },
}
TalentEffects.VeteranLegs = {
	type = "Passive", description = "Sprinting drains 25% less stamina.",
	passiveModifier = { SprintStaminaDrain = 0.75 },
}
TalentEffects.WarriorsRead = {
	type = "Passive", description = "Your combat tag lasts 90s instead of 60s.",
	passiveModifier = { CombatTagDuration = 90 },
}
TalentEffects.ScarTissue = {
	type = "Passive", description = "Post-combat regen delay is 25% shorter.",
	passiveModifier = { PostCombatRegenDelay = 0.75 },
}
TalentEffects.HungerDiscipline = {
	type = "Passive", description = "Hunger drains 40% slower.",
	passiveModifier = { HungerDrainRate = 0.6 },
}
TalentEffects.LowProfile = {
	type = "Passive", description = "Slightly harder for NPCs to notice you.",
	onApply = setAttr("LowProfile"), onRemove = clearAttr("LowProfile"),
}
TalentEffects.SunImmunity = {
	type = "Passive", description = "Immune to sun-related penalties.",
	onApply = setAttr("SunImmune"), onRemove = clearAttr("SunImmune"),
}
TalentEffects.SpatialAwareness = {
	type = "Passive", description = "Every 45s, briefly sense nearby players' outlines.",
	onApply = setAttr("SpatialAwareness"), onRemove = clearAttr("SpatialAwareness"),
}
TalentEffects.LegendaryBlacksmithDescendant = {
	type = "Passive", description = "Weapons you craft get +1 quality tier.",
	passiveModifier = { CraftedWeaponQualityBonusAdd = 1 },
}
TalentEffects.WarHardened = {
	type = "Passive", description = "After 5 hits taken in one fight, light stagger stops interrupting you.",
	onDamageTake = function(player)
		local char = player.Character; if not char then return end
		local hits = (char:GetAttribute("CombatHitsTaken") or 0) + 1
		char:SetAttribute("CombatHitsTaken", hits)
		if hits >= 5 then char:SetAttribute("SuppressLightStagger", true) end
	end,
	onCombatEnd = function(player)
		local char = player.Character; if not char then return end
		char:SetAttribute("CombatHitsTaken", 0)
		char:SetAttribute("SuppressLightStagger", nil)
	end,
}
TalentEffects.PatientHunter = {
	type = "Passive", description = "Standing still for 8+ seconds charges your next M1 with +20% damage.",
	-- HOOK ONLY: needs a per-frame "time since last moved" watcher (MovementManager doesn't
	-- expose one) to actually charge/consume the bonus; the timestamp is tracked so that
	-- watcher has something to read once it exists.
	onSpawn = function(player)
		local char = player.Character; if not char then return end
		char:SetAttribute("LastMovedAt", tick())
	end,
}
TalentEffects.DruidsTongue = {
	type = "Passive", description = "Swamp and forest zone discoveries stay quiet -- no announcement.",
	onZoneEnter = function(player, zoneName)
		if zoneName == "Swamp" or zoneName == "GreatForest" or zoneName == "Forest" then
			return { suppressDiscovery = true }
		end
		return {}
	end,
}

-- ================================================================================
-- ROLEPLAY TALENTS (12) -- mostly lore hooks (attribute markers other systems/the lore team
-- read), except GreekTongue which has a real one-time mechanical effect.
-- ================================================================================

TalentEffects.HereticsSutra = { type = "Roleplay", description = "Lore hook -- heretical rites.", onApply = setAttr("HereticsSutra"), onRemove = clearAttr("HereticsSutra") }
TalentEffects.MerchantsTongue = { type = "Roleplay", description = "Lore hook -- a trader's silver tongue.", onApply = setAttr("MerchantsTongue"), onRemove = clearAttr("MerchantsTongue") }
TalentEffects.Oathkeeper = { type = "Roleplay", description = "Lore hook -- bound by a sworn oath.", onApply = setAttr("Oathkeeper"), onRemove = clearAttr("Oathkeeper") }
TalentEffects.TheConfessor = { type = "Roleplay", description = "Lore hook -- hears confessions.", onApply = setAttr("Confessor"), onRemove = clearAttr("Confessor") }
TalentEffects.Forgemaster = {
	type = "Roleplay", description = "Can craft up to Masterwork quality.",
	passiveModifier = { WeaponQualityCraftLimit = 3 },
}
TalentEffects.Tracker = { type = "Roleplay", description = "Lore hook -- skilled at tracking.", onApply = setAttr("Tracker"), onRemove = clearAttr("Tracker") }
TalentEffects.Chronicler = { type = "Roleplay", description = "Lore hook -- keeps a record of events.", onApply = setAttr("Chronicler"), onRemove = clearAttr("Chronicler") }
TalentEffects.WarCry = { type = "Roleplay", description = "Unlocks the war cry action.", onApply = setAttr("CanWarCry"), onRemove = clearAttr("CanWarCry") }
TalentEffects.Herald = { type = "Roleplay", description = "Lore hook -- speaks with the weight of an official messenger.", onApply = setAttr("Herald"), onRemove = clearAttr("Herald") }
TalentEffects.Inquisitor = { type = "Roleplay", description = "Lore hook -- roots out heresy.", onApply = setAttr("Inquisitor"), onRemove = clearAttr("Inquisitor") }
TalentEffects.GreekTongue = {
	type = "Roleplay", description = "+20 starting reputation with the Greeks, granted once.",
	-- Guard must be persisted (DataManager), NOT a Character attribute -- onApply re-fires on
	-- every respawn (TalentManager reapplies all granted talents via loadPlayer/spawn), and a
	-- Character-attribute guard would reset every time, silently re-granting +20 rep each death.
	onApply = function(player)
		local dm = _G.DataManager; if not dm then return end
		if dm.getValue(player, "GreekTongueGranted") then return end
		local rep = dm.getValue(player, "Reputation") or {}
		rep.Greeks = (rep.Greeks or 0) + 20
		dm.setValue(player, "Reputation", rep)
		dm.setValue(player, "GreekTongueGranted", true)
	end,
}
TalentEffects.DruidsRite = { type = "Roleplay", description = "Lore hook -- performs the old rites.", onApply = setAttr("DruidsRite"), onRemove = clearAttr("DruidsRite") }

-- ================================================================================
-- LEGENDARY TALENTS (8)
-- ================================================================================

TalentEffects.TheUnbroken = {
	type = "Legendary", description = "The first hit that would kill you instead leaves you at 1 HP, once per life.",
	onDamageWouldKill = function(player)
		local char = player.Character; if not char then return {} end
		if char:GetAttribute("UnbrokenUsed") then return {} end
		char:SetAttribute("UnbrokenUsed", true)
		return { setHPTo = 1 }
	end,
	-- "Once per session" per the design doc -- UnbrokenUsed is a Character attribute
	-- deliberately (resets every respawn = every "life", matching the doc's own "resets on
	-- next session" framing more naturally as "resets on next life" for a survival mechanic).
}
TalentEffects.ApostlesHunger = {
	type = "Legendary", description = "Lore hook -- enables the Apostle transition path.",
	onApply = setAttr("ApostlesHunger"), onRemove = clearAttr("ApostlesHunger"),
}
TalentEffects.DragonslayersBurden = {
	type = "Legendary", description = "+30% damage against bosses and elites.",
	-- HOOK: no boss/elite marker exists on any NPC yet (confirmed -- IsBossOrElite is not set
	-- anywhere in NPCManager). Ready to consume the moment one does.
	onDamageDeal = function(player, target)
		if target and target:GetAttribute("IsBossOrElite") then return { damageMult = 1.30 } end
		return { damageMult = 1.0 }
	end,
}
TalentEffects.PaleRider = {
	type = "Legendary", description = "Below 15% HP, speed penalties no longer apply to you.",
	onLowHPState = function(player, hpPercent)
		local char = player.Character; if not char then return end
		char:SetAttribute("IgnoreSpeedPenalties", (hpPercent < 0.15) or nil)
	end,
}
TalentEffects.TheName = {
	type = "Legendary", description = "Your name is known the moment you enter a zone.",
	-- HOOK ONLY: same "no zone-roster query exists yet" gap as OmenChild above.
	onApply = setAttr("TheName"), onRemove = clearAttr("TheName"),
}
TalentEffects.BloodMemory = {
	type = "Legendary", description = "On Permanent Death, the lore team may carry one talent into your next character.",
	onApply = setAttr("BloodMemory"),
	onRemove = clearAttr("BloodMemory"),
	-- HOOK: LoreManager's triggerPDE is the real call site for onPDEDeath, once someone wants
	-- to wire the lore-team talent-carryover prompt through it.
}
TalentEffects.VoidTouched = {
	type = "Legendary", description = "Factions treat you as neutral until a major event changes that.",
	onApply = setAttr("VoidTouched"), onRemove = clearAttr("VoidTouched"),
}
TalentEffects.LastOfTheLine = {
	type = "Legendary", description = "If no other online player shares your family name, M1/M2 deal 20% more damage.",
	onApply = function(player)
		local dm = _G.DataManager; if not dm then return end
		local myFamily = dm.getValue(player, "FamilyName")
		local char = player.Character; if not char or not myFamily or myFamily == "" then return end
		local isLast = true
		for _, other in ipairs(game.Players:GetPlayers()) do
			if other ~= player and dm.getValue(other, "FamilyName") == myFamily then isLast = false; break end
		end
		char:SetAttribute("LastOfTheLineActive", isLast or nil)
	end,
	onRemove = clearAttr("LastOfTheLineActive"),
	getModifier = function(player)
		local char = player.Character
		if char and char:GetAttribute("LastOfTheLineActive") then
			return { M1Damage = 1.20, M2Damage = 1.20 }
		end
		return {}
	end,
}

-- ================================================================================
-- BLESSED TALENTS (12)
-- ================================================================================

TalentEffects.SaintsResolve = {
	type = "Blessed", description = "The first hit that would down you instead leaves you at 5 HP, once per life.",
	onDamageWouldDown = function(player)
		local char = player.Character; if not char then return {} end
		if char:GetAttribute("SaintsResolveUsed") then return {} end
		char:SetAttribute("SaintsResolveUsed", true)
		return { setHPTo = 5 }
	end,
}
TalentEffects.Absolution = {
	type = "Blessed", description = "Downed players near you bleed out more slowly.",
	onApply = setAttr("Absolution"), onRemove = clearAttr("Absolution"),
}
TalentEffects.TheShepherd = {
	type = "Blessed", description = "Carrying another player costs no movement speed.",
	passiveModifier = { CarrySpeedPenalty = 0 },
}
TalentEffects.Bloodless = {
	type = "Blessed", description = "Your real HP is hidden -- always displays as full to others and mods.",
	onApply = setAttr("HideRealHP"), onRemove = clearAttr("HideRealHP"),
}
TalentEffects.IronCovenant = {
	type = "Blessed", description = "For 24 hours after taking the oath, you take 10% less damage.",
	getModifier = function(player)
		local dm = _G.DataManager
		local oathActive = dm and dm.getValue(player, "OathActive")
		local expiresAt = dm and dm.getValue(player, "OathExpiresAt") or 0
		if oathActive and tick() < expiresAt then return { AllDamageTaken = 0.90 } end
		return {}
	end,
}
TalentEffects.TheUndyingName = {
	type = "Blessed", description = "Your Permanent Death is recorded on the Lore Board in gold.",
	onApply = setAttr("TheUndyingName"), onRemove = clearAttr("TheUndyingName"),
	-- HOOK: LoreManager's triggerPDE would need to check this and pass a gold flag to whatever
	-- eventually implements a real Lore Board entry store.
}
TalentEffects.GraceUnderGod = {
	type = "Blessed", description = "Your execution animation cannot be interrupted.",
	onExecutionStart = setAttr("ExecutionUninterruptable"),
	onExecutionEnd = clearAttr("ExecutionUninterruptable"),
}
TalentEffects.ConfessorsImmunity = {
	type = "Blessed", description = "Immune to being targeted by Heretic's Sutra.",
	onHereticsSutraTargeted = function(player) return { immune = true } end,
}
TalentEffects.FatesWarning = {
	type = "Blessed", description = "Lore hook -- warned before a PDE event.",
	onApply = setAttr("FatesWarning"), onRemove = clearAttr("FatesWarning"),
}
TalentEffects.TheReturn = {
	type = "Blessed", description = "Lore hook -- a 10-minute window for the lore team to reverse a Valhalla confirmation.",
	onApply = setAttr("TheReturn"), onRemove = clearAttr("TheReturn"),
}
TalentEffects.MarkedByHeaven = {
	type = "Blessed", description = "A specific action phrase triggers a one-time gold outline, visible to everyone for 5s.",
	onApply = setAttr("MarkedByHeaven"), onRemove = clearAttr("MarkedByHeaven"),
	-- HOOK: ChatManager's /a handler would need to check for the trigger phrase and consult
	-- this talent + a MarkedUses counter before firing the gold-outline broadcast.
}
TalentEffects.StillWaters = {
	type = "Blessed", description = "Guard-breaking you now takes 3 separate posture hits instead of 1.",
	passiveModifier = { GuardBreakRequiredHits = 3 },
}

-- ================================================================================
-- EXTRA SANITY/RAGE PROTECTIVE TALENT -- ColdBlood/IronNerve/Stoicism/AwakenedEyes/
-- BloodInsight/BlindSight already exist as legacy talents; SoundVision is the one genuinely
-- new entry from this list.
-- ================================================================================

TalentEffects.SoundVision = {
	type = "Roleplay", description = "Sense nearby movement through sound alone.",
	onApply = setAttr("SoundVision"), onRemove = clearAttr("SoundVision"),
}

return TalentEffects

