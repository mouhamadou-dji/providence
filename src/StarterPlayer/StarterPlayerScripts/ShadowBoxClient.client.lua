-- ShadowBoxClient -- design doc PART ONE. Everything about the shadow figure (spawn, AI,
-- "hit" detection, death) lives here and ONLY here -- a LocalScript-created Instance never
-- replicates to the server or other clients, which is exactly what makes this purely-personal
-- practice mode free (no server load, invisible to everyone else) by construction, not by
-- convention. The shadow's damage back to the player is deliberately cosmetic-only (never
-- touches the real Humanoid.Health) -- mutating real Health here would fight the server's
-- own regen/HealthChanged-based "real damage interrupts practice" watchdog in ShadowBoxManager.

local Players         = game:GetService("Players")
local RepStorage      = game:GetService("ReplicatedStorage")
local RunService      = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService    = game:GetService("TweenService")

local player = Players.LocalPlayer

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local sbCfg  = Config.ShadowBoxing
-- The shadow obeys the SAME combat laws as real players -- all timing/window numbers come
-- straight from the shared combat config instead of being invented locally.
local CombatCfg    = Config.Combat
local ParryCfg     = Config.Parry
local SpeedCfg     = Config.Speed
local COMBAT_ANIMS = Config.CombatAnims

local Remotes = RepStorage:WaitForChild("RemoteEvents")
local RE_ShadowPracticeState = Remotes:WaitForChild("ShadowPracticeState")

local AnimFolder = RepStorage:WaitForChild("_Animations")
local FistAnims  = AnimFolder:WaitForChild("Fist")
local CombatAnims = AnimFolder:WaitForChild("Combat")
local MoveAnims  = AnimFolder:WaitForChild("Movement")

local shadowModel, shadowHum, shadowAnimator, shadowHRP
local hitsLanded = 0
local hitsToDefeat = 0 -- set from the server's ShadowPracticeState payload (mod-configurable, see ModManager.setShadowBoxHits)
local aiRunning = false
local lastPlayerHitAt = 0
local dying = false

-- Shadow-side combat state (same state law real players live under: stagger locks actions,
-- ender endlag locks the chain, parry has a cooldown).
local shadowState = {
	staggeredUntil     = 0,
	blockingUntil      = 0,
	endlagUntil        = 0,
	attacking          = false,
	parryCooldownUntil = 0,
}

-- Player-side defense tracking, mirroring InputHandler's F law exactly: press = instant
-- parry attempt (WindowTotal frames), still-held past the window = block, cooldown gates
-- spam. Also mirrors the got-parried stagger the server would apply in real combat.
local playerParryPressedAt     = -math.huge
local playerFDownAt            = 0
local playerHoldingF           = false
local playerParryCooldownUntil = 0
local playerStaggeredUntil     = 0

-- Small local-only status toast (top-center, fades) -- avoids depending on any other
-- system's notification GUI plumbing for a purely client-side feature.
local statusGui
local function ensureStatusGui()
	if statusGui and statusGui.Parent then return statusGui end
	local pg = player:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "ShadowBoxStatus"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.Parent = pg
	local label = Instance.new("TextLabel")
	label.Name = "Status"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.12, 0)
	label.Size = UDim2.new(0, 420, 0, 30)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Antique
	label.TextSize = 20
	label.TextColor3 = Color3.fromRGB(210, 200, 180)
	label.TextTransparency = 1
	label.TextStrokeTransparency = 0.5
	label.Text = ""
	label.Parent = screen
	statusGui = screen
	return screen
end

local function statusToast(text)
	local screen = ensureStatusGui()
	local label = screen.Status
	label.Text = text
	label.TextTransparency = 0
	TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
	task.delay(2.2, function()
		if label and label.Text == text then
			TweenService:Create(label, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		end
	end)
end

local function screenFlash(color, transparency)
	local screen = ensureStatusGui()
	local flash = screen:FindFirstChild("HitFlash")
	if not flash then
		flash = Instance.new("Frame")
		flash.Name = "HitFlash"
		flash.Size = UDim2.new(1, 0, 1, 0)
		flash.BackgroundColor3 = color
		flash.BorderSizePixel = 0
		flash.BackgroundTransparency = 1
		flash.ZIndex = 0
		flash.Parent = screen
	end
	flash.BackgroundColor3 = color
	flash.BackgroundTransparency = transparency
	TweenService:Create(flash, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
end

local function playOn(rigAnimator, animObj, priority)
	if not rigAnimator or not animObj then return nil end
	local ok, track = pcall(function() return rigAnimator:LoadAnimation(animObj) end)
	if not ok or not track then return nil end
	track.Priority = priority or Enum.AnimationPriority.Action2
	track:Play()
	return track
end

local function playAnimId(rigAnimator, animId, priority)
	if not rigAnimator or not animId or animId == "" then return nil end
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local ok, track = pcall(function() return rigAnimator:LoadAnimation(anim) end)
	if not ok or not track then return nil end
	track.Priority = priority or Enum.AnimationPriority.Action2
	track:Play()
	return track
end

local function playShadowAnimId(animId)
	return playAnimId(shadowAnimator, animId)
end

-- Cosmetic reaction anims on the local player's own rig (got-hit, got-parried) -- local
-- animation only, never touches server state.
local function playPlayerAnimId(animId)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	return playAnimId(animator, animId, Enum.AnimationPriority.Action3)
end

-- ── Real-combat feedback layer ────────────────────────────────────────────────
-- The shadow already obeyed the same combat LAWS as a real player (timings/windows/stagger
-- all come from shared config), but it is client-only, so it never fires OnHit /
-- OnParryResult / OnStagger -- which is exactly what drives every piece of feedback a real
-- fight has. Result: correct combat that felt like nothing. These mirror CombatManager's own
-- spawn functions (same authored-VFX attribute convention, same blood/flash) and the shared
-- _Sounds.Combat library, just run locally so the practice mode stays free and invisible.
local Debris       = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local SoundsRoot   = RepStorage:FindFirstChild("_Sounds")
local CombatSounds = SoundsRoot and SoundsRoot:FindFirstChild("Combat")
local function soundId(name)
	local s = CombatSounds and CombatSounds:FindFirstChild(name)
	local id = s and s.SoundId
	if not id or id == "" or id == "rbxassetid://0" then return nil end
	return id
end

-- Positional (3D) for impacts, so a hit sounds like it happened where it happened.
local function playSoundAt(name, position, volume)
	local id = soundId(name); if not id or not position then return end
	local anchor = Instance.new("Part")
	anchor.Name = "ShadowSFX"; anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position); anchor.Parent = workspace
	local snd = Instance.new("Sound")
	snd.SoundId = id; snd.Volume = volume or 0.6
	snd.PlaybackSpeed = 0.96 + math.random() * 0.08 -- same pitch variance real combat uses
	snd.Parent = anchor; snd:Play()
	Debris:AddItem(anchor, 6)
end

-- 2D for parries, matching CombatFeelClient (a parry is a personal cue, not a world event).
local function play2D(name, volume)
	local id = soundId(name); if not id then return end
	local snd = Instance.new("Sound")
	snd.SoundId = id; snd.Volume = volume or 0.5
	snd.PlaybackSpeed = 0.98 + math.random() * 0.1
	snd.RollOffMaxDistance = 0
	snd.Parent = SoundService; snd:Play()
	snd.Ended:Once(function() if snd.Parent then snd:Destroy() end end)
	task.delay(8, function() if snd.Parent then snd:Destroy() end end)
end
-- Several combat sounds are still unauthored placeholders (Parry_Late among them), so fall
-- through to the next best real sound instead of playing silence at the player.
local function play2DAny(names, volume)
	for _, n in ipairs(names) do
		if soundId(n) then play2D(n, volume); return end
	end
end

-- Authored VFX packs, cloned with CombatManager's exact per-emitter attribute convention
-- (EmitDelay / EmitCount / EmitDuration, GetDescendants so nested packs like Parry -- whose
-- real emitters sit several Attachments deep -- aren't silently skipped).
local vfxCombat = workspace:FindFirstChild("VFX") and workspace.VFX:FindFirstChild("combat")
local vfxHit    = vfxCombat and vfxCombat:FindFirstChild("Hit")
local vfxBlock  = vfxCombat and vfxCombat:FindFirstChild("Block")
local vfxParry  = vfxCombat and vfxCombat:FindFirstChild("Parry")
local function spawnVFX(sourcePart, position, defaultCount, defaultDuration)
	if not sourcePart or not position then return end
	local sourceAttachment = sourcePart:FindFirstChildOfClass("Attachment")
	if not sourceAttachment then return end
	local anchor = Instance.new("Part")
	anchor.Name = sourcePart.Name .. "FX_Shadow"
	anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position); anchor.Parent = workspace
	local attachment = Instance.new("Attachment"); attachment.Parent = anchor
	local maxCleanup = 0.5
	for _, child in ipairs(sourceAttachment:GetDescendants()) do
		if child:IsA("ParticleEmitter") then
			local clone = child:Clone()
			clone.Enabled = false
			clone.Parent = attachment
			local d = child:GetAttribute("EmitDelay") or 0
			local count = child:GetAttribute("EmitCount") or defaultCount
			local duration = child:GetAttribute("EmitDuration")
			if duration == nil then duration = defaultDuration end
			task.delay(d, function()
				if not clone.Parent then return end
				clone:Emit(count)
				clone.Enabled = true
				task.delay(duration, function() if clone then clone.Enabled = false end end)
			end)
			maxCleanup = math.max(maxCleanup, d + duration + child.Lifetime.Max + 0.5)
		end
	end
	Debris:AddItem(anchor, maxCleanup)
end
-- Same default counts/durations CombatManager passes for each pack.
local function spawnHitVFX(p)   spawnVFX(vfxHit,   p, 12, 0.3) end
local function spawnBlockVFX(p) spawnVFX(vfxBlock, p, 50, 0.4) end
local function spawnParryVFX(p) spawnVFX(vfxParry, p,  8, 0.3) end

local function spawnBloodBurst(position, sizeMult)
	if not position then return end
	sizeMult = sizeMult or 1
	local anchor = Instance.new("Part")
	anchor.Name = "BloodBurstFX"; anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position); anchor.Parent = workspace
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(Color3.fromRGB(120, 10, 10)) -- dark arterial red, matching CombatManager
	e.Size = NumberSequence.new(0.35 * sizeMult)
	e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.1),NumberSequenceKeypoint.new(1,1)})
	e.Speed = NumberRange.new(4 * sizeMult, 9 * sizeMult)
	e.Lifetime = NumberRange.new(0.2, 0.4)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rate = 0
	e.Parent = anchor
	e:Emit(math.max(4, math.floor(9 * sizeMult)))
	Debris:AddItem(anchor, 0.6)
end

local function spawnImpactFlash(model)
	if not model then return end
	local hl = Instance.new("Highlight")
	hl.FillColor = Color3.new(1, 1, 1)
	hl.FillTransparency = 0.6
	hl.OutlineTransparency = 1
	hl.Parent = model
	Debris:AddItem(hl, 0.05) -- ~1 frame, same as real hits
end

-- Camera effects are borrowed from CombatFeelClient rather than reimplemented -- it owns the
-- camera CFrame and FieldOfView, and a second writer here would fight it. No-ops safely if
-- that script hasn't finished initializing yet.
local function feel(fnName, ...)
	local cf = _G.CombatFeel
	local fn = cf and cf[fnName]
	if fn then pcall(fn, ...) end
end

local function cleanupShadow()
	aiRunning = false
	if shadowModel then shadowModel:Destroy(); shadowModel = nil end
	shadowHum, shadowAnimator, shadowHRP = nil, nil, nil
	dying = false
end

local function dissolveShadow()
	if dying or not shadowModel then return end
	dying = true
	aiRunning = false
	if shadowHum then shadowHum.WalkSpeed = 0 end
	-- PLACEHOLDER_ASSET: ShadowDissolveEffect -- a burst of dark particles at the rig's torso.
	local torso = shadowModel:FindFirstChild("Torso") or shadowModel:FindFirstChild("HumanoidRootPart")
	if torso then
		local att = Instance.new("Attachment"); att.Parent = torso
		local pe = Instance.new("ParticleEmitter")
		pe.Color = ColorSequence.new(Color3.new(0,0,0))
		pe.Size = NumberSequence.new(1.2, 0)
		pe.Lifetime = NumberRange.new(0.4, 0.7)
		pe.Speed = NumberRange.new(4, 9)
		pe.Rate = 0
		pe.Parent = att
		pe:Emit(40)
	end
	local model = shadowModel
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			TweenService:Create(part, TweenInfo.new(0.8), { Transparency = 1 }):Play()
		end
	end
	task.delay(0.9, function()
		if model and model.Parent then model:Destroy() end
	end)
	shadowModel, shadowHum, shadowAnimator, shadowHRP = nil, nil, nil, nil
	statusToast("The shadow dissolves. Type /shadowbox to spar again.")
end

-- Tracks LANDED HITS directly (not an HP pool) so the mod-configurable "how many hits to
-- defeat" setting maps 1:1 onto what a mod actually typed in -- Health is still driven off
-- it purely for the cosmetic health-bar-style visual (proportional to hits remaining).
local function registerHit()
	if not shadowModel or dying then return end
	-- Identical landed-hit feedback to a real player taking an M1: authored Hit VFX, blood
	-- burst, one-frame white impact flash, and a random M1_Hit from the shared library.
	local pos = shadowHRP and shadowHRP.Position
	spawnHitVFX(pos)
	spawnBloodBurst(pos, 0.8)
	playSoundAt("M1_Hit" .. math.random(1, 5), pos, 0.7)
	spawnImpactFlash(shadowModel)
	hitsLanded += 1
	if shadowHum then
		local frac = hitsToDefeat > 0 and math.max(0, 1 - hitsLanded / hitsToDefeat) or 0
		shadowHum.Health = sbCfg.HP * frac
	end
	if hitsLanded >= hitsToDefeat then dissolveShadow() end
end

-- Purely cosmetic "the shadow hit you" feedback -- never touches real Humanoid.Health
-- (see header comment for why).
local function shadowHitsPlayer(damage, isHeavy)
	screenFlash(Color3.fromRGB(120, 10, 10), 0.75)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local pos = hrp and hrp.Position
	spawnHitVFX(pos)
	spawnBloodBurst(pos, isHeavy and 1.3 or 0.8) -- heavies burst bigger, same as BLOOD_TIER
	playSoundAt(isHeavy and "M2_Hit" or ("M1_Hit" .. math.random(1, 5)), pos, 0.7)
	spawnImpactFlash(char)
	feel("flinch", pos) -- the same camera kick a real hit gives the victim
end

local function spawnShadow(maxHits)
	hitsToDefeat = math.max(1, tonumber(maxHits) or sbCfg.DefaultHitsToDefeat)
	if shadowModel then cleanupShadow() end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not char or not hrp then return end

	-- Character.Archivable defaults to false in this game (confirmed live) -- Clone() silently
	-- returns nil off an unarchivable Model, so it must be flipped true for just the clone call.
	local wasArchivable = char.Archivable
	char.Archivable = true
	local clone = char:Clone()
	char.Archivable = wasArchivable
	if not clone then return end
	clone.Name = "ShadowFigure"
	-- Strip anything that isn't core rig geometry -- tools, accessories, scripts (this is a
	-- purely cosmetic client-only dummy, not a functioning character).
	for _, inst in ipairs(clone:GetDescendants()) do
		if inst:IsA("Tool") or inst:IsA("Accessory") or inst:IsA("BaseScript") then
			inst:Destroy()
		elseif inst:IsA("BasePart") then
			inst.BrickColor = BrickColor.new("Really black")
			inst.Material = Enum.Material.Neon
			-- HRP must stay invisible (it's a hitbox proxy, not body geometry), and the rig
			-- needs at least its root collidable -- with EVERY part CanCollide=false the
			-- humanoid had nothing to stand on and sank straight into the ground on spawn.
			if inst.Name == "HumanoidRootPart" then
				inst.Transparency = 1
				inst.CanCollide = true
			else
				inst.Transparency = 0.4
				inst.CanCollide = false
			end
			inst.CanQuery = false
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			inst:Destroy()
		end
	end
	-- No name label above head (design doc) -- strip any BillboardGui/head-nameplate clones.
	for _, inst in ipairs(clone:GetDescendants()) do
		if inst:IsA("BillboardGui") then inst:Destroy() end
	end

	local hum = clone:FindFirstChildOfClass("Humanoid")
	if not hum then clone:Destroy(); return end
	hum.MaxHealth = sbCfg.HP
	hum.Health = sbCfg.HP
	hum.WalkSpeed = sbCfg.MoveSpeed
	hum.DisplayName = ""
	hum.NameDisplayDistance = 0
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	local chrHRP = clone:FindFirstChild("HumanoidRootPart")
	if not chrHRP then clone:Destroy(); return end
	-- Snap the spawn point onto the actual floor under it (raycast) instead of trusting the
	-- player's HRP height -- on any slope/step the naive offset buried the shadow in the ground.
	local spawnCF = hrp.CFrame * CFrame.new(0, 0, -sbCfg.SpawnDistance)
	local rp = RaycastParams.new()
	rp.FilterDescendantsInstances = {char, clone}
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local ray = workspace:Raycast(spawnCF.Position + Vector3.new(0, 8, 0), Vector3.new(0, -80, 0), rp)
	if ray then
		-- R6 root part center rests ~3 studs above the floor (legs 2 + half of the 2-tall torso).
		spawnCF = CFrame.new(ray.Position + Vector3.new(0, 3.1, 0))
	end
	clone:PivotTo(CFrame.lookAt(spawnCF.Position, Vector3.new(hrp.Position.X, spawnCF.Position.Y, hrp.Position.Z)))

	-- PLACEHOLDER_ASSET: ShadowAura -- a faint dark particle drift around the figure.
	local auraAtt = Instance.new("Attachment"); auraAtt.Parent = chrHRP
	local aura = Instance.new("ParticleEmitter")
	aura.Color = ColorSequence.new(Color3.new(0.05,0.05,0.08))
	aura.Size = NumberSequence.new(0.8, 0)
	aura.Lifetime = NumberRange.new(1, 1.6)
	aura.Speed = NumberRange.new(0.5, 1.5)
	aura.Rate = 6
	aura.Parent = auraAtt

	clone.Parent = workspace
	shadowModel = clone
	shadowHum = hum
	shadowHRP = chrHRP
	shadowAnimator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
	hitsLanded = 0
	dying = false

	shadowState.staggeredUntil     = 0
	shadowState.blockingUntil      = 0
	shadowState.endlagUntil        = 0
	shadowState.attacking          = false
	shadowState.parryCooldownUntil = 0

	-- One landed shadow swing, resolved under the player's REAL defensive laws:
	-- F pressed within Parry.WindowTotal frames -> parried (Perfect inside PerfectWindow,
	-- staggering the shadow for the same durations the server would use); F held past the
	-- window -> block absorbs an M1 (a heavy still chips); otherwise the hit lands.
	local function resolveShadowHitOnPlayer(isHeavy)
		if not shadowModel or dying then return end
		local char2 = player.Character
		local hrp2 = char2 and char2:FindFirstChild("HumanoidRootPart")
		if not hrp2 or not shadowHRP then return end
		if (hrp2.Position - shadowHRP.Position).Magnitude > sbCfg.HitRange then return end
		local now = tick()
		local sinceParry = now - playerParryPressedAt
		if sinceParry >= 0 and sinceParry <= ParryCfg.WindowTotal / 60 then
			local perfect = sinceParry <= ParryCfg.PerfectWindow / 60
			local dur = perfect and ParryCfg.StaggerDurationPerfect or ParryCfg.StaggerDurationLate
			shadowState.staggeredUntil = now + dur
			shadowState.attacking = false
			playShadowAnimId(COMBAT_ANIMS.M1Parried[math.random(1, #COMBAT_ANIMS.M1Parried)])
			if shadowHum then
				shadowHum.WalkSpeed = SpeedCfg.Stagger
				task.delay(dur, function()
					if shadowModel and shadowHum and not dying and tick() >= shadowState.staggeredUntil then
						shadowHum.WalkSpeed = sbCfg.MoveSpeed
					end
				end)
			end
			local mid = (hrp2.Position + shadowHRP.Position) / 2
			spawnParryVFX(mid)
			play2DAny(perfect and {"Parry_Perfect"} or {"Parry_Late", "Parry_Whiff"}, 0.5)
			screenFlash(Color3.fromRGB(255, 255, 255), perfect and 0.55 or 0.75)
			statusToast(perfect and "PERFECT PARRY -- the shadow reels!" or "Parried -- the shadow staggers.")
			playerParryPressedAt = -math.huge -- one press parries one hit, same as the real window closing
		elseif playerHoldingF and (now - playerFDownAt) > ParryCfg.WindowTotal / 60 then
			local mid = (hrp2.Position + shadowHRP.Position) / 2
			spawnBlockVFX(mid)
			playSoundAt("block", mid, 0.6)
			if isHeavy then
				shadowHitsPlayer(sbCfg.Damage * 0.5, true)
				statusToast("The heavy chips through your guard!")
			else
				screenFlash(Color3.fromRGB(90, 90, 90), 0.85)
			end
		else
			shadowHitsPlayer(isHeavy and sbCfg.Damage * 2 or sbCfg.Damage, isHeavy)
			playPlayerAnimId(COMBAT_ANIMS.M1GotHit[math.random(1, #COMBAT_ANIMS.M1GotHit)])
		end
	end

	-- Real M1 chain law: up to 5 swings at the server's 0.5s per-swing rate, first hitbox
	-- delayed by the same M1Startup telegraph players get, chain dies instantly if the
	-- shadow gets parried mid-combo, and a full 5-swing ender eats the same 2s endlag.
	local function doM1Chain()
		local now = tick()
		if shadowState.attacking or now < shadowState.staggeredUntil or now < shadowState.endlagUntil then return end
		shadowState.attacking = true
		shadowState.blockingUntil = 0
		if shadowHum then shadowHum.WalkSpeed = SpeedCfg.M1Active end
		task.spawn(function()
			local swings = math.random(2, 5)
			for i = 1, swings do
				if not shadowModel or dying or not aiRunning then break end
				if tick() < shadowState.staggeredUntil then break end
				local char2 = player.Character
				local hrp2 = char2 and char2:FindFirstChild("HumanoidRootPart")
				if hrp2 and shadowHum then shadowHum:MoveTo(hrp2.Position) end
				playShadowAnimId(COMBAT_ANIMS.M1Attack[i])
				-- Audible windup, same as a real player's swing -- this is the telegraph the
				-- player is meant to parry off, so it needs a sound to react to, not just an anim.
				playSoundAt("M1_Swing_" .. math.random(1, 3), shadowHRP and shadowHRP.Position, 0.55)
				local landDelay = (i == 1) and (CombatCfg.M1Startup / 60) or 0.3
				task.wait(landDelay)
				if not shadowModel or dying or tick() < shadowState.staggeredUntil then break end
				resolveShadowHitOnPlayer(false)
				local rest = 0.5 - landDelay
				if rest > 0 then task.wait(rest) end
			end
			if swings >= 5 then shadowState.endlagUntil = tick() + 2.0 end
			shadowState.attacking = false
			if shadowModel and shadowHum and not dying and tick() >= shadowState.staggeredUntil then
				shadowHum.WalkSpeed = sbCfg.MoveSpeed
			end
		end)
	end

	local function doM2Heavy()
		local now = tick()
		if shadowState.attacking or now < shadowState.staggeredUntil or now < shadowState.endlagUntil then return end
		shadowState.attacking = true
		if shadowHum then shadowHum.WalkSpeed = SpeedCfg.M2Swing end
		playOn(shadowAnimator, CombatAnims.M2_Swing)
		playSoundAt("M2_Swing", shadowHRP and shadowHRP.Position, 0.65)
		task.delay(0.75, function()
			if shadowModel and not dying and tick() >= shadowState.staggeredUntil then
				resolveShadowHitOnPlayer(true)
			end
			shadowState.attacking = false
			if shadowModel and shadowHum and not dying and tick() >= shadowState.staggeredUntil then
				shadowHum.WalkSpeed = sbCfg.MoveSpeed
			end
		end)
	end

	-- Guard: absorbs M1s exactly like a player block would. Visibly firms up (less
	-- transparent) while the guard is held.
	local function doBlock()
		local now = tick()
		if shadowState.attacking or now < shadowState.staggeredUntil then return end
		local dur = 0.8 + math.random() * 0.9
		shadowState.blockingUntil = now + dur
		if shadowHum then shadowHum.WalkSpeed = SpeedCfg.Blocking end
		for _, part in ipairs(shadowModel:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then part.Transparency = 0.15 end
		end
		task.delay(dur, function()
			if not shadowModel or dying then return end
			for _, part in ipairs(shadowModel:GetDescendants()) do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then part.Transparency = 0.4 end
			end
			if shadowHum and tick() >= shadowState.staggeredUntil then shadowHum.WalkSpeed = sbCfg.MoveSpeed end
		end)
	end

	local function doDashAway()
		if shadowState.attacking or tick() < shadowState.staggeredUntil then return end
		playOn(shadowAnimator, MoveAnims.Dash_Forward)
		local char2 = player.Character
		local hrp2 = char2 and char2:FindFirstChild("HumanoidRootPart")
		if hrp2 and shadowHRP then
			local away = (shadowHRP.Position - hrp2.Position)
			if away.Magnitude > 0.1 then
				away = away.Unit * 10
				hum:MoveTo(shadowHRP.Position + away)
			end
		end
	end

	aiRunning = true
	task.spawn(function()
		while aiRunning and shadowModel and shadowModel.Parent do
			task.wait(0.25)
			if not aiRunning or not shadowModel or dying then break end
			local now = tick()
			if shadowState.attacking or now < shadowState.staggeredUntil or now < shadowState.endlagUntil then continue end
			local char2 = player.Character
			local hrp2 = char2 and char2:FindFirstChild("HumanoidRootPart")
			if not hrp2 or not shadowHRP then continue end
			local dist = (hrp2.Position - shadowHRP.Position).Magnitude
			if dist > 6 then
				hum:MoveTo(hrp2.Position)
				continue
			end
			hum:MoveTo(hrp2.Position) -- stay engaged / keep facing
			local roll = math.random()
			if roll < 0.50 then doM1Chain()
			elseif roll < 0.68 then doBlock()
			elseif roll < 0.80 then doDashAway()
			elseif roll < 0.90 then doM2Heavy()
			end
		end
	end)

	statusToast("Shadow practice started -- swing at it, /shadowbox stop to end.")
end

-- Player's own swings: real M1 input still fires normally through the real combat system
-- (see header comment) -- this ALSO resolves the swing against the shadow, but under the
-- REAL M1 law: the hit only lands after the same M1Startup telegraph the server uses, the
-- shadow can parry that visible windup (staggering the player exactly like a real got-parried
-- would), and a raised shadow guard absorbs it like a real block.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	-- Mirror InputHandler's F law so parry/block state here matches what the player sees:
	-- press = parry attempt (unless on cooldown -> straight to block), hold = block.
	if input.KeyCode == Enum.KeyCode.F then
		local now = tick()
		playerFDownAt = now
		playerHoldingF = true
		if now >= playerParryCooldownUntil then
			playerParryPressedAt = now
			playerParryCooldownUntil = now + ParryCfg.Cooldown
		end
		return
	end

	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not shadowModel or dying then return end
	local now = tick()
	if now < playerStaggeredUntil then return end -- got parried: same action lock real combat applies
	if now - lastPlayerHitAt < sbCfg.PlayerHitCooldown then return end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not shadowHRP then return end
	local toShadow = shadowHRP.Position - hrp.Position
	if toShadow.Magnitude > sbCfg.HitRange then return end
	local facing = hrp.CFrame.LookVector
	if facing:Dot(toShadow.Unit) < 0.4 then return end -- must be roughly facing the shadow
	lastPlayerHitAt = now
	playSoundAt("M1_Swing_" .. math.random(1, 3), hrp.Position, 0.55) -- own swing, same as real M1

	-- The shadow reads the windup NOW and commits to a parry (or not) -- same reaction a
	-- real defender gets during your M1Startup telegraph.
	local willParry = false
	if now >= shadowState.parryCooldownUntil and now >= shadowState.staggeredUntil
		and not shadowState.attacking and math.random() < sbCfg.ParryChance then
		willParry = true
		shadowState.parryCooldownUntil = now + ParryCfg.Cooldown
	end

	local landDelay = CombatCfg.M1Startup / 60 -- identical startup law to the real first M1
	if willParry then
		task.delay(math.max(0, landDelay - 0.15), function()
			if shadowModel and not dying then playShadowAnimId(COMBAT_ANIMS.Parry[1]) end
		end)
	end
	task.delay(landDelay, function()
		if not shadowModel or dying then return end
		local char2 = player.Character
		local hrp2 = char2 and char2:FindFirstChild("HumanoidRootPart")
		if not hrp2 or not shadowHRP then return end
		if (shadowHRP.Position - hrp2.Position).Magnitude > sbCfg.HitRange then return end -- it moved out of reach
		local mid = (shadowHRP.Position + hrp2.Position) / 2
		if willParry then
			playerStaggeredUntil = tick() + ParryCfg.StaggerDurationLate
			playPlayerAnimId(COMBAT_ANIMS.M1Parried[math.random(1, #COMBAT_ANIMS.M1Parried)])
			spawnParryVFX(mid)
			play2DAny({"Parry_Late", "Parry_Whiff"}, 0.5)
			-- Getting parried is a stagger -- give it the real stagger feedback (red wash +
			-- camera kick) that CombatManager's applyStagger would have triggered.
			feel("stagger", { duration = ParryCfg.StaggerDurationLate })
			screenFlash(Color3.fromRGB(200, 200, 220), 0.7)
			statusToast("The shadow parries you!")
		elseif tick() < shadowState.blockingUntil then
			spawnBlockVFX(mid)
			playSoundAt("block", mid, 0.6)
			screenFlash(Color3.fromRGB(90, 90, 90), 0.88)
			statusToast("Blocked.")
		else
			registerHit()
			if tick() >= shadowState.staggeredUntil then
				playShadowAnimId(COMBAT_ANIMS.M1GotHit[math.random(1, #COMBAT_ANIMS.M1GotHit)])
			end
		end
	end)
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.F then
		playerHoldingF = false
	end
end)

RE_ShadowPracticeState.OnClientEvent:Connect(function(data)
	if not data then return end
	if data.active then
		if not shadowModel or not shadowModel.Parent then
			spawnShadow(data.maxHits)
		end
	else
		if shadowModel then
			cleanupShadow()
			statusToast("Shadow practice ended (" .. tostring(data.reason or "?") .. ")")
		end
	end
end)

player.CharacterRemoving:Connect(function()
	cleanupShadow()
end)

print("[ShadowBoxClient] Init")
