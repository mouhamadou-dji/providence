local DS=game:GetService("DataStoreService");local P=game:GetService("Players");local RS=game:GetService("RunService")
-- Data wipe (design doc PART ONE) -- version-bump approach, not a destructive delete.
-- META is a small, permanent, never-wiped store holding just the current version number;
-- bumping it points every FUTURE server session at a brand-new empty PlayerData store,
-- while the old version's data stays sitting there untouched/recoverable. Read once at
-- server start -- DM.wipeAll below only takes full effect from the next server start
-- onward (matching Kick-and-rejoin being how the spec describes players getting fresh data).
local META=DS:GetDataStore("AbyssMeta_v1")
local function readVersion() local ok,v=pcall(function() return META:GetAsync("DataVersion") end); return (ok and v) or 1 end
local DATA_VERSION=readVersion()
local PDS=DS:GetDataStore("AbyssPlayerData_v"..DATA_VERSION);local SS=DS:GetDataStore("AbyssSessionLock_v1")
local pd={};local ls={};local sl={}
-- Session locks are written as os.time(). A hard server crash never runs BindToClose, so the
-- lock is orphaned -- without an age check that player is kicked with "Data loading elsewhere"
-- on EVERY future join, forever. Anything older than this is treated as dead and stepped over.
local LOCK_STALE_AFTER=600
local DD={CharacterID="",FirstName="",FamilyName="",Relation="None",Gender="",Race="Human",PlayerState="Alive",SpawnOverride=nil,Stats={Strength=0,Endurance=0,Agility=0},RevealedStats={},Currency={Obol=0,Drachma=0,Stater=0,RoyalStater=0},Talents={},FightingStyle="None",Title="",Scars={},Hunger=100,Water=100,FamilyAssigned="",BannerID=0,DiscoveredZones={},LoreEchoes={},BountyAmount=0,BountyActive=false,BrandActive=false,Reputation={Gauls=0,Greeks=0,Military=0},Inventory={},EquippedWeapon=nil,UnlockedMapSections={},DataVersion=1,CreatedAt=0,LastSaved=0,SkinToneIndex=0,FaceIndex=0,HairAccessories={},HairOverrideId=0,ActiveOutfitSlot=1,KnownNames={},ConcealmentActive=false,IdentitySetupDone=false,EquippedClothing="None",EquippedFaceGear="None",MeditationQTEsPassed=0,PushupsQTEsPassed=0,SpiritReputation={Flame=0,Wind=0,Water=0,Earth=0,Shadow=0,Blood=0},Injuries={},DNA={Clan="",Purity=0,Caste=""},KnownAboutSelf={Caste=false,Purity=false,Clan=false,Stats=false,Sanity=false},Titles={},ReceivedCasteStartingCurrency=false,Sanity=0,RageActive=false,RageExhaustedUntil=0,AllyProgress={},Allies={},PendingSmelts={}}
local RP={{value="Brother",weight=20},{value="Sister",weight=20},{value="Twin",weight=5},{value="Cousin",weight=25},{value="DistantRelative",weight=20},{value="None",weight=10}}
local function wr(pool) local t=0;for _,e in ipairs(pool) do t+=e.weight end;local r=math.random(1,t);local c=0;for _,e in ipairs(pool) do c+=e.weight;if r<=c then return e.value end end;return pool[#pool].value end
local function guid() return string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx","[xy]",function(c) local v=(c=="x")and math.random(0,0xf)or math.random(8,0xb);return string.format("%x",v) end) end
local function merge(t,d) for k,v in pairs(d) do if t[k]==nil then if type(v)=="table" then t[k]={};merge(t[k],v) else t[k]=v end elseif type(v)=="table" and type(t[k])=="table" then merge(t[k],v) end end end
local function snap(d) local c={};for k,v in pairs(d) do c[k]=v end;return c end
local function su(key,fn) local a=0;local s,r;repeat a+=1;s,r=pcall(function() return PDS:UpdateAsync(key,fn) end);if not s then warn("[DM] fail "..a);if a<3 then task.wait(2) end end until s or a>=3;return s,r end
local function load(pl) local uid=pl.UserId;local key="Player_"..uid;if not RS:IsStudio() then local ok,ex=pcall(function() return SS:GetAsync("Lock_"..uid) end);if ok and type(ex)=="number" and (os.time()-ex)<LOCK_STALE_AFTER then pl:Kick("Data loading elsewhere");return end;if ok and ex~=nil and type(ex)~="number" then warn("[DM] non-numeric session lock for "..pl.Name..", treating as stale") end;pcall(function() SS:SetAsync("Lock_"..uid,os.time()) end);sl[uid]=true else print("[DM] Studio: lock bypassed "..pl.Name) end;local ok,stored=pcall(function() return PDS:GetAsync(key) end);if not ok then warn("[DM] GetAsync fail: "..tostring(stored));if RS:IsStudio() then stored=nil else pl:Kick("Load failed");return end end;local d=stored or{};local isNew=stored==nil;if isNew then d.CharacterID=guid();d.Relation=wr(RP);d.CreatedAt=os.time() end;merge(d,DD);pd[uid]=d;print("[DM] Loaded "..pl.Name.." "..(isNew and"NEW"or"returning")) end
local function save(pl,force) local uid=pl.UserId;local d=pd[uid];if not d then return end;local now=tick();if not force and ls[uid] and(now-ls[uid])<6 then return end;ls[uid]=now;d.LastSaved=os.time();su("Player_"..uid,function() return snap(d) end) end
local function rem(pl) local uid=pl.UserId;save(pl,true);if sl[uid] then pcall(function() SS:RemoveAsync("Lock_"..uid) end);sl[uid]=nil end;pd[uid]=nil;ls[uid]=nil end
P.PlayerAdded:Connect(load);P.PlayerRemoving:Connect(rem)
for _,p in ipairs(P:GetPlayers()) do task.spawn(load,p) end
game:BindToClose(function() for _,p in ipairs(P:GetPlayers()) do task.spawn(function() ls[p.UserId]=nil;save(p,true);if sl[p.UserId] then pcall(function() SS:RemoveAsync("Lock_"..p.UserId) end) end end) end;task.wait(5) end)
local DM={};function DM.get(p) return pd[p.UserId] end;function DM.getValue(p,k) local d=pd[p.UserId];return d and d[k] end;function DM.setValue(p,k,v) local d=pd[p.UserId];if d then d[k]=v end end;function DM.save(p,f) save(p,f) end;function DM.isLoaded(p) return pd[p.UserId]~=nil end
function DM.getDataVersion() return DATA_VERSION end
function DM.wipeAll(exec)
	local newVersion=DATA_VERSION+1
	local ok=pcall(function() META:SetAsync("DataVersion",newVersion) end)
	if not ok then return false,"Failed to write new data version" end
	pcall(function() META:SetAsync("LastWipeAt",os.time()) end)
	local execName=exec and exec.Name or "SYSTEM"
	print("[DATA WIPE] All player data reset to v"..newVersion.." by "..execName)
	local disc=_G.DiscordManager
	if disc and disc.logServer then disc.logServer("DATA_WIPE","Database version bumped to v"..newVersion.." by "..execName) end
	for _,p in ipairs(P:GetPlayers()) do
		task.spawn(function() p:Kick("Server data has been reset. Please rejoin.") end)
	end
	return true,"Data version bumped to v"..newVersion.." -- fully applies once the server restarts"
end
_G.DataManager=DM;print("[DataManager] Initialized -- data version v"..DATA_VERSION)

-- Broadcast on next server start if a wipe happened recently (spec: "Server broadcast on
-- restart mentions wipe"). Heuristic window (1hr) since there's no other cross-session
-- "have I already announced this" state worth persisting for a rare admin action.
task.spawn(function()
	local ok,lastWipe=pcall(function() return META:GetAsync("LastWipeAt") end)
	if ok and lastWipe and (os.time()-lastWipe)<3600 then
		task.wait(5) -- let HUDManager finish initializing
		local hud=_G.HUDManager
		if hud and hud.showGlobalMessage then
			hud.showGlobalMessage("Player data has been reset. All characters begin anew.")
		end
	end
end)
