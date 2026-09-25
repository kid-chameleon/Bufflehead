-- Bufflehead is an addon to skin player buffs and debuffs.
--
-- Features:
-- 1. Hide/show Blizzard buff frame (buffs, debuffs, weapon enchants)
-- 2. Options panel to configure display of player buffs and debuffs
-- 3. Option to use Masque to skin borders
-- 4. Options for layout although limited by SecureAuraHeaderTemplate
-- 5. Efficient event-driven handler
-- 6. Load-on-demand options panel to minimize memory use
--
-- Author: Tomber/Tojaso (curseforge, github, wowinterface)
-- Copyright 2020, All Rights Reserved

Bufflehead = LibStub("AceAddon-3.0"):NewAddon("Bufflehead", "AceConsole-3.0", "AceEvent-3.0")
local MOD = Bufflehead
local MOD_Options = "Bufflehead_Options"
local SHIM = {}
MOD.SHIM = SHIM
local _

MOD.isClassic = (WOW_PROJECT_ID == WOW_PROJECT_CLASSIC)
	or (WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC)
	or (WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC)
	or (WOW_PROJECT_ID == WOW_PROJECT_CATACLYSM_CLASSIC)
	or (WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC)


-- Use the AuraContainer code in restricted environments
MOD.useContainer = (C_Secrets and C_Secrets.HasSecretRestrictions and C_Secrets.HasSecretRestrictions()) or false

MOD.frame = nil
MOD.headers = {}
MOD.previews = {}
MOD.db = nil
MOD.LibLDB = nil -- LibDataBroker support
MOD.ldb = nil -- set to addon's data broker object
MOD.ldbi = nil -- set for addon's minimap icon
MOD.uiOpen = false -- true when options panel is open
MOD.showAnchors = false -- enable to show anchors
MOD.showPreviews = false -- enable to show previews

local FILTER_BUFFS = "HELPFUL"
local FILTER_DEBUFFS = "HARMFUL"
local BUFFS_TEMPLATE = "BuffleheadAuraTemplate"
local HEADER_NAME = "BuffleheadSecureHeader"
local HEADER_PLAYER_BUFFS = HEADER_NAME .. "PlayerBuffs"
local HEADER_PLAYER_DEBUFFS = HEADER_NAME .. "PlayerDebuffs"
local BUFFLE_ICON = "Interface\\AddOns\\Bufflehead\\Media\\BuffleheadIcon"
local PRESET_BUFF_ICON = "Interface\\Icons\\inv_bijou_green"
local PRESET_DEBUFF_ICON = "Interface\\Icons\\inv_bijou_red"
local HEADER_FRAME_LEVEL = 100
local DEFAULT_ICON_BORDER = "Interface\\Buttons\\UI-ActionButton-Border"
local RAVEN_ICON_BORDER = "Interface\\AddOns\\Bufflehead\\Media\\IconDefault"

local onePixelBackdrop = { -- backdrop initialization for icons when using optional one and two pixel borders
	bgFile = "Interface\\AddOns\\Bufflehead\\Media\\WhiteBar",
	edgeFile = "Interface\\BUTTONS\\WHITE8X8.blp", edgeSize = 1, insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

local twoPixelBackdrop = { -- backdrop initialization for icons when using optional one and two pixel borders
	bgFile = "Interface\\AddOns\\Bufflehead\\Media\\WhiteBar",
	edgeFile = "Interface\\BUTTONS\\WHITE8X8.blp", edgeSize = 2, insets = { left = 0, right = 0, top = 0, bottom = 0 }
}

local justifyH = { BOTTOM = "CENTER", BOTTOMLEFT = "LEFT", BOTTOMRIGHT = "RIGHT", CENTER = "CENTER", LEFT = "LEFT",
				   RIGHT = "RIGHT", TOP = "CENTER", TOPLEFT = "LEFT", TOPRIGHT = "RIGHT" }

local justifyV = { BOTTOM = "BOTTOM", BOTTOMLEFT = "BOTTOM", BOTTOMRIGHT = "BOTTOM", CENTER = "MIDDLE", LEFT = "MIDDLE",
				   RIGHT = "MIDDLE", TOP = "TOP", TOPLEFT = "TOP", TOPRIGHT = "TOP" }

local debuffTypes = { "none", "Disease", "Poison", "Curse", "Magic" }

local addonInitialized = false -- set when the addon is initialized
local addonEnabled = false -- set when the addon is enabled
local optionsLoaded = false -- set when options panel is loaded
local optionsFailed = false -- set if loading options panel fails
local enteredWorld = false -- set when player enter world event handled
local blizzHidden = false -- set when blizzard buffs and debuffs are hidden
local updateAll = false -- set in combat to defer running event handler
local MSQ_Group = nil -- create a single group for masque
local MSQ_ButtonData = nil -- template for masque button data structure
local weaponDurations = {} -- best guess for weapon buff durations, indexed by enchant id
local buffTooltip = nil -- temporary table for getting weapon enchant names
local transparent = { r = 0, g = 0, b = 0, a = 0 } -- transparent color
local pg, pp -- global and character-specific profiles

local UnitAura = UnitAura
local GetTime = GetTime
local GetScreenHeight = GetScreenHeight
local GetPhysicalScreenSize = GetPhysicalScreenSize
local CreateFrame = CreateFrame
local RegisterAttributeDriver = RegisterAttributeDriver
local RegisterStateDriver = RegisterStateDriver
local InCombatLockdown = InCombatLockdown
local GetWeaponEnchantInfo = GetWeaponEnchantInfo
local GetInventoryItemTexture = GetInventoryItemTexture

-- Functions used for pixel pefect calculations
local pixelScale = 1 -- scale factor used for size and alignment
local screenWidth, screenHeight -- physical size of screen in pixels
local displayWidth, displayHeight, displayScale -- virtual size and scale of UIParent

local function PS(x) if type(x) == "number" then return pixelScale * math.floor(x / pixelScale + 0.5) else return x end end
local function PSetWidth(region, w) if w then w = pixelScale * math.floor(w / pixelScale + 0.5) end region:SetWidth(w) end
local function PSetHeight(region, h) if h then h = pixelScale * math.floor(h / pixelScale + 0.5) end region:SetHeight(h) end

local function PSetSize(frame, w, h)
	if w then w = pixelScale * math.floor(w / pixelScale + 0.5) end
	if h then h = pixelScale * math.floor(h / pixelScale + 0.5) end
	frame:SetSize(w, h)
end

local function PSetPoint(frame, point, relativeFrame, relativePoint, x, y)
	if x then x = pixelScale * math.floor(x / pixelScale + 0.5) end
	if y then y = pixelScale * math.floor(y / pixelScale + 0.5) end
	if frame then
		frame:SetPoint(point, relativeFrame, relativePoint, x or 0, y or 0)
	end
end

-- Return the color for a debuff type
local function GetDebuffTypeColor(btype)
	if _G.DebuffTypeColor then return _G.DebuffTypeColor[btype] end
	if AuraUtil and AuraUtil.GetAuraBorderColor then return AuraUtil.GetAuraBorderColor((btype ~= "none") and btype or nil) end
	return nil
end

-- Print debug messages with variable number of arguments in a useful format
function MOD.Debug(a, ...)
	if type(a) == "table" then
		for k, v in pairs(a) do print(tostring(k) .. " = " .. tostring(v)) end -- if first parameter is a table, print out its fields
	else
		local s = tostring(a) -- otherwise first argument is a string but just make sure
		local parm = {...}
		for i = 1, #parm do s = s .. " " .. tostring(parm[i]) end -- append remaining arguments converted to strings
		print(s)
	end
end

-- Check if the options panel is loaded, if not then get it loaded and ask it to toggle open/close status
function MOD.OptionsPanel()
	if not optionsLoaded and not optionsFailed then
		optionsLoaded = true
		local loaded, reason = SHIM:LoadAddOn(MOD_Options) -- try to load the options panel on demand
		if not loaded then
			print("Bufflehead: failed to load " .. tostring(MOD_Options) .. ": " .. tostring(reason))
			optionsFailed = true
		end
	end
	if not optionsFailed then MOD:ToggleOptions() end
end

-- Initialize tooltip to be used for determining weapon buffs
local function InitializeBuffTooltip()
	local tipName = "Bufflehead_WeaponBuff_Tooltip"
	buffTooltip = buffTooltip or CreateFrame("GameTooltip", tipName, nil)
	buffTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
	buffTooltip.tooltipLines = buffTooltip.tooltipLines or {} -- cache of font strings for each line in the tooltip

	for i = 1, 30 do
		local leftText, rightText = _G[tipName.."TextLeft"..i], _G[tipName.."TextRight"..i]
		if leftText then
			buffTooltip.tooltipLines[i] = leftText
		else
			local ls = buffTooltip:CreateFontString(tipName.."TextLeft"..i, "ARTWORK", "GameTooltipText")
			local rs = buffTooltip:CreateFontString(tipName.."TextRight"..i, "ARTWORK", "GameTooltipText")
			ls:SetFontObject(GameTooltipText)
			rs:SetFontObject(GameTooltipText)
			buffTooltip.tooltipLines[i] = ls
			buffTooltip:AddFontStrings(buffTooltip.tooltipLines[i], rs)
		end
	end
end

-- Return the temporary table for storing buff tooltips
local function GetBuffTooltip()
	buffTooltip:ClearLines()
	if not buffTooltip:IsOwned(WorldFrame) then buffTooltip:SetOwner(WorldFrame, "ANCHOR_NONE") end
	return buffTooltip
end

local function GetWeaponBuffName(weaponSlot)
	local ttInfo = C_TooltipInfo.GetInventoryItem("player", weaponSlot, false)

	for i = 1, 30 do
		if ttInfo.lines[i] and ttInfo.lines[i].leftText then
			local text = ttInfo.lines[i].leftText

			if text then
				local name = text:match("^(.+) %(%d+ [^$)]+%)$") -- extract up to left paren if match weapon buff format
				if name then
					name = (name:match("^(.*) %d+$")) or name -- remove any trailing numbers
					return name
				end
			else
				break
			end
		end
	end

	return nil
end

-- No easy way to get this info, so scan item slot info for mainhand and offhand weapons using a tooltip
-- Weapon buffs are usually formatted in tooltips as name strings followed by remaining time in parentheses
-- This routine scans the tooltip for the first line that is in this format and extracts the weapon buff name without rank or time
local function GetWeaponBuffNameClassic(weaponSlot)
	local tt = GetBuffTooltip()
	tt:SetInventoryItem("player", weaponSlot)
	for i = 1, 30 do
		local text = tt.tooltipLines[i]:GetText()
		if text then
			local name = text:match("^(.+) %(%d+ [^$)]+%)$") -- extract up to left paren if match weapon buff format
			if name then
				name = (name:match("^(.*) %d+$")) or name -- remove any trailing numbers
				return name
			end
		else
			break
		end
	end

	local id = GetInventoryItemID("player", weaponSlot) -- fall back to returning weapon name
	if id then
		local name = C_Item.GetItemNameByID(id)
		if name then return name end -- fall back to returning name of the weapon
	end
	return "Unknown Enchant [" .. weaponSlot .. "]"
end

-- Event called when addon is loaded, good time to load libraries
function MOD:OnInitialize()
	if addonInitialized then return end -- only run this code once
	addonInitialized = true
	MOD.frame = CreateFrame("Frame")-- create a frame to catch events
	SHIM:LoadAddOn("LibDataBroker-1.1")
	SHIM:LoadAddOn("LibDBIcon-1.0")
end

-- Adjust a backdrop's insets for pixel perfect factor
local function SetInsets(backdrop, x)
	local t = backdrop.insets
	t.left = x; t.right = x; t.top = x; t.bottom = x
end

-- Calculate pixel perfect scale factor
local function SetPixelScale()
	screenWidth, screenHeight = GetPhysicalScreenSize() -- size in pixels of display in full screen, otherwise window size in pixels
	displayWidth = UIParent:GetWidth() -- saved for calculating anchor position
	displayHeight = UIParent:GetHeight()
	displayScale = UIParent:GetScale() -- adjusted by ElvUI and possibly others
	pixelScale = GetScreenHeight() / screenHeight -- figure out how big virtual pixels are versus screen pixels
	onePixelBackdrop.edgeSize = PS(1) -- update one pixel border backdrop
	SetInsets(onePixelBackdrop, PS(1))
	twoPixelBackdrop.edgeSize = PS(2) -- update two pixel border backdrop
	SetInsets(twoPixelBackdrop, PS(2))

	-- MOD.Debug("Bufflehead: pixel w/h/scale", screenWidth, screenHeight, pixelScale, displayWidth, displayHeight, displayScale)
	-- MOD.Debug("Bufflehead: UIParent scale/effective", UIParent:GetScale(), UIParent:GetEffectiveScale())
end

-- Adjust pixel perfect scale factor when the UIScale is changed
local function UIScaleChanged()
	if not enteredWorld then return end
	if InCombatLockdown() then
		updateAll = true
	else
		SetPixelScale()
		MOD.UpdateAll() -- redraw everything
	end
end

-- Completely redraw everything that can be redrawn without /reload
-- Only execute this when not in combat, defer to when leave combat if necessary
function MOD.UpdateAll()
	if not enteredWorld then return end
	pg = MOD.db.global; pp = MOD.db.profile
	if InCombatLockdown() then
		updateAll = true
	else
		updateAll = false
		for k, header in pairs(MOD.headers) do MOD.UpdateHeader(header) end
	end
end

-- Event called when addon is enabled, good time to register events and chat commands
function MOD:OnEnable()
	if addonEnabled then return end -- only run this code once
	addonEnabled = true

	MOD.db = LibStub("AceDB-3.0"):New("BuffleheadDB", MOD.DefaultProfile) -- get current profile
	pg = MOD.db.global; pp = MOD.db.profile

	MOD:RegisterChatCommand("bufflehead", function() MOD.OptionsPanel() end)
	MOD:RegisterChatCommand("buffle", function() MOD.OptionsPanel() end)
	MOD.InitializeLDB() -- initialize the data broker and minimap icon
	MOD.LSM = LibStub("LibSharedMedia-3.0")
	MOD.MSQ = LibStub("Masque", true)
	if MOD.MSQ then MSQ_Group = MOD.MSQ:Group("Bufflehead", "Buffs and Debuffs") end

	MSQ_ButtonData = { AutoCast = false, AutoCastable = false, Border = false, Checked = false, Cooldown = false, Count = false, Duration = false,
					   Disabled = false, Flash = false, Highlight = false, HotKey = false, Icon = false, Name = false, Normal = false, Pushed = false }

	InitializeBuffTooltip()

	self:RegisterEvent("UI_SCALE_CHANGED", UIScaleChanged)
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	-- auras are also secret in PvP matches, encounters, and on restricted maps, which end without a regen event
	if MOD.useContainer then self:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", MOD.RestrictionChanged) end
end

-- Event called when play starts, initialize subsystems that had to wait for system bootstrap
function MOD:PLAYER_ENTERING_WORLD()
	if enteredWorld then return end -- only run this code once
	enteredWorld = true
	SetPixelScale() -- initialize scale factor for pixel perfect size and alignment

	if pg.enabled then -- make sure addon is enabled
		MOD.CheckBlizzFrames() -- check blizz frames and hide the ones selected on the Defaults tab
		for name, group in pairs(pp.groups) do
			if group.enabled then -- create header for enabled group, must do /reload if change header-related options
				local unit, filter = group.unit, group.filter
				local header
				if MOD.useContainer then
					header = MOD.CreateContainer(name, unit, filter)
				else
					header = CreateFrame("Frame", name, UIParent, "SecureAuraHeaderTemplate")
					header:SetAttribute("unit", unit)
					header:SetAttribute("filter", filter)
					RegisterAttributeDriver(header, "state-visibility", "[petbattle] hide; show")
				end
				header:SetFrameLevel(HEADER_FRAME_LEVEL)
				--header:SetClampedToScreen(true)
				header.filter = filter
				MOD.headers[name] = header

				if (unit == "player") and not MOD.useContainer then
					RegisterAttributeDriver(header, "unit", "[vehicleui] vehicle; player")
					if filter == FILTER_BUFFS then
						header:SetAttribute("consolidateDuration", -1) -- no consolidation
						header:SetAttribute("includeWeapons", pp.weaponEnchants and 1 or 0)
					end
				end

				local backdrop = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate")
				backdrop.caption = backdrop:CreateFontString(nil, "OVERLAY")
				backdrop.caption:SetFontObject(ChatFontNormal)
				PSetPoint(backdrop.caption,"CENTER", backdrop, "BOTTOM")
				backdrop.caption:SetText(group.caption)
				backdrop:SetFrameStrata("LOW") -- show it behind Bufflehead's buttons
				backdrop:SetMovable(true)
				backdrop.headerName = name
				backdrop._deltaX = 0 -- delta for backdrop position when bars extend outside bounding box
				backdrop._deltaY = 0
				header.anchorBackdrop = backdrop
				MOD.UpdateHeader(header)
			end
		end
	end
end

-- Event called when leaving combat
function MOD:PLAYER_REGEN_ENABLED(e)
	if updateAll then MOD.UpdateAll() end
end

-- Event called when an addon restriction starts or ends, sequenced after the restriction is lifted
function MOD.RestrictionChanged()
	if updateAll and not C_Secrets.ShouldAurasBeSecret() then MOD.UpdateAll() end
end

-- Create a data broker and minimap icon for the addon
function MOD.InitializeLDB()
	MOD.LibLDB = LibStub("LibDataBroker-1.1", true)
	if not MOD.LibLDB then return end
	MOD.ldb = MOD.LibLDB:NewDataObject("Bufflehead", {
		type = "launcher",
		text = "Bufflehead",
		icon = BUFFLE_ICON,
		OnClick = function(_, msg)
			if IsShiftKeyDown() or IsAltKeyDown() then return end
			if msg == "LeftButton" then
				MOD.OptionsPanel()
			elseif msg == "RightButton" then
				MOD.TogglePreviews()
			end
		end,
		OnTooltipShow = function(tooltip)
			if not tooltip or not tooltip.AddLine then return end
			tooltip:AddLine("Bufflehead")
			tooltip:AddLine("|cffffff00Left-click|r to open/close options menu")
			tooltip:AddLine("|cffffff00Right-click|r to toggle showing previews")
		end,
	})

	MOD.ldbi = LibStub("LibDBIcon-1.0", true)
	if MOD.ldbi then MOD.ldbi:Register("Bufflehead", MOD.ldb, pg.Minimap) end
end

-- Toggle visibility of previews
function MOD.TogglePreviews()
	MOD.showPreviews = not MOD.showPreviews
	MOD.CheckPreviews()
	MOD.UpdateAll()
end

-- Register the events a Blizzard aura frame listens to, undoing UnregisterAllEvents
local function RestoreAuraFrameEvents(frame)
	if frame.AuraFrameEventListener_OnLoad then
		frame:AuraFrameEventListener_OnLoad()
		if frame == BuffFrame then frame:RegisterEvent("WEAPON_ENCHANT_CHANGED"); frame:RegisterEvent("WEAPON_SLOT_CHANGED") end
	else
		frame:RegisterEvent("UNIT_AURA")
	end
end

-- Show or hide the blizzard buff frames, called during update so synched with other changes
function MOD.CheckBlizzFrames()
	if not MOD.isClassic and C_PetBattles and C_PetBattles.IsInBattle() then return end -- don't change visibility of any frame during pet battles
	local frame = _G.BuffFrame
	local hide, show = false, false
	local visible = frame:IsShown()
	if visible then
		if pg.hideBlizz then hide = true end
	else
		if pg.hideBlizz then show = false else show = blizzHidden end -- only show if this addon hid the frame
	end
	-- MOD.Debug("Bufflehead: hide/show", key, "hide:", hide, "show:", show, "vis: ", visible)
	if hide then
		BuffFrame:Hide()
		BuffFrame:UnregisterAllEvents()
		blizzHidden = true
		if not MOD.isClassic and DebuffFrame then
			DebuffFrame:Hide();
			DebuffFrame:UnregisterAllEvents()
		end
		if TemporaryEnchantFrame then
			TemporaryEnchantFrame:Hide();
		end
	elseif show then
		BuffFrame:Show()
		RestoreAuraFrameEvents(BuffFrame)
		blizzHidden = false
		if not MOD.isClassic and DebuffFrame then
			DebuffFrame:Show();
			RestoreAuraFrameEvents(DebuffFrame)
		end
		if TemporaryEnchantFrame then
			TemporaryEnchantFrame:Show();
		end
	end
end

-- Toggle visibility of the anchors
function MOD.ToggleAnchors()
	MOD.showAnchors = not MOD.showAnchors
	MOD.UpdateAll()
end

-- Get weapon enchant duration, since this is not supplied by blizzard look at current detected duration
-- and compare it to longest previous duration for the given weapon buff in order to find maximum detected
local function WeaponDuration(buff, duration)
	local maxd = weaponDurations[buff]
	if not maxd or (duration > maxd) then
		weaponDurations[buff] = math.floor(duration + 0.5) -- round up
	else
		if maxd > duration then duration = maxd end
	end
	return duration
end

-- Function called when a new aura button is created
function MOD:Button_OnLoad(button)
	local level = button:GetFrameLevel()

	button.iconTexture = button:CreateTexture(nil, "ARTWORK")
	button.iconBorder = button:CreateTexture(nil, "OVERLAY", nil, -3)
	button.iconBackdrop = CreateFrame("Frame", nil, button, BackdropTemplateMixin and "BackdropTemplate")
	button.iconBackdrop:SetFrameLevel(level - 1) -- behind icon
	button.iconHighlight = button:CreateTexture(nil, "HIGHLIGHT")
	button.iconHighlight:SetColorTexture(1, 1, 1, 0.5)
	button.clock = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
	local bc = button.clock
	bc.noCooldownCount = pg.hideOmniCC -- enable or disable OmniCC text
	bc:SetHideCountdownNumbers(true)
	bc:SetFrameLevel(level + 2) -- in front of icon but behind bar
	bc:SetSwipeTexture(0)
	bc:SetDrawBling(false)
	bc:ClearAllPoints()
	bc:SetPoint("CENTER", button, "CENTER") -- always centered on the button
	button.texts = CreateFrame("Frame", nil, button) -- all texts are in this frame
	button.texts:SetFrameLevel(level + 6) -- texts are on top of everything else
	button.timeText = button.texts:CreateFontString(nil, "OVERLAY")
	button.timeText:SetFontObject(ChatFontNormal)
	button.countText = button.texts:CreateFontString(nil, "OVERLAY")
	button.labelText = button.texts:CreateFontString(nil, "OVERLAY")
	button.bar = CreateFrame("StatusBar", nil, button, BackdropTemplateMixin and "BackdropTemplate")
	button.bar:SetFrameLevel(level + 4) -- in front of icon
	button.barBackdrop = CreateFrame("Frame", nil, button.bar, BackdropTemplateMixin and "BackdropTemplate")
	button.barBackdrop:SetFrameLevel(level + 3) -- behind bar but in front of icon

	if MOD.MSQ then -- if MSQ is loaded then initialize its required data table
		button.buttonData = {}
		for k, v in pairs(MSQ_ButtonData) do button.buttonData[k] = v end
	end

	-- aura container buttons refuse scripts from addons
	if not button.SetCancelAuraButtons then button:SetScript("OnAttributeChanged", MOD.Button_OnAttributeChanged) end
end

-- Trim and scale icon
local function IconTextureTrim(tex, icon, trim, iconSize)
	local left, right, top, bottom = 0, 1, 0, 1 -- default without trim
	if trim then left = 0.07; right = 0.93; top = 0.07; bottom = 0.93 end -- trim removes 7% of edges
	tex:SetTexCoord(left, right, top, bottom) -- set the corner coordinates
	PSetSize(tex, iconSize, iconSize)
	icon.iconTextureSize = iconSize
end

-- Draw a border of solid edges around a frame, plus a background, using plain textures instead of a backdrop
local pixelBorderEdges = { "top", "bottom", "left", "right" }

local function SetPixelBorder(frame, edgeSize, bgFile)
	local t = frame.pixelBorder
	if not t then
		if not edgeSize then return end
		t = { bg = frame:CreateTexture(nil, "BACKGROUND") }
		for _, k in ipairs(pixelBorderEdges) do t[k] = frame:CreateTexture(nil, "BORDER"); t[k]:SetColorTexture(1, 1, 1, 1) end
		frame.pixelBorder = t
	end
	for _, tex in pairs(t) do tex:ClearAllPoints(); tex:SetShown(edgeSize ~= nil) end
	if not edgeSize then return end

	t.top:SetPoint("TOPLEFT"); t.top:SetPoint("TOPRIGHT"); t.top:SetHeight(edgeSize)
	t.bottom:SetPoint("BOTTOMLEFT"); t.bottom:SetPoint("BOTTOMRIGHT"); t.bottom:SetHeight(edgeSize)
	t.left:SetPoint("TOPLEFT", 0, -edgeSize); t.left:SetPoint("BOTTOMLEFT", 0, edgeSize); t.left:SetWidth(edgeSize)
	t.right:SetPoint("TOPRIGHT", 0, -edgeSize); t.right:SetPoint("BOTTOMRIGHT", 0, edgeSize); t.right:SetWidth(edgeSize)
	for _, k in ipairs(pixelBorderEdges) do t[k]:SetShown(edgeSize > 0) end
	t.bg:SetPoint("TOPLEFT", edgeSize, -edgeSize); t.bg:SetPoint("BOTTOMRIGHT", -edgeSize, edgeSize)
	t.bg:SetTexture(bgFile or "Interface\\BUTTONS\\WHITE8X8.blp")
end

local function SetPixelBorderColors(frame, border, background, backgroundOpacity)
	local t = frame.pixelBorder
	if not t then return end
	for _, k in ipairs(pixelBorderEdges) do
		if border then t[k]:SetVertexColor(border.r, border.g, border.b, border.a or 1) else t[k]:SetVertexColor(0, 0, 0, 0) end
	end
	if background then
		t.bg:SetVertexColor(background.r, background.g, background.b, backgroundOpacity or background.a or 1)
	else
		t.bg:SetVertexColor(0, 0, 0, 0)
	end
end

-- Skin the icon's border
local function SkinBorder(button, c)
	local bib = button.iconBorder
	local bik = button.iconBackdrop
	local bih = button.iconHighlight
	local tex = button.iconTexture
	local iconSize = button.iconSize
	local masqueLoaded = MOD.MSQ and MSQ_Group and button.buttonData
	local opt = pp.iconBorder -- option for type of border
	bib:ClearAllPoints()
	bik:ClearAllPoints()
	if masqueLoaded then MSQ_Group:RemoveButton(button, true) end
	if not c then c = { r = 0.5, g = 0.5, b = 0.5, a = 1 } end

	if opt == "raven" then -- skin with raven's border
		IconTextureTrim(tex, button, true, iconSize * 0.91)
		bib:SetAllPoints(button)
		bib:SetTexture(GetFileIDFromPath(RAVEN_ICON_BORDER))
		bib:SetVertexColor(c.r, c.g, c.b, c.a or 1)
		bib:SetBlendMode("ADD")
		bib:Show()
		bih:Hide()
		bik:Hide()
	elseif (opt == "one") or (opt == "two") then -- skin with single or double pixel border
		IconTextureTrim(tex, button, true, iconSize - ((opt == "one") and PS(2) or PS(4)))
		bik:SetAllPoints(button)
		if button.noBackdrops then
			SetPixelBorder(bik, (opt == "one") and PS(1) or PS(2))
			SetPixelBorderColors(bik, c, nil)
		else
			bik:SetBackdrop((opt == "one") and onePixelBackdrop or twoPixelBackdrop)
			bik:SetBackdropColor(0, 0, 0, 0)
			bik:SetBackdropBorderColor(c.r, c.g, c.b, c.a or 1)
		end
		bik:Show()
		bih:Hide()
		bib:Hide()
	elseif (opt == "masque") and masqueLoaded then -- use Masque only if available
		IconTextureTrim(tex, button, false, iconSize)
		bib:SetAllPoints(button)
		bib:SetVertexColor(c.r, c.g, c.b, c.a or 1)
		bib:SetBlendMode("ADD")
		bib:Show()
		bih:Show()
		local bdata = button.buttonData
		bdata.Icon = tex
		bdata.Normal = button:GetNormalTexture()
		bdata.Cooldown = button.clock
		bdata.Border = bib
		bdata.Highlight = button.iconHighlight
		MSQ_Group:AddButton(button, bdata)
		bik:Hide()
	elseif opt == "default" then -- show blizzard's standard border
		IconTextureTrim(tex, button, false, iconSize)
		bib:SetTexture(GetFileIDFromPath(DEFAULT_ICON_BORDER))
		bib:SetVertexColor(c.r, c.g, c.b, c.a or 1)
		bib:SetBlendMode("ADD")
		PSetSize(bib, iconSize * 1.7, iconSize * 1.7)
		PSetPoint(bib, "CENTER", button, "CENTER")
		bib:Show()
		bih:Hide()
		bik:Hide()
	else -- no border (remove standard border)
		IconTextureTrim(tex, button, true, iconSize)
		bib:Hide()
		bih:Hide()
		bik:Hide()
	end
end

-- Skin the icon's clock overlay, must be done after skinning the border
local function SkinClock(button, duration, expire)
	local bc = button.clock
	local remaining = (expire or 0) - GetTime()

	if pp.showClock and duration and duration > 0.1 and remaining > 0.05 then -- check if limited duration
		-- bc:ClearAllPoints()
		local w, h = button.iconTexture:GetSize()
		bc:SetDrawEdge(pp.clockEdge)
		bc:SetReverse(pp.clockReverse)
		local c = pp.clockColor
		-- bc:SetSwipeTexture(0)
		bc:SetSwipeColor(c.r, c.g, c.b, c.a or 1)
		bc:SetSize(w, h) -- icon texture was already sized and scaled
		-- bc:SetPoint("CENTER", button, "CENTER")
		bc:SetCooldown(expire - duration, duration)
		bc:Show()
	else
		bc:SetCooldown(0, 0)
		bc:Hide()
	end
end

-- Validate that have a valid font reference
local function ValidFont(name) return (name and (type(name) == "string") and (name ~= "")) end

-- Return font flags based on text settings
local function GetFontFlags(flags)
	local ff = ""
	if flags.outline then ff = "OUTLINE" end
	if flags.thick then if ff == "" then ff = "THICKOUTLINE" else ff = ff .. ", THICKOUTLINE" end end
	if flags.mono then if ff == "" then ff = "MONOCHROME" else ff = ff .. ", MONOCHROME" end end
	return ff
end

-- Clear the time text
local function StopButtonTime(button)
	button:SetScript("OnUpdate", nil) -- stop updating the time text
	button._expire = nil
	button._update = nil
	button.timeText:SetText(" ")
	button.timeText:Hide()
end

-- Update the time text for a button, triggered OnUpdate so keep it quick
local function UpdateButtonTime(button)
	if button and button._expire then -- make sure valid call
		local now = GetTime()
		local remaining = button._expire - now
		local c = pp.timeColor
		if remaining < 5 then c = pp.expireColor end -- set either regular or expiring color
		if c then button.timeText:SetTextColor(c.r, c.g, c.b, c.a) end
		if remaining > 0.05 then
			if (button._update == 0) or ((now - button._update) > 0.05) then -- about 20/second
				button._update = now
				button.timeText:SetText(MOD.FormatTime(remaining, pp.timeFormat, pp.timeSpaces, pp.timeCase))
			end
		else
			StopButtonTime(button)
		end
	end
end

-- Configure the button's time text for given duration and expire values
local function SkinTime(button, duration, expire)
	local bt = button.timeText
	local remaining = (expire or 0) - GetTime()

	if pp.showTime and duration and duration > 0.1 and remaining > 0.05 then -- check if limited duration
		bt:ClearAllPoints() -- need to reset because size changes
		bt:SetFontObject(ChatFontNormal)
		local font = pp.timeFontPath
		if ValidFont(font) then
			local flags = GetFontFlags(pp.timeFontFlags)
			bt:SetFont(font, pp.timeFontSize, flags)
		elseif ValidFont(pp.timeFont) then
			pp.timeFontPath = MOD.LSM:Fetch("font", pp.timeFont)
		end
		bt:SetText("0:00:00") -- set to widest time string, note this is overwritten later with correct string!
		local timeMaxWidth = bt:GetStringWidth() -- get maximum text width using current font
		PSetWidth(bt, timeMaxWidth) -- helps with jitter since keeps size static
		bt:SetShadowColor(0, 0, 0, pp.timeShadow and 1 or 0)
		local pos = pp.timePosition
		local pt = pos.point
		bt:SetJustifyV(justifyV[pt]); bt:SetJustifyH(justifyH[pt]) -- anchor point adjusts alignment too
		local frame = button
		if pp.showBar and (pos.anchor == "bar") then frame = button.bar end
		PSetPoint(bt, pos.point, frame, pos.relativePoint, pos.offsetX, pos.offsetY)
		button._update = 0
		UpdateButtonTime(button)
		bt:Show()
		button:SetScript("OnUpdate", UpdateButtonTime) -- start updating time text
	else
		StopButtonTime(button)
	end
end

-- Configure the button's count text for given value
local function SkinCount(button, count)
	local ct = button.countText

	if pp.showCount and count and count > 1 then -- check if valid parameters
		ct:ClearAllPoints()
		ct:SetFontObject(ChatFontNormal)
		local font = pp.countFontPath
		if ValidFont(font) then
			local flags = GetFontFlags(pp.countFontFlags)
			ct:SetFont(font, pp.countFontSize, flags)
		elseif ValidFont(pp.countFont) then
			pp.countFontPath = MOD.LSM:Fetch("font", pp.countFont)
		end
		local c = pp.countColor
		if c then ct:SetTextColor(c.r, c.g, c.b, c.a) end
		ct:SetShadowColor(0, 0, 0, pp.countShadow and 1 or 0)
		ct:SetText(count)
		local pos = pp.countPosition
		local pt = pos.point
		ct:SetJustifyV(justifyV[pt]); ct:SetJustifyH(justifyH[pt]) -- anchor point adjusts alignment too
		local frame = button
		if pp.showBar and (pos.anchor == "bar") then frame = button.bar end
		PSetPoint(ct, pt, frame, pos.relativePoint, pos.offsetX, pos.offsetY)
		ct:Show()
	else
		ct:Hide()
	end
end

-- Configure the button's count text for given value
local function SkinLabel(button, name)
	local lt = button.labelText

	if pp.showLabel and name and name ~= "" then -- check if valid parameters
		lt:ClearAllPoints()
		lt:SetFontObject(ChatFontNormal)
		local font = pp.labelFontPath
		if ValidFont(font) then
			local flags = GetFontFlags(pp.labelFontFlags)
			lt:SetFont(font, pp.labelFontSize, flags)
		elseif ValidFont(pp.labelFont) then
			pp.labelFontPath = MOD.LSM:Fetch("font", pp.labelFont)
		end

		local c = pp.labelColor
		if c then lt:SetTextColor(c.r, c.g, c.b, c.a) end
		lt:SetShadowColor(0, 0, 0, pp.labelShadow and 1 or 0)
		lt:SetText(name)
		if pp.labelMaxWidth > 0 then PSetWidth(lt, pp.labelMaxWidth) end
		lt:SetWordWrap(pp.labelWrap)
		lt:SetNonSpaceWrap(pp.labelWordWrap)

		local pos = pp.labelPosition
		local pt = pos.point
		lt:SetJustifyV(justifyV[pt]); lt:SetJustifyH(justifyH[pt]) -- anchor point adjusts alignment too
		local frame = button
		if pp.showBar and (pos.anchor == "bar") then frame = button.bar end
		PSetPoint(lt, pt, frame, pos.relativePoint, pos.offsetX, pos.offsetY)
		lt:Show()
	else
		lt:Hide()
	end
end

-- Clear the button's bar
local function StopBar(bb)
	if bb then
		bb:SetScript("OnUpdate", nil) -- stop updating the time text
		bb._duration = nil
		bb._expire = nil
		bb._limited = nil
		bb:Hide()
	end
end

-- Update the amount of fill for a button's bar, triggered OnUpdate so keep it quick
local function UpdateBar(bb)
	if bb and bb._duration and bb._expire then -- make sure valid call
		local duration = bb._duration
		local remaining = bb._expire - GetTime()
		local stopping = false

		if duration then
			if remaining > duration then remaining = duration end -- range check
			if duration > 0.1 then -- real timer bar
				if remaining < 0.05 then stopping = true end
			else -- unlimited bar, check if "full" or "empty"
				if bb._limited == "empty" then remaining = 0 else remaining = 100 end
			end
		end

		if not stopping then
			bb:SetValue(remaining)
		else
			StopBar(bb)
		end
	end
end

-- Configure the button's bar and its border
local function SkinBar(button, duration, expire, barColor, barBorderColor)
	local bb = button.bar
	local bbk = button.barBackdrop
	local opt = pp.barBorder -- option for type of border
	local iconSize = button.iconSize
	local remaining = (expire or 0) - GetTime()
	local showBorder = false -- set to true when showing border
	local delta, width = 0, 0

	if pp.showBar and ((pp.barUnlimited ~= "none") or (duration and (duration > 0.1) and (remaining > 0.05))) then
		bb:ClearAllPoints()
		bbk:ClearAllPoints()
		bbk:SetBackdrop(nil)
		bb._duration = duration or 0
		bb._expire = expire or 0
		bb._limited = pp.barUnlimited
		local pos = pp.barPosition
		PSetPoint(bb, pos.point, button, pos.relativePoint, pos.offsetX, pos.offsetY)
		local bw = (pp.barWidth > 0) and pp.barWidth or iconSize
		local bh = (pp.barHeight > 0) and pp.barHeight or iconSize

		bb:SetOrientation(pp.barOrientation and "HORIZONTAL" or "VERTICAL")
		bb:SetFillStyle(pp.barDirection and "STANDARD" or "REVERSE")

		local tex = pp.barTexture
		if tex == "None" then tex = nil end
		if tex then tex = MOD.LSM:Fetch("statusbar", tex) end
		if not tex then tex = "Interface\\AddOns\\Bufflehead\\Media\\WhiteBar" end
		bb:SetStatusBarTexture(tex)

		local drop = { -- backdrop initialization for bars, initialized to facilitate pixel borders
			bgFile = tex, edgeFile = "Interface\\BUTTONS\\WHITE8X8.blp",
			tile = false, edgeSize = 1, insets = { left = 0, right = 0, top = 0, bottom = 0 }
		}

		if (opt == "one") or (opt == "two") then -- skin single/double pixel border
			if (bw > 4) and (bh > 4) then -- check minimum dimensions for border
				if opt == "one" then delta = 2; width = 1 else delta = 4; width = 2 end
				drop.edgeSize = PS(width)
				showBorder = true
			end
		elseif (opt == "media") and (pp.barBorderMedia ~= "None") then -- use shared media border
			width = pp.barBorderOffset or 0
			delta = width * 2
			if (bw > delta) and (bh > delta) then -- check minimum dimensions for this border
				drop.edgeFile = MOD.LSM:Fetch("border", pp.barBorderMedia) or nil
				drop.edgeSize = PS(pp.barBorderWidth or 1)
				showBorder = true
			end
		end

		PSetPoint(bbk, "CENTER", bb, "CENTER") -- use backdrop to show the border
		PSetSize(bbk, bw, bh)
		SetInsets(drop, PS(width))
		bbk:SetBackdrop(drop)
		local c = pp.barBackgroundColor
		if pp.barUseForeground then c = barColor end
		bbk:SetBackdropColor(c.r, c.g, c.b, pp.barBackgroundOpacity or c.a)
		if showBorder then
			c = barBorderColor -- bar backdrop color
			bbk:SetBackdropBorderColor(c.r, c.g, c.b, c.a)
		else
			bbk:SetBackdropBorderColor(0, 0, 0, 0) -- invisible border
		end
		bbk:Show()

		PSetSize(bb, bw - delta, bh - delta) -- set bar size based on border adjustments

		c = barColor
		bb:SetStatusBarColor(c.r, c.g, c.b, pp.barForegroundOpacity or 1)
		if (pp.barUnlimited ~= "none") and (duration == 0) then duration = 100 end -- ensure shows unlimited bars
		bb:SetMinMaxValues(0, duration)
		UpdateBar(bb)
		bb:Show()
		bb:SetScript("OnUpdate", UpdateBar) -- start updating bar fill
	else
		StopBar(bb)
		bb:Hide()
	end
end

-- Show a button and skin all its enabled elements
local function ShowButton(button, name, icon, duration, expire, count, btype, barColor, borderColor, barBorderColor)
	if ((duration ~= 0) and (expire ~= button._expire)) or (duration ~= button._duration) or (icon ~= button._icon) or
			(count ~= button._count) or (name ~=button._name) or (btype ~= button._btype) or MOD.uiOpen then

		-- MOD.Debug("att", name, duration, GetTime(), (expire ~= button._expire), (duration ~= button._duration), (icon ~= button._icon),
		--	(count ~= button._count), (name ~=button._name), (btype ~= button._btype), MOD.uiOpen)

		button._expire = expire; button._duration = duration; button._icon = icon
		button._count = count; button._name = name; button._btype = btype

		local tex = button.iconTexture
		tex:ClearAllPoints()
		PSetPoint(tex, "CENTER", icon, "CENTER")
		tex:SetTexture(icon)
		tex:Show()
		SkinBorder(button, borderColor)
		SkinClock(button, duration, expire) -- after highlight!
		SkinTime(button, duration, expire)
		SkinCount(button, count)
		SkinLabel(button, name)
		SkinBar(button, duration, expire, barColor, barBorderColor)
	end
end

-- Hide a button and all its elements
local function HideButton(button)
	button._expire = nil; button._duration = nil; button._icon = nil
	button._count = nil; button._name = nil; button._btype = nil

	button.iconTexture:Hide()
	button.iconHighlight:Hide()
	button.iconBorder:Hide()
	button.iconBackdrop:Hide()
	button.barBackdrop:Hide()
end

-- Function called when an attribute for a button changes
function MOD:Button_OnAttributeChanged(k, v)
	local button = self
	local header = button:GetParent()
	local unit = header:GetAttribute("unit")
	local filter = header:GetAttribute("filter")
	local show, hide = false, false
	local name, icon, count, btype, duration, expire
	local enchant, remaining, id, offEnchant, offRemaining, offCount, offId
	local borderColor = (pp.iconBorder == "default") and transparent or pp.iconBuffColor
	local barColor = pp.barBuffColor
	local barBorderColor = pp.barBorderBuffColor

	local iconSize = pp.iconSize
	if (filter == FILTER_DEBUFFS) and pp.debuffIconSize then iconSize = pp.debuffIconSize end
	button.iconSize = iconSize

	if k == "index" then -- update a buff or debuff
		name, icon, count, btype, duration, expire = SHIM:UnitAura(unit, v, filter)
		if name then
			show = true
			if filter == FILTER_DEBUFFS then
				borderColor = (pp.iconBorder == "default") and transparent or pp.iconDebuffColor
				barColor = pp.barDebuffColor
				barBorderColor = pp.barBorderDebuffColor
				btype = btype or "none"
				local c = GetDebuffTypeColor(btype)
				if c then
					if pp.debuffColoring then borderColor = c end
					if pp.barDebuffColoring then barColor = c end
					if pp.barBorderDebuffColoring then barBorderColor = c end
				end
			end
		else
			hide = true
		end
	elseif k == "target-slot" and ((v == 16) or (v == 17) or (v == 18)) then -- player mainhand, offhand or ranged weapon enchant
		enchant, remaining, count, id,
		offEnchant, offRemaining, offCount, offId,
		rangedEnchant, rangedRemaining, rangedCount, rangedId
			= GetWeaponEnchantInfo()

		if v == 17 then enchant = offEnchant; remaining = offRemaining; count = offCount; id = offId end
		if v == 18 then enchant = rangedEnchant; remaining = rangedRemaining; count = rangedCount; id = rangedId end

		if enchant then
			remaining = remaining / 1000 -- blizz function returned milliseconds
			expire = remaining + GetTime()
			expire = 0.01 * math.floor(expire * 100 + 0.5) -- round to nearest 1/100
			duration = WeaponDuration(id, remaining)
			icon = GetInventoryItemTexture("player", v)

			if MOD.isClassic then
				name = GetWeaponBuffNameClassic(v)
			else
				name = GetWeaponBuffName(v)
			end

			btype = "none"
			show = true
		else
			hide = true
		end
	end

	if show then -- show the button after skinning all its elements
		ShowButton(button, name, icon, duration, expire, count, btype, barColor, borderColor, barBorderColor)
	elseif hide then -- hide the button and all its elements
		HideButton(button)
	end
end

-- Calculate screen position based on current settings and adjust both header and backdrop
local function UpdatePosition(header)
	if not header then return end -- make sure valid header
	local backdrop = header.anchorBackdrop -- backdrop for this header
	if not backdrop then return end -- make sure valid backdrop
	local name = backdrop.headerName
	local group = pp.groups[name] -- use settings specific to this header
	local pt = header.anchorPoint -- relative point for positioning

	local x = group.anchorX * displayWidth  -- anchor location is based on UIParent using fractions of its size for offsets
	local y = group.anchorY * displayHeight
	header:ClearAllPoints()
	PSetPoint(header, pt, UIParent, "BOTTOMLEFT", x + (header.offsetX or 0), y + (header.offsetY or 0)) -- offset makes room for weapon enchants
	backdrop:ClearAllPoints()
	PSetPoint(backdrop, pt, UIParent, "BOTTOMLEFT", x + backdrop._deltaX, y + backdrop._deltaY)
end

-- While moving an anchor, keep the header moving in sync
local function UpdateBackdrop(backdrop)
	if backdrop._moving then
		local x, y = GetCursorPosition()
		local dx = (backdrop._lastX - x)
		local dy = (backdrop._lastY - y)
		if dx < 0 then dx = -dx end
		if dy < 0 then dy = -dy end
		if (dx >= 1) or (dy >= 1) then -- see if moved at least one pixel distance in either direction
			local header = MOD.headers[backdrop.headerName]
			local pt = header.anchorPoint -- relative point for positioning
			local name = backdrop.headerName
			local group = pp.groups[name] -- use settings specific to this header
			if pt == "TOPLEFT" then
				dx = backdrop:GetLeft()
				dy = backdrop:GetTop()
			elseif pt == "TOPRIGHT" then
				dx = backdrop:GetRight()
				dy = backdrop:GetTop()
			elseif pt == "BOTTOMRIGHT" then
				dx = backdrop:GetRight()
				dy = backdrop:GetBottom()
			else -- must be BOTTOMLEFT
				dx = backdrop:GetLeft()
				dy = backdrop:GetBottom()
			end
			group.anchorX = (dx - backdrop._deltaX) / displayWidth
			group.anchorY = (dy - backdrop._deltaY) / displayHeight
			backdrop._lastX = x
			backdrop._lastY = y
			-- MOD.Debug("moveto", backdrop.headerName, group.anchorX, group.anchorY, x, y, backdrop._deltaX, backdrop._deltaY)
			UpdatePosition(header)
			MOD.UpdateOptions() -- also update sliders in options panel, if it is open
		end
	end
end

-- Start moving the anchor when mouse down detected (only out-of-combat)
local function Backdrop_OnMouseDown(backdrop)
	if InCombatLockdown() then return end -- don't move anchors in combat!
	if not backdrop.moving then
		backdrop._moving = true
		local x, y = GetCursorPosition()
		backdrop._lastX = x
		backdrop._lastY = y
		backdrop:SetFrameStrata("HIGH")
		backdrop:StartMoving()
		backdrop:SetScript("OnUpdate", UpdateBackdrop) -- start updating for anchor movement
		-- MOD.Debug("start moving", backdrop.headerName, x, y)
	end
end

-- Stop moving the anchor when mouse up detected
local function Backdrop_OnMouseUp(backdrop)
	if backdrop._moving then
		backdrop:SetScript("OnUpdate", nil) -- stop updating the time text
		UpdateBackdrop(backdrop) -- check for possible final movement
		backdrop._moving = false
		backdrop:StopMovingOrSizing()
		backdrop:SetFrameStrata("LOW")
		backdrop._lastX = nil
		backdrop._lastY = nil
	end
end

-- Update secure header with optional attributes based on current profile settings
function MOD.UpdateHeader(header)
	local name = header:GetName()
	if name then
		local group = pp.groups[name] -- settings specific to this header

		if group then
			local red, green = 1, 0 -- anchor color
			local filter = header.filter
			local backdrop = header.anchorBackdrop
			local attrs = {} -- layout attributes, in the order they are applied
			local function SetAttribute(k, v) attrs[#attrs + 1] = k; attrs[k] = v end

			header:ClearAllPoints() -- set position any time called
			if group.enabled then
				local dirX = pp.directionX
				local dirY = pp.directionY

				local iconSize = pp.iconSize
				if (filter == FILTER_DEBUFFS) and pp.debuffIconSize then iconSize = pp.debuffIconSize end

				local s = BUFFS_TEMPLATE
				local i = tonumber(iconSize) -- use different template for each size, constrained by available templates
				if i and (i >= 10) and (i <= 64) then i = 2 * math.floor(i / 2); s = s .. tostring(i) end

				if filter == FILTER_BUFFS then
					red = 0; green = 1
					SetAttribute("consolidateTo", 0) -- no consolidation
					if pp.weaponEnchants then SetAttribute("weaponTemplate", s) end
				elseif filter == FILTER_DEBUFFS then
					if pp.mirrorX then dirX = -dirX end
					if pp.mirrorY then dirY = -dirY end
				end

				SetAttribute("template", s)
				SetAttribute("sortMethod", pp.sortMethod)
				SetAttribute("sortDirection", pp.sortDirection)
				SetAttribute("separateOwn", pp.separateOwn)
				SetAttribute("wrapAfter", pp.wrapAfter)
				SetAttribute("maxWraps", pp.maxWraps)

				local pt = "TOPRIGHT"
				if dirX > 0 then
					if dirY > 0 then pt = "BOTTOMLEFT" else pt = "TOPLEFT" end
				else
					if dirY > 0 then pt = "BOTTOMRIGHT" end
				end
				SetAttribute("point", pt) -- relative point on icons based on grow and wrap directions
				header.anchorPoint = pt

				if pp.showBar then -- adjust backdrop position when bars are outside bounding box
					local dx, dy = 0, 0 -- deltas are how far outside the bars are
					local bpos = pp.barPosition
					local bpt =  bpos.relativePoint -- where bars attach to icon
					local offsetX = bpos.offsetX
					local offsetY = bpos.offsetY

					if (string.find(bpt, "RIGHT") and string.find(pt, "RIGHT")) then dx = pp.barWidth + offsetX end
					if (string.find(bpt, "LEFT") and string.find(pt, "LEFT")) then dx = pp.barWidth - offsetX end
					if (string.find(bpt, "TOP") and string.find(pt, "TOP")) then dy = pp.barHeight + offsetY end
					if (string.find(bpt, "BOTTOM") and string.find(pt, "BOTTOM")) then dy = pp.barHeight - offsetY end

					backdrop._deltaX = dx
					backdrop._deltaY = dy
				else
					backdrop._deltaX = 0 -- no adjustment when bar is not shown
					backdrop._deltaY = 0
				end

				local wraps = pp.maxWraps -- limit anchor to include just enough rows and columns for 40 buttons
				if (pp.maxWraps * pp.wrapAfter) > 40 then wraps = math.ceil(40 / pp.wrapAfter) end
				local dx, dy, mw, mh, wx, wy = 0, 0, 0, 0, 0, 0
				if pp.orientation == 1 then -- grow horizontally
					dx = dirX * (pp.spaceX + iconSize)
					wy = dirY * (pp.spaceY + iconSize)
					-- mw = (PS(pp.spaceX + iconSize) * (pp.wrapAfter - 1)) + PS(iconSize)
					mw = PS(pp.spaceX + iconSize) * pp.wrapAfter
					mh = PS(pp.spaceY + iconSize) * wraps
				else -- otherwise grow vertically
					dy = dirY * (pp.spaceY + iconSize)
					wx = dirX * (pp.spaceX + iconSize)
					-- mw = (PS(pp.spaceX + iconSize) * (wraps - 1)) + PS(iconSize)
					mw = PS(pp.spaceX + iconSize) * wraps
					mh = PS(pp.spaceY + iconSize) * pp.wrapAfter
				end
				SetAttribute("xOffset", PS(dx))
				SetAttribute("yOffset", PS(dy))
				SetAttribute("wrapXOffset", PS(wx))
				SetAttribute("wrapYOffset", PS(wy))
				SetAttribute("minWidth", PS(mw))
				SetAttribute("minHeight", PS(mh))
				-- if IsAltKeyDown() then MOD.Debug("Bufflehead: dx/dy", dx, dy, "wx/wy", wx, wy, "mw/mh", mw, mh) end

				header.layoutAttrs = attrs
				UpdatePosition(header) -- update screen position based on current settings

				if header.isContainer then
					MOD.UpdateContainer(header, attrs, iconSize)
				else
					for _, k in ipairs(attrs) do header:SetAttribute(k, attrs[k]) end
					PSetSize(header, 100, 100)
					header:Show()

					local k = 1
					local button = select(1, header:GetChildren())
					while button do
						button:SetSize(iconSize, iconSize)
						button.iconSize = iconSize
						if k > (pp.wrapAfter * pp.maxWraps) and button:IsShown() then button:Hide() end
						k = k + 1
						button = select(k, header:GetChildren())
					end
				end

				PSetSize(backdrop, mw, mh)
				backdrop:SetBackdrop(twoPixelBackdrop)
				backdrop:SetBackdropColor(0, 0, 0, 0) -- transparent background
				backdrop:SetBackdropBorderColor(red, green, 0, 0.5) -- buffs have green border and debuffs have red border

				if MOD.showAnchors then
					backdrop:SetScript("OnMouseDown", Backdrop_OnMouseDown)
					backdrop:SetScript("OnMouseUp", Backdrop_OnMouseUp)
					backdrop.headerName = name
					backdrop:EnableMouse(true)
					backdrop:Show()
				else
					backdrop:SetScript("OnMouseDown", nil)
					backdrop:SetScript("OnMouseUp", nil)
					backdrop:EnableMouse(false)
					backdrop:Hide()
				end
			else
				header:Hide()
			end
		end
	end
end

-- Scan through all the buff locations and show/hide previews as needed
local function UpdatePreviews()
	local now = GetTime()
	if not MOD.showPreviews then MOD.frame:SetScript("OnUpdate", nil) end

	for k, header in pairs(MOD.headers) do
		local attrs = header.layoutAttrs or {}
		local pt = attrs.point -- relative point on icons based on grow and wrap directions
		local dx = attrs.xOffset
		local dy = attrs.yOffset
		local wx = attrs.wrapXOffset
		local wy = attrs.wrapYOffset
		local filter = header.filter
		local columns, rows = pp.wrapAfter, pp.maxWraps
		local num = rows * columns -- number of icons needed for previewing
		if num > 40 then num = 40 end -- respect the limit on player buffs/debuffs
		local previewButtons = MOD.previews[k]

		local iconSize = pp.iconSize
		if (filter == FILTER_DEBUFFS) and pp.debuffIconSize then iconSize = pp.debuffIconSize end

		for i = 1, #previewButtons do -- check if any icon displayed in each location and show/hide previews
			local button = previewButtons[i]
			local hide = true
			local column = (i - 1) % columns -- which column the button is in, numbered from 0
			local row = math.floor((i - 1) / columns) -- which row the button is in, numbered from 0

			if MOD.showPreviews and i <= num then
				-- an aura container hides itself while previewing
				local real = not header.isContainer and header:GetAttribute("child" .. i)

				if not real or not real:IsShown() then -- check if real button is currently shown
					local anchor, ax, ay = header, 0, 0
					if header.isContainer then -- frames can't be anchored to an aura container
						anchor = header.anchorBackdrop; ax = -anchor._deltaX; ay = -anchor._deltaY
					end
					button:ClearAllPoints()
					PSetPoint(button, pt, anchor, pt, (dx * column) + (wx * row) + ax, (dy * column) + (wy * row) + ay)
					button:SetSize(iconSize, iconSize)
					button.iconSize = iconSize
					-- if IsAltKeyDown() then MOD.Debug("Preview: x/y", math.floor((dx * column) + (wx * row)), math.floor((dy * column) + (wy * row)), i, column, row,
					--	math.floor(dx), math.floor(dy), math.floor(wx), math.floor(wy)) end


					local duration = i * 5
					local expire = button._refresh
					if not expire or (expire < now) then expire = now + duration end
					button._refresh = expire

					local name = "#" .. i
					local icon = PRESET_BUFF_ICON
					local btype = "none"
					local count = ((i - 1) % 5) + 1
					local borderColor = (pp.iconBorder == "default") and transparent or pp.iconBuffColor
					local barColor = pp.barBuffColor
					local barBorderColor = pp.barBorderBuffColor

					if filter == FILTER_DEBUFFS then
						icon = PRESET_DEBUFF_ICON
						borderColor = (pp.iconBorder == "default") and transparent or pp.iconDebuffColor
						barColor = pp.barDebuffColor
						barBorderColor = pp.barBorderDebuffColor
						local btype = debuffTypes[count]
						if btype ~= "none" then
							local c = GetDebuffTypeColor(btype)
							if c then
								if pp.debuffColoring then borderColor = c end
								if pp.barDebuffColoring then barColor = c end
								if pp.barBorderDebuffColoring then barBorderColor = c end
							end
						end
					end
					ShowButton(button, name, GetFileIDFromPath(icon), duration, expire, count, btype, barColor, borderColor, barBorderColor)
					button:Show()
					hide = false
				end
			end
			if hide and button:IsShown() then button:Hide(); HideButton(button) end
		end
	end
end

-- Toggle preview mode and allocate preview buttons as needed
function MOD.CheckPreviews()
	if MOD.showPreviews then
		local num = pp.maxWraps * pp.wrapAfter -- number of icons needed for previewing
		if num > 40 then num = 40 end -- respect the limit on player buffs/debuffs
		for k, header in pairs(MOD.headers) do
			if not MOD.previews[k] then MOD.previews[k] = {} end -- allocate preview buttons on demand
			local previewButtons = MOD.previews[k]
			local currentIcons = #previewButtons -- current number of preview icons
			for i = currentIcons + 1, num do
				local button = CreateFrame("Button", "BuffleheadPreviewButton" .. i, UIParent, BackdropTemplateMixin and "BackdropTemplate")
				MOD:Button_OnLoad(button)
				previewButtons[i] = button
			end
		end
		MOD.frame:SetScript("OnUpdate", UpdatePreviews)
	end
end

-- Convert a time value into a compact text string using a selected display format
MOD.TimeFormatOptions = {
	{ 1, 1, 1, 1, 1 }, { 1, 1, 1, 3, 5 }, { 1, 1, 1, 3, 4 }, { 2, 3, 1, 2, 3 }, -- 4
	{ 2, 3, 1, 2, 2 }, { 2, 3, 1, 3, 4 }, { 2, 3, 1, 3, 5 }, { 2, 2, 2, 2, 3 }, -- 8
	{ 2, 2, 2, 2, 2 }, { 2, 2, 2, 2, 4 }, { 2, 2, 2, 3, 4 }, { 2, 2, 2, 3, 5 }, -- 12
	{ 2, 3, 2, 2, 3 }, { 2, 3, 2, 2, 2 }, { 2, 3, 2, 2, 4 }, { 2, 3, 2, 3, 4 }, -- 16
	{ 2, 3, 2, 3, 5 }, { 2, 3, 3, 2, 3 }, { 2, 3, 3, 2, 2 }, { 2, 3, 3, 2, 4 }, -- 20
	{ 2, 3, 3, 3, 4 }, { 2, 3, 3, 3, 5 }, { 3, 3, 3, 2, 3 }, { 3, 3, 3, 3, 5 }, -- 24
	{ 4, 3, 1, 2, 3 }, { 4, 3, 1, 2, 2 }, { 4, 3, 1, 3, 4 }, { 4, 3, 1, 3, 5 }, -- 28
	{ 5, 1, 1, 2, 3 }, { 5, 1, 1, 2, 2 }, { 5, 1, 1, 3, 4 }, { 5, 1, 1, 3, 5 }, -- 32
	{ 3, 3, 3, 2, 2 }, { 3, 3, 3, 3, 4 }, -- 34
}

function MOD.FormatTime(t, timeFormat, timeSpaces, timeCase)
	if not timeFormat or (timeFormat > #MOD.TimeFormatOptions) then timeFormat = 24 end -- default to most compact
	timeFormat = math.floor(timeFormat)
	if timeFormat < 1 then timeFormat = 1 end
	local opt = MOD.TimeFormatOptions[timeFormat]
	local d, h, m, hplus, mplus, s, ts, f
	local o1, o2, o3, o4, o5 = opt[1], opt[2], opt[3], opt[4], opt[5]
	if t >= 86400 then -- special case for more than one day which applies regardless of selected format
		d = math.floor(t / 86400); h = math.floor((t - (d * 86400)) / 3600)
		if (d >= 2) then f = string.format("%.0fd", d) else f = string.format("%.0fd %.0fh", d, h) end
	else
		h = math.floor(t / 3600); m = math.floor((t - (h * 3600)) / 60); s = math.floor(t - (h * 3600) - (m * 60))
		hplus = math.floor((t + 3599.99) / 3600); mplus = math.floor((t - (h * 3600) + 59.99) / 60) -- provides compatibility with tooltips
		ts = math.floor(t * 10) / 10 -- truncated to a tenth second
		if t >= 3600 then
			if o1 == 1 then f = string.format("%.0f:%02.0f:%02.0f", h, m, s) elseif o1 == 2 then f = string.format("%.0fh %.0fm", h, m)
			elseif o1 == 3 then f = string.format("%.0fh", hplus) elseif o1 == 4 then f = string.format("%.0fh %.0f", h, m)
			else f = string.format("%.0f:%02.0f", h, m) end
		elseif t >= 120 then
			if o2 == 1 then f = string.format("%.0f:%02.0f", m, s) elseif o2 == 2 then f = string.format("%.0fm %.0fs", m, s)
			else f = string.format("%.0fm", mplus) end
		elseif t >= 60 then
			if o3 == 1 then f = string.format("%.0f:%02.0f", m, s) elseif o3 == 2 then f = string.format("%.0fm %.0fs", m, s)
			else f = string.format("%.0fm", mplus) end
		elseif t >= 10 then
			if o4 == 1 then f = string.format(":%02.0f", s) elseif o4 == 2 then f = string.format("%.0fs", s)
			else f = string.format("%.0f", s) end
		else
			if o5 == 1 then f = string.format(":%02.0f", s) elseif o5 == 2 then f = string.format("%.1fs", ts)
			elseif o5 == 3 then f = string.format("%.0fs", s) elseif o5 == 4 then f = string.format("%.1f", ts)
			else f = string.format("%.0f", s) end
		end
	end
	if not timeSpaces then f = string.gsub(f, " ", "") end
	if timeCase then f = string.upper(f) end
	return f
end

-- Defer a complete redraw until combat ends
function MOD.DeferUpdate() updateAll = true end

-- Shared with Container.lua
MOD.util = {
	PS = PS, PSetWidth = PSetWidth, PSetSize = PSetSize, PSetPoint = PSetPoint, SetInsets = SetInsets,
	SkinBorder = SkinBorder, ValidFont = ValidFont, GetFontFlags = GetFontFlags,
	SetPixelBorder = SetPixelBorder, SetPixelBorderColors = SetPixelBorderColors, pixelBorderEdges = pixelBorderEdges,
	ShowButton = ShowButton, HideButton = HideButton, UpdatePosition = UpdatePosition,
	GetWeaponBuffName = GetWeaponBuffName, WeaponDuration = WeaponDuration,
	justifyH = justifyH, justifyV = justifyV, transparent = transparent,
}
