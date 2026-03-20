-- We: Character selection panel (client-side UI)

WePanel = ISPanel:derive("WePanel")

local PANEL_W    = 320
local ROW_H      = 52
local PADDING    = 12
local BTN_W      = 80
local BTN_H      = 28

-- ─── Singleton ───────────────────────────────────────────────────────────────

local _instance = nil

function WePanel.toggle()
    if not _instance then
        local sw = getCore():getScreenWidth()
        local sh = getCore():getScreenHeight()
        local ph = PADDING * 2 + ROW_H * We.MAX_SLOTS
        _instance = WePanel:new((sw - PANEL_W) / 2, (sh - ph) / 2)
        _instance:initialise()
        _instance:addToUIManager()
    end
    _instance:setVisible(not _instance:isVisible())
    if _instance:isVisible() then
        _instance:refreshRows()
        _instance:bringToTop()
    end
end

-- ─── Constructor ─────────────────────────────────────────────────────────────

function WePanel:new(x, y)
    local ph = PADDING * 2 + ROW_H * We.MAX_SLOTS + 32  -- +32 for title bar
    local o  = ISPanel.new(self, x, y, PANEL_W, ph)
    o.backgroundColor = { r = 0.1, g = 0.1, b = 0.1, a = 0.92 }
    o.borderColor     = { r = 0.4, g = 0.6, b = 0.9, a = 1 }
    o.moveWithMouse   = true
    o.rows            = {}
    return o
end

-- ─── Initialise ──────────────────────────────────────────────────────────────

function WePanel:initialise()
    ISPanel.initialise(self)

    -- Title
    local title = ISLabel:new(PADDING, 8, 24, "We — Characters", 1, 1, 1, 1, UIFont.Medium, true)
    self:addChild(title)

    -- Close button
    local closeBtn = ISButton:new(self.width - 28, 6, 22, 22, "x", self, WePanel.onClose)
    closeBtn.backgroundColor      = { r = 0.6, g = 0.1, b = 0.1, a = 1 }
    closeBtn.backgroundColorMouseOver = { r = 0.9, g = 0.2, b = 0.2, a = 1 }
    self:addChild(closeBtn)

    -- Slot rows
    for i = 1, We.MAX_SLOTS do
        local rowY = 36 + PADDING + (i - 1) * ROW_H
        local row  = {}

        -- Name label (click to rename)
        local nameLabel = ISLabel:new(PADDING, rowY + 6, 20, "Slot " .. i, 1, 1, 1, 1, UIFont.Small, true)
        nameLabel.slotIndex = i
        nameLabel.onmousedown = function(lbl) self:onNameClick(lbl.slotIndex) end
        self:addChild(nameLabel)
        row.nameLabel = nameLabel

        -- Status label (stats preview)
        local statusLabel = ISLabel:new(PADDING, rowY + 22, 14, "", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
        self:addChild(statusLabel)
        row.statusLabel = statusLabel

        -- Switch button
        local switchBtn = ISButton:new(PANEL_W - BTN_W - PADDING, rowY + (ROW_H - BTN_H) / 2, BTN_W, BTN_H,
            getText("UI_We_Switch"), self, WePanel.onSwitchClick)
        switchBtn.slotIndex = i
        switchBtn.backgroundColor = { r = 0.15, g = 0.35, b = 0.6, a = 1 }
        switchBtn.backgroundColorMouseOver = { r = 0.2, g = 0.5, b = 0.85, a = 1 }
        self:addChild(switchBtn)
        row.switchBtn = switchBtn

        self.rows[i] = row
    end

    self:refreshRows()
end

-- ─── Refresh ─────────────────────────────────────────────────────────────────

function WePanel:refreshRows()
    local active = WeData.getActiveSlot()
    for i = 1, We.MAX_SLOTS do
        local row  = self.rows[i]
        local slot = WeData.getSlot(i)

        row.nameLabel.name = slot.name
        if i == active then
            row.nameLabel.r, row.nameLabel.g, row.nameLabel.b = 0.3, 0.9, 0.4
        else
            row.nameLabel.r, row.nameLabel.g, row.nameLabel.b = 1, 1, 1
        end

        if slot.x ~= nil then
            local s = slot.stats
            row.statusLabel.name = string.format(
                "HP:%.0f%%  Hunger:%.0f%%  Thirst:%.0f%%",
                (1 - (s.Pain or 0)) * 100,
                (s.Hunger or 0) * 100,
                (s.Thirst or 0) * 100
            )
        else
            row.statusLabel.name = getText("UI_We_NeverUsed")
        end

        row.switchBtn:setEnable(i ~= active)
    end
end

-- ─── Render ──────────────────────────────────────────────────────────────────

function WePanel:render()
    ISPanel.render(self)
    local active = WeData.getActiveSlot()
    local rowY   = 36 + PADDING + (active - 1) * ROW_H
    self:drawRect(0, rowY - 2, self.width, ROW_H, 0.12, 0.3, 0.8, 0.3)
end

-- ─── Button callbacks ────────────────────────────────────────────────────────

function WePanel:onClose()
    self:setVisible(false)
end

function WePanel:onSwitchClick(button)
    WeData.switchTo(button.slotIndex)
    self:refreshRows()
    self:setVisible(false)
end

function WePanel:onNameClick(slotIndex)
    local slot = WeData.getSlot(slotIndex)
    local row  = self.rows[slotIndex]

    -- Simple rename via ISTextEntryBox overlaid on the name label
    if self.renameBox then
        self:removeChild(self.renameBox)
        self.renameBox = nil
    end

    local rowY = 36 + PADDING + (slotIndex - 1) * ROW_H
    local box  = ISTextEntryBox:new(slot.name, PADDING, rowY + 2, 180, 22)
    box.slotIndex = slotIndex
    box.onpresskey = function(tb, key)
        if key == Keyboard.KEY_RETURN then
            local newName = tb:getText()
            if newName and newName ~= "" then
                WeData.renameSlot(tb.slotIndex, newName)
            end
            self:removeChild(tb)
            self.renameBox = nil
            self:refreshRows()
        elseif key == Keyboard.KEY_ESCAPE then
            self:removeChild(tb)
            self.renameBox = nil
        end
    end
    box:initialise()
    box:instantiate()
    self:addChild(box)
    self.renameBox = box
    box:focus()
end
