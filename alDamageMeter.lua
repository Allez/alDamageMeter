-- Config start
local anchor = "TOPLEFT"
local x, y = 12, -12
local width, height = 130, 130
local barheight = 14
local spacing = 1
local maxbars = 20
local maxfights = 10
local reportstrings = 10
-- Config end

local boss = LibStub("LibBossIDs-1.0")
local bossname, mobname = nil, nil
local units, guids, bar, barguids, owners, pets = {}, {}, {}, {}, {}, {}
local current, display, fights = {}, {}, {}
local timer = 0
local MainFrame, DisplayFrame
local combatstarted = false
local filter = COMBATLOG_OBJECT_AFFILIATION_RAID + COMBATLOG_OBJECT_AFFILIATION_PARTY + COMBATLOG_OBJECT_AFFILIATION_MINE
local backdrop = {
	bgFile = [=[Interface\ChatFrame\ChatFrameBackground]=],
	insets = {top = -1, left = -1, bottom = -1, right = -1},
}

local menuFrame = CreateFrame("Frame", "FightsMenu", UIParent, "UIDropDownMenuTemplate")
local reportFrame = CreateFrame("Frame", "ReportMenu", UIParent, "UIDropDownMenuTemplate")

local truncate = function(value)
	if value >= 1e6 then
		return string.format('%.2fm', value / 1e6)
	elseif value >= 1e4 then
		return string.format('%.1fk', value / 1e3)
	else
		return string.format('%.0f', value)
	end
end

local IsFriendlyUnit = function(uGUID)
	if guids[uGUID] or owners[uGUID] or uGUID==UnitGUID("player") then
		return true
	else
		return false
	end
end

local IsUnitInCombat = function(uGUID)
	unit = guids[uGUID]
	if unit then
		return UnitAffectingCombat(unit)
	end
	return false
end

local CreateButton = function(parent, size, color)
	local button = CreateFrame("Button", nil, parent)
	button:SetWidth(size)
	button:SetHeight(size)
	local texture = button:CreateTexture(nil, "OVERLAY")
	texture:SetTexture(unpack(color))
	texture:SetAllPoints(button)
	return button
end

local CreateFS = function(frame, fsize, fstyle)
	local fstring = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight')
	fstring:SetFont(GameFontHighlight:GetFont(), fsize, fstyle)
	return fstring
end

local tcopy = function(src)
	local dest = {}
	for k, v in pairs(src) do
		dest[k] = v
	end
	return dest
end

local dps = function(cdata)
	return cdata.damage / cdata.combatTime
end

local report = function(channel)
	local message
	for i, v in pairs(barguids) do
		if i > reportstrings then return end
		message = string.format("%2d. %s    %s (%.0f)", i, display[v].name, truncate(display[v].damage), dps(display[v]))
		if channel == "Chat" then
			DEFAULT_CHAT_FRAME:AddMessage(message)
		else
			SendChatMessage(message, channel)
		end
	end
end

local reportList = {
	{
		text = "Chat", 
		func = function() report("Chat") end,
	},
	{
		text = "Say", 
		func = function() report("SAY") end,
	},
	{
		text = "Party", 
		func = function() report("PARTY") end,
	},
	{
		text = "Raid", 
		func = function() report("RAID") end,
	},
	{
		text = "Officer", 
		func = function() report("OFFICER") end,
	},
	{
		text = "Guild", 
		func = function() report("GUILD") end,
	},
}

local Report = function()
	EasyMenu(reportList, reportFrame, "cursor", 0, 0, "MENU", 2)
end

local CreateBar = function()
	local newbar = CreateFrame("Statusbar", nil, DisplayFrame)
	newbar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	newbar:SetMinMaxValues(0, 100)
	newbar:SetWidth(width)
	newbar:SetHeight(barheight)
	newbar.left = CreateFS(newbar, 11)
	newbar.left:SetPoint("LEFT", 2, 0)
	newbar.left:SetJustifyH("LEFT")
	newbar.right = CreateFS(newbar, 11)
	newbar.right:SetPoint("RIGHT", -2, 0)
	newbar.right:SetJustifyH("RIGHT")
	return newbar
end

local Add = function(uGUID, damage, heal)
	local unit = guids[uGUID]
	if not unit then return end
	if not current[uGUID] then
		local newdata = {
			name = UnitName(unit),
			class = select(2, UnitClass(unit)),
			damage = 0,
			heal = 0,
			combatTime = 1,
		}
		current[uGUID] = newdata
		tinsert(barguids, uGUID)
	end
	current[uGUID].heal = current[uGUID].heal + (heal or 0)
	current[uGUID].damage = current[uGUID].damage + (damage or 0)
end

local SortMethod = function(a, b)
	return display[b].damage < display[a].damage
end

local UpdateBars = function(frame)
	table.sort(barguids, SortMethod)
	local color
	for i, v in pairs(barguids) do
		if not bar[i] then 
			bar[i] = CreateBar()
			bar[i]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(barheight+spacing)*(i-1))
		end
		bar[i]:SetValue(100 * display[v].damage / display[barguids[1]].damage)
		color = RAID_CLASS_COLORS[display[v].class]
		bar[i]:SetStatusBarColor(color.r, color.g, color.b)
		bar[i].right:SetFormattedText("%s (%.0f)", truncate(display[v].damage), dps(display[v]))
		bar[i].left:SetText(display[v].name)
		bar[i]:Show()
	end
	DisplayFrame:SetHeight((barheight+spacing)*#barguids)
end

local ResetDisplay = function(fight)
	for i, v in pairs(bar) do
		v:Hide()
	end
	display = fight
	wipe(barguids)
	for guid, v in pairs(display) do
		tinsert(barguids, guid)
	end
	MainFrame:SetVerticalScroll(0)
	UpdateBars(DisplayFrame)
end

local Menu = function()
	local menuList = {}
	tinsert(menuList, {text = "Current", func = function() ResetDisplay(current) end})
	for i, v in pairs(fights) do
		tinsert(menuList, {text = v.name, func = function() ResetDisplay(v.data) end})
	end
	EasyMenu(menuList, menuFrame, "cursor", 0, 0, "MENU", 2)
end

local Clean = function()
	numfights = 0
	wipe(current)
	wipe(fights)
	ResetDisplay(current)
end

local EndCombat = function()
	DisplayFrame:SetScript('OnUpdate', nil)
	combatstarted = false
	local fname = bossname or mobname
	if name then
		if #fights >= maxfights then
			tremove(fights, 1)
		end
		tinsert(fights, {name = fname, data = tcopy(current)})
		mobname, bossname = nil, nil
	end
end

local UpdatePets = function(unit, pet)
	if UnitExists(pet) then
		owners[UnitGUID(pet)] = UnitGUID(unit)
		pets[UnitGUID(unit)] = UnitGUID(pet)
	elseif pets[UnitGUID(unit)] then
		owners[pets[UnitGUID(unit)]] = nil
		pets[UnitGUID(unit)] = nil
	end
end

local UpdateRoster = function(group, count)
	for id = 1, count do
		local unit = group .. id
		if UnitExists(unit) then
			guid = UnitGUID(unit)
			if guid == UnitGUID("player") then
				unit = "player"
			end
			units[unit] = guid
			guids[guid] = unit
			pet = unit .. "pet"
			UpdatePets(unit, pet)
		elseif units[unit] then
			guids[units[unit]] = nil
			units[unit] = nil
		end
	end
end

local IsRaidInCombat = function()
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers(), 1 do
			if UnitExists("raid"..i) and UnitAffectingCombat("raid"..i) then
				return true
			end
		end
	elseif GetNumPartyMembers() > 0 then
		for i = 1, GetNumPartyMembers(), 1 do
			if UnitExists("party"..i) and UnitAffectingCombat("party"..i) then
				return true
			end
		end
	end
	return false
end

local OnUpdate = function(self, elapsed)
	timer = timer + elapsed
	if timer > 0.5 then
		for i, v in pairs(current) do
			if IsUnitInCombat(i) then
				v.combatTime = v.combatTime + timer
			end
		end
		UpdateBars(DisplayFrame)
		if not InCombatLockdown() and not IsRaidInCombat() then
			EndCombat()
		end
		timer = 0
	end
end

local StartCombat = function()
	wipe(current)
	combatstarted = true
	ResetDisplay(current)
	DisplayFrame:SetScript('OnUpdate', OnUpdate)
end

local OnEvent = function(self, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = select(1, ...)
		if not bit.band(sourceFlags, filter) or not combatstarted then return end
		if eventType=="SWING_DAMAGE" or eventType=="RANGE_DAMAGE" or eventType=="SPELL_DAMAGE" or eventType=="SPELL_PERIODIC_DAMAGE" then
			local ammount = select(eventType=="SWING_DAMAGE" and 9 or 12, ...)
			if IsFriendlyUnit(sourceGUID) and not IsFriendlyUnit(destGUID) then
				if ammount and ammount > 0 then
					sourceGUID = owners[sourceGUID] or sourceGUID
					Add(sourceGUID, ammount)
					if not bossname and boss.BossIDs[tonumber(destGUID:sub(9, 12), 16)] then
						bossname = destName
					elseif not mobname then
						mobname = destName
					end
				end
			end
		elseif eventType=="SPELL_SUMMON" then
			owners[destGUID] = sourceGUID
			pets[sourceGUID] = destGUID
			return
		elseif eventType=="SPELL_HEAL" or eventType=="SPELL_PERIDOIC_HEAL" then
			--[[spellId, spellName, spellSchool, ammount, over, school, resist = select(9, ...)
			if IsFriendlyUnit(sourceGUID) and IsFriendlyUnit(destGUID) then
				over = over or 0
				if ammount and ammount > 0 then
					sourceGUID = owners[sourceGUID] or sourceGUID
					Add(sourceGUID, nil, ammount - over)
				end
			end]]
		else
			return
		end
	elseif event == "ADDON_LOADED" then
		local name = ...
		if name == "qDamage" then
			self:UnregisterEvent("ADDON_LOADED")
			MainFrame = CreateFrame("ScrollFrame", "qDamageScrollFrame", UIParent, "UIPanelScrollFrameTemplate")
			DisplayFrame = CreateFrame("Frame", "qDamageDisplayFrame", UIParent)
			MainFrame:SetScrollChild(DisplayFrame)
			MainFrame:SetPoint(anchor, UIParent, anchor, x, y)
			DisplayFrame:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", 0, 0)
			DisplayFrame:SetWidth(width)
			DisplayFrame:SetHeight(height)
			MainFrame:SetWidth(width)
			MainFrame:SetHeight(height)
			MainFrame:SetBackdrop(backdrop)
			MainFrame:SetBackdropColor(0, 0, 0, 0.5)
			MainFrame:SetHorizontalScroll(0)
			MainFrame:SetVerticalScroll(0)
			MainFrame:EnableMouse(true)
			MainFrame:Show()
			local menu = CreateButton(MainFrame, 9, {0,0.5,1})
			menu:SetPoint("BOTTOMRIGHT",MainFrame,"TOPRIGHT",0,2)
			menu:SetScript("OnClick", Menu)
			local report = CreateButton(MainFrame, 9, {0.5,1,0})
			report:SetPoint("TOPRIGHT",menu,"TOPLEFT",-2,0)
			report:SetScript("OnClick", Report)
			local clean = CreateButton(MainFrame, 9, {0.7,0.7,0.7})
			clean:SetPoint("TOPRIGHT",report,"TOPLEFT",-2,0)
			clean:SetScript("OnClick", Clean)
		end
	elseif event == "RAID_ROSTER_UPDATE" then
		UpdateRoster("raid", 40)
	elseif event == "PARTY_MEMBERS_CHANGED" then
		UpdateRoster("party", 4)
	elseif event == "PLAYER_ENTERING_WORLD" then
		units["player"] = UnitGUID("player")
		guids[UnitGUID("player")] = "player"
	elseif event == "PLAYER_REGEN_DISABLED" then
		if not combatstarted then
			StartCombat()
		end
	elseif event == "UNIT_PET" then
		local unit = ...
		local pet = unit .. "pet"
		UpdatePets(unit, pet)
	end
end

local addon = CreateFrame("frame")
addon:SetScript('OnEvent', OnEvent)
addon:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("RAID_ROSTER_UPDATE")
addon:RegisterEvent("PARTY_MEMBERS_CHANGED")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:RegisterEvent("PLAYER_REGEN_DISABLED")
addon:RegisterEvent("UNIT_PET")

SlashCmdList["alDamage"] = function(msg)
	Add(UnitGUID("player"), 100500)
	UpdateBars(DisplayFrame)
end
SLASH_alDamage1 = "/aldmg"