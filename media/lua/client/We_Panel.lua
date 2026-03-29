-- We: Character selection panel (client-side UI)

WePanel = ISPanel:derive("WePanel")

local PANEL_W = 340
local ROW_H   = 58
local PADDING = 12
local BTN_W   = 80
local BTN_H   = 28

-- ─── Singleton ────────────────────────────────────────────────────────────────

local _instance = nil

function WePanel.toggle()
    if not _instance then
        local sw = getCore():getScreenWidth()
        local sh = getCore():getScreenHeight()
        local ph = PADDING * 2 + ROW_H * We.MAX_SLOTS + 36 + 22  -- +22 for base status bar
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

-- ─── Constructor ──────────────────────────────────────────────────────────────

function WePanel:new(x, y)
    local ph = PADDING * 2 + ROW_H * We.MAX_SLOTS + 36 + 22
    local o  = ISPanel.new(self, x, y, PANEL_W, ph)
    o.backgroundColor = {r=0.08, g=0.08, b=0.12, a=0.94}
    o.borderColor     = {r=0.35, g=0.55, b=0.85, a=1}
    o.moveWithMouse   = true
    o.rows            = {}
    return o
end

-- ─── Initialise ───────────────────────────────────────────────────────────────

function WePanel:initialise()
    ISPanel.initialise(self)

    local title = ISLabel:new(PADDING, 8, 24, "We — Characters", 1, 1, 1, 1, UIFont.Medium, true)
    self:addChild(title)

    local closeBtn = ISButton:new(self.width - 28, 6, 22, 22, "x", self, WePanel.onClose)
    closeBtn.backgroundColor          = {r=0.6, g=0.1, b=0.1, a=1}
    closeBtn.backgroundColorMouseOver = {r=0.9, g=0.2, b=0.2, a=1}
    self:addChild(closeBtn)

    -- Base status bar (shows whether switching is currently available)
    self.baseStatusLabel = ISLabel:new(PADDING, 28, 14, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.baseStatusLabel)

    local rowOffset = 58   -- title (36) + status bar (22)

    for i = 1, We.MAX_SLOTS do
        local rowY = rowOffset + PADDING + (i - 1) * ROW_H
        local row  = {}

        local nameLabel = ISLabel:new(PADDING, rowY + 4, 20, "Slot " .. i, 1, 1, 1, 1, UIFont.Small, true)
        nameLabel.slotIndex   = i
        nameLabel.onmousedown = function(lbl) self:onNameClick(lbl.slotIndex) end
        self:addChild(nameLabel)
        row.nameLabel = nameLabel

        local statusLabel = ISLabel:new(PADDING, rowY + 22, 14, "", 0.6, 0.8, 0.6, 1, UIFont.Small, true)
        self:addChild(statusLabel)
        row.statusLabel = statusLabel

        local homeLabel = ISLabel:new(PADDING, rowY + 36, 12, "", 0.5, 0.6, 0.9, 1, UIFont.Small, true)
        self:addChild(homeLabel)
        row.homeLabel = homeLabel

        local switchBtn = ISButton:new(PANEL_W - BTN_W - PADDING, rowY + (ROW_H - BTN_H) / 2,
            BTN_W, BTN_H, getText("UI_We_Switch"), self, WePanel.onSwitchClick)
        switchBtn.slotIndex               = i
        switchBtn.backgroundColor          = {r=0.12, g=0.30, b=0.55, a=1}
        switchBtn.backgroundColorMouseOver = {r=0.18, g=0.45, b=0.80, a=1}
        self:addChild(switchBtn)
        row.switchBtn = switchBtn

        self.rows[i] = row
    end

    self:refreshRows()
end

-- ─── Refresh ──────────────────────────────────────────────────────────────────

function WePanel:refreshRows()
    local active         = WeData.getActiveSlot()
    local atBase, reason = WeData.isAtHomeBase()

    -- Base status bar
    if atBase then
        self.baseStatusLabel.name = getText("UI_We_Status_AtBase")
        self.baseStatusLabel.r, self.baseStatusLabel.g, self.baseStatusLabel.b = 0.3, 0.9, 0.4
    elseif reason == "noHome" then
        self.baseStatusLabel.name = getText("UI_We_Status_NoHome")
        self.baseStatusLabel.r, self.baseStatusLabel.g, self.baseStatusLabel.b = 0.9, 0.7, 0.2
    else
        self.baseStatusLabel.name = getText("UI_We_Status_TooFar")
        self.baseStatusLabel.r, self.baseStatusLabel.g, self.baseStatusLabel.b = 0.9, 0.3, 0.3
    end

    for i = 1, We.MAX_SLOTS do
        local row  = self.rows[i]
        local slot = WeData.getSlot(i)

        -- Name colour: green = active
        row.nameLabel.name = slot.name
        if i == active then
            row.nameLabel.r, row.nameLabel.g, row.nameLabel.b = 0.3, 0.9, 0.4
        else
            row.nameLabel.r, row.nameLabel.g, row.nameLabel.b = 1, 1, 1
        end

        -- Status line
        if i == active then
            local s = slot.stats
            if slot.x ~= nil then
                row.statusLabel.name = string.format(
                    "Hunger:%.0f%%  Thirst:%.0f%%  Fatigue:%.0f%%",
                    (s.Hunger or 0) * 100,
                    (s.Thirst or 0) * 100,
                    (s.Fatigue or 0) * 100
                )
            else
                row.statusLabel.name = getText("UI_We_NeverUsed")
            end
            row.statusLabel.r, row.statusLabel.g, row.statusLabel.b = 0.6, 0.8, 0.6
        else
            if slot.x == nil then
                row.statusLabel.name = getText("UI_We_NeverUsed")
                row.statusLabel.r, row.statusLabel.g, row.statusLabel.b = 0.5, 0.5, 0.5
            elseif slot.npcId then
                row.statusLabel.name = getText("UI_We_NPC_AtHome")
                row.statusLabel.r, row.statusLabel.g, row.statusLabel.b = 0.4, 0.7, 1.0
            else
                row.statusLabel.name = getText("UI_We_NPC_Unspawned")
                row.statusLabel.r, row.statusLabel.g, row.statusLabel.b = 0.8, 0.5, 0.2
            end
        end

        -- Home position info
        if slot.homeX ~= nil then
            row.homeLabel.name = getText("UI_We_HomeAt",
                math.floor(slot.homeX), math.floor(slot.homeY))
        else
            row.homeLabel.name = getText("UI_We_NoHome")
        end

        -- Switch button: active when not this slot AND player is at their base
        row.switchBtn:setEnable(i ~= active and atBase)
    end
end

-- ─── Render ───────────────────────────────────────────────────────────────────

function WePanel:render()
    ISPanel.render(self)
    local active    = WeData.getActiveSlot()
    local rowOffset = 58
    local rowY      = rowOffset + PADDING + (active - 1) * ROW_H
    self:drawRect(0, rowY - 2, self.width, ROW_H, 0.12, 0.25, 0.70, 0.28)
end

-- ─── Callbacks ────────────────────────────────────────────────────────────────

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

    if self.renameBox then
        self:removeChild(self.renameBox)
        self.renameBox = nil
    end

    local rowOffset = 58
    local rowY = rowOffset + PADDING + (slotIndex - 1) * ROW_H
    local box  = ISTextEntryBox:new(slot.name, PADDING, rowY + 2, 180, 22)
    box.slotIndex  = slotIndex
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
