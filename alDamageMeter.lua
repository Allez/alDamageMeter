-- Config start
local anchor = "TOPLEFT"
local x, y = 12, -12
local barheight = 15
local spacing = 1
local maxbars = 8
local width, height = 125, maxbars*(barheight+spacing)-spacing
local maxfights = 10
local reportstrings = 10
local texture = "Interface\\TargetingFrame\\UI-StatusBar"
local backdrop_color = {0, 0, 0, 0.5}
local border_color = {0, 0, 0, 1}
local border_size = 1
local hidetitle = false
-- Config end

local addon_name, ns = ...
local boss = LibStub("LibBossIDs-1.0")
local dataobj = LibStub:GetLibrary('LibDataBroker-1.1'):NewDataObject('Dps', {type = "data source", text = 'DPS: ', icon = "", iconCoords = {0.065, 0.935, 0.065, 0.935}})
local band = bit.band
local bossname, mobname = nil, nil
local units, bar, barguids, owners = {}, {}, {}, {}
local current, display, fights, udata = {}, {}, {}, {}
local timer, num, offset = 0, 0, 0
local MainFrame
local combatstarted = false
local filter = COMBATLOG_OBJECT_AFFILIATION_RAID + COMBATLOG_OBJECT_AFFILIATION_PARTY + COMBATLOG_OBJECT_AFFILIATION_MINE
local backdrop = {
	bgFile = [=[Interface\ChatFrame\ChatFrameBackground]=],
	edgeFile = [=[Interface\ChatFrame\ChatFrameBackground]=], edgeSize = border_size,
	insets = {top = 0, left = 0, bottom = 0, right = 0},
}
local displayMode = {
	'Damage',
	'Healing',
	'Dispels',
	'Interrupts',
}
local sMode = 'Damage'

local menuFrame = CreateFrame("Frame", "alDamageMeterMenu", UIParent, "UIDropDownMenuTemplate")

local dummy = function() return end

local truncate = function(value)
	if value >= 1e6 then
		return string.format('%.2fm', value / 1e6)
	elseif value >= 1e4 then
		return string.format('%.1fk', value / 1e3)
	else
		return string.format('%.0f', value)
	end
end

function dataobj.OnLeave()
	GameTooltip:SetClampedToScreen(true)
	GameTooltip:Hide()
end

function dataobj.OnEnter(self)
	GameTooltip:SetOwner(self, 'ANCHOR_BOTTOMLEFT', 0, self:GetHeight())
	GameTooltip:AddLine("alDamageMeter")
	GameTooltip:AddLine("Hint: click to show/hide damage meter window.")
	GameTooltip:Show()
end

function dataobj.OnClick(self, button)
	if MainFrame:IsShown() then
		MainFrame:Hide()
	else
		MainFrame:Show()
	end
end

local IsFriendlyUnit = function(uGUID)
	if units[uGUID] or owners[uGUID] or uGUID==UnitGUID("player") then
		return true
	else
		return false
	end
end

local IsUnitInCombat = function(uGUID)
	unit = units[uGUID]
	if unit then
		return UnitAffectingCombat(unit.unit)
	end
	return false
end

local CreateFS = function(frame, fsize, fstyle)
	local fstring = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight')
	fstring:SetFont(GameFontHighlight:GetFont(), fsize, fstyle)
	return fstring
end

local CreateBG = function(parent)
	local bg = CreateFrame("Frame", nil, parent)
	bg:SetPoint("TOPLEFT", parent, "TOPLEFT", -border_size, border_size)
	bg:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", border_size, -border_size)
	bg:SetFrameStrata("LOW")
	bg:SetBackdrop(backdrop)
	bg:SetBackdropColor(unpack(backdrop_color))
	bg:SetBackdropBorderColor(unpack(border_color))
	return bg
end

local tcopy = function(src)
	local dest = {}
	for k, v in pairs(src) do
		dest[k] = v
	end
	return dest
end

local perSecond = function(cdata)
	return cdata[sMode] / cdata.combatTime
end

local report = function(channel)
	local message = sMode..":"
	if channel == "Chat" then
		DEFAULT_CHAT_FRAME:AddMessage(message)
	else
		SendChatMessage(message, channel)
	end
	for i, v in pairs(barguids) do
		if i > reportstrings then return end
		if sMode == "Damage" or sMode == "Healing" then
			message = string.format("%2d. %s    %s (%.0f)", i, display[v].name, truncate(display[v][sMode]), perSecond(display[v]))
		else
			message = string.format("%2d. %s    %s", i, display[v].name, truncate(display[v][sMode]))
		end
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

local CreateBar = function()
	local newbar = CreateFrame("Statusbar", nil, MainFrame)
	newbar:SetStatusBarTexture(texture)
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

local Add = function(uGUID, ammount, mode, name)
	local unit = units[uGUID]
	if not current[uGUID] then
		local newdata = {
			name = unit.name,
			class = unit.class,
			combatTime = 1,
		}
		for _, v in pairs(displayMode) do
			newdata[v] = 0
		end
		current[uGUID] = newdata
		tinsert(barguids, uGUID)
	end
	udata = current[uGUID]
	udata[mode] = udata[mode] + ammount
end

local SortMethod = function(a, b)
	return display[b][sMode] < display[a][sMode]
end

local UpdateBars = function()
	table.sort(barguids, SortMethod)
	local color, cur, max
	for i = 1, #barguids do
		cur = display[barguids[i+offset]]
		max = display[barguids[1]]
		if i > maxbars or not cur then break end
		if cur[sMode] == 0 then break end
		if not bar[i] then 
			bar[i] = CreateBar()
			bar[i]:SetPoint("TOP", 0, -(barheight + spacing) * (i-1))
		end
		bar[i]:SetValue(100 * cur[sMode] / max[sMode])
		color = RAID_CLASS_COLORS[cur.class]
		bar[i]:SetStatusBarColor(color.r, color.g, color.b)
		if sMode == "Damage" or sMode == "Healing" then
			bar[i].right:SetFormattedText("%s (%.0f)", truncate(cur[sMode]), perSecond(cur))
		else
			bar[i].right:SetFormattedText("%s", truncate(cur[sMode]))
		end
		bar[i].left:SetText(cur.name)
		bar[i]:Show()
	end
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
	offset = 0
	UpdateBars()
end

local Clean = function()
	numfights = 0
	wipe(current)
	wipe(fights)
	ResetDisplay(current)
end

local SetMode = function(mode)
	sMode = mode
	for i, v in pairs(bar) do
		v:Hide()
	end
	UpdateBars()
	MainFrame.title:SetText(sMode)
end

local CreateMenu = function(self, level)
	level = level or 1
	local info = {}
	if level == 1 then
		info.isTitle = 1
		info.text = "Menu"
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = "Mode"
		info.hasArrow = 1
		info.value = "Mode"
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = "Report to"
		info.hasArrow = 1
		info.value = "Report"
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = "Fight"
		info.hasArrow = 1
		info.value = "Fight"
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = "Clean"
		info.func = Clean
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
	elseif level == 2 then
		if UIDROPDOWNMENU_MENU_VALUE == "Mode" then
			for i, v in pairs(displayMode) do
				wipe(info)
				info.text = v
				info.func = function() SetMode(v) end
				info.notCheckable = 1
				UIDropDownMenu_AddButton(info, level)
			end
		end
		if UIDROPDOWNMENU_MENU_VALUE == "Report" then
			for i, v in pairs(reportList) do
				wipe(info)
				info.text = v.text
				info.func = v.func
				info.notCheckable = 1
				UIDropDownMenu_AddButton(info, level)
			end
		end
		if UIDROPDOWNMENU_MENU_VALUE == "Fight" then
			wipe(info)
			info.text = "Current"
			info.func = function() ResetDisplay(current) end
			info.notCheckable = 1
			UIDropDownMenu_AddButton(info, level)
			for i, v in pairs(fights) do
				wipe(info)
				info.text = v.name
				info.func = function() ResetDisplay(v.data) end
				info.notCheckable = 1
				UIDropDownMenu_AddButton(info, level)
			end
		end
	end
end

local EndCombat = function()
	MainFrame:SetScript('OnUpdate', nil)
	combatstarted = false
	local fname = bossname or mobname
	if fname then
		if #fights >= maxfights then
			tremove(fights, 1)
		end
		tinsert(fights, {name = fname, data = tcopy(current)})
		mobname, bossname = nil, nil
	end
end

local CheckPet = function(unit, pet)
	if UnitExists(pet) then
		owners[UnitGUID(pet)] = UnitGUID(unit)
	end
end

local CheckUnit = function(unit)
	if UnitExists(unit) then
		units[UnitGUID(unit)] = { name = UnitName(unit), class = select(2, UnitClass(unit)), unit = unit}
		pet = unit .. "pet"
		CheckPet(unit, pet)
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
			if i == UnitGUID("player") then
				dataobj.text = string.format("DPS: %.0f", v["Damage"] / v.combatTime)
			end
		end
		UpdateBars()
		if not InCombatLockdown() and not IsRaidInCombat() then
			EndCombat()
		end
		timer = 0
	end
end

local OnMouseWheel = function(self, direction)
	num = 0
	for i = 1, #barguids do
		if display[barguids[i]][sMode] > 0 then
			num = num + 1
		end
	end
	if direction > 0 then
		if offset > 0 then
			offset = offset - 1
		end
	else
		if num > maxbars + offset then
			offset = offset + 1
		end
	end
	UpdateBars()
end

local StartCombat = function()
	wipe(current)
	combatstarted = true
	ResetDisplay(current)
	MainFrame:SetScript('OnUpdate', OnUpdate)
end

local OnEvent = function(self, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = select(1, ...)
		if band(sourceFlags, filter) == 0 then return end
		if eventType=="SWING_DAMAGE" or eventType=="RANGE_DAMAGE" or eventType=="SPELL_DAMAGE" or eventType=="SPELL_PERIODIC_DAMAGE" or eventType=="DAMAGE_SHIELD" then
			local ammount = select(eventType=="SWING_DAMAGE" and 9 or 12, ...)
			if IsFriendlyUnit(sourceGUID) and not IsFriendlyUnit(destGUID) and combatstarted then
				if ammount and ammount > 0 then
					sourceGUID = owners[sourceGUID] or sourceGUID
					Add(sourceGUID, ammount, 'Damage', sourceName)
					if not bossname and boss.BossIDs[tonumber(destGUID:sub(9, 12), 16)] then
						bossname = destName
					elseif not mobname then
						mobname = destName
					end
				end
			end
		elseif eventType=="SPELL_SUMMON" then
			if owners[sourceGUID] then 
				owners[destGUID] = owners[sourceGUID]
			else
				owners[destGUID] = sourceGUID
			end
		elseif eventType=="SPELL_HEAL" or eventType=="SPELL_PERIODIC_HEAL" then
			spellId, spellName, spellSchool, ammount, over, school, resist = select(9, ...)
			if IsFriendlyUnit(sourceGUID) and IsFriendlyUnit(destGUID) and combatstarted then
				over = over or 0
				if ammount and ammount > 0 then
					sourceGUID = owners[sourceGUID] or sourceGUID
					Add(sourceGUID, ammount - over, "Healing")
				end
			end
		elseif eventType=="SPELL_DISPEL" then
			if IsFriendlyUnit(sourceGUID) and IsFriendlyUnit(destGUID) and combatstarted then
				sourceGUID = owners[sourceGUID] or sourceGUID
				Add(sourceGUID, 1, "Dispels")
			end
		elseif eventType=="SPELL_INTERRUPT" then
			if IsFriendlyUnit(sourceGUID) and not IsFriendlyUnit(destGUID) and combatstarted then
				sourceGUID = owners[sourceGUID] or sourceGUID
				Add(sourceGUID, 1, "Interrupts")
			end
		else
			return
		end
	elseif event == "ADDON_LOADED" then
		local name = ...
		if name == addon_name then
			self:UnregisterEvent(event)
			MainFrame = CreateFrame("ScrollFrame", addon_name.."ScrollFrame", UIParent, "UIPanelScrollFrameTemplate")
			MainFrame:SetPoint(anchor, UIParent, anchor, x, y)
			MainFrame:SetSize(width, height)
			MainFrame.bg = CreateBG(MainFrame)
			MainFrame:SetMovable(true)
			MainFrame:EnableMouse(true)
			MainFrame:SetScript("OnMouseDown", function(self, button)
				if button == "LeftButton" and IsModifiedClick("SHIFT") then
					self:StartMoving()
				end
			end)
			MainFrame:SetScript("OnMouseUp", function(self, button)
				if button == "RightButton" then
					ToggleDropDownMenu(1, nil, menuFrame, 'cursor', 0, 0)
				end
				if button == "LeftButton" then
					self:StopMovingOrSizing()
				end
			end)
			MainFrame:SetScript("OnMouseWheel", OnMouseWheel)
			MainFrame:Show()
			UIDropDownMenu_Initialize(menuFrame, CreateMenu, "MENU")
			MainFrame.title = CreateFS(MainFrame, 11)
			MainFrame.title:SetPoint("BOTTOMLEFT", MainFrame, "TOPLEFT", 0, 1)
			MainFrame.title:SetText(sMode)
			if hidetitle then MainFrame.title:Hide() end
			_G[addon_name.."ScrollFrameScrollBar"]:SetAlpha(0)
			_G[addon_name.."ScrollFrameScrollBar"]:EnableMouse(false)
			_G[addon_name.."ScrollFrameScrollBarScrollUpButton"]:EnableMouse(false)
			_G[addon_name.."ScrollFrameScrollBarScrollDownButton"]:EnableMouse(false)
		end
	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
		wipe(units)
		if GetNumRaidMembers() > 0 then
			for i = 1, GetNumRaidMembers(), 1 do
				CheckUnit("raid"..i)
			end
		elseif GetNumPartyMembers() > 0 then
			for i = 1, GetNumPartyMembers(), 1 do
				CheckUnit("party"..i)
			end
		end
		CheckUnit("player")
	elseif event == "PLAYER_REGEN_DISABLED" then
		if not combatstarted then
			StartCombat()
		end
	elseif event == "UNIT_PET" then
		local unit = ...
		local pet = unit .. "pet"
		CheckPet(unit, pet)
	end
end

local addon = CreateFrame("frame", nil, UIParent)
addon:SetScript('OnEvent', OnEvent)
addon:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("RAID_ROSTER_UPDATE")
addon:RegisterEvent("PARTY_MEMBERS_CHANGED")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:RegisterEvent("PLAYER_REGEN_DISABLED")
addon:RegisterEvent("UNIT_PET")

SlashCmdList["alDamage"] = function(msg)
	for i = 1, 20 do
		units[i] = {name = UnitName("player"), class = select(2, UnitClass("player")), unit = "1"}
		Add(i, i*10000, "Damage")
	end
	wipe(units)
	CheckUnit("player")
	display = current
	UpdateBars()
end
SLASH_alDamage1 = "/aldmg"