-- Config start
local anchor = "TOPLEFT"
local x, y = 12, -12
local barheight = 14
local spacing = 1
local maxbars = 8
local width, height = 125, maxbars*(barheight+spacing)-spacing
local maxfights = 10
local reportstrings = 10
local texture = "Interface\\Addons\\alDamageMeter\\media\\UI-StatusBar"
local backdrop_color = {0, 0, 0, 0.5}
local border_color = {0, 0, 0, 1}
local border_size = 1
local font = "Interface\\Addons\\alDamageMeter\\media\\VisitorR.TTF"
local font_style = "OUTLINEMONOCHROME"
local font_size = 10
local hidetitle = false
-- Config end

local config = {
	["Texture"] = texture,
	["Width"] = width,
	["Bar height"] = barheight,
	["Visible bars"] = maxbars,
	["Saved fights"] = maxfights,
	["Report lines"] = reportstrings,
	["Hide title"] = hidetitle,
	["Font"] = font,
	["Font size"] = font_size,
	["Font style"] = font_style,
	["Anchor point"] = anchor,
	["X offset"] = x,
	["Y offset"] = y,
	["Bar spacing"] = spacing,
}
if UIConfig then
	UIConfig["Damage Meter"] = config
end

local addon_name, ns = ...
local boss = LibStub("LibBossIDs-1.0")
local dataobj = LibStub:GetLibrary('LibDataBroker-1.1'):NewDataObject('Dps', {type = "data source", text = 'DPS: ', icon = "", iconCoords = {0.065, 0.935, 0.065, 0.935}})
local band = bit.band
local bossname, mobname = nil, nil
local units, bar, barguids, owners = {}, {}, {}, {}
local current, display, fights = {}, {}, {}
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
	DAMAGE,
	SHOW_COMBAT_HEALING,
	ABSORB,
	DISPELS,
	INTERRUPTS,
}
local sMode = DAMAGE
local AbsorbSpellDuration = {
	-- Death Knight
	[48707] = 5, -- Anti-Magic Shell (DK) Rank 1 -- Does not currently seem to show tracable combat log events. It shows energizes which do not reveal the amount of damage absorbed
	[51052] = 10, -- Anti-Magic Zone (DK)( Rank 1 (Correct spellID?)
		-- Does DK Spell Deflection show absorbs in the CL?
	[51271] = 20, -- Unbreakable Armor (DK)
	[77535] = 10, -- Blood Shield (DK)
	-- Druid
	[62606] = 10, -- Savage Defense proc. (Druid) Tooltip of the original spell doesn't clearly state that this is an absorb, but the buff does.
	-- Mage
	[11426] = 60, -- Ice Barrier
	[6143] = 30, -- Frost Ward
	[1463] = 60, --  Mana shield
	[543] = 30 , -- Fire Ward
	-- Paladin
	[58597] = 6, -- Sacred Shield (Paladin) proc (Fixed, thanks to Julith)
	[86273] = 6,	-- Illuminated Healing, Pala Mastery
	-- Priest
	[17] = 30, -- Power Word: Shield
	[47753] = 12, -- Divine Aegis
	[47788] = 10, -- Guardian Spirit  (Priest) (50 nominal absorb, this may not show in the CL)
	-- Warlock
	[7812] = 30, -- Sacrifice
	[6229] = 30, -- Shadow Ward
	-- Item procs
	[64411] = 15, -- Blessing of the Ancient (Val'anyr Hammer of Ancient Kings equip effect)
	[64413] = 8, -- Val'anyr, Hammer of Ancient Kings proc Protection of Ancient Kings
}
local shields = {}

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

local CreateFS = function(frame)
	local fstring = frame:CreateFontString(nil, 'OVERLAY')
	fstring:SetFont(config["Font"], config["Font size"], config["Font style"])
	fstring:SetShadowColor(0, 0, 0, 1)
	fstring:SetShadowOffset(0, 0)
	return fstring
end

local CreateBG = function(parent)
	local bg = CreateFrame("Frame", nil, parent)
	bg:SetPoint("TOPLEFT", -border_size, border_size)
	bg:SetPoint("BOTTOMRIGHT", border_size, -border_size)
	bg:SetFrameLevel(parent:GetFrameLevel() - 1)
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

local report = function(channel, cn)
	local message = sMode..":"
	if channel == "Chat" then
		DEFAULT_CHAT_FRAME:AddMessage(message)
	else
		SendChatMessage(message, channel, nil, cn)
	end
	for i, v in pairs(barguids) do
		if i > config["Report lines"] then return end
		if sMode == DAMAGE or sMode == SHOW_COMBAT_HEALING then
			message = string.format("%2d. %s    %s (%.0f)", i, display[v].name, truncate(display[v][sMode]), perSecond(display[v]))
		else
			message = string.format("%2d. %s    %s", i, display[v].name, truncate(display[v][sMode]))
		end
		if channel == "Chat" then
			DEFAULT_CHAT_FRAME:AddMessage(message)
		else
			SendChatMessage(message, channel, nil, cn)
		end
	end
end

StaticPopupDialogs[addon_name.."ReportDialog"] = {
	text = "", 
	button1 = ACCEPT, 
	button2 = CANCEL,
	hasEditBox = 1,
	timeout = 30, 
	hideOnEscape = 1, 
}

local reportList = {
	{
		text = CHAT_LABEL, 
		func = function() report("Chat") end,
	},
	{
		text = SAY, 
		func = function() report("SAY") end,
	},
	{
		text = PARTY, 
		func = function() report("PARTY") end,
	},
	{
		text = RAID, 
		func = function() report("RAID") end,
	},
	{
		text = OFFICER, 
		func = function() report("OFFICER") end,
	},
	{
		text = GUILD, 
		func = function() report("GUILD") end,
	},
	{
		text = TARGET, 
		func = function() 
			if UnitExists("target") and UnitIsPlayer("target") then
				report("WHISPER", UnitName("target"))
			end
		end,
	},
	{
		text = PLAYER.."..", 
		func = function() 
			StaticPopupDialogs[addon_name.."ReportDialog"].OnAccept = 	function(self)
				report("WHISPER", _G[self:GetName().."EditBox"]:GetText())
			end
			StaticPopup_Show(addon_name.."ReportDialog")
		end,
	},
	{
		text = CHANNEL.."..", 
		func = function() 
			StaticPopupDialogs[addon_name.."ReportDialog"].OnAccept = 	function(self)
				report("CHANNEL", _G[self:GetName().."EditBox"]:GetText())
			end
			StaticPopup_Show(addon_name.."ReportDialog")
		end,
	},
}

local CreateBar = function()
	local newbar = CreateFrame("Statusbar", nil, MainFrame)
	newbar:SetStatusBarTexture(config["Texture"])
	newbar:SetMinMaxValues(0, 100)
	newbar:SetWidth(config["Width"])
	newbar:SetHeight(config["Bar height"])
	newbar.left = CreateFS(newbar)
	newbar.left:SetPoint("LEFT", 2, 0)
	newbar.left:SetJustifyH("LEFT")
	newbar.right = CreateFS(newbar)
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
	current[uGUID][mode] = current[uGUID][mode] + ammount
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
		if i > config["Visible bars"] or not cur then break end
		if cur[sMode] == 0 then break end
		if not bar[i] then 
			bar[i] = CreateBar()
			bar[i]:SetPoint("TOP", 0, -(config["Bar height"] + config["Bar spacing"]) * (i-1))
		end
		bar[i]:SetValue(100 * cur[sMode] / max[sMode])
		color = RAID_CLASS_COLORS[cur.class]
		bar[i]:SetStatusBarColor(color.r, color.g, color.b)
		if sMode == DAMAGE or sMode == SHOW_COMBAT_HEALING then
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
		info.text = GAMEOPTIONS_MENU
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = MODE
		info.hasArrow = 1
		info.value = "Mode"
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = CHAT_ANNOUNCE
		info.hasArrow = 1
		info.value = "Report"
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = COMBAT
		info.hasArrow = 1
		info.value = "Fight"
		info.notCheckable = 1
		UIDropDownMenu_AddButton(info, level)
		wipe(info)
		info.text = RESET
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
		if #fights >= config["Saved fights"] then
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
				dataobj.text = string.format("DPS: %.0f", v[DAMAGE] / v.combatTime)
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

local FindShielder = function(destGUID, timestamp)
	if not shields[destGUID] then return end
	local found_shielder = nil
	for shield, spells in pairs(shields[destGUID]) do
		for shielder, ts in pairs(spells) do
			if ts - timestamp > 0 then
				found_shielder = shielder
			end
		end
	end
	return found_shielder
end

local OnEvent = function(self, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = select(1, ...)
		if band(sourceFlags, filter) == 0 and band(destFlags, filter) == 0 then return end
		if eventType=="SWING_DAMAGE" or eventType=="RANGE_DAMAGE" or eventType=="SPELL_DAMAGE" or eventType=="SPELL_PERIODIC_DAMAGE" or eventType=="DAMAGE_SHIELD" then
			local ammount, _, _, _, _, absorbed = select(eventType=="SWING_DAMAGE" and 9 or 12, ...)
			if IsFriendlyUnit(sourceGUID) and not IsFriendlyUnit(destGUID) and combatstarted then
				if ammount and ammount > 0 then
					sourceGUID = owners[sourceGUID] or sourceGUID
					Add(sourceGUID, ammount, DAMAGE)
					if not bossname and boss.BossIDs[tonumber(destGUID:sub(9, 12), 16)] then
						bossname = destName
					elseif not mobname then
						mobname = destName
					end
				end
			end
			if IsFriendlyUnit(destGUID) then
				local shielder = FindShielder(destGUID, timestamp)
				if shielder and absorbed and absorbed > 0 then
					Add(shielder, absorbed, ABSORB)
				end
			end
		elseif eventType=="SWING_MISSED" or eventType=="RANGE_MISSED" or eventType=="SPELL_MISSED" or eventType=="SPELL_PERIODIC_MISSED" then
			local misstype, amount = select(eventType=="SWING_MISSED" and 9 or 12, ...)
			if misstype == "ABSORB" and IsFriendlyUnit(destGUID) then
				local shielder = FindShielder(destGUID, timestamp)
				if shielder and amount and amount > 0 then
					Add(shielder, amount, ABSORB)
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
					Add(sourceGUID, ammount - over, SHOW_COMBAT_HEALING)
				end
			end
		elseif eventType=="SPELL_DISPEL" then
			if IsFriendlyUnit(sourceGUID) and IsFriendlyUnit(destGUID) and combatstarted then
				sourceGUID = owners[sourceGUID] or sourceGUID
				Add(sourceGUID, 1, DISPELS)
			end
		elseif eventType=="SPELL_INTERRUPT" then
			if IsFriendlyUnit(sourceGUID) and not IsFriendlyUnit(destGUID) and combatstarted then
				sourceGUID = owners[sourceGUID] or sourceGUID
				Add(sourceGUID, 1, INTERRUPTS)
			end
		elseif eventType=="SPELL_AURA_APPLIED" or eventType=="SPELL_AURA_REFRESH" then
			local spellId = select(9, ...)
			sourceGUID = owners[sourceGUID] or sourceGUID
			if AbsorbSpellDuration[spellId] and IsFriendlyUnit(sourceGUID) and IsFriendlyUnit(destGUID) then
				shields[destGUID] = shields[destGUID] or {}
				shields[destGUID][spellId] = shields[destGUID][spellId] or {}
				shields[destGUID][spellId][sourceGUID] = timestamp + AbsorbSpellDuration[spellId]
			end
		elseif eventType=="SPELL_AURA_REMOVED" then
			local spellId = select(9, ...)
			sourceGUID = owners[sourceGUID] or sourceGUID
			if AbsorbSpellDuration[spellId] and IsFriendlyUnit(destGUID) then
				if shields[destGUID] and shields[destGUID][spellId] and shields[destGUID][spellId][destGUID] then
					shields[destGUID][spellId][destGUID] = timestamp + 0.1
				end
			end
		else
			return
		end
	elseif event == "ADDON_LOADED" then
		local name = ...
		if name == addon_name then
			self:UnregisterEvent(event)
			MainFrame = CreateFrame("Frame", addon_name.."Frame", UIParent)
			MainFrame:SetPoint(config["Anchor point"], config["X offset"], config["Y offset"])
			MainFrame:SetSize(config["Width"], height)
			MainFrame.bg = CreateBG(MainFrame)
			MainFrame:SetMovable(true)
			MainFrame:EnableMouse(true)
			MainFrame:EnableMouseWheel(true)
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
			MainFrame.title = CreateFS(MainFrame)
			MainFrame.title:SetPoint("BOTTOMLEFT", MainFrame, "TOPLEFT", 0, 0)
			MainFrame.title:SetText(sMode)
			if config["Hide title"] then MainFrame.title:Hide() end
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
		Add(i, i*10000, DAMAGE)
		units[i] = nil
	end
	display = current
	UpdateBars()
end
SLASH_alDamage1 = "/aldmg"
