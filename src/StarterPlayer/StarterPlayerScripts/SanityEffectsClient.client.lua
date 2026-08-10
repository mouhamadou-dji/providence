-- SanityEffectsClient.client.lua
-- Renders the 5 hallucination tiers driven by the hidden Sanity meter (see SanityManager /
-- design doc PART TWO). Tier flags arrive over UpdateSanityEffects; Tier1/3-4's actual
-- moments (scratch, shadow spawn/attack) arrive as separate one-shot remotes so the server
-- stays authoritative over their timing (Tier1 deals real damage, Tier4 applies a real stun).

local Players      = game:GetService("Players")
local RepStorage   = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris       = game:GetService("Debris")
local Lighting     = game:GetService("Lighting")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local tiers = {scratch=false, scribble=false, shadow=false, shadowAttack=false, cliffPull=false}

local function getAnimator(char)
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum and hum:FindFirstChildOfClass("Animator")
end

local function playPlaceholderAnim(char, animId)
	if not animId or animId == "" or animId == "rbxassetid://0" then return end
	local animator = getAnimator(char); if not animator then return end
	local anim = Instance.new("Animation"); anim.AnimationId = animId
	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	if ok and track then track.Priority = Enum.AnimationPriority.Action; track:Play() end
end

local function playPlaceholderSound(parent, soundId)
	if not soundId or soundId == "" or soundId == "rbxassetid://0" then return end
	local snd = Instance.new("Sound"); snd.SoundId = soundId; snd.Parent = parent
	snd:Play()
	snd.Ended:Once(function() snd:Destroy() end)
	task.delay(8, function() if snd.Parent then snd:Destroy() end end)
end

-- ── Tier 1: Scratching (real HP damage is applied server-side; this is just the cue) ─────
Remotes.SanityScratchTrigger.OnClientEvent:Connect(function()
	local char = localPlayer.Character; if not char then return end
	playPlaceholderAnim(char, "rbxassetid://0") -- PLACEHOLDER_ANIMATION: sanity_scratch
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then
		playPlaceholderSound(hrp, "rbxassetid://0") -- PLACEHOLDER_SOUND: sanity_scratch_sound
		local anchor = Instance.new("Part")
		anchor.Anchored=true; anchor.CanCollide=false; anchor.CanQuery=false; anchor.Transparency=1
		anchor.Size=Vector3.new(0.2,0.2,0.2); anchor.CFrame=hrp.CFrame*CFrame.new(0.8,0.3,0); anchor.Parent=workspace
		local e = Instance.new("ParticleEmitter")
		e.Color = ColorSequence.new(Color3.fromRGB(120,10,10))
		e.Size = NumberSequence.new(0.25)
		e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.1),NumberSequenceKeypoint.new(1,1)})
		e.Speed = NumberRange.new(1,3); e.Lifetime = NumberRange.new(0.3,0.5); e.SpreadAngle=Vector2.new(180,180)
		e.Rate = 0; e.Parent = anchor; e:Emit(6)
		Debris:AddItem(anchor, 1)
	end
end)

-- ── Tier 2: Face Scribbles ────────────────────────────────────────────────────────────────
-- Name-hide side is handled inside NameBillboardClient itself (it already polls its own
-- billboards every 1s, so it owns Enabled there -- avoids a race between two scripts writing
-- the same property). This just handles the actual scribble overlay on faces.
local SCRIBBLE_RANGE = 60
local scribbledFaces = {} -- [player] = {decal=originalFace, origColor=Color3}

local function clearScribble(p)
	local e = scribbledFaces[p]; if not e then return end
	if e.decal and e.decal.Parent then e.decal.Color3 = e.origColor end
	scribbledFaces[p] = nil
end

local function applyScribble(p)
	if scribbledFaces[p] then return end
	local char = p.Character
	local head = char and char:FindFirstChild("Head")
	local face = head and head:FindFirstChild("face")
	if not face then return end
	-- PLACEHOLDER_ASSET: FaceScribbleDecal (a real scribble texture would overlay here instead
	-- of/alongside this blackout -- blackening the real face decal is the honest-limitation
	-- fallback that reads correctly without needing new art, same convention as Bad Vision's
	-- non-directional blur).
	scribbledFaces[p] = {decal = face, origColor = face.Color3}
	face.Color3 = Color3.new(0,0,0)
end

task.spawn(function()
	while true do
		task.wait(0.5)
		local char = localPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if tiers.scribble and hrp then
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= localPlayer then
					local ohrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
					if ohrp and (ohrp.Position-hrp.Position).Magnitude <= SCRIBBLE_RANGE then
						applyScribble(p)
					else
						clearScribble(p)
					end
				end
			end
		else
			for p in pairs(scribbledFaces) do clearScribble(p) end
		end
	end
end)

-- ── Tier 3/4: Shadow figures (+ Tier4 approach & stun cue) ────────────────────────────────
-- Fixed: this used to fade in smoothly and (when attacking) glide toward the player on a
-- single 1s linear CFrame tween -- at 20-40 studs out that reads as the figure "flying in"
-- rather than a creepy hallucination materializing nearby. Now it flickers rapidly into
-- existence at a fixed spot, and the attack approach is a few discrete blink-teleports
-- (flicker-out, jump closer, flicker-in) instead of one continuous glide.

-- Rapidly toggles a set of parts' Transparency between `visibleAt` and 1 (fully gone) --
-- the actual "flicker" primitive reused for both materializing and each blink-step.
local function flickerParts(parts, visibleAt, flickerCount, totalTime)
	local step = totalTime / flickerCount
	for i = 1, flickerCount do
		local showing = (i % 2) == 1
		for _, part in ipairs(parts) do
			part.Transparency = showing and visibleAt or 1
		end
		task.wait(step)
	end
	for _, part in ipairs(parts) do part.Transparency = visibleAt end
end

local function spawnShadowFigure(willAttack)
	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local cam = workspace.CurrentCamera
	if not hrp or not cam then return end

	local dist = math.random(20,40)
	local angle = math.rad(math.random(-150,150)) -- weighted toward edges/behind, not dead-center
	local dir = (cam.CFrame.LookVector * math.cos(angle)) + (cam.CFrame.RightVector * math.sin(angle))
	local spawnPos = hrp.Position + Vector3.new(dir.X, 0, dir.Z).Unit * dist
	-- Snap onto the real floor at that spot -- copying the player's HRP height buried the
	-- figure inside slopes/steps (and the rig is non-collidable, so it can't settle itself).
	do
		local rp = RaycastParams.new()
		rp.FilterDescendantsInstances = {char}
		rp.FilterType = Enum.RaycastFilterType.Exclude
		local ray = workspace:Raycast(spawnPos + Vector3.new(0, 12, 0), Vector3.new(0, -140, 0), rp)
		if ray then spawnPos = ray.Position + Vector3.new(0, 3.1, 0) end
	end

	local desc = Instance.new("HumanoidDescription")
	local ok, model = pcall(function() return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R6) end)
	if not ok or not model then return end
	model.Name = "SanityShadowFigure" -- PLACEHOLDER_ASSET: ShadowFigureModel
	local animate = model:FindFirstChild("Animate"); if animate then animate:Destroy() end
	local shum = model:FindFirstChildOfClass("Humanoid"); if shum then shum.PlatformStand = true end
	local parts = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide=false; part.CanQuery=false; part.Color=Color3.fromRGB(5,5,8); part.Material=Enum.Material.SmoothPlastic
			table.insert(parts, part)
		elseif part:IsA("Decal") then
			part.Transparency = 1
		end
	end
	local smhrp = model:FindFirstChild("HumanoidRootPart")
	if not smhrp then model:Destroy(); return end
	-- Anchored: every part is CanCollide=false, so an unanchored rig just sinks through the
	-- ground. The blink-teleport steps drive smhrp.CFrame directly, which works anchored.
	smhrp.Anchored = true
	smhrp.CFrame = CFrame.new(spawnPos, Vector3.new(hrp.Position.X, spawnPos.Y, hrp.Position.Z))
	model.Parent = workspace
	for _, part in ipairs(parts) do part.Transparency = 1 end
	playPlaceholderSound(smhrp, "rbxassetid://0") -- PLACEHOLDER_SOUND: sanity_whisper

	-- Materialize: flicker fully in over ~0.5s, landing at 0.3 (matches the original steady
	-- state transparency), then keep a faint ambient flicker for as long as it's around.
	task.spawn(function()
		flickerParts(parts, 0.3, 6, 0.5)
		while model.Parent do
			task.wait(math.random(8,20)/10)
			if not model.Parent then break end
			for _, part in ipairs(parts) do part.Transparency = 0.6 end
			task.wait(0.05)
			if model.Parent then for _, part in ipairs(parts) do part.Transparency = 0.3 end end
		end
	end)

	if willAttack then
		-- Blink-teleports closer in 3 discrete steps (flicker-out, jump, flicker-in) instead of
		-- one continuous glide -- still lands at melee range by the 1.0s mark so
		-- SanityManager's server-side stun timing (anchors the HRP at t=1.0) stays in sync.
		local STEPS = 3
		local originPos = smhrp.Position
		local finalPos = hrp.Position + (originPos - hrp.Position).Unit * 3
		task.spawn(function()
			for i = 1, STEPS do
				task.wait(1.0 / STEPS - 0.12)
				if not model.Parent then return end
				for _, part in ipairs(parts) do part.Transparency = 1 end
				task.wait(0.06)
				if not model.Parent then return end
				local alpha = i / STEPS
				local stepPos = originPos:Lerp(finalPos, alpha)
				smhrp.CFrame = CFrame.new(stepPos, hrp.Position)
				for _, part in ipairs(parts) do part.Transparency = 0.3 end
				task.wait(0.06)
			end
		end)
		task.delay(1.0, function()
			if not model.Parent then return end
			playPlaceholderAnim(char, "rbxassetid://0") -- PLACEHOLDER_ANIMATION: sanity_shadow_hit
			-- Brief camera jerk on the real stun moment (server anchors the HRP for 0.8s).
			local cam2 = workspace.CurrentCamera
			if cam2 then
				local original = cam2.CFrame
				local jerk = CFrame.Angles(math.rad(math.random(-4,4)), math.rad(math.random(-4,4)), math.rad(math.random(-3,3)))
				cam2.CFrame = original * jerk
				task.delay(0.15, function() if cam2.CFrame == original*jerk then cam2.CFrame = original end end)
			end
			for _, part in ipairs(parts) do TweenService:Create(part, TweenInfo.new(0.3), {Transparency=1}):Play() end
			task.delay(0.4, function() if model.Parent then model:Destroy() end end)
		end)
	else
		local life = math.random(30,50)/10
		task.delay(life, function()
			if not model.Parent then return end
			flickerParts(parts, 0.3, 5, 0.4)
			for _, part in ipairs(parts) do part.Transparency = 1 end
			task.delay(0.2, function() if model.Parent then model:Destroy() end end)
		end)
	end
end

Remotes.SanityShadowSpawn.OnClientEvent:Connect(function(payload)
	spawnShadowFigure(payload and payload.attack == true)
end)

-- ── Tier 5: Cliff Pull ─────────────────────────────────────────────────────────────────────
local cliffBlur = Instance.new("BlurEffect")
cliffBlur.Name = "SanityCliffBlur"; cliffBlur.Size = 0; cliffBlur.Parent = Lighting

local CLIFF_DIRECTIONS = {}
for i = 0, 7 do
	local a = math.rad(i * 45)
	table.insert(CLIFF_DIRECTIONS, Vector3.new(math.sin(a), 0, math.cos(a)))
end

local cliffPullDir = nil -- flat Vector3 toward the nearest detected drop, or nil
local baseWalkSpeed = 16

task.spawn(function()
	while true do
		task.wait(0.5)
		if not tiers.cliffPull then cliffPullDir = nil; cliffBlur.Size = 0; continue end
		local char = localPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then cliffPullDir = nil; continue end
		local params = RaycastParams.new()
		params.FilterDescendantsInstances = {char}
		params.FilterType = Enum.RaycastFilterType.Exclude
		local bestDir, found = nil, false
		for _, dir in ipairs(CLIFF_DIRECTIONS) do
			local edgeResult = workspace:Raycast(hrp.Position + dir*15, Vector3.new(0,-100,0), params)
			local groundResult = workspace:Raycast(hrp.Position, Vector3.new(0,-100,0), params)
			local groundY = groundResult and groundResult.Position.Y or hrp.Position.Y
			if not edgeResult or (groundY - edgeResult.Position.Y) > 10 then
				found = true; bestDir = dir; break
			end
		end
		cliffPullDir = found and bestDir or nil
		cliffBlur.Size = found and 10 or 0
		if found then playPlaceholderSound(hrp, "rbxassetid://0") end -- PLACEHOLDER_SOUND: sanity_cliff_whisper
	end
end)

--[[ WalkSpeed nudge: a flavour pull toward the cliff, applied client-side because it depends
     on this frame's own input direction (the player always keeps full control -- per design
     doc it is a lean, not a lock).

     REWRITTEN 2026-08-10 against MovementFlow. The previous version snapshotted a base speed
     once at spawn and wrote `base * 1.2` / `base * 0.7` every Heartbeat with no else branch,
     so it (a) drifted from every later legitimate speed change, (b) NEVER restored when the
     pull ended, leaving a permanent 11.2 or 19.2, and (c) re-asserted itself over the server
     every frame.

     Now it scales the server's CURRENT resolved value, read from the MovementWalkSpeed
     attribute, and yields entirely when a high-priority server state owns the character --
     the MovementWeight gate. A stagger, a freeze or an attack commitment must not be
     softened by a sanity effect. ]]
local NUDGE_MAX_WEIGHT = 25 -- yield to anything above Crouch: Guard, Windup, Attack, Stagger, Freeze
local nudging = false

RunService.Heartbeat:Connect(function()
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp then return end

	local resolved = char:GetAttribute("MovementWalkSpeed")
	local weight   = char:GetAttribute("MovementWeight") or 0

	local mult
	if cliffPullDir and resolved and weight <= NUDGE_MAX_WEIGHT then
		local moveDir = hum.MoveDirection
		if moveDir.Magnitude >= 0.1 then
			if moveDir.Unit:Dot(cliffPullDir) > 0.3 then
				mult = 1.2
			elseif moveDir.Unit:Dot(-cliffPullDir) > 0.3 then
				mult = 0.7
			end
		end
	end

	if mult then
		hum.WalkSpeed = resolved * mult
		nudging = true
	elseif nudging then
		-- Hand it straight back to the server's value. This is the branch the old version
		-- never had, and its absence is why the effect outlived the sanity tier that caused it.
		if resolved then hum.WalkSpeed = resolved end
		nudging = false
	end
end)

-- Camera tilt: applied AFTER the default camera script's own RenderStepped update (Camera
-- priority + 1) so it layers on top instead of fighting it every frame.
RunService:BindToRenderStep("SanityCliffTilt", Enum.RenderPriority.Camera.Value + 1, function()
	if not cliffPullDir then return end
	local cam = workspace.CurrentCamera; if not cam then return end
	local camCF = cam.CFrame
	local localDir = camCF:VectorToObjectSpace(cliffPullDir)
	local tiltZ = math.clamp(localDir.X, -1, 1) * math.rad(8)
	local tiltX = math.clamp(-localDir.Z, -1, 1) * math.rad(4)
	cam.CFrame = camCF * CFrame.Angles(tiltX, 0, tiltZ)
end)

-- ── Character setup: capture base WalkSpeed for the Tier5 nudge math above ────────────────
local function hookCharacter(char)
	local hum = char:WaitForChild("Humanoid", 5)
	if hum then baseWalkSpeed = hum.WalkSpeed end
end
if localPlayer.Character then hookCharacter(localPlayer.Character) end
localPlayer.CharacterAdded:Connect(hookCharacter)

-- ── Tier flag updates ──────────────────────────────────────────────────────────────────────
Remotes.UpdateSanityEffects.OnClientEvent:Connect(function(payload)
	if not payload or not payload.tiers then return end
	tiers = payload.tiers
end)

print("[SanityEffectsClient] Loaded")
