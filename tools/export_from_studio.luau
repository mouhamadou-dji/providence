--!nolint
-- Providence — Studio → disk exporter (Studio side)
--
-- Usage:
--   1. Start the receiver on this machine:
--        node tools/export_receiver.js "C:\path\to\providence"
--   2. Open the Providence place in Roblox Studio.
--   3. Paste this whole script into the Studio Command Bar and run it.
--   4. Stop the receiver (Ctrl+C), then `git add -A && git commit`.
--
-- It walks every service below, writes each Script / LocalScript / ModuleScript
-- to src/<Service>/<path>/<Name>.<ext>, and preserves nesting: a script that
-- itself contains scripts becomes a folder with an `init` file inside it
-- (same convention Rojo uses).

local HttpService = game:GetService("HttpService")
HttpService.HttpEnabled = true

local services = {
	"ServerScriptService", "ServerStorage", "ReplicatedStorage", "ReplicatedFirst",
	"StarterGui", "StarterPlayer", "StarterPack", "Workspace", "Lighting",
	"SoundService", "Chat", "TestService",
}

local function extFor(inst)
	if inst:IsA("ModuleScript") then return ".lua" end
	if inst:IsA("LocalScript") then return ".client.lua" end
	if inst:IsA("Script") then
		local ok, rc = pcall(function() return inst.RunContext end)
		if ok and tostring(rc) == "Enum.RunContext.Client" then return ".client.lua" end
		return ".server.lua"
	end
	return ".lua"
end

local function hasScriptDescendant(inst)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then return true end
	end
	return false
end

local batch, batchBytes, sent, failed = {}, 0, 0, {}

local function flush()
	if #batch == 0 then return end
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = "http://127.0.0.1:8777/write",
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(batch),
		})
	end)
	if ok and res.Success then
		sent += #batch
	else
		table.insert(failed, tostring(ok and res.StatusCode or res))
	end
	batch, batchBytes = {}, 0
end

for _, sname in ipairs(services) do
	local okSvc, svc = pcall(function() return game:GetService(sname) end)
	if okSvc and svc then
		for _, d in ipairs(svc:GetDescendants()) do
			if d:IsA("LuaSourceContainer") then
				local segs, cur = {}, d
				while cur and cur ~= svc do
					table.insert(segs, 1, cur.Name)
					cur = cur.Parent
				end
				local leaf = table.remove(segs)
				local ext = extFor(d)
				local tail = hasScriptDescendant(d) and (leaf .. "/init" .. ext) or (leaf .. ext)
				local relpath = "src/" .. sname .. "/"
					.. (#segs > 0 and (table.concat(segs, "/") .. "/") or "")
					.. tail

				local okSrc, src = pcall(function() return d.Source end)
				src = okSrc and src or ("-- FAILED TO READ SOURCE: " .. tostring(src))

				table.insert(batch, { relpath = relpath, source = src })
				batchBytes += #src
				-- Keep request bodies to a sane size rather than one 2 MB POST.
				if batchBytes > 250000 then flush() end
			end
		end
	end
end
flush()

print(string.format("Providence export: %d scripts sent, %d batch failures", sent, #failed))
for _, f in ipairs(failed) do warn("  failed batch: " .. f) end
