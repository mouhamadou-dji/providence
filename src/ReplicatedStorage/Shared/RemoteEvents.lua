-- All RemoteEvents and RemoteFunctions defined here
-- Server creates them. Client reads them from ReplicatedStorage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteEvents = {}

local reFolder = ReplicatedStorage:FindFirstChild("RemoteEvents")
    or (function()
        local f = Instance.new("Folder")
        f.Name = "RemoteEvents"
        f.Parent = ReplicatedStorage
        return f
    end)()

local function getOrCreate(name, isFunction)
    local existing = reFolder:FindFirstChild(name)
    if existing then return existing end
    local obj = isFunction
        and Instance.new("RemoteFunction")
        or Instance.new("RemoteEvent")
    obj.Name = name
    obj.Parent = reFolder
    return obj
end

-- COMBAT -- removed 2026-08-02 (full revamp). RequestM1/M2/Parry/Block/BlockEnd/
-- Critical/Riposte/ClashInput, RequestPostureDrain/UpdatePostureBar, and the
-- OnHit/OnParryResult/OnGuardBreak/OnClashStart/OnClashResult/OnStagger results were
-- all deleted with the combat stack. The instances are archived at
-- ServerStorage._OldCombat_2026_08_02.Remotes. They MUST stay out of this file --
-- getOrCreate would resurrect them as orphan instances that nothing listens to.
-- The new combat system declares its own remotes here when it lands.

-- MOVEMENT -- stack removed 2026-08-04 (full revamp). RequestDash, RequestSprint,
-- RequestSprintEnd, RequestSlide and RequestJump were deleted with it, along with the
-- server->client OnDashDenied / OnSlideDenied cues. The instances are archived at
-- ServerStorage._OldMovement_2026_08_04.Remotes. They MUST stay out of this file --
-- getOrCreate would resurrect them as orphans nothing fires or listens to.
-- Jump is plain Roblox jump; nothing round-trips for it, and RequestSlide stays gone until
-- slide is rebuilt in pass 2.
--
-- Movement revamp pass 1 (2026-08-04) re-declares sprint and dash. These are FRESH
-- instances -- the originals were moved into ServerStorage by the teardown, so getOrCreate
-- mints new ones rather than resurrecting orphans.
RemoteEvents.RequestCrouch       = getOrCreate("RequestCrouch")        -- client -> server: toggle crouch
RemoteEvents.RequestSprint       = getOrCreate("RequestSprint")        -- client -> server: begin sprint
RemoteEvents.RequestSprintEnd    = getOrCreate("RequestSprintEnd")     -- client -> server: end sprint
RemoteEvents.RequestDash         = getOrCreate("RequestDash")          -- client -> server: dirToken, wasGrounded
RemoteEvents.RequestSlide        = getOrCreate("RequestSlide")         -- client -> server: slide started (C)
RemoteEvents.RequestSlideEnd     = getOrCreate("RequestSlideEnd")      -- client -> server: slide finished
RemoteEvents.OnDodgeResult       = getOrCreate("OnDodgeResult")        -- server -> client: {result="clean"|"fatigued"|"denied", reason, retryAfter, stock}
RemoteEvents.UpdateMovementState = getOrCreate("UpdateMovementState")  -- server -> client: "Crouch"|"CrouchEnd"|"Sprint"|"SprintEnd"

-- Movement rehaul phase 1 (2026-08-05): the VelocityManager. Server-initiated velocity
-- (knockback, launches) cannot be written server-side on a client-owned character -- the
-- next replication tick overwrites it -- so the server pushes a contribution spec and the
-- owning client's VelocityClient applies it. Server -> client ONLY; this system has no
-- client->server surface, so there is nothing to validate or rate-limit on the way in.
-- (A future displacement guard needs no echo either: the server authored the spec, so it
-- already knows exactly what displacement it should budget for.)
RemoteEvents.VelocityPush = getOrCreate("VelocityPush") -- server -> owning client: {id?, planar=Vector3, vertical?, duration, maxForce?, decay="none"|"linear", suppressInput?}

-- HUD / UI (server -> specific client)
RemoteEvents.UpdateHUD          = getOrCreate("UpdateHUD")
RemoteEvents.UpdateEclipseMoon  = getOrCreate("UpdateEclipseMoon")
RemoteEvents.ShowZoneNotify     = getOrCreate("ShowZoneNotify")
RemoteEvents.ShowGlobalMessage  = getOrCreate("ShowGlobalMessage")
RemoteEvents.TriggerQTE         = getOrCreate("TriggerQTE")
RemoteEvents.QTEResult          = getOrCreate("QTEResult")

-- WEATHER
RemoteEvents.UpdateWeather  = getOrCreate("UpdateWeather")
RemoteEvents.UpdateLighting = getOrCreate("UpdateLighting")
RemoteEvents.ApplyZoneFog   = getOrCreate("ApplyZoneFog")

-- DATA
RemoteEvents.RequestJournalData = getOrCreate("RequestJournalData", true)

-- INVENTORY / HOTBAR
RemoteEvents.UpdateInventory  = getOrCreate("UpdateInventory")   -- server -> client: (inventory array, equippedSlotIndex|nil)
RemoteEvents.RequestEquipSlot = getOrCreate("RequestEquipSlot")  -- client -> server: hotbar slot index (1-10) to equip

-- MOD MENU
RemoteEvents.ModCommand       = getOrCreate("ModCommand")
RemoteEvents.ModMenuData      = getOrCreate("ModMenuData", true)
RemoteEvents.PDSoundEvent     = getOrCreate("PDSoundEvent")
RemoteEvents.ModFlyToggle     = getOrCreate("ModFlyToggle")
RemoteEvents.RequestModFly    = getOrCreate("RequestModFly")
RemoteEvents.ModFullLog       = getOrCreate("ModFullLog", true)
RemoteEvents.ModPlayerTalents = getOrCreate("ModPlayerTalents", true)
RemoteEvents.ModLoreBoard     = getOrCreate("ModLoreBoard", true)
RemoteEvents.ModSelfEffect    = getOrCreate("ModSelfEffect")
RemoteEvents.ModTargetEffect  = getOrCreate("ModTargetEffect")
RemoteEvents.ShowNotification = getOrCreate("ShowNotification")
RemoteEvents.ShowWhisper      = getOrCreate("ShowWhisper")
RemoteEvents.ShowAlert        = getOrCreate("ShowAlert")
RemoteEvents.PDGlobalAnnounce = getOrCreate("PDGlobalAnnounce") -- server -> all clients: global Permanent Death activation cinematic

-- CHAT (legacy hooks — kept for backwards compat)
RemoteEvents.ActionCommand    = getOrCreate("ActionCommand")
RemoteEvents.LoreTeamMessage  = getOrCreate("LoreTeamMessage")

-- CHAT SYSTEM (ChatManager / ChatClient)
RemoteEvents.SendChatMessage  = getOrCreate("SendChatMessage")  -- custom chat client → server
RemoteEvents.ChatBubble       = getOrCreate("ChatBubble")        -- server → nearby clients: overhead bubble
RemoteEvents.ChatEvent      = getOrCreate("ChatEvent")      -- server → clients: {type,charName,zone,text,color}
RemoteEvents.ShoutBroadcast = getOrCreate("ShoutBroadcast") -- server → in-range: shout overlay
RemoteEvents.ThoughtNotif   = getOrCreate("ThoughtNotif")   -- server → all mods: thought panel
RemoteEvents.LiveFeedUpdate = getOrCreate("LiveFeedUpdate") -- server → all mods: live feed entry
RemoteEvents.BroadcastMsg   = getOrCreate("BroadcastMsg")   -- server → target: [LORE TEAM] message
RemoteEvents.ModBroadcast   = getOrCreate("ModBroadcast")   -- mod client → server: send broadcast

-- DOWNED / CARRY / EXECUTE -- removed 2026-08-02 with the combat stack.
-- NOTE: the downed/grip-execution path was the kill hook that SanityManager and
-- RageManager keyed off. Whatever replaces it needs to re-fire that hook.


-- IDENTITY (gender select, name visibility, appearance)
RemoteEvents.ShowGenderSelect   = getOrCreate("ShowGenderSelect")             -- server → client: prompt gender pick
RemoteEvents.SubmitGenderSelect = getOrCreate("SubmitGenderSelect")           -- client → server: {"Male"|"Female"}
RemoteEvents.GetKnownNames      = getOrCreate("GetKnownNames", true)          -- RF, client fetch on spawn
RemoteEvents.NameLearned        = getOrCreate("NameLearned")                  -- server → client: incremental KnownNames update

-- EMOTE WHEEL
RemoteEvents.RequestPlayEmote = getOrCreate("RequestPlayEmote") -- client -> server: emoteId
RemoteEvents.OnPlayEmote      = getOrCreate("OnPlayEmote")      -- server -> all clients: {player, animId, loop}
RemoteEvents.RequestStopEmote = getOrCreate("RequestStopEmote") -- client -> server: movement cancelled a looping emote
RemoteEvents.OnFocusUpdate    = getOrCreate("OnFocusUpdate")    -- server -> client: meditation/pushups stage/interrupt events

-- QTE (foundation for meditation, pushups, interactables, mod-triggered)
RemoteEvents.QTEStart        = getOrCreate("QTEStart")        -- server -> client: {instanceId, tierName, tierConfig, context}
RemoteEvents.QTESubmitResult = getOrCreate("QTESubmitResult") -- client -> server: instanceId, success
RemoteEvents.QTEOutcome      = getOrCreate("QTEOutcome")      -- server -> client: instanceId, success (final confirm)

-- SPIRITS
RemoteEvents.RequestSpiritInteract = getOrCreate("RequestSpiritInteract") -- client -> server: spirit instance

-- INTERACTABLES
RemoteEvents.RequestInteractableTrigger = getOrCreate("RequestInteractableTrigger") -- client -> server: interactable instance

-- MOD ACTION CARD -- generic persistent mod-facing prompt with buttons that just fire the
-- existing ModCommand pipeline (see ModMenuClient's `fire`). Used by meditation/pushups
-- milestones and spirit interactions instead of one-off bespoke remotes each.
RemoteEvents.ModActionCard = getOrCreate("ModActionCard") -- server -> all mods

-- NPC SYSTEM
RemoteEvents.NPCSpeak = getOrCreate("NPCSpeak") -- server -> all clients: {head=Instance, name=string, text=string, color, duration}

-- INJURIES
RemoteEvents.InsanityHallucination = getOrCreate("InsanityHallucination") -- server -> owning client: {kind, position|targetUserId}

-- RITUALS
RemoteEvents.RequestPlaceRitualCircle = getOrCreate("RequestPlaceRitualCircle") -- client -> server: (no args, uses player position)
RemoteEvents.RequestPlaceRitualItem   = getOrCreate("RequestPlaceRitualItem")   -- client -> server: circlePart, itemSlotIndex
RemoteEvents.RequestRemoveRitualItem  = getOrCreate("RequestRemoveRitualItem")  -- client -> server: circlePart, itemIndex (owner only)
RemoteEvents.RequestSubmitRitual      = getOrCreate("RequestSubmitRitual")      -- client -> server: circlePart
RemoteEvents.RitualSubmittedNotify    = getOrCreate("RitualSubmittedNotify")    -- server -> all mods: {circlePart, ownerName, position, items}
RemoteEvents.RequestRitualDecision    = getOrCreate("RequestRitualDecision")    -- mod client -> server: circlePart, "approve"|"reject"|"ignore", effectText
RemoteEvents.RitualOutcome            = getOrCreate("RitualOutcome")            -- server -> owner+nearby: {approved, effectText}

-- POTIONS
RemoteEvents.RequestUsePotion  = getOrCreate("RequestUsePotion")  -- client -> server: slotIndex
RemoteEvents.PotionUseFeedback = getOrCreate("PotionUseFeedback") -- server -> user: {ok, message, potionId}

-- CUSTOM MOD BTOOLS
RemoteEvents.RequestBToolAction = getOrCreate("RequestBToolAction") -- client -> server: action, ...args
RemoteEvents.BToolFeedback      = getOrCreate("BToolFeedback")      -- server -> requesting mod: {ok, message, count}

-- SANITY / RAGE / FEELINGS / ALLY SYSTEM
RemoteEvents.UpdateSanityEffects = getOrCreate("UpdateSanityEffects") -- server -> owning client: {sanity, tiers={scratch,scribble,shadow,shadowAttack,cliffPull}}
RemoteEvents.SanityScratchTrigger = getOrCreate("SanityScratchTrigger") -- server -> owning client: fire the scratch animation/damage moment
RemoteEvents.SanityShadowSpawn    = getOrCreate("SanityShadowSpawn")    -- server -> owning client: spawn/attack a shadow figure
RemoteEvents.TriggerFeeling       = getOrCreate("TriggerFeeling")       -- server -> owning client: {feelingId}
RemoteEvents.RageStateChanged     = getOrCreate("RageStateChanged")     -- server -> owning client: {active, exhausted}
RemoteEvents.RageBroadcast        = getOrCreate("RageBroadcast")        -- server -> nearby clients: {targetUserId, active} (red glow/scream visibility)
RemoteEvents.AllyBondFormed       = getOrCreate("AllyBondFormed")       -- server -> the two allies
RemoteEvents.RageDebuffPrompt     = getOrCreate("RageDebuffPrompt")     -- server -> all mods: lore team must assign an exit debuff

-- INTERACTABLE FRAMEWORK (design doc: Interactables/Mining/Smelting/Tailoring/Smithing/Farming)
RemoteEvents.ShowChestUI        = getOrCreate("ShowChestUI")        -- server -> client: {partRef, slots={itemName,quality}, title}
RemoteEvents.RequestTakeChestItem = getOrCreate("RequestTakeChestItem") -- client -> server: chestPart, slotIndex
RemoteEvents.ShowWorldJournal    = getOrCreate("ShowWorldJournal")    -- server -> client: {title, text}
RemoteEvents.CustomInteractTriggered = getOrCreate("CustomInteractTriggered") -- server -> client: {name}

-- Mining needs no new remotes -- it's a new QTE `type` ("ReactiveClick") that reuses the
-- existing QTEStart/QTESubmitResult/QTEOutcome pipeline, see Config.QTETiers.MiningQTE.

RemoteEvents.SmeltingOpenUI      = getOrCreate("SmeltingOpenUI")      -- server -> client: {smelterPart, ores={itemName,count}}
RemoteEvents.RequestStartSmelt   = getOrCreate("RequestStartSmelt")   -- client -> server: smelterPart, oreName
RemoteEvents.SmeltingQTEStart    = getOrCreate("SmeltingQTEStart")    -- server -> client: {smelterPart, greenZoneWidth, barSpeed, markerSpeed}
RemoteEvents.SmeltingQTESubmit   = getOrCreate("SmeltingQTESubmit")   -- client -> server: smelterPart, outcome ("Success"|"Partial"|"Fail")
RemoteEvents.SmeltingQTEResult   = getOrCreate("SmeltingQTEResult")   -- server -> client: {outcome}
RemoteEvents.SmeltingProgress    = getOrCreate("SmeltingProgress")    -- server -> owner: {smelterPart, secondsLeft, ready}
RemoteEvents.RequestCollectSmelt = getOrCreate("RequestCollectSmelt") -- client -> server: smelterPart

RemoteEvents.TailoringOpenUI     = getOrCreate("TailoringOpenUI")     -- server -> client: {stationPart, recipes}
RemoteEvents.RequestStartTailoring = getOrCreate("RequestStartTailoring") -- client -> server: stationPart, garmentName
RemoteEvents.TailoringStart      = getOrCreate("TailoringStart")      -- server -> client: {stationPart, shape, timeLimit}
RemoteEvents.TailoringSubmitResult = getOrCreate("TailoringSubmitResult") -- client -> server: stationPart, outcome ("Success"|"Rip"|"Timeout")
RemoteEvents.TailoringResult     = getOrCreate("TailoringResult")     -- server -> client: {outcome}

RemoteEvents.SmithingOpenUI      = getOrCreate("SmithingOpenUI")      -- server -> client: {forgePart, recipes}
RemoteEvents.RequestStartSmithing = getOrCreate("RequestStartSmithing") -- client -> server: forgePart, weaponName
RemoteEvents.SmithingHammerBeat  = getOrCreate("SmithingHammerBeat")  -- server -> client: {step, total} (hammer anim + spark cue between QTEs)
RemoteEvents.SmithingComplete    = getOrCreate("SmithingComplete")    -- server -> client: {success, qualityTier, fails}

RemoteEvents.FarmingOpenSeedSelect = getOrCreate("FarmingOpenSeedSelect") -- server -> client: {plotPart, seeds}
RemoteEvents.RequestPlantSeed    = getOrCreate("RequestPlantSeed")    -- client -> server: plotPart, seedName
RemoteEvents.FarmingFeedback     = getOrCreate("FarmingFeedback")     -- server -> client: {message}

-- CASTE / REVEAL / TITLES (design doc: DNA Caste System, NPC Info Reveal & Mod Player Viewer)
RemoteEvents.ShowStatReveal      = getOrCreate("ShowStatReveal")      -- server -> the asking client only: {speaker, lines={...}, revealType}
RemoteEvents.ModPlayerInfo       = getOrCreate("ModPlayerInfo", true) -- mod client -> server: playerName; returns the full Player Info Viewer model
RemoteEvents.ModRevealerConfig   = getOrCreate("ModRevealerConfig", true) -- mod client -> server: npcId; returns {isRevealer, revealType, cost, cooldown}

return RemoteEvents
