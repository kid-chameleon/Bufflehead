-- Container.lua draws player buffs and debuffs with Blizzard's AuraContainer.
--
-- Clients that enforce secret values no longer load SecureAuraHeaderTemplate
-- and refuse to let addons read aura data in combat.
--
-- The aura container is the engine-driven replacement.

local MOD = Bufflehead
if not MOD.useContainer then return end

local FILTER_BUFFS = "HELPFUL"
local FILTER_DEBUFFS = "HARMFUL"
local GROUP_KEY = "auras" -- each container has one aura group, unless the player's own auras are shown separately
local OTHERS_KEY = "others" -- then this second group is added for auras cast by others
local MAX_BUTTONS = 40
local CANCEL_BUTTONS = "RightButtonUp"
local TIME_WIDEST = "0:00:00"

local util = MOD.util
local PS, PSetWidth, PSetSize, PSetPoint, SetInsets = util.PS, util.PSetWidth, util.PSetSize, util.PSetPoint, util.SetInsets
local SkinBorder, ValidFont, GetFontFlags = util.SkinBorder, util.ValidFont, util.GetFontFlags
local justifyH, justifyV, transparent = util.justifyH, util.justifyV, util.transparent
local ShowButton, HideButton, UpdatePosition = util.ShowButton, util.HideButton, util.UpdatePosition
local GetWeaponBuffName, WeaponDuration = util.GetWeaponBuffName, util.WeaponDuration
local SetPixelBorder, SetPixelBorderColors, pixelBorderEdges = util.SetPixelBorder, util.SetPixelBorderColors, util.pixelBorderEdges

local durationTextOptions = nil -- cached options for time text, rebuilt when settings change
local measureText = nil
local pp -- current profile

-- Build the engine-side equivalent of MOD.FormatTime for the selected time format
local function CreateTimeFormatter()
	local timeFormat = pp.timeFormat
	if not timeFormat or (timeFormat > #MOD.TimeFormatOptions) then timeFormat = 24 end
	timeFormat = math.floor(timeFormat)
	if timeFormat < 1 then timeFormat = 1 end
	local o1, o2, o3, o4, o5 = unpack(MOD.TimeFormatOptions[timeFormat])
	local down, up = Enum.NumericRuleFormatRounding.Down, Enum.NumericRuleFormatRounding.Up
	local sp = pp.timeSpaces and " " or ""
	 -- only units change case
	local function U(unit) return pp.timeCase and string.upper(unit) or unit end

	local hours = { div = 3600, step = 1, rounding = down }
	local minutes = { div = 60, mod = 60, step = 1, rounding = down }
	local minutesAll = { div = 60, step = 1, rounding = down }
	local seconds = { mod = 60, step = 1, rounding = down }
	local days = { div = 86400, step = 1, rounding = down }
	local dayHours = { div = 3600, mod = 24, step = 1, rounding = down }

	local function Hours()
		if o1 == 1 then return "%d:%02d:%02d", { hours, minutes, seconds } end
		if o1 == 2 then return "%d" .. U("h") .. sp .. "%d" .. U("m"), { hours, minutes } end
		if o1 == 3 then return "%d" .. U("h"), { hours }, 3600, up end
		if o1 == 4 then return "%d" .. U("h") .. sp .. "%d", { hours, minutes } end
		return "%d:%02d", { hours, minutes }
	end

	local function Minutes(o)
		if o == 1 then return "%d:%02d", { minutesAll, seconds } end
		if o == 2 then return "%d" .. U("m") .. sp .. "%d" .. U("s"), { minutesAll, seconds } end
		return "%d" .. U("m"), { minutesAll }, 60, up
	end

	local breakpoints = {}
	local function Add(threshold, format, components, step, rounding)
		breakpoints[#breakpoints + 1] = { threshold = threshold, format = format, components = components,
										  step = step or 1, rounding = rounding or down }
	end

	if o5 == 1 then Add(0, ":%02d") elseif o5 == 2 then Add(0, "%.1f" .. U("s"), nil, 0.1) elseif o5 == 3 then Add(0, "%d" .. U("s"))
	elseif o5 == 4 then Add(0, "%.1f", nil, 0.1) else Add(0, "%d") end
	if o4 == 1 then Add(10, ":%02d") elseif o4 == 2 then Add(10, "%d" .. U("s")) else Add(10, "%d") end
	Add(60, Minutes(o3))
	Add(120, Minutes(o2))
	Add(3600, Hours())
	Add(86400, "%d" .. U("d") .. sp .. "%d" .. U("h"), { days, dayHours })
	Add(172800, "%d" .. U("d"), { days })

	local formatter = C_StringUtil.CreateNumericRuleFormatter()
	formatter:SetBreakpoints(breakpoints)
	return formatter
end

-- Time text switches to the expire color for the last five seconds
local function CreateTimeColorCurve()
	local c, e = pp.timeColor, pp.expireColor
	local curve = C_CurveUtil.CreateColorCurve()
	curve:SetType(Enum.LuaCurveType.Step) -- without this the color blends instead of switching
	curve:AddPoint(0, CreateColor(e.r, e.g, e.b, e.a))
	curve:AddPoint(5, CreateColor(c.r, c.g, c.b, c.a))
	return curve
end

-- Return the options for a button's time text
local function GetDurationTextOptions()
	if not durationTextOptions then
		durationTextOptions = {
			textFormatter = CreateTimeFormatter(),
			textColor = { curve = CreateTimeColorCurve(), property = Enum.DurationTextBindingProperty.RemainingDuration },
		}
	end
	return durationTextOptions
end

-- Set font, color, and shadow for one of the button's texts.
local function SkinText(fs, prefix)
	fs:SetFontObject(ChatFontNormal)
	if not ValidFont(pp[prefix .. "FontPath"]) and ValidFont(pp[prefix .. "Font"]) then
		pp[prefix .. "FontPath"] = MOD.LSM:Fetch("font", pp[prefix .. "Font"])
	end
	local font = pp[prefix .. "FontPath"]
	if ValidFont(font) then fs:SetFont(font, pp[prefix .. "FontSize"], GetFontFlags(pp[prefix .. "FontFlags"])) end
	local c = pp[prefix .. "Color"]
	if c then fs:SetTextColor(c.r, c.g, c.b, c.a) end
	fs:SetShadowColor(0, 0, 0, pp[prefix .. "Shadow"] and 1 or 0)
end

-- Position one of the button's texts relative to either the icon or the bar
local function PositionText(button, fs, pos)
	local pt = pos.point
	fs:ClearAllPoints()
	fs:SetJustifyV(justifyV[pt]); fs:SetJustifyH(justifyH[pt]) -- anchor point adjusts alignment too
	local frame = button
	if pp.showBar and (pos.anchor == "bar") then frame = button.bar end
	PSetPoint(fs, pt, frame, pos.relativePoint, pos.offsetX, pos.offsetY)
end

-- Return the width of a string using the same font as a button's text
local function MeasureText(fs, text)
	if not measureText then measureText = MOD.frame:CreateFontString(nil, "OVERLAY") end
	measureText:SetFontObject(ChatFontNormal)
	local font, size, flags = fs:GetFont()
	if font then measureText:SetFont(font, size, flags) end
	measureText:SetText(text)
	return measureText:GetStringWidth()
end

-- Ask the engine to color textures by debuff type
local function AddDebuffTypeTextures(button, textures)
	local options = {
		style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
		showWhenHarmful = true, showWithoutDispelType = true,
	}
	for _, tex in pairs(textures) do button:AddDispelTypeTexture(tex, options) end
end

-- Return the textures used to draw a frame's pixel border
local function GetPixelBorderTextures(frame, textures)
	if frame.pixelBorder then
		for _, k in ipairs(pixelBorderEdges) do textures[#textures + 1] = frame.pixelBorder[k] end
	end
	return textures
end

-- Configure the button's bar and its border
local function SkinContainerBar(button, isDebuff)
	local bb = button.bar
	local bbk = button.barBackdrop
	local opt = pp.barBorder
	local iconSize = button.iconSize
	local barColor = isDebuff and pp.barDebuffColor or pp.barBuffColor
	local barBorderColor = isDebuff and pp.barBorderDebuffColor or pp.barBorderBuffColor
	local showBorder = false
	local delta, width = 0, 0

	button:ClearDurationBar()
	if not pp.showBar then bb:Hide(); return end

	bb:ClearAllPoints()
	bbk:ClearAllPoints()
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

	local media = nil -- shared media border, the only kind that needs a backdrop
	if (opt == "one") or (opt == "two") then -- skin single/double pixel border
		if (bw > 4) and (bh > 4) then
			if opt == "one" then delta = 2; width = 1 else delta = 4; width = 2 end
			showBorder = true
		end
	elseif (opt == "media") and (pp.barBorderMedia ~= "None") then -- use shared media border
		width = pp.barBorderOffset or 0
		delta = width * 2
		if (bw > delta) and (bh > delta) then -- check minimum dimensions for this border
			media = MOD.LSM:Fetch("border", pp.barBorderMedia) or nil
			showBorder = (media ~= nil)
		end
	end

	PSetPoint(bbk, "CENTER", bb, "CENTER")
	PSetSize(bbk, bw, bh)
	local c = pp.barBackgroundColor
	if pp.barUseForeground then c = barColor end

	-- Draw pixel borders with a texture to avoid reading the size of the frame, which ends up being secret.
	local key = media and (media .. "|" .. tostring(pp.barBorderWidth) .. "|" .. tostring(width) .. "|" .. tex) or nil
	if key ~= bbk.backdropKey then
		bbk.backdropKey = key
		if media then
			local drop = { bgFile = tex, edgeFile = media, tile = false, edgeSize = PS(pp.barBorderWidth or 1),
						   insets = { left = 0, right = 0, top = 0, bottom = 0 } }
			SetInsets(drop, PS(width))
			pcall(bbk.SetBackdrop, bbk, drop)
		else
			bbk:SetBackdrop(nil)
		end
	end

	if media then
		SetPixelBorder(bbk, nil)
		bbk:SetBackdropColor(c.r, c.g, c.b, pp.barBackgroundOpacity or c.a)
		bbk:SetBackdropBorderColor(barBorderColor.r, barBorderColor.g, barBorderColor.b, barBorderColor.a)
	else
		SetPixelBorder(bbk, showBorder and PS(width) or 0, tex)
		SetPixelBorderColors(bbk, showBorder and barBorderColor or nil, c, pp.barBackgroundOpacity)
	end
	bbk:Show()

	PSetSize(bb, bw - delta, bh - delta) -- set bar size based on border adjustments
	bb:SetStatusBarColor(barColor.r, barColor.g, barColor.b, pp.barForegroundOpacity or 1)
	bb:Show()
	button:SetDurationBar(bb, { direction = Enum.StatusBarTimerDirection.RemainingTime })

	if isDebuff then
		local textures = {}
		if pp.barDebuffColoring then textures[1] = bb:GetStatusBarTexture() end
		if showBorder and pp.barBorderDebuffColoring and not media then GetPixelBorderTextures(bbk, textures) end
		AddDebuffTypeTextures(button, textures)
	end
end

-- Apply all appearance settings to a button and tell the engine which of its elements to drive
-- Only valid while the button is being created or when auras are not secret (i.e., out of combat)
local function SkinContainerButton(button)
	pp = MOD.db.profile
	local isDebuff = (button.filter == FILTER_DEBUFFS)
	local iconSize = pp.iconSize
	if isDebuff and pp.debuffIconSize then iconSize = pp.debuffIconSize end
	button.iconSize = iconSize
	button:SetSize(iconSize, iconSize)

	local tex = button.iconTexture
	tex:ClearAllPoints()
	PSetPoint(tex, "CENTER", button, "CENTER")
	tex:Show()

	local borderColor = isDebuff and pp.iconDebuffColor or pp.iconBuffColor
	if pp.iconBorder == "default" then borderColor = transparent end
	button:ClearDispelTypeTextures()
	xpcall(SkinBorder, geterrorhandler(), button, borderColor)
	if isDebuff and pp.debuffColoring then
		local opt = pp.iconBorder
		if (opt == "one") or (opt == "two") then
			AddDebuffTypeTextures(button, GetPixelBorderTextures(button.iconBackdrop, {}))
		elseif (opt == "raven") or (opt == "default") or ((opt == "masque") and MOD.MSQ) then
			AddDebuffTypeTextures(button, { button.iconBorder })
		end
	end

	local bc = button.clock
	if pp.showClock then
		local size = button.iconTextureSize or iconSize
		local c = pp.clockColor
		bc:SetDrawEdge(pp.clockEdge)
		bc:SetReverse(pp.clockReverse)
		bc:SetSwipeColor(c.r, c.g, c.b, c.a or 1)
		PSetSize(bc, size, size)
		bc:Show()
		button:SetDurationCooldown(bc)
	else
		button:ClearDurationCooldown()
		bc:Hide()
	end

	SkinContainerBar(button, isDebuff) -- before texts since they can be positioned relative to the bar

	local bt = button.timeText
	if pp.showTime then
		SkinText(bt, "time")
		PSetWidth(bt, MeasureText(bt, TIME_WIDEST)) -- helps with jitter
		PositionText(button, bt, pp.timePosition)
		bt:Show()
		button:SetDurationText(bt, GetDurationTextOptions())
	else
		button:ClearDurationText()
		bt:Hide()
	end

	local ct = button.countText
	if pp.showCount then
		SkinText(ct, "count")
		PositionText(button, ct, pp.countPosition)
		ct:Show()
		button:SetApplicationCount(ct) -- only shows counts greater than one
	else
		button:ClearApplicationCount()
		ct:Hide()
	end

	local lt = button.labelText
	if pp.showLabel then
		SkinText(lt, "label")
		if pp.labelMaxWidth > 0 then PSetWidth(lt, pp.labelMaxWidth) end
		lt:SetWordWrap(pp.labelWrap)
		lt:SetNonSpaceWrap(pp.labelWordWrap)
		PositionText(button, lt, pp.labelPosition)
		lt:Show()
		button:SetSpellName(lt)
	else
		button:ClearSpellName()
		lt:Hide()
	end
end

-- Return the longest a line of icons can be, in pixels rather than icons
-- Also leaves room for weapon enchants at the start of the line
local function GetMaximumLineSize(container, iconSize)
	local spacing = (pp.orientation == 1) and pp.spaceX or pp.spaceY
	local count = math.max(1, pp.wrapAfter - (container.enchantCount or 0))
	return (count * iconSize) + ((count - 1) * spacing) + 1
end

local weaponSlots = { { name = "MainHand", slot = 16 }, { name = "OffHand", slot = 17 }, { name = "Ranged", slot = 18 } }
local activeEnchants = {}

local function EnchantButton_OnEnter(button)
	GameTooltip:SetOwner(button, "ANCHOR_BOTTOM", 0, 0)
	GameTooltip:SetInventoryItem("player", button.inventorySlot)
end

-- Show weapon enchants in the first icon positions of the buffs container
local function UpdateWeaponEnchants(container)
	if container.filter ~= FILTER_BUFFS then return end
	pp = MOD.db.profile
	local attrs = container.layoutAttrs
	local buttons = container.enchantButtons
	local n = 0

	if pp.weaponEnchants and attrs and not MOD.showPreviews and C_Item.GetWeaponEnchantInfo and Enum.WeaponSlot then
		for _, weapon in ipairs(weaponSlots) do
			local ok, enchants = pcall(C_Item.GetWeaponEnchantInfo, Enum.WeaponSlot[weapon.name])
			if ok and enchants then
				for _, enchant in ipairs(enchants) do
					if enchant.hasEnchant then
						n = n + 1
						activeEnchants[n] = enchant
						enchant.inventorySlot = weapon.slot
					end
				end
			end
		end
	end

	local iconSize = pp.iconSize
	local borderColor = (pp.iconBorder == "default") and transparent or pp.iconBuffColor
	for i = 1, n do
		local enchant = activeEnchants[i]
		local button = buttons[i]
		if not button then
			button = CreateFrame("Button", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate")
			button:SetFrameLevel(container:GetFrameLevel() + 4) -- same level as the container's buttons
			MOD:Button_OnLoad(button)
			button:SetScript("OnEnter", EnchantButton_OnEnter)
			button:SetScript("OnLeave", GameTooltip_Hide)
			buttons[i] = button
		end

		local slot = enchant.inventorySlot
		local remaining = (enchant.timeLeft or 0) / 1000 -- blizz function returned milliseconds
		local duration, expire = 0, 0
		if remaining > 0 then
			expire = remaining + GetTime()
			-- scans don't agree to the millisecond, keep the previous value unless the enchant was changed or refreshed
			if (button.enchantID == enchant.enchantID) and button._expire and (math.abs(button._expire - expire) < 1) then expire = button._expire end
			duration = WeaponDuration(enchant.enchantID, remaining)
		end
		local icon = enchant.enchantIconID
		if not icon or (icon == 0) then icon = GetInventoryItemTexture("player", slot) end
		local count = enchant.charges
		if count == 0 then count = nil end

		button.inventorySlot = slot
		button.enchantID = enchant.enchantID
		button.iconSize = iconSize
		button:SetSize(iconSize, iconSize)
		-- frames can't be anchored to a container, so use the group's anchor which is in the same place
		-- except for an adjustment when bars extend outside the bounding box
		local anchor = container.anchorBackdrop
		button:ClearAllPoints()
		PSetPoint(button, attrs.point, anchor, attrs.point, ((i - 1) * attrs.xOffset) - anchor._deltaX, ((i - 1) * attrs.yOffset) - anchor._deltaY)
		ShowButton(button, GetWeaponBuffName(slot) or "", icon, duration, expire, count, "none", pp.barBuffColor, borderColor, pp.barBorderBuffColor)
		button:Show()
	end

	for i = n + 1, #buttons do
		local button = buttons[i]
		if button:IsShown() then button:Hide(); HideButton(button); button.enchantID = nil end
	end

	local offsetX, offsetY = 0, 0
	if attrs then offsetX = n * attrs.xOffset; offsetY = n * attrs.yOffset end
	if (n ~= container.enchantCount) or (offsetX ~= container.offsetX) or (offsetY ~= container.offsetY) then
		container.enchantCount = n -- make room, none of this is restricted in combat
		container.offsetX = offsetX
		container.offsetY = offsetY
		UpdatePosition(container)
		container:SetFlowLayoutMaximumLineSize(GetMaximumLineSize(container, iconSize))
	end
end

local enchantEvents = CreateFrame("Frame")
enchantEvents:RegisterEvent("WEAPON_ENCHANT_CHANGED")
enchantEvents:RegisterEvent("WEAPON_SLOT_CHANGED")
enchantEvents:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
enchantEvents:SetScript("OnEvent", function()
	for _, header in pairs(MOD.headers) do
		if header.isContainer then UpdateWeaponEnchants(header) end
	end
end)

-- Create an aura container for a group of player buffs or debuffs
function MOD.CreateContainer(name, unit, filter)
	local container = CreateFrame("AuraContainer", name, UIParent, "CustomAuraContainerTemplate")
	container.isContainer = true
	container.buttons = {}
	container.enchantButtons = {}
	container.enchantCount = 0
	container:SetUnit(unit)

	container.groupOptions = {
		maxFrameCount = MAX_BUTTONS,
		initializeFrame = function(button) -- called when the engine needs more buttons, possibly in combat
			button.filter = filter
			button.noBackdrops = true
			MOD:Button_OnLoad(button)
			button:SetIcon(button.iconTexture)
			if filter == FILTER_BUFFS then button:SetCancelAuraButtons(CANCEL_BUTTONS) end
			button:SetTooltipAnchorPoint("ANCHOR_BOTTOM", 0, 0)
			SkinContainerButton(button)
			table.insert(container.buttons, button)
		end,
	}
	container:AddAuraGroup(GROUP_KEY, filter, container.groupOptions)
	return container
end

local sortMethods = { INDEX = "AuraInstanceIDOnly", NAME = "NameOnly", TIME = "ExpirationOnly" }

-- Update layout and appearance of a container based on current profile settings
-- Layout values are calculated by MOD.UpdateHeader, which is shared with secure headers
function MOD.UpdateContainer(container, attrs, iconSize)
	pp = MOD.db.profile
	durationTextOptions = nil

	local pt = attrs.point -- corner that the first icon is placed in
	local horizontal = (pp.orientation == 1)
	local spacing, lineSpacing = pp.spaceX, pp.spaceY
	if not horizontal then spacing, lineSpacing = pp.spaceY, pp.spaceX end

	container:SetFlowLayoutAxis(horizontal and AnchorUtil.FlowLayoutAxis.Horizontal or AnchorUtil.FlowLayoutAxis.Vertical)
	container:SetFlowLayoutAnchorPoint(pt)
	container:SetFlowLayoutGrowthDirection(
		string.find(pt, "LEFT") and AnchorUtil.FlowDirection.Right or AnchorUtil.FlowDirection.Left,
		string.find(pt, "BOTTOM") and AnchorUtil.FlowDirection.Up or AnchorUtil.FlowDirection.Down)
	container:SetFlowLayoutMaximumLineSize(GetMaximumLineSize(container, iconSize))

	-- Showing the player's own auras separately takes two groups, one for each caster, laid out one after the other
	local separate = (pp.separateOwn ~= 0)
	local hasOthers = container:HasAuraGroup(OTHERS_KEY)
	if separate and not hasOthers then
		container:AddAuraGroup(OTHERS_KEY, container.filter, container.groupOptions)
		hasOthers = true
	end

	local maxButtons = math.min(MAX_BUTTONS, pp.wrapAfter * pp.maxWraps)
	local sortMethod = AuraContainerSortMethod[sortMethods[pp.sortMethod] or "ExpirationOnly"]
	local sortDirection = (pp.sortDirection == "-") and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal
	local layout = { elementSpacing = spacing, lineSpacing = lineSpacing, groupSpacing = spacing, groupLineSpacing = lineSpacing,
					 elementWidth = iconSize, elementHeight = iconSize }

	-- "Cast by me" is the PLAYER component of the filter string, negated with "!" for everyone else's auras
	local function UpdateGroup(key, filterString, layoutIndex)
		layout.layoutIndex = layoutIndex
		container:SetAuraGroupFilterString(key, filterString)
		container:SetAuraGroupLayout(key, layout)
		container:SetAuraGroupMaxFrameCount(key, maxButtons)
		container:SetAuraGroupSortMethod(key, sortMethod, sortDirection)
	end

	if separate then
		UpdateGroup(GROUP_KEY, container.filter .. "|PLAYER", (pp.separateOwn == 1) and 1 or 2)
		UpdateGroup(OTHERS_KEY, container.filter .. "|!PLAYER", (pp.separateOwn == 1) and 2 or 1)
	else
		UpdateGroup(GROUP_KEY, container.filter, 1)
	end
	if hasOthers then container:SetAuraGroupEnabled(OTHERS_KEY, separate) end

	if C_Secrets.ShouldAurasBeSecret() then
		MOD.DeferUpdate()
	else
		for _, button in ipairs(container.buttons) do SkinContainerButton(button) end
	end

	container:SetShown(not MOD.showPreviews)
	UpdateWeaponEnchants(container)
end
