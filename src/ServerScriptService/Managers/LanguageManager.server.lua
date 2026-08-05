-- LanguageManager — per-player spoken language + text garbling
-- None = universal (no garbling). Gaulish / Greek / Latin = culture-specific.
-- Mods always hear original text. Same-language players understand each other.

local Players      = game:GetService("Players")

local OWNERS       = require(game:GetService("ReplicatedStorage").Shared.Config).Owners
local MOD_GROUP_ID = 3015509993
local MOD_RANK_MIN = 200

local function isMod(p)
	if table.find(OWNERS, p.Name) then return true end
	local ok, rank = pcall(function() return p:GetRankInGroup(MOD_GROUP_ID) end)
	return ok and rank >= MOD_RANK_MIN
end

local VALID = { None=true, Gaulish=true, Greek=true, Latin=true }

local POOLS = {
	Gaulish = {"rix","ver","amb","cal","dun","brig","avo","seno","bel","tou","ger","brix","vir","nos"},
	Greek   = {"os","on","is","eus","ios","an","tos","kos","mno","thos","phi","kra","nis","los"},
	Latin   = {"us","um","is","ae","ere","or","ius","ens","alis","tur","bus","mus","vit","tis"},
}

local function garbleWord(word, lang)
	if #word <= 2 then return word end
	local pool = POOLS[lang]; if not pool then return word end
	local syllables = math.max(1, math.round(#word / 2.5))
	local parts = {}
	for i = 1, syllables do parts[i] = pool[math.random(1,#pool)] end
	local result = table.concat(parts)
	if word:sub(1,1):upper() == word:sub(1,1) then
		result = result:sub(1,1):upper()..result:sub(2)
	end
	return result
end

local function garbleText(text, senderLang, keepPct)
	local gLang = (senderLang=="Gaulish") and "Greek" or "Gaulish"
	local keepChance = (keepPct or 0) / 100
	local parts = {}
	for word in text:gmatch("[^%s]+") do
		local f = word:sub(1,1)
		if f=='"' or f=='[' or f=='{' or f=='*' or f=='~' or f=='(' then
			parts[#parts+1] = word
		elseif keepChance > 0 and math.random() < keepChance then
			parts[#parts+1] = word
		else
			parts[#parts+1] = garbleWord(word, gLang)
		end
	end
	return table.concat(parts," ")
end

local languages = {}
local comprehension = {} -- [userId][lang] = 0-100, how much of a non-native language a player understands

local LanguageManager = {}

function LanguageManager.setLanguage(player, lang)
	lang = tostring(lang or "None")
	lang = lang:sub(1,1):upper()..lang:sub(2):lower()
	if not VALID[lang] then lang = "None" end
	languages[player.UserId] = lang
	return lang
end

function LanguageManager.getLanguage(player)
	return languages[player.UserId] or "None"
end

-- Sets how well `player` understands `lang` (0-100%). Only meaningful for Gaulish/Greek/Latin.
function LanguageManager.setComprehension(player, lang, pct)
	lang = tostring(lang or "")
	lang = lang:sub(1,1):upper()..lang:sub(2):lower()
	if not VALID[lang] or lang=="None" then return nil end
	pct = math.clamp(tonumber(pct) or 0, 0, 100)
	comprehension[player.UserId] = comprehension[player.UserId] or {}
	comprehension[player.UserId][lang] = pct
	return lang, pct
end

function LanguageManager.getComprehension(player, lang)
	local t = comprehension[player.UserId]
	return (t and t[lang]) or 0
end

function LanguageManager.process(text, sender, receiver)
	if isMod(receiver) then return text end
	local sLang = languages[sender.UserId]   or "None"
	local rLang = languages[receiver.UserId] or "None"
	if sLang=="None" or rLang=="None" then return text end
	if sLang==rLang then return text end
	local pct = LanguageManager.getComprehension(receiver, sLang)
	if pct >= 100 then return text end
	return garbleText(text, sLang, pct)
end

Players.PlayerRemoving:Connect(function(p)
	languages[p.UserId] = nil
	comprehension[p.UserId] = nil
end)

_G.LanguageManager = LanguageManager
print("[LanguageManager] Init — None / Gaulish / Greek / Latin")