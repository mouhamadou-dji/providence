--[[
	CombatClient -- input and presentation for level-based melee (2026-08-09).

	CLIENT OWNS FEEL, SERVER OWNS TRUTH -- the same split MovementClient keeps. This script
	binds the inputs, plays the swing clips and the local cues, and nothing else. It does not
	decide whether a swing lands, what level it was, or whether a guard held: every one of
	those is answered on the server, and every remote below is fired WITH NO PAYLOAD.

	In particular the LEVEL is never sent. This script reads MoveState only to pick which
	animation to play; the server derives the real level from its own replicated crouch/slide
	state. If the two ever disagree the server wins and the animation is simply the wrong
	one -- which is a cosmetic bug, not an exploit.

	BINDS: LMB = swing. RMB held = guard, RMB tapped = parry. The tap/hold split is decided by
	how long the button is down: release inside TAP_MAX_SECONDS and it was a parry, keep
	holding and it becomes a guard. The guard fires on the threshold rather than on press, so
	a parry tap never briefly registers as a guard.

	ANIMATION PRIORITY IS Action2, NOT Action. MovementController's suppressForeignTracks
	stops every foreign track at Action or below on each RenderStepped frame -- that is
	exactly what made the old critical animations play for a single frame and vanish.
]]

local Players           = game:GetService("Players")
local UIS               = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Model  = require(Shared:WaitForChild("CombatModel"))

local MCFG = Config.Melee

local remotes     = ReplicatedStorage:WaitForChild("RemoteEvents", 10)
local RE_Swing    = remotes:WaitForChild("RequestSwing", 10)
local RE_Guard    = remotes:WaitForChild("RequestGuard", 10)
local RE_GuardEnd = remotes:WaitForChild("RequestGuardEnd", 10)
local RE_Parry    = remotes:WaitForChild("RequestParry", 10)
local RE_Event    = remotes:WaitForChild("OnMeleeEvent", 10)

local character, hum, animator
local tracks = {}

-- Anything held longer than this is a guard, anything shorter was a parry tap.
local TAP_MAX_SECONDS = 0.2

local rmbDownAt   = nil
local guardActive = false
local guardTimer  = nil

-- ── Animation ─────────────────────────────────────────────────────────────
local function loadTracks(anim)
	tracks = {}
	if not anim then return end
	for i, id in ipairs(MCFG.Anims or {}) do
		local a = Instance.new("Animation")
		a.AnimationId = id
		local ok, t = pcall(function() return anim:LoadAnimation(a) end)
		if ok and t then
			-- Action2, deliberately: see the header. Action or below is stopped every frame
			-- by MovementController while any locomotion clip is playing.
			t.Priority = Enum.AnimationPriority.Action2
			t.Looped = false
			tracks[i] = t
		end
	end
end

local function playSwing(hitNum)
	local t = tracks[hitNum]
	if not t then return end
	for i, other in pairs(tracks) do
		if i ~= hitNum and other.IsPlaying then other:Stop(0.05) end
	end
	t:Play(0.05)
	-- Time-scale the clip into the swing so it always completes: windup plus active frames is
	-- the real length of a swing, and a clip authored longer than that would otherwise be cut
	-- off partway. Guarded on Length, which is 0 until the asset finishes loading.
	local swingLen = (MCFG.Windup or 0.3) + (MCFG.ActiveWindow or 0.12)
	if t.Length > 0 and swingLen > 0 then t:AdjustSpeed(t.Length / swingLen) end
end

-- ── Level intent (COSMETIC ONLY) ──────────────────────────────────────────
-- Read from the same MoveState vocabulary the server derives its own answer from, so the two
-- agree in every normal case -- but this value is never transmitted.
local function localLevel()
	local ms = character and character:GetAttribute("MoveState")
	return Model.levelFromState(ms)
end

-- ── Input ─────────────────────────────────────────────────────────────────
local function requestGuard()
	if guardActive then return end
	guardActive = true
	if RE_Guard then RE_Guard:FireServer() end
end

local function releaseGuard()
	if not guardActive then return end
	guardActive = false
	if RE_GuardEnd then RE_GuardEnd:FireServer() end
end

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if RE_Swing then RE_Swing:FireServer() end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		rmbDownAt = os.clock()
		-- Guard engages only once the hold threshold passes, so a parry tap never flickers
		-- through a guard state on its way out.
		guardTimer = task.delay(TAP_MAX_SECONDS, function()
			if rmbDownAt then requestGuard() end
		end)
	end
end)

UIS.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
	local heldFor = rmbDownAt and (os.clock() - rmbDownAt) or 0
	rmbDownAt = nil
	if guardTimer then task.cancel(guardTimer); guardTimer = nil end
	if guardActive then
		releaseGuard()
	elseif heldFor < TAP_MAX_SECONDS then
		if RE_Parry then RE_Parry:FireServer() end
	end
end)

-- ── Server events ─────────────────────────────────────────────────────────
if RE_Event then
	RE_Event.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		if payload.kind == "Swing" then
			playSwing(payload.hit or 1)
		elseif payload.kind == "Staggered" then
			-- Cut the swing clip: the server has already invalidated the swing, so letting the
			-- animation play out would show a strike that cannot land.
			for _, t in pairs(tracks) do
				if t.IsPlaying then t:Stop(0.1) end
			end
		end
	end)
end

-- ── Character lifecycle ───────────────────────────────────────────────────
local function acquire(char)
	character = char
	hum = char:WaitForChild("Humanoid", 10)
	animator = hum and hum:WaitForChild("Animator", 10)
	guardActive = false
	rmbDownAt = nil
	if guardTimer then task.cancel(guardTimer); guardTimer = nil end
	if animator then
		task.wait(0.1) -- same settle the locomotion loader uses before LoadAnimation
		loadTracks(animator)
	end
end

if player.Character then task.spawn(acquire, player.Character) end
player.CharacterAdded:Connect(acquire)

print(string.format(
	"[CombatClient] Loaded -- LMB swing / RMB hold guard, tap parry (%.2fs tap threshold), %d clips",
	TAP_MAX_SECONDS, #(MCFG.Anims or {})))
