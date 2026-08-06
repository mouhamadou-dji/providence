--[[
	VelocityClient -- the client half of the VelocityManager. Movement rehaul phase 1
	(2026-08-05).

	Owns the local character's single VM_Velocity constraint (via VelocityRuntime) and steps
	the contribution model every frame. CLIENT-FIRST BY DESIGN: the character is
	client-owned, so this is the only side whose velocity writes reliably stick -- the
	server's job is to DECIDE (knockback force, resist, immunity) and push the resulting
	spec over the VelocityPush remote; applying it is ours.

	Who feeds it:
	  * other CLIENT systems, through _G.VelocityClient (MovementClient routes dash and
	    slide through here -- client-side _G is the established pattern, same as
	    _G.CameraController);
	  * the SERVER, through VelocityPush (knockback and whatever the combat revamp brings).

	FRAME ORDER MATTERS. This binds at RenderPriority.Character + 1 -- one slot after
	MovementClient (300). MovementClient issues its Humanoid:Move and publishes Flow first;
	then this step runs: it reads the resulting MoveDirection as the player's INTENT, and
	  * if any active contribution suppresses input, issues Move(zero) after MovementClient's
	    Move -- "last Move before the physics step wins", the same trick MovementClient
	    plays on ControlModule at priority 100;
	  * otherwise hands the intent velocity to the runtime, which ADDS it to the constraint
	    target -- so a non-suppressing push (wind, a current) blends with walking as an
	    honest vector sum instead of the Humanoid controller arm-wrestling the constraint.

	Never writes Humanoid.WalkSpeed. Never touches AssemblyAngularVelocity either --
	MovementClient already zeroes that every frame, unconditionally.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config  = require(Shared:WaitForChild("Config"))
local Runtime = require(Shared:WaitForChild("VelocityRuntime"))

local VCFG = Config.Velocity or {}

local remotes         = ReplicatedStorage:WaitForChild("RemoteEvents", 10)
local RE_VelocityPush = remotes and remotes:WaitForChild("VelocityPush", 10)

local character, hum, hrp
local handle

-- ── Public client API ─────────────────────────────────────────────────────
-- Late-bound consumers (MovementClient's dash/slide, future systems) reach this through
-- _G.VelocityClient with nil-guards, so load order between StarterPlayerScripts never
-- matters. push returns the contribution id (pass your own spec.id to update/cancel it).
local VelocityClient = {}

function VelocityClient.push(spec)
	if not handle then return nil end
	return Runtime.push(handle, spec, os.clock())
end

function VelocityClient.update(id, planar)
	if handle then Runtime.update(handle, id, planar) end
end

function VelocityClient.cancel(id)
	if handle then Runtime.cancel(handle, id) end
end

function VelocityClient.clear()
	if handle then Runtime.clear(handle) end
end

function VelocityClient.isActive()
	return Runtime.isActive(handle, os.clock())
end

_G.VelocityClient = VelocityClient

-- ── Server pushes ─────────────────────────────────────────────────────────
-- Server -> client only; there is nothing to exploit in this direction. The validation
-- below is typo-defence against a bad server-side spec, not security: clamp rather than
-- trust, so a misconfigured force can never fling the character across the map.
local function sanitizeServerSpec(data)
	if type(data) ~= "table" then return nil end
	if typeof(data.planar) ~= "Vector3" then return nil end
	local maxSpeed = VCFG.MaxSpeed or 200
	local duration = tonumber(data.duration) or (VCFG.Knockback and VCFG.Knockback.Duration) or 0.25
	return {
		id            = type(data.id) == "string" and data.id or nil,
		planar        = data.planar,
		vertical      = math.clamp(tonumber(data.vertical) or 0, -maxSpeed, maxSpeed),
		-- The remote NEVER carries an indefinite contribution: a nil/typo duration becomes
		-- the default, and the model clamps to MaxDuration. Indefinite is reserved for local
		-- callers that also own the matching cancel() (slide).
		duration      = math.clamp(duration, 0, VCFG.MaxDuration or 5),
		decay         = data.decay == "linear" and "linear" or "none",
		maxForce      = tonumber(data.maxForce),
		suppressInput = data.suppressInput ~= false,
	}
end

if RE_VelocityPush then
	RE_VelocityPush.OnClientEvent:Connect(function(data)
		local spec = sanitizeServerSpec(data)
		if spec then VelocityClient.push(spec) end
	end)
else
	warn("[VelocityClient] VelocityPush remote missing -- server-initiated velocity will not reach this client")
end

-- ── The frame loop ────────────────────────────────────────────────────────
-- The player's own intended flat walk velocity: where the Humanoid was just told to go,
-- scaled by the movement model's published momentum and the authorised ceiling.
-- MoveDirection is engine-normalised (its magnitude information is destroyed -- the exact
-- trap documented in MovementClient.publishState), which is why Flow is read back instead:
-- Flow IS the magnitude MovementClient just applied. Falls back to full WalkSpeed when the
-- attribute is absent (MovementClient not running).
local function intentPlanar()
	local dir = hum.MoveDirection
	if dir.Magnitude < 0.01 then return nil end
	local flow = character and character:GetAttribute("Flow")
	local mag = (type(flow) == "number" and flow or 1) * hum.WalkSpeed
	return Vector3.new(dir.X, 0, dir.Z) * mag
end

RunService:BindToRenderStep("VelocityClientStep", Enum.RenderPriority.Character.Value + 1, function(dt)
	if not handle or not hum or not hrp or hum.Health <= 0 then return end

	local out = Runtime.step(handle, os.clock(), dt, intentPlanar())
	if out and out.active and out.suppressInput then
		hum:Move(Vector3.zero, false)
	end
end)

-- ── Character lifecycle ───────────────────────────────────────────────────
-- Run once for the already-present character, then on every respawn; attach() self-heals
-- stale VM_* instances. Death clears every live contribution -- a corpse being shoved by a
-- leftover knockback is ragdoll physics' job, not ours.
local function acquire(char)
	character = char
	hum = char:WaitForChild("Humanoid", 10)
	hrp = char:WaitForChild("HumanoidRootPart", 10)
	if not hum or not hrp then return end

	handle = Runtime.attach(hrp, VCFG)

	hum.Died:Connect(function()
		Runtime.clear(handle)
	end)
end

if player.Character then acquire(player.Character) end
player.CharacterAdded:Connect(acquire)

print("[VelocityClient] Loaded -- one VM_Velocity per character; local pushes via _G.VelocityClient, server pushes via VelocityPush")
