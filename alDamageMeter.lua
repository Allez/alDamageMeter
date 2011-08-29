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
local font = GameFontNormal:GetFont()
local font_style = "NONE"
local font_size = 10
local hidetitle = false
local classcolorbar = true
local onlyboss = false
local classcolorname = false
local mergeHealAbsorbs = false
-- Config end

if IsAddOnLoaded("alInterface") then
	local cfg = {}
	local config = {
		general = {
			hidetitle = {
				order = 1,
				value = false,
			},
			mergeheal = {
				order = 2,
				value = false,
			},
			visiblebars = {
				order = 3,
				value = 8,
				type = "range",
				min = 2,
				max = 40,
			},
			maxfights = {
				order = 4,
				value = 10,
				type = "range",
				min = 1,
				max = 30,
			},
			reportstrings = {
				order = 5,
				value = 10,
				type = "range",
				min = 1,
				max = 40,
			},
			onlyboss = {
				order = 6,
				value = false,
			},
		},
		sizes = {
			width = {
				order = 1,
				value = 125,
				type = "range",
				min = 10,
				max = 400,
			},
			barheight = {
				order = 2,
				value = 14,
				type = "range",
				min = 8,
				max = 25,
			},
			spacing = {
				order = 3,
				value = 1,
				type = "range",
				min = 0,
				max = 10,
			},
		},
	}

	UIConfigGUI.damage = config
	UIConfig.damage = cfg

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("VARIABLES_LOADED")
	frame:SetScript("OnEvent", function(self, event)
		width = cfg.sizes.width
		barheight = cfg.sizes.barheight
		spacing = cfg.sizes.spacing
		maxbars = cfg.general.visiblebars
		maxfights = cfg.general.maxfights
		reportstrings = cfg.general.reportstrings
		hidetitle = cfg.general.hidetitle
		mergeHealAbsorbs = cfg.general.mergeheal
		onlyboss = cfg.general.onlyboss
	end)
end

local addon_name, ns = ...
local boss = LibStub("LibBossIDs-1.0")
local dataobj = LibStub:GetLibrary('LibDataBroker-1.1'):NewDataObject('Dps', {type = "data source", text = 'DPS: ', icon = "", iconCoords = {0.065, 0.935, 0.065, 0.935}})
local band = bit.band
local bossname, mobname = nil, nil
local units, bar, barguids, owners = {}, {}, {}, {}
local current, total, display, fights = {}, {}, {}, {}
local timer, num, offset = 0, 0, 0
local MainFrame
local combatstarted = false
local raidFlags = COMBATLOG_OBJECT_AFFILIATION_RAID + COMBATLOG_OBJECT_AFFILIATION_PARTY + COMBATLOG_OBJECT_AFFILIATION_MINE
local petFlags = COMBATLOG_OBJECT_TYPE_PET + COMBATLOG_OBJECT_TYPE_GUARDIAN
local npcFlags = COMBATLOG_OBJECT_TYPE_NPC+COMBATLOG_OBJECT_CONTROL_NPC
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
	[86273] = 6, -- Illuminated Healing, Pala Mastery
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

local CreateFS = CreateFS or function(frame)
	local fstring = frame:CreateFontString(nil, 'OVERLAY')
	fstring:SetFont(font, font_size, font_style)
	fstring:SetShadowColor(0, 0, 0, 1)
	fstring:SetShadowOffset(0.5, -0.5)
	return fstring
end

local CreateBG = CreateBG or function(parent)
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
	return cdata[sMode].amount / cdata.combatTime
end

local report = function(channel, cn)
	local message = sMode..":"
	if channel == "Chat" then
		DEFAULT_CHAT_FRAME:AddMessage(message)
	else
		SendChatMessage(message, channel, nil, cn)
	end
	for i, v in pairs(barguids) do
		if i > reportstrings or display[v][sMode].amount == 0 then return end
		if sMode == DAMAGE or sMode == SHOW_COMBAT_HEALING then
			message = string.format("%2d. %s    %s (%.0f)", i, display[v].name, truncate(display[v][sMode].amount), perSecond(display[v]))
		else
			message = string.format("%2d. %s    %s", i, display[v].name, truncate(display[v][sMode].amount))
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
			StaticPopupDialogs[addon_name.."ReportDialog"].OnAccept = function(self)
				report("WHISPER", _G[self:GetName().."EditBox"]:GetText())
			end
			StaticPopup_Show(addon_name.."ReportDialog")
		end,
	},
	{
		text = CHANNEL.."..", 
		func = function() 
			StaticPopupDialogs[addon_name.."ReportDialog"].OnAccept = function(self)
				report("CHANNEL", _G[self:GetName().."EditBox"]:GetText())
			end
			StaticPopup_Show(addon_name.."ReportDialog")
		end,
	},
}

local OnBarEnter = function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
	GameTooltip:AddLine(self.left:GetText())
	GameTooltip:AddLine(SPELL_DETAIL)
	local a = {}
	local amount = display[barguids[self.id]][sMode].amount
	for spell, value in pairs(display[barguids[self.id]][sMode].spells) do
		tinsert(a, {spell, value})
	end
	table.sort(a, function(a, b) return a[2] > b[2] end)
	for _, v in pairs(a) do
		GameTooltip:AddDoubleLine(v[1], string.format("%d (%.1f%%)", v[2], v[2]/amount*100), 1, 1, 1, 1, 1, 1)
	end
	wipe(a)
	GameTooltip:AddLine(TARGET)
	for target, value in pairs(display[barguids[self.id]][sMode].targets) do
		tinsert(a, {target, value})
	end
	table.sort(a, function(a, b) return a[2] > b[2] end)
	for _, v in pairs(a) do
		GameTooltip:AddDoubleLine(v[1], string.format("%d (%.1f%%)", v[2], v[2]/amount*100), 1, 1, 1, 1, 1, 1)
	end
	GameTooltip:Show()
end

local OnBarLeave = function(self)
	GameTooltip:Hide()
end

local CreateBar = function()
	local newbar = CreateFrame("Statusbar", nil, MainFrame)
	newbar:SetStatusBarTexture(texture)
	newbar:SetMinMaxValues(0, 100)
	newbar:SetWidth(width)
	newbar:SetHeight(barheight)
	newbar.left = CreateFS(newbar)
	newbar.left:SetPoint("LEFT", 2, 0)
	newbar.left:SetJustifyH("LEFT")
	newbar.right = CreateFS(newbar)
	newbar.right:SetPoint("RIGHT", -2, 0)
	newbar.right:SetJustifyH("RIGHT")
	newbar:SetScript("OnEnter", OnBarEnter)
	newbar:SetScript("OnLeave", OnBarLeave)
	newbar:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" then
			ToggleDropDownMenu(1, nil, menuFrame, 'cursor', 0, 0)
		end
	end)
	return newbar
end

local CreateUnitInfo = function(uGUID)
	local unit = units[uGUID]
	local newdata = {
		name = unit.name,
		class = unit.class,
		combatTime = 1,
	}
	for _, v in pairs(displayMode) do
		newdata[v] = {
			amount = 0,
			spells = {},
			targets = {},
		}
	end
	return newdata
end

local Add = function(uGUID, amount, mode, spell, target)
	if not current[uGUID] then
		current[uGUID] = CreateUnitInfo(uGUID)
		tinsert(barguids, uGUID)
	end
	if not total[uGUID] then
		total[uGUID] = CreateUnitInfo(uGUID)
	end
	current[uGUID][mode].amount = current[uGUID][mode].amount + amount
	total[uGUID][mode].amount = total[uGUID][mode].amount + amount
	if spell then 
		current[uGUID][mode].spells[spell] = (current[uGUID][mode].spells[spell] or 0) + amount
		current[uGUID][mode].targets[target] = (current[uGUID][mode].targets[target] or 0) + amount
		total[uGUID][mode].spells[spell] = (total[uGUID][mode].spells[spell] or 0) + amount
		total[uGUID][mode].targets[target] = (total[uGUID][mode].targets[target] or 0) + amount
	end
end

local SortMethod = function(a, b)
	return display[b][sMode].amount < display[a][sMode].amount
end

local UpdateBars = function()
	table.sort(barguids, SortMethod)
	local color, cur, max
	for i = 1, #barguids do
		cur = display[barguids[i+offset]]
		max = display[barguids[1]]
		if i > maxbars or not cur then break end
		if cur[sMode].amount == 0 then break end
		if not bar[i] then 
			bar[i] = CreateBar()
			bar[i]:SetPoint("TOP", 0, -(barheight + spacing) * (i-1))
		end
		bar[i].id = i + offset
		bar[i]:SetValue(100 * cur[sMode].amount / max[sMode].amount)
		color = RAID_CLASS_COLORS[cur.class]
		bar[i]:SetStatusBarColor(color.r, color.g, color.b)
		if sMode == DAMAGE or sMode == SHOW_COMBAT_HEALING then
			bar[i].right:SetFormattedText("%s (%.0f)", truncate(cur[sMode].amount), perSecond(cur))
		else
			bar[i].right:SetFormattedText("%s", truncate(cur[sMode].amount))
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
	wipe(total)
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
		info.text = addon_name
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
			wipe(info)
			info.text = "Total"
			info.func = function() ResetDisplay(total) end
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
		units[UnitGUID(unit)] = {
			name = UnitName(unit),
			class = select(2, UnitClass(unit)),
			unit = unit,
		}
		pet = unit .. "pet"
		CheckPet(unit, pet)
	end
end

local CheckRoster = function()
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
				dataobj.text = string.format("DPS: %.0f", v[DAMAGE].amount / v.combatTime)
			end
		end
		for i, v in pairs(total) do
			if IsUnitInCombat(i) then
				v.combatTime = v.combatTime + timer
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
		if display[barguids[i]][sMode].amount > 0 then
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
	local found_shielder, found_shield = nil, nil
	for shield, spells in pairs(shields[destGUID]) do
		for shielder, ts in pairs(spells) do
			if ts - timestamp > 0 then
				found_shielder = shielder
				found_shield = shield
			end
		end
	end
	return found_shielder, found_shield
end

local IsUnitOrPet = function(flags)
	if band(flags, raidFlags) ~= 0 or band(flags, petFlags) ~= 0 then
		return true
	end
	return false
end

local OnEvent = function(self, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = select(1, ...)
		if eventType=="SPELL_SUMMON" and (band(sourceFlags, raidFlags) ~= 0 or band(sourceFlags, npcFlags) ~= 0 or band(sourceFlags, petFlags) ~= 0 or band(destFlags, petFlags) ~= 0) then
			if owners[sourceGUID] then
				owners[destGUID] = owners[sourceGUID]
			else
				owners[destGUID] = sourceGUID
				for pet, owner in pairs(owners) do
					if owners[owner] then
						owners[pet] = owners[owner]
						break
					end
				end
			end
		end
		if band(sourceFlags, raidFlags) == 0 and band(destFlags, raidFlags) == 0 and band(sourceFlags, petFlags) == 0 and band(destFlags, petFlags) == 0 then return end
		if eventType=="SWING_DAMAGE" or eventType=="RANGE_DAMAGE" or eventType=="SPELL_DAMAGE" or eventType=="SPELL_PERIODIC_DAMAGE" or eventType=="DAMAGE_SHIELD" then
			local amount, _, _, _, _, absorbed = select(eventType=="SWING_DAMAGE" and 12 or 15, ...)
			local spellName = eventType=="SWING_DAMAGE" and MELEE_ATTACK or select(13, ...)
			if IsFriendlyUnit(sourceGUID) and not IsFriendlyUnit(destGUID) and combatstarted then
				if amount and amount > 0 then
					if owners[sourceGUID] then
						sourceGUID = owners[sourceGUID]
						spellName = "Pet: "..spellName
					end
					Add(sourceGUID, amount, DAMAGE, spellName, destName)
					if not bossname and boss.BossIDs[tonumber(destGUID:sub(9, 12), 16)] then
						bossname = destName
					elseif not mobname and not onlyboss then
						mobname = destName
					end
				end
			end
			if IsFriendlyUnit(destGUID) then
				local shielder, shield = FindShielder(destGUID, timestamp)
				if shielder and absorbed and absorbed > 0 then
					Add(shielder, absorbed, mergeHealAbsorbs and SHOW_COMBAT_HEALING or ABSORB, shield, destName)
				end
			end
		elseif eventType=="SWING_MISSED" or eventType=="RANGE_MISSED" or eventType=="SPELL_MISSED" or eventType=="SPELL_PERIODIC_MISSED" then
			local misstype, amount = select(eventType=="SWING_MISSED" and 12 or 15, ...)
			if misstype == "ABSORB" and IsFriendlyUnit(destGUID) then
				local shielder, shield = FindShielder(destGUID, timestamp)
				if shielder and amount and amount > 0 then
					Add(shielder, amount, mergeHealAbsorbs and SHOW_COMBAT_HEALING or ABSORB, shield, destName)
				end
			end
		elseif eventType=="SPELL_HEAL" or eventType=="SPELL_PERIODIC_HEAL" then
			spellId, spellName, spellSchool, amount, over, school, resist = select(12, ...)
			if IsFriendlyUnit(sourceGUID) and IsFriendlyUnit(destGUID) and combatstarted then
				over = over or 0
				if amount and amount > 0 then
					sourceGUID = owners[sourceGUID] or sourceGUID
					Add(sourceGUID, amount - over, SHOW_COMBAT_HEALING, spellName, destName)
				end
			end
		elseif eventType=="SPELL_DISPEL" then
			if IsFriendlyUnit(sourceGUID) and combatstarted then
				sourceGUID = owners[sourceGUID] or sourceGUID
				Add(sourceGUID, 1, DISPELS, "Dispel", destName)
			end
		elseif eventType=="SPELL_INTERRUPT" then
			if IsFriendlyUnit(sourceGUID) and not IsFriendlyUnit(destGUID) and combatstarted then
				sourceGUID = owners[sourceGUID] or sourceGUID
				Add(sourceGUID, 1, INTERRUPTS, "Interrupt", destName)
			end
		elseif eventType=="SPELL_AURA_APPLIED" or eventType=="SPELL_AURA_REFRESH" then
			local spellId, spellName = select(12, ...)
			sourceGUID = owners[sourceGUID] or sourceGUID
			if AbsorbSpellDuration[spellId] and IsFriendlyUnit(sourceGUID) and IsFriendlyUnit(destGUID) then
				shields[destGUID] = shields[destGUID] or {}
				shields[destGUID][spellName] = shields[destGUID][spellName] or {}
				shields[destGUID][spellName][sourceGUID] = timestamp + AbsorbSpellDuration[spellId]
			end
		elseif eventType=="SPELL_AURA_REMOVED" then
			local spellId, spellName = select(12, ...)
			sourceGUID = owners[sourceGUID] or sourceGUID
			if AbsorbSpellDuration[spellId] and IsFriendlyUnit(destGUID) then
				if shields[destGUID] and shields[destGUID][spellName] and shields[destGUID][spellName][destGUID] then
					shields[destGUID][spellName][destGUID] = timestamp + 0.1
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
			MainFrame:SetPoint(anchor, x, y)
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
			CheckRoster()
		end
	elseif event == "VARIABLES_LOADED" then
		if not hidetitle then
			MainFrame.title = CreateFS(MainFrame)
			MainFrame.title:SetPoint("BOTTOM", MainFrame, "TOP", 0, 1)
			MainFrame.title:SetText(sMode)
		end
		MainFrame:SetSize(width, height)
	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
		CheckRoster()
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
addon:RegisterEvent("VARIABLES_LOADED")
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
