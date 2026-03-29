-- We: Faction tab integration
-- Hooks the Faction button in ISUserPanelUI to open a tabbed window that
-- contains both the standard Faction panel and our Characters roster.

local PANEL_W  = 520
local VIEW_H   = 450
local TAB_H    = getTextManager():getFontHeight(UIFont.Small) + 6
local PANEL_H  = TAB_H + VIEW_H

local PADDING  = 10
local ROW_H    = 58
local BTN_W    = 80
local BTN_H    = 28

-- ─── WeRosterPanel ────────────────────────────────────────────────────────────
-- The "Characters" tab content, migrated from We_Panel.lua.

WeRosterPanel = ISPanel:derive("WeRosterPanel")

function WeRosterPanel:new(x, y, w, h)
    local o = ISPanel.new(self, x, y, w, h)
    o.backgroundColor = {r=0.08, g=0.08, b=0.12, a=0.94}
    o.rows = {}
    return o
end

function WeRosterPanel:initialise()
    ISPanel.initialise(self)

    -- Base status bar
    self.baseStatusLabel = ISLabel:new(PADDING, 6, 14, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.baseStatusLabel)

    local rowOffset = 26

    for i = 1, We.MAX_SLOTS do
        local rowY = rowOffset + (i - 1) * ROW_H
        local row  = {}

        -- Name (click to rename)
        local nameLabel = ISLabel:new(PADDING, rowY + 4, 20, "Slot " .. i, 1, 1, 1, 1, UIFont.Small, true)
        nameLabel.slotIndex   = i
        nameLabel.onmousedown = function(lbl) self:onNameClick(lbl.slotIndex) end
        self:addChild(nameLabel)
        row.nameLabel = nameLabel

        -- Profession (gold)
        local profLabel = ISLabel:new(PADDING + 4, rowY + 18, 13, "", 0.9, 0.8, 0.3, 1, UIFont.Small, true)
        self:addChild(profLabel)
        row.profLabel = profLabel

        -- Status
        local statusLabel = ISLabel:new(PADDING, rowY + 30, 13, "", 0.6, 0.8, 0.6, 1, UIFont.Small, true)
        self:addChild(statusLabel)
        row.statusLabel = statusLabel

        -- Home coords
        local homeLabel = ISLabel:new(PADDING, rowY + 44, 12, "", 0.5, 0.6, 0.9, 1, UIFont.Small, true)
        self:addChild(homeLabel)
        row.homeLabel = homeLabel

        -- Switch button
        local switchBtn = ISButton:new(self.width - BTN_W - PADDING, rowY + (ROW_H - BTN_H) / 2,
            BTN_W, BTN_H, getText("UI_We_Switch"), self, WeRosterPanel.onSwitchClick)
        switchBtn.slotIndex               = i
        switchBtn.backgroundColor          = {r=0.12, g=0.30, b=0.55, a=1}
        switchBtn.backgroundColorMouseOver = {r=0.18, g=0.45, b=0.80, a=1}
        self:addChild(switchBtn)
        row.switchBtn = switchBtn

        self.rows[i] = row
    end

    self:refreshRows()
end

function WeRosterPanel:refreshRows()
    local active         = WeData.getActiveSlot()
    local atBase, reason = WeData.isAtHomeBase()

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

        row.nameLabel.name = slot.name
        if i == active then
            row.nameLabel.r, row.nameLabel.g, row.nameLabel.b = 0.3, 0.9, 0.4
        else
            row.nameLabel.r, row.nameLabel.g, row.nameLabel.b = 1, 1, 1
        end

        if slot.creation and slot.creation.profession then
            local prof = ProfessionFactory.getProfession(slot.creation.profession)
            row.profLabel.name = prof and prof:getName() or slot.creation.profession
        else
            row.profLabel.name = (slot.x ~= nil) and "" or getText("UI_We_NeverUsed")
        end

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

        if slot.homeX ~= nil then
            row.homeLabel.name = getText("UI_We_HomeAt",
                math.floor(slot.homeX), math.floor(slot.homeY))
        else
            row.homeLabel.name = getText("UI_We_NoHome")
        end

        row.switchBtn:setEnable(i ~= active and atBase)
    end
end

function WeRosterPanel:render()
    ISPanel.render(self)
    local active  = WeData.getActiveSlot()
    local rowY    = 26 + (active - 1) * ROW_H
    self:drawRect(0, rowY - 2, self.width, ROW_H, 0.12, 0.25, 0.70, 0.28)
end

function WeRosterPanel:onSwitchClick(button)
    WeData.switchTo(button.slotIndex)
    self:refreshRows()
end

function WeRosterPanel:onNameClick(slotIndex)
    if self.renameBox then
        self:removeChild(self.renameBox)
        self.renameBox = nil
    end
    local rowY = 26 + (slotIndex - 1) * ROW_H
    local slot  = WeData.getSlot(slotIndex)
    local box   = ISTextEntryBox:new(slot.name, PADDING, rowY + 2, 180, 22)
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

-- ─── Hook ─────────────────────────────────────────────────────────────────────

local WeTabPanel = nil  -- singleton

local function openWeTabPanel(userPanel)
    -- Close any existing instances
    if ISFactionUI.instance then
        ISFactionUI.instance:close()
    end
    if ISCreateFactionUI and ISCreateFactionUI.instance then
        ISCreateFactionUI.instance:close()
    end

    -- Toggle: close our panel if already open
    if WeTabPanel and WeTabPanel:isVisible() then
        WeTabPanel:setVisible(false)
        return
    end

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local px = math.floor(sw / 2 - PANEL_W / 2)
    local py = math.floor(sh / 2 - PANEL_H / 2)

    WeTabPanel = ISTabPanel:new(px, py, PANEL_W, PANEL_H)
    WeTabPanel.moveWithMouse = true
    WeTabPanel.allowDraggingTabs = false
    WeTabPanel:initialise()
    WeTabPanel:addToUIManager()

    -- ── Faction tab ──────────────────────────────────────────────────────────
    local factionView
    local player = userPanel.player

    if Faction.isAlreadyInFaction(player) then
        factionView = ISFactionUI:new(0, 0, PANEL_W, VIEW_H,
            Faction.getPlayerFaction(player), player)
        -- Override close so it hides the tab instead of calling removeFromUIManager
        factionView.close = function(self)
            self:setVisible(false)
        end
        ISFactionUI.instance = factionView
    else
        factionView = ISCreateFactionUI:new(0, 0, PANEL_W, VIEW_H, player)
        factionView.close = function(self)
            self:setVisible(false)
        end
        if ISCreateFactionUI then
            ISCreateFactionUI.instance = factionView
        end
    end
    factionView:initialise()
    WeTabPanel:addView(getText("UI_We_Tab_Faction"), factionView)

    -- ── Characters tab ───────────────────────────────────────────────────────
    local rosterView = WeRosterPanel:new(0, 0, PANEL_W, VIEW_H)
    rosterView:initialise()
    WeTabPanel:addView(getText("UI_We_Tab_Characters"), rosterView)

    -- Start on Characters tab
    WeTabPanel:activateView(getText("UI_We_Tab_Characters"))
end

-- Monkey-patch ISUserPanelUI
local origOnOptionMouseDown = ISUserPanelUI.onOptionMouseDown

function ISUserPanelUI:onOptionMouseDown(button, x, y)
    if button.internal == "FACTIONPANEL" then
        openWeTabPanel(self)
        return
    end
    origOnOptionMouseDown(self, button, x, y)
end
