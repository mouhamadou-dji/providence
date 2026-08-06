--[[
	VelocityRuntime -- the Instance glue between VelocityModel (pure maths) and an actual
	character root. Movement rehaul phase 1 (2026-08-05).

	SHARED ON PURPOSE. The same runtime drives two owners:
	  * the CLIENT, for the local player's character -- client-owned physics is the only
	    kind whose velocity writes stick on a player (a server-side write is overwritten by
	    the next replication tick; documented in Movement_TestHarness S8b's comment), and
	  * the SERVER, for server-owned NPC models -- where server physics IS authoritative
	    (WolfManager already drives pounces server-side).
	Duplicating the attachment/constraint/apply code in two places is exactly the mirrored-
	constant drift this codebase keeps writing post-mortems about, so it lives once, here.

	Owns ONE Attachment ("VM_Attachment") + ONE LinearVelocity ("VM_Velocity") per attached
	root -- the single persistent instance the whole system funnels through. The constraint
	is created once and toggled via .Enabled; it is never destroyed/recreated per push.

	The constraint config is the one MovementClient's dash/slide constraints proved out:
	Plane mode (Vector mode pins Y and cancels gravity -- it made the dash hover and broke
	slides on slopes), world-relative X/Z tangent axes, and a FINITE MaxForce (unbounded
	force fights wall collisions instead of letting the solver resolve them -- the
	dash-into-wall fling/spin bug).

	No OOP: plain functions over an explicit handle table, per house style.
]]

local VelocityModel = require(script.Parent.VelocityModel)

local VelocityRuntime = {}

local ATT_NAME = "VM_Attachment"
local LV_NAME  = "VM_Velocity"

--[[
	attach(rootPart, cfg) -> handle

	Idempotent per root: stale VM_* children from a previous attach (respawn edge, script
	reload) are destroyed first, exactly like MovementClient's ensureDashVelocity did.
	`cfg` is Config.Velocity (may be nil -- the model's DEFAULTS cover it).
	handle = { root, lv, att, state, cfg, lastActive }
]]
function VelocityRuntime.attach(rootPart, cfg)
	if not rootPart then return nil end
	for _, n in ipairs({ ATT_NAME, LV_NAME }) do
		local old = rootPart:FindFirstChild(n)
		if old then old:Destroy() end
	end

	local att = Instance.new("Attachment")
	att.Name = ATT_NAME
	att.Parent = rootPart

	local lv = Instance.new("LinearVelocity")
	lv.Name = LV_NAME
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.xAxis
	lv.SecondaryTangentAxis = Vector3.zAxis
	-- MaxForce (the scalar) is the one that applies in Plane mode; MaxAxesForce is
	-- Vector-only. Re-set per frame from the resolve output anyway; this is just the idle value.
	lv.MaxForce = (cfg and cfg.MaxForce) or 45000
	lv.PlaneVelocity = Vector2.zero
	lv.Enabled = false
	lv.Parent = rootPart

	return {
		root  = rootPart,
		att   = att,
		lv    = lv,
		state = VelocityModel.newState(),
		ctx   = { config = cfg },
		-- os.clock() of the last frame that had a live contribution; owners use it to decide
		-- when an idle NPC handle is worth detaching.
		lastActive = 0,
	}
end

function VelocityRuntime.push(handle, spec, now)
	if not handle then return nil end
	local id
	handle.state, id = VelocityModel.add(handle.state, spec, now, handle.ctx)
	return id
end

function VelocityRuntime.update(handle, id, planar)
	if not handle then return end
	handle.state = VelocityModel.update(handle.state, id, planar, handle.ctx)
end

function VelocityRuntime.cancel(handle, id)
	if not handle then return end
	handle.state = VelocityModel.remove(handle.state, id)
end

function VelocityRuntime.clear(handle)
	if not handle then return end
	handle.state = VelocityModel.clear(handle.state)
	if handle.lv then
		handle.lv.Enabled = false
		handle.lv.PlaneVelocity = Vector2.zero
	end
end

function VelocityRuntime.isActive(handle, now)
	return handle ~= nil and VelocityModel.count(handle.state, now) > 0
end

--[[
	step(handle, now, dt, extraPlanar) -> out

	Resolve the model and press the answer onto the constraint. `extraPlanar` is an optional
	flat velocity ADDED to the target -- the client passes the player's own intended walk
	velocity through it, so the constraint's target is (forces + your own legs) and walking
	through a wind drift comes out as the honest vector sum instead of the Humanoid
	controller and the constraint arm-wrestling. A LinearVelocity is a velocity CONSTRAINT
	(it brakes as readily as it pushes), so whatever the Humanoid adds on top, the assembly
	still lands on the summed target. Ignored while any contribution suppresses input --
	suppressed means suppressed, the legs do not get to smuggle their velocity in through
	the target either.

	The vertical impulse is applied here, once, by SETTING Y (matching how the old system's
	launches behaved: EnderKnockback set 28 up, SlamLaunch set 35 up) -- upward launches
	should not be diluted by however fast you happened to be falling. A negative impulse
	(slam-down) sets downward the same way.
]]
function VelocityRuntime.step(handle, now, dt, extraPlanar)
	if not handle or not handle.lv then return nil end
	local out
	out, handle.state = VelocityModel.resolve(handle.state, now, dt, handle.ctx)

	local root = handle.root
	if root and root.Parent then
		if out.verticalImpulse ~= 0 then
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(v.X, out.verticalImpulse, v.Z)
		end
		if out.active then
			handle.lastActive = now
			local target = out.planar
			if extraPlanar and not out.suppressInput then target += extraPlanar end
			handle.lv.MaxForce = out.maxForce
			handle.lv.PlaneVelocity = Vector2.new(target.X, target.Z)
			handle.lv.Enabled = true
		else
			handle.lv.Enabled = false
			handle.lv.PlaneVelocity = Vector2.zero
		end
	end
	return out
end

function VelocityRuntime.detach(handle)
	if not handle then return end
	if handle.lv then handle.lv:Destroy() end
	if handle.att then handle.att:Destroy() end
	handle.lv, handle.att, handle.root = nil, nil, nil
	handle.state = VelocityModel.newState()
end

return VelocityRuntime
