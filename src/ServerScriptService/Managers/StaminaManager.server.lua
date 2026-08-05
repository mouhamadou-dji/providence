local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")

local Config  = require(RepStorage.Shared.Config)
local Remotes = require(RepStorage.Shared.RemoteEvents)

local function getOrCreateRE(name)
	local folder = RepStorage:FindFirstChild("RemoteEvents")
		or (function() local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f end)()
	local r = folder:FindFirstChild(name)
	if r then return r end
	r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = folder
	return r
end
local RE_MovState = getOrCreateRE("UpdateMovementState") -- Turn Speed Cap: AttackStart/AttackEnd
local RE_CombatTagged = getOrCreateRE("CombatTagged") -- server -> client: (re)start the "In Combat" indicator's countdown

local st  = Config.Stamina
local com = Config.Combat
local hungerCfg = Config.Hunger
local waterCfg  = Config.Water

local data = {}   -- [userId] = {current, lastHitTime}

local function isDead(p)
	local dm = _G.DataManager
	return dm and dm.getValue(p, "PlayerState") == "Dead"
end

local function getHunger(p)
	local dm = _G.DataManager
	return (dm and dm.getValue(p, "Hunger")) or 100
end

local function getWater(p)
	local dm = _G.DataManager
	return (dm and dm.getValue(p, "Water")) or 100
end

-- Hunger/Water jointly gate HP regen: full rate above LowThreshold, tapering down to
-- MinHealMult as either one bottoms out, and a hard 0 (no healing at all) once BOTH are
-- completely empty. Previously only Hunger existed and only ever halved the rate at
-- exactly 0 (HungerZeroRegenMult below) rather than tapering or considering Water at all.
local function healMultiplier(hunger, water)
	if hunger <= 0 and water <= 0 then return 0 end
	local function taper(v, cfg)
		if v >= cfg.LowThreshold then return 1 end
		local t = math.max(0, v) / cfg.LowThreshold
		return cfg.MinHealMult + (1 - cfg.MinHealMult) * t
	end
	return taper(hunger, hungerCfg) * taper(water, waterCfg)
end

local function inCombat(p)
	local d = data[p.UserId]
	if not d then return false end
	return (tick() - d.lastHitTime) < (com.CombatTagDuration or 60)
end

-- Aeliana's DNA buff (+10 StaminaMax) and the ReinforcedMuscles talent (+15, design doc
-- "ABYSS Full Talents Integration") both stack additively on the base Config.Stamina.Max --
-- recalculated fresh every call, never cached, so either changing takes effect immediately.
local function effectiveMax(p)
	local dnaM = _G.DNAManager
	local tm = _G.TalentManager
	local casteM = _G.CasteManager -- Sequani's purity-scaled +5, same additive stacking
	return st.Max + (dnaM and dnaM.getStaminaMaxBonus(p) or 0) + (tm and tm.getModifier(p, "MaxStaminaAdd") or 0)
		+ (casteM and casteM.getMaxStaminaBonus(p) or 0)
end

local function syncHUD(p, d)
	Remotes.UpdateHUD:FireClient(p, {Stamina = math.floor(d.current * 10) / 10, StaminaMax = effectiveMax(p)})
end

local DOWNED_RECOVER_PCT = 0.15 -- fraction of MaxHealth a Downed player must regen to auto-get-up

local EXHAUST_TRIGGER_THRESHOLD = 4  -- drain() refuses any action it can't fully afford, so stamina
local EXHAUST_RECOVER_THRESHOLD = 15 -- realistically bottoms out near the cheapest action's cost (Feint=4)
-- rather than hitting exactly 0 — "exhausted" means "can't afford to do anything meaningful", not literal zero.

local function updateExhaustion(d)
	if d.current < EXHAUST_TRIGGER_THRESHOLD then d.exhausted = true
	elseif d.exhausted and d.current > EXHAUST_RECOVER_THRESHOLD then d.exhausted = false end
end

local function initPlayer(p)
	data[p.UserId] = {current = effectiveMax(p), lastHitTime = 0, exhausted = false, lastSpeed = 0, wasAttacking = false}
	syncHUD(p, data[p.UserId])
	print("[StaminaManager] Init " .. p.Name)
end

-- Regen loop: rates are per-second, multiplied by dt each frame
-- Out of combat: RegenIdle=1 → 1/s → 3 per 3s
-- In combat:     RegenCombat=0.4 → 0.4/s → 2 per 5s
-- Throttled onLowHPState dispatch (SurvivorsInstinct/BerserkrBlood/PaleRider) -- runs every
-- 0.5s per player rather than every Heartbeat frame; low-HP thresholds don't need tighter
-- than that, and firing a full talent-hook loop for every player every frame would be wasted
-- work at any real player count.
local lowHPAccum = 0

RunService.Heartbeat:Connect(function(dt)
	lowHPAccum += dt
	local checkLowHP = lowHPAccum >= 0.5
	if checkLowHP then lowHPAccum = 0 end

	for _, p in ipairs(Players:GetPlayers()) do
		local d = data[p.UserId]
		if not d then continue end
		local dead = isDead(p)

		local combat  = inCombat(p)

		if checkLowHP and not dead then
			local tm = _G.TalentManager
			local char = p.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if tm and hum and hum.MaxHealth > 0 then
				tm.fireHook(p, "onLowHPState", hum.Health / hum.MaxHealth)
			end
		end

		-- Passive Hunger/Water drain -- DrainPassiveRate existed in Config for Hunger already
		-- but nothing ever actually applied it; Water is tuned to drain faster by design.
		-- Still frozen while "Dead" (void limbo) -- only stamina regen below was asked to keep
		-- working there, so hunger/water/HP stay paused same as before.
		if not dead then
			local dm0 = _G.DataManager
			if dm0 then
				-- Talent compendium (IronStomach/HungerDiscipline/EternalHunger/SurvivorsInstinct) --
				-- HungerDrainRate multiplies the rate same as any other modifier; SurvivorsInstinct's
				-- SuppressHungerDrain attribute (set by its own onLowHPState hook) zeroes it outright
				-- below 20% HP rather than just slowing it.
				local tm = _G.TalentManager
				local char = p.Character
				local suppressed = char and char:GetAttribute("SuppressHungerDrain")
				local hungerMul = suppressed and 0 or (tm and tm.getModifier(p, "HungerDrainRate") or 1)
				-- Parisii HungerThirstEfficiency slows BOTH tracks (the caste that knows how to go
				-- without) -- unlike the talent modifier above, which is hunger-only.
				local casteM0 = _G.CasteManager
				local casteDrainMul = casteM0 and casteM0.getHungerThirstDrainMultiplier(p) or 1
				dm0.setValue(p, "Hunger", math.max(0, (dm0.getValue(p,"Hunger") or 100) - hungerCfg.DrainPassiveRate*dt*hungerMul*casteDrainMul))
				dm0.setValue(p, "Water",  math.max(0, (dm0.getValue(p,"Water")  or 100) - waterCfg.DrainPassiveRate*dt*casteDrainMul))
			end
		end

		local hunger  = getHunger(p)
		local water   = getWater(p)
		local hungMul = hunger <= 0 and (st.HungerZeroRegenMult or 0.5) or 1

		-- Rage Exhaustion: -- 50% slower stamina/HP regen for its duration (see RageManager).
		local rageM = _G.RageManager
		local rageMul = rageM and rageM.getRegenMult(p) or 1

		-- Stamina regen -- now allowed even while "Dead": the void's floatable parkour needs
		-- dash/sprint/slide to work there (CombatManager.isActionBlocked no longer blocks those
		-- for Dead players either), and none of that works for long without stamina to spend.
		if d.current < effectiveMax(p) then
			local im = _G.InjuryManager
			local injuryMul = im and im.getStaminaRegenMultiplier(p) or 1 -- ConcussedMind halves regen
			-- Wine/Ale intoxication (design doc PART FOUR, see EdibleManager/IntoxicationClient) --
			-- -20% stamina regen for the drink's duration, off the same IntoxicatedUntil attribute
			-- the client reads for its camera-sway effect.
			local intoxMul = (tick() < (p:GetAttribute("IntoxicatedUntil") or 0)) and Config.Intoxication.StaminaRegenMult or 1
			local casteM = _G.CasteManager -- Sequani StaminaRegenBonus (+10% at full purity)
			local casteRegenMul = casteM and casteM.getStaminaRegenMultiplier(p) or 1
			local rate = (combat and st.RegenCombat or st.RegenIdle) * hungMul * injuryMul * rageMul * intoxMul * casteRegenMul
			d.current  = math.min(effectiveMax(p), d.current + rate * dt)
			updateExhaustion(d)
			syncHUD(p, d)
		end

		if dead then continue end -- HP regen / wall-impact below stay frozen while "Dead", as before

		-- HP regen: fully frozen while dead/carried/being executed. Downed is a special case --
		-- regen keeps ticking at the idle rate so a knocked player can heal back up; once they
		-- cross DOWNED_RECOVER_PCT of MaxHealth, CombatManager.recoverFromDowned() gets them back
		-- on their feet automatically (see below).
		local char = p.Character
		local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
		local cm   = _G.CombatManager
		local cs   = cm and cm.getCombatState(p)
		local locked = cs=="Dead" or cs=="BeingCarried" or cs=="BeingExecuted"

		-- Turn Speed Cap (attacks): tell the client when an attack starts/ends so it can cap
		-- rotation. Centralized here (transition detection) rather than instrumenting every
		-- attack-start/attack-end call site in CombatManager individually.
		-- Uses CombatManager's dedicated turn-cap window, not the raw combatState=="Attacking"
		-- check -- that state persists across an entire M1 chain's post-swing grace window (up
		-- to 2s of no follow-up), which kept rotation capped long after a single swing actually
		-- finished ("you don't turn after you hit someone").
		local isAttacking = cm ~= nil and cm.isTurnCapped(p)
		if isAttacking and not d.wasAttacking then
			RE_MovState:FireClient(p, "AttackStart")
		elseif d.wasAttacking and not isAttacking then
			RE_MovState:FireClient(p, "AttackEnd")
		end
		d.wasAttacking = isAttacking
		if hum and not locked and hum.Health > 0 and hum.Health < hum.MaxHealth then
			if cs == "Downed" then
				local hpRate = (st.HPRegenIdle or 1) * healMultiplier(hunger, water) * rageMul
				hum.Health = math.min(hum.MaxHealth, hum.Health + hpRate * dt)
				if hum.Health >= hum.MaxHealth * DOWNED_RECOVER_PCT and cm and cm.recoverFromDowned then
					cm.recoverFromDowned(p)
				end
			else
				local hpRate = (combat and (st.HPRegenCombat or 0.4) or (st.HPRegenIdle or 1)) * healMultiplier(hunger, water) * rageMul
				hum.Health   = math.min(hum.MaxHealth, hum.Health + hpRate * dt)
			end
		end

		-- Wall/Ground Impact (Part Eleven): a sharp velocity drop after a fast (knockback-
		-- speed) moment means a collision. Piggybacks this existing per-frame loop instead
		-- of adding a second Heartbeat connection just for this.
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			local speed = hrp.AssemblyLinearVelocity.Magnitude
			if d.lastSpeed > 25 and speed < d.lastSpeed * 0.3 and cm and cm.spawnWallImpact then
				cm.spawnWallImpact(hrp.Position)
			end
			d.lastSpeed = speed
		end
	end
end)

Players.PlayerAdded:Connect(function(p)
	initPlayer(p)
	p.CharacterAdded:Connect(function()
		local d = data[p.UserId]
		if d then
			-- Full reset on every respawn (not just first join) -- a player who dies at low/zero
			-- stamina or exhausted, or mid-combat-tag, otherwise spawned back in still stuck in
			-- that state with a fresh body that can't do anything.
			d.current = effectiveMax(p)
			d.exhausted = false
			d.wasAttacking = false
			d.lastHitTime = 0
			d.lastSpeed = 0
			task.wait(0.1); syncHUD(p, d)
		end
	end)
end)
Players.PlayerRemoving:Connect(function(p) data[p.UserId] = nil end)
for _, p in ipairs(Players:GetPlayers()) do task.spawn(initPlayer, p) end

local SM = {}

function SM.get(p)
	local d = data[p.UserId]; return d and d.current or 0
end

function SM.drain(p, amount)
	local d = data[p.UserId]; if not d then return false end
	local hunger = getHunger(p)
	local cost   = amount * (hunger <= 0 and (st.HungerZeroDrainMult or 1.2) or 1)
	if d.current < cost then return false end
	d.current = math.max(0, d.current - cost)
	updateExhaustion(d)
	syncHUD(p, d)
	return true
end

function SM.isExhausted(p)
	local d = data[p.UserId]; return d ~= nil and d.exhausted == true
end

function SM.refund(p, amount)
	local d = data[p.UserId]; if not d then return end
	d.current = math.min(effectiveMax(p), d.current + amount)
	syncHUD(p, d)
end

function SM.canAfford(p, amount)
	local d = data[p.UserId]; return d ~= nil and d.current >= amount
end

function SM.tagCombat(p)
	local d = data[p.UserId]; if not d then return end
	d.lastHitTime = tick()
	-- Client owns its own countdown/hide timer off this duration rather than the server
	-- polling everyone's inCombat() every frame just to flip a GUI -- re-tagging (another hit
	-- landed or taken) just re-fires this, which naturally resets the client's countdown too.
	RE_CombatTagged:FireClient(p, com.CombatTagDuration or 60)
	print("[StaminaManager] Combat tagged: " .. p.Name)
end

function SM.isInCombat(p) return inCombat(p) end

function SM.set(p, amount)
	local d = data[p.UserId]; if not d then return end
	d.current = math.clamp(amount, 0, effectiveMax(p))
	syncHUD(p, d)
end

SM.Costs = st
_G.StaminaManager = SM

print(string.format("[StaminaManager] Init — idle %.1f/s | combat %.1f/s | HPidle %.1f/s | HPcombat %.1f/s",
	st.RegenIdle, st.RegenCombat, st.HPRegenIdle or 1, st.HPRegenCombat or 0.4))
