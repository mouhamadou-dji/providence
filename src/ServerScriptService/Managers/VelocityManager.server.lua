--[[
	VelocityManager -- the server half of the velocity stack. Movement rehaul phase 1
	(2026-08-05).

	THE ROUTER. `push(character, spec)` sends a velocity contribution to whoever owns that
	character's physics:

	  * a PLAYER character is client-owned -- a server-side AssemblyLinearVelocity write is
	    overwritten by the next replication tick (the old CombatManager's knockback was
	    documented-unreliable for exactly this reason; see Movement_TestHarness S8b's
	    comment). So the spec is fired over the VelocityPush remote and the owning client's
	    VelocityClient applies it. Server decides, client applies.

	  * an NPC model is server-owned -- server physics IS authoritative there (WolfManager
	    already drives pounces server-side), so the same VelocityRuntime the client uses is
	    driven right here, one lazily-created handle per pushed model, stepped on Heartbeat
	    and detached again once idle. Mobs that never get pushed never grow a constraint.

	KNOCKBACK LIVES HERE. applyKnockback matches the old CombatManager signature exactly --
	ShroomManager and WolfManager have been calling `cm.applyKnockback(...)` through their
	nil-guards since the teardown and silently no-opping; CombatCore now delegates that name
	to this implementation, so both mobs' knockback goes live with zero edits to either.
	The orphaned wiring is made real at the same time: RageManager.isKnockbackImmune,
	the KnockbackResist mob attribute / Config.Combat.MobKnockbackResist, and the
	Unshakeable/Ironwall KnockbackForceMult talent modifiers all apply.

	Decisions are returned, not just applied: applyKnockback hands back the spec it built
	(or nil + reason). Physics on a client-owned victim is not server-assertable, the
	decision is -- that return value is the harness's test surface.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config  = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Runtime = require(ReplicatedStorage.Shared:WaitForChild("VelocityRuntime"))

local VCFG   = Config.Velocity or {}
local KBCFG  = VCFG.Knockback or {}

-- Same local getOrCreate pattern as MovementSystem/ModManager (accepted duplication of the
-- shared RemoteEvents module; the canonical declaration lives there).
local reFolder = ReplicatedStorage:FindFirstChild("RemoteEvents") or (function()
	local f = Instance.new("Folder"); f.Name = "RemoteEvents"; f.Parent = ReplicatedStorage; return f
end)()
local function getOrCreateRE(name)
	local r = reFolder:FindFirstChild(name)
	if r then return r end
	r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = reFolder
	return r
end
local RE_VelocityPush = getOrCreateRE("VelocityPush")

-- ── NPC handles ───────────────────────────────────────────────────────────
-- [model] = handle. Created on first push, stepped on Heartbeat, dropped (constraint
-- destroyed) once the model is gone or has been idle past the linger window -- so the
-- steady state for a world full of mobs that are not being shoved is zero handles.
local IDLE_LINGER = 2 -- seconds a quiet handle survives before detach

local npcHandles = {}

local function npcRoot(model)
	return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

local function npcHandleFor(model)
	local h = npcHandles[model]
	if h and h.root and h.root.Parent then return h end
	local root = npcRoot(model)
	if not root then return nil end
	h = Runtime.attach(root, VCFG)
	npcHandles[model] = h
	return h
end

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	for model, h in pairs(npcHandles) do
		if not model.Parent or not h.root or not h.root.Parent then
			Runtime.detach(h)
			npcHandles[model] = nil
		else
			Runtime.step(h, now, dt)
			if not Runtime.isActive(h, now) and now - h.lastActive > IDLE_LINGER then
				Runtime.detach(h)
				npcHandles[model] = nil
			end
		end
	end
end)

-- ── Spec hygiene ──────────────────────────────────────────────────────────
-- Only the documented fields travel (or apply), and durations are always finite here:
-- indefinite contributions are a client-local privilege (slide owns its cancel); anything
-- the server starts must be guaranteed to end even if a later cancel never comes.
local function sanitizeSpec(spec)
	if type(spec) ~= "table" or typeof(spec.planar) ~= "Vector3" then return nil end
	local duration = tonumber(spec.duration) or VCFG.DefaultDuration or 0.25
	return {
		id            = type(spec.id) == "string" and spec.id or nil,
		planar        = spec.planar,
		vertical      = tonumber(spec.vertical) or 0,
		duration      = math.clamp(duration, 0, VCFG.MaxDuration or 5),
		decay         = spec.decay == "linear" and "linear" or "none",
		maxForce      = tonumber(spec.maxForce),
		suppressInput = spec.suppressInput ~= false,
	}
end

-- ── Public surface ────────────────────────────────────────────────────────
local VelocityManager = {}

-- push(character, spec) -> id|true|nil, reason|nil
-- Routes by ownership (see header). For a player the return is `true` -- the contribution
-- id is minted client-side and there is nothing meaningful to hand back.
function VelocityManager.push(character, spec)
	if typeof(character) ~= "Instance" then return nil, "nochar" end
	local clean = sanitizeSpec(spec)
	if not clean then return nil, "badspec" end

	local plr = Players:GetPlayerFromCharacter(character)
	if plr then
		RE_VelocityPush:FireClient(plr, clean)
		return true
	end

	local h = npcHandleFor(character)
	if not h then return nil, "noroot" end
	return Runtime.push(h, clean, os.clock())
end

function VelocityManager.pushPlayer(player, spec)
	local char = player and player.Character
	if not char then return nil, "nochar" end
	return VelocityManager.push(char, spec)
end

-- NPC handles only; a player's contributions live client-side, so the honest answer for a
-- player is nil ("not something the server can see"), not false.
function VelocityManager.isActive(character)
	local plr = Players:GetPlayerFromCharacter(character)
	if plr then return nil end
	local h = npcHandles[character]
	return h ~= nil and Runtime.isActive(h, os.clock())
end

-- Fresh id per call so rapid hits STACK (vector-sum) rather than refresh -- the chosen
-- rule: a wolf pack landing three bites genuinely displaces you three bites' worth.
local kbCounter = 0

--[[
	applyKnockback(attackerChar, victimChar, force, lateralDir, lateralForce)
		-> spec|nil, reason|nil

	The old CombatManager's knockback (archived at _OldCombat_2026_08_02, L348) rebuilt on
	the contribution system -- same signature, same direction maths, same resist rules, so
	the existing ShroomManager/WolfManager call sites work unchanged. lateralDir/
	lateralForce stay optional: a sideways shove along a supplied axis for sweeping attacks
	where a purely backward push reads as a poke.
]]
function VelocityManager.applyKnockback(attackerChar, victimChar, force, lateralDir, lateralForce)
	if typeof(attackerChar) ~= "Instance" or typeof(victimChar) ~= "Instance" then return nil, "badargs" end
	local aHRP = attackerChar:FindFirstChild("HumanoidRootPart")
	local vHRP = victimChar:FindFirstChild("HumanoidRootPart")
	if not aHRP or not vHRP then return nil, "noroot" end

	local victimPlayer = Players:GetPlayerFromCharacter(victimChar)
	local resist = 0
	local forceMult = 1
	if victimPlayer then
		local rm = _G.RageManager
		if rm and rm.isKnockbackImmune and rm.isKnockbackImmune(victimPlayer) then
			return nil, "immune"
		end
		-- Unshakeable (0.80) / Ironwall (0.75) -- orphaned in TalentEffects until now.
		local tm = _G.TalentManager
		if tm and tm.getModifier then
			local ok, v = pcall(tm.getModifier, victimPlayer, "KnockbackForceMult")
			if ok and type(v) == "number" then forceMult = v end
		end
	else
		-- Non-player victim = a mob. Mobs are bigger than humans and shouldn't be launched
		-- by a person's swing; they take a step back instead. Per-model "KnockbackResist"
		-- attribute wins over the global default when present.
		local attr = victimChar:GetAttribute("KnockbackResist")
		resist = math.clamp(tonumber(attr) or Config.Combat.MobKnockbackResist or 0, 0, 1)
		if resist >= 1 then return nil, "immovable" end
	end

	-- Direction: victim away from attacker, flat; a perfect overlap falls back to the
	-- attacker's facing.
	local dir = vHRP.Position - aHRP.Position
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	if flatDir.Magnitude < 0.01 then
		local lv = aHRP.CFrame.LookVector
		flatDir = Vector3.new(lv.X, 0, lv.Z)
	end
	if flatDir.Magnitude < 0.01 then return nil, "nodir" end

	local f = (tonumber(force) or Config.Combat.KnockbackForce or 40) * (1 - resist) * forceMult
	local planar = flatDir.Unit * f
	if lateralDir and tonumber(lateralForce) and lateralForce ~= 0 and typeof(lateralDir) == "Vector3" then
		local lat = Vector3.new(lateralDir.X, 0, lateralDir.Z)
		if lat.Magnitude > 0.01 then
			planar += lat.Unit * (lateralForce * (1 - resist) * forceMult)
		end
	end

	kbCounter += 1
	local spec = {
		id            = "kb_" .. kbCounter,
		planar        = planar,
		duration      = KBCFG.Duration or 0.25,
		decay         = KBCFG.Decay or "linear",
		suppressInput = true,
	}
	local ok, reason = VelocityManager.push(victimChar, spec)
	if not ok then return nil, reason end
	return spec
end

_G.VelocityManager = VelocityManager

print(string.format(
	"[VelocityManager] Live -- players via VelocityPush remote, NPCs via server runtime; knockback %.2fs/%s",
	KBCFG.Duration or 0.25, KBCFG.Decay or "linear"))
