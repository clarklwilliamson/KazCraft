local addonName, ns = ...

-- VP flat style constants
ns.COLORS = {
    backdrop     = { 18/255, 18/255, 18/255, 0.94 },
    border       = { 90/255, 80/255, 65/255, 1 },
    panelBg      = { 12/255, 12/255, 12/255, 0.5 },
    panelBorder  = { 70/255, 65/255, 55/255, 1 },
    footerBg     = { 10/255, 10/255, 10/255, 0.6 },
    tabInactive  = { 160/255, 150/255, 130/255 },
    tabHover     = { 220/255, 200/255, 160/255 },
    tabActive    = { 255/255, 235/255, 180/255 },
    accent       = { 200/255, 170/255, 100/255, 1 },
    rowDivider   = { 70/255, 65/255, 55/255, 0.5 },
    rowHover     = { 255/255, 220/255, 150/255, 0.08 },
    rowSelected  = { 200/255, 170/255, 100/255, 0.12 },
    headerText   = { 130/255, 125/255, 115/255 },
    brightText   = { 220/255, 215/255, 200/255 },
    mutedText    = { 180/255, 180/255, 180/255 },
    greenText    = { 0.3, 0.9, 0.3 },
    redText      = { 0.9, 0.3, 0.3 },
    goldText     = { 1, 0.82, 0 },
    searchBg     = { 10/255, 10/255, 10/255, 0.6 },
    searchBorder = { 70/255, 65/255, 55/255, 1 },
    searchFocus  = { 120/255, 105/255, 80/255, 1 },
    scrollThumb  = { 80/255, 75/255, 65/255, 1 },
    scrollTrack  = { 30/255, 30/255, 30/255, 0.5 },
    btnDefault   = { 150/255, 140/255, 120/255 },
    btnHover     = { 220/255, 200/255, 160/255 },
    closeDefault = { 140/255, 130/255, 115/255 },
    closeHover   = { 220/255, 100/255, 100/255 },
}

ns.FONT = "Fonts\\FRIZQT__.TTF"
ns.ROW_HEIGHT = 26
ns.ICON_SIZE = 20

local BACKDROP_FLAT = {
    bgFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeSize = 1,
}

local BACKDROP_EDGE = {
    edgeFile = "Interface\\BUTTONS\\WHITE8X8",
    edgeSize = 1,
}

function ns.CreateFlatFrame(name, w, h, parent)
    local f = CreateFrame("Frame", name, parent or UIParent, "BackdropTemplate")
    f:SetSize(w, h)
    f:SetBackdrop(BACKDROP_FLAT)
    f:SetBackdropColor(unpack(ns.COLORS.backdrop))
    f:SetBackdropBorderColor(unpack(ns.COLORS.border))
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self.SavePosition then self:SavePosition() end
    end)
    return f
end

function ns.CreateRow(parent, index, height)
    height = height or ns.ROW_HEIGHT
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * height)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * height)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0)

    row.leftAccent = row:CreateTexture(nil, "ARTWORK", nil, 2)
    row.leftAccent:SetSize(2, height)
    row.leftAccent:SetPoint("LEFT")
    row.leftAccent:SetColorTexture(unpack(ns.COLORS.accent))
    row.leftAccent:Hide()

    row.divider = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", 4, 0)
    row.divider:SetPoint("BOTTOMRIGHT", -4, 0)
    row.divider:SetColorTexture(unpack(ns.COLORS.rowDivider))

    row._defaultBgAlpha = (index % 2 == 0) and 0.03 or 0
    row.bg:SetColorTexture(1, 1, 1, row._defaultBgAlpha)

    row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(unpack(ns.COLORS.rowHover))
        self.leftAccent:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(1, 1, 1, self._defaultBgAlpha)
        self.leftAccent:Hide()
    end)

    return row
end

function ns.CreateTabBar(parent, tabs, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(28)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local accentBar = bar:CreateTexture(nil, "ARTWORK")
    accentBar:SetHeight(2)
    accentBar:SetColorTexture(unpack(ns.COLORS.accent))
    bar.accentBar = accentBar

    bar.buttons = {}
    bar.activeKey = nil

    for i, info in ipairs(tabs) do
        local btn = CreateFrame("Button", nil, bar)
        btn:SetHeight(28)
        btn.label = btn:CreateFontString(nil, "OVERLAY")
        btn.label:SetFont(ns.FONT, 12, "")
        btn.label:SetPoint("CENTER")
        btn.label:SetText(info.label)
        btn.label:SetTextColor(unpack(ns.COLORS.tabInactive))
        btn:SetWidth(btn.label:GetStringWidth() + 16)
        btn.key = info.key

        if i == 1 then
            btn:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 8, 0)
        else
            btn:SetPoint("BOTTOMLEFT", bar.buttons[i - 1], "BOTTOMRIGHT", 16, 0)
        end

        btn:SetScript("OnClick", function()
            bar:Select(info.key)
            if onSelect then onSelect(info.key) end
        end)
        btn:SetScript("OnEnter", function(self)
            if bar.activeKey ~= self.key then
                self.label:SetTextColor(unpack(ns.COLORS.tabHover))
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if bar.activeKey ~= self.key then
                self.label:SetTextColor(unpack(ns.COLORS.tabInactive))
            end
        end)

        bar.buttons[i] = btn
    end

    function bar:Select(key)
        bar.activeKey = key
        for _, btn in ipairs(bar.buttons) do
            if btn.key == key then
                btn.label:SetTextColor(unpack(ns.COLORS.tabActive))
                accentBar:ClearAllPoints()
                accentBar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
                accentBar:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
                accentBar:Show()
            else
                btn.label:SetTextColor(unpack(ns.COLORS.tabInactive))
            end
        end
    end

    if #tabs > 0 then
        bar:Select(tabs[1].key)
    end

    return bar
end

function ns.CreateButton(parent, text, w, h)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w or 80, h or 22)
    btn:SetBackdrop(BACKDROP_FLAT)
    btn:SetBackdropColor(30/255, 30/255, 30/255, 0.8)
    btn:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))

    btn.label = btn:CreateFontString(nil, "OVERLAY")
    btn.label:SetFont(ns.FONT, 11, "")
    btn.label:SetPoint("CENTER")
    btn.label:SetText(text)
    btn.label:SetTextColor(unpack(ns.COLORS.btnDefault))

    btn:SetScript("OnEnter", function(self)
        self.label:SetTextColor(unpack(ns.COLORS.btnHover))
        self:SetBackdropBorderColor(unpack(ns.COLORS.accent))
    end)
    btn:SetScript("OnLeave", function(self)
        self.label:SetTextColor(unpack(ns.COLORS.btnDefault))
        self:SetBackdropBorderColor(unpack(ns.COLORS.panelBorder))
    end)

    return btn
end

function ns.CreateCloseButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 20)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    btn.label = btn:CreateFontString(nil, "OVERLAY")
    btn.label:SetFont(ns.FONT, 14, "")
    btn.label:SetPoint("CENTER")
    btn.label:SetText("x")
    btn.label:SetTextColor(unpack(ns.COLORS.closeDefault))

    btn:SetScript("OnEnter", function(self)
        self.label:SetTextColor(unpack(ns.COLORS.closeHover))
    end)
    btn:SetScript("OnLeave", function(self)
        self.label:SetTextColor(unpack(ns.COLORS.closeDefault))
    end)
    btn:SetScript("OnClick", function()
        parent:Hide()
    end)

    return btn
end

function ns.FormatGold(copper)
    if not copper or copper == 0 then return "—" end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    if gold > 0 then
        return string.format("%s|cffffd700g|r %02d|cffc7c7cfs|r", BreakUpLargeNumbers(gold), silver)
    elseif silver > 0 then
        return string.format("%d|cffc7c7cfs|r %02d|cffeda55fc|r", silver, copper % 100)
    else
        return string.format("%d|cffeda55fc|r", copper % 100)
    end
end

function ns.CreateScrollFrame(parent, topOffset, bottomOffset)
    topOffset = topOffset or 0
    bottomOffset = bottomOffset or 0

    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -topOffset)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -20, bottomOffset)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth())
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)

    -- Style the scrollbar
    local scrollBar = scrollFrame.ScrollBar
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 2, -16)
        scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 2, 16)
    end

    scrollFrame.content = content
    return scrollFrame
end

function ns.FadeFrame(frame, targetAlpha, duration)
    if not frame then return end
    duration = duration or 0.2
    if targetAlpha > 0 then frame:Show() end
    local startAlpha = frame:GetAlpha()
    if math.abs(startAlpha - targetAlpha) < 0.01 then
        frame:SetAlpha(targetAlpha)
        if targetAlpha == 0 then frame:Hide() end
        return
    end
    local startTime = GetTime()
    if frame._fadeTicker then frame._fadeTicker:Cancel() end
    frame._fadeTicker = C_Timer.NewTicker(0.016, function(ticker)
        local elapsed = GetTime() - startTime
        local pct = math.min(1, elapsed / duration)
        frame:SetAlpha(startAlpha + (targetAlpha - startAlpha) * pct)
        if pct >= 1 then
            ticker:Cancel()
            frame._fadeTicker = nil
            if targetAlpha == 0 then frame:Hide() end
        end
    end)
end

--------------------------------------------------------------------
-- Crafting quality helpers
--------------------------------------------------------------------
function ns.GetCraftingQuality(itemID)
    if not itemID then return nil end
    if C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo then
        return C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemID)
    end
    return nil
end

function ns.GetQualityAtlas(tier)
    if not tier or tier < 1 or tier > 5 then return nil end
    return "Professions-Icon-Quality-Tier" .. tier .. "-Small"
end
