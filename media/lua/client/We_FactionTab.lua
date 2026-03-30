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
local STATUS_H = 26    -- fixed status bar at top
local REMOVE_H = BTN_H + 16  -- reserved height at bottom for remove button

-- ─── WeRosterPanel ────────────────────────────────────────────────────────────
-- Shows only used character slots + one empty "Create" row, up to MAX_SLOTS.
-- When the list is taller than the visible area a scrollbar appears.

WeRosterPanel = ISPanel:derive("WeRosterPanel")

function WeRosterPanel:new(x, y, w, h)
    local o = ISPanel.new(self, x, y, w, h)
    o.backgroundColor = {r=0.08, g=0.08, b=0.12, a=0.94}
    return o
end

-- Returns [{slotIndex, isAddRow}] — used slots + one empty slot (unless full)
function WeRosterPanel:getVisibleSlots()
    local data   = WeData.getData()
    local result = {}
    local usedCount = 0
    for i = 1, We.MAX_SLOTS do
        local slot = data.slots[i]
        if slot and slot.x ~= nil then
            usedCount = usedCount + 1
            table.insert(result, {slotIndex = i, isAddRow = false})
        end
    end
    if usedCount < We.MAX_SLOTS then
        table.insert(result, {slotIndex = usedCount + 1, isAddRow = true})
    end
    return result
end

function WeRosterPanel:initialise()
    ISPanel.initialise(self)

    -- Fixed status label at top
    self.baseStatusLabel = ISLabel:new(PADDING, 6, 14, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.baseStatusLabel)

    -- Scrollable slot list
    local listH = self.height - STATUS_H - REMOVE_H
    self.slotList = ISScrollingListBox:new(0, STATUS_H, self.width, listH)
    self.slotList.font        = UIFont.Small
    self.slotList.itemheight  = ROW_H
    self.slotList.drawBorder  = false
    self.slotList.backgroundColor = {r=0, g=0, b=0, a=0}
    self.slotList.rosterPanel = self

    -- ── Custom row renderer ──────────────────────────────────────────────────
    function self.slotList:doDrawItem(y, item, alt)
        local d      = item.item
        local atBase = WeData.isAtHomeBase()

        if d.isAddRow then
            -- "Create new character" row
            self:drawText(
                We.getText("UI_We_EmptySlot"),
                PADDING, y + 20,
                0.50, 0.50, 0.60, 1, UIFont.Small)

            local btnX  = self.width - BTN_W - PADDING - 12
            local btnY2 = y + (ROW_H - BTN_H) / 2
            local a     = atBase and 1 or 0.30
            self:drawRect(btnX, btnY2, BTN_W, BTN_H, a, 0.10, 0.40, 0.18)
            local label = We.getText("UI_We_CreateChar")
            local lw    = getTextManager():MeasureStringX(UIFont.Small, label)
            self:drawText(label, btnX + (BTN_W - lw) / 2, btnY2 + 7, 1, 1, 1, a, UIFont.Small)
        else
            local slotIndex = d.slotIndex
            local slot      = WeData.getSlot(slotIndex)
            local active    = WeData.getActiveSlot()

            -- Active-row highlight
            if slotIndex == active then
                self:drawRect(0, y, self.width, ROW_H, 0.12, 0.25, 0.70, 0.28)
            end

            -- Separator line
            self:drawRect(PADDING, y + ROW_H - 1,
                self.width - PADDING * 2 - 12, 1, 0.3, 0.3, 0.35, 0.5)

            -- Name (green = active, white = inactive)
            local nr = slotIndex == active and 0.3 or 1
            local ng = slotIndex == active and 0.9 or 1
            local nb = slotIndex == active and 0.4 or 1
            self:drawText(slot.name, PADDING, y + 4, nr, ng, nb, 1, UIFont.Small)

            -- Profession label
            if slot.creation and slot.creation.profName then
                self:drawText(slot.creation.profName,
                    PADDING + 4, y + 18, 0.9, 0.8, 0.3, 1, UIFont.Small)
            end

            -- Status line
            local statusText, sr, sg, sb
            if slotIndex == active then
                local s = slot.stats
                statusText = string.format(
                    "Hunger:%.0f%%  Thirst:%.0f%%  Fatigue:%.0f%%",
                    (s.Hunger or 0)*100, (s.Thirst or 0)*100, (s.Fatigue or 0)*100)
                sr, sg, sb = 0.6, 0.8, 0.6
            elseif slot.npcId then
                statusText = We.getText("UI_We_NPC_AtHome")
                sr, sg, sb = 0.4, 0.7, 1.0
            else
                statusText = We.getText("UI_We_NPC_Unspawned")
                sr, sg, sb = 0.8, 0.5, 0.2
            end
            self:drawText(statusText, PADDING, y + 34, sr, sg, sb, 1, UIFont.Small)

            -- Switch button (inactive slots only)
            if slotIndex ~= active then
                local btnX  = self.width - BTN_W - PADDING - 12
                local btnY2 = y + (ROW_H - BTN_H) / 2
                local a     = atBase and 1 or 0.30
                self:drawRect(btnX, btnY2, BTN_W, BTN_H, a, 0.12, 0.30, 0.55)
                local label = We.getText("UI_We_Switch")
                local lw    = getTextManager():MeasureStringX(UIFont.Small, label)
                self:drawText(label, btnX + (BTN_W - lw) / 2, btnY2 + 7,
                    1, 1, 1, a, UIFont.Small)
            end
        end

        -- REQUIRED: return the next y position so ISScrollingListBox can track row heights
        return y + self.itemheight
    end

    -- ── Click handling ───────────────────────────────────────────────────────
    -- Uses self.selected (set by parent onMouseDown) for item identification.
    -- Divides each row into left zone (rename) and right zone (switch/create).
    function self.slotList:onMouseDown(x, y)
        ISScrollingListBox.onMouseDown(self, x, y)

        local idx = self.selected
        if not idx or idx < 1 or idx > #self.items then return end

        local d    = self.items[idx].item
        local btnX = self.width - BTN_W - PADDING - 12

        if x >= btnX and x <= btnX + BTN_W then
            -- Right zone → switch / create
            if d.isAddRow then
                self.rosterPanel:onAddClick()
            elseif d.slotIndex ~= WeData.getActiveSlot() then
                self.rosterPanel:onSwitchClick(d.slotIndex)
            end
        elseif not d.isAddRow and x >= PADDING and x <= PADDING + 180 then
            -- Left zone → rename
            self.rosterPanel:onNameClick(d.slotIndex, idx)
        end
    end

    self.slotList:initialise()
    self.slotList:instantiate()
    self:addChild(self.slotList)

    -- Fixed "Remove Safehouse" button at bottom (SP-only, shown when home set)
    local removeY = self.height - BTN_H - 8
    self.removeHomeBtn = ISButton:new(PADDING, removeY, 180, BTN_H,
        We.getText("UI_We_RemoveHome"), self, WeRosterPanel.onRemoveHome)
    self.removeHomeBtn.backgroundColor          = {r=0.40, g=0.10, b=0.10, a=1}
    self.removeHomeBtn.backgroundColorMouseOver = {r=0.65, g=0.15, b=0.15, a=1}
    self:addChild(self.removeHomeBtn)

    self:refreshRows()
end

function WeRosterPanel:refreshRows()
    local data   = WeData.getData()
    local atBase = WeData.isAtHomeBase()

    -- Status label
    if atBase then
        self.baseStatusLabel.name = We.getText("UI_We_Status_AtBase")
        self.baseStatusLabel.r, self.baseStatusLabel.g, self.baseStatusLabel.b = 0.3, 0.9, 0.4
    elseif not data.homeX then
        self.baseStatusLabel.name = We.getText("UI_We_Status_NoHome")
        self.baseStatusLabel.r, self.baseStatusLabel.g, self.baseStatusLabel.b = 0.9, 0.7, 0.2
    else
        self.baseStatusLabel.name = We.getText("UI_We_Status_TooFar")
        self.baseStatusLabel.r, self.baseStatusLabel.g, self.baseStatusLabel.b = 0.9, 0.3, 0.3
    end

    -- Rebuild list items
    self.slotList.items    = {}
    self.slotList.selected = 0
    local visSlots = self:getVisibleSlots()
    for _, entry in ipairs(visSlots) do
        local label = entry.isAddRow
            and We.getText("UI_We_EmptySlot")
            or WeData.getSlot(entry.slotIndex).name
        self.slotList:addItem(label, entry)
    end

    -- Remove button: SP only, when home is set
    local isMP = getWorld and getWorld():getGameMode() == "Multiplayer"
    self.removeHomeBtn:setVisible(not isMP and data.homeX ~= nil)
end

function WeRosterPanel:update()
    -- Refresh button states every 30 frames so changes apply live
    self._tick = (self._tick or 0) + 1
    if self._tick >= 30 then
        self._tick = 0
        self:refreshRows()
    end
end

function WeRosterPanel:render()
    ISPanel.render(self)
end

function WeRosterPanel:onRemoveHome()
    WeData.clearHome()
    self:refreshRows()
    local player = getSpecificPlayer(0)
    if player then
        HaloTextHelper.addText(player, We.getText("UI_We_HomeRemoved"))
    end
end

function WeRosterPanel:onSwitchClick(slotIndex)
    WeData.switchTo(slotIndex)
    self:refreshRows()
end

function WeRosterPanel:onAddClick()
    -- Find the first unused slot and switch to it (triggers character creation)
    local data = WeData.getData()
    for i = 1, We.MAX_SLOTS do
        if not data.slots[i] or data.slots[i].x == nil then
            WeData.switchTo(i)
            self:refreshRows()
            return
        end
    end
end

function WeRosterPanel:onNameClick(slotIndex, itemIdx)
    if self.renameBox then
        self:removeChild(self.renameBox)
        self.renameBox = nil
    end

    -- Position the text entry near the clicked row (best-effort scroll offset)
    local scrollOff = self.slotList.scrollY or 0
    local rowY = STATUS_H + (itemIdx - 1) * ROW_H - scrollOff
    rowY = math.max(STATUS_H, math.min(rowY, self.height - REMOVE_H - 30))

    local slot = WeData.getSlot(slotIndex)
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

-- ─── Hook ─────────────────────────────────────────────────────────────────────

local WeTabPanel = nil  -- singleton

function openWeTabPanel(userPanel)
    -- Toggle: close if already open
    if WeTabPanel and WeTabPanel:isVisible() then
        WeTabPanel:setVisible(false)
        return
    end

    local player = (userPanel and userPanel.player) or getSpecificPlayer(0)
    local isSP   = not isClient() and not isServer()

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local px = math.floor(sw / 2 - PANEL_W / 2)
    local py = math.floor(sh / 2 - PANEL_H / 2)

    WeTabPanel = ISTabPanel:new(px, py, PANEL_W, PANEL_H)
    WeTabPanel.moveWithMouse    = true
    WeTabPanel.allowDraggingTabs = false
    WeTabPanel.onKeyPressed = function(self, key)
        if key == Keyboard.KEY_ESCAPE then self:setVisible(false) end
    end
    WeTabPanel:initialise()
    WeTabPanel:addToUIManager()

    -- Close button in the tab bar
    local closeBtn = ISButton:new(PANEL_W - 22, 2, 18, TAB_H - 4, "x", WeTabPanel,
        function(panel) panel:setVisible(false) end)
    closeBtn.backgroundColor          = {r=0.5, g=0.1, b=0.1, a=1}
    closeBtn.backgroundColorMouseOver = {r=0.8, g=0.2, b=0.2, a=1}
    closeBtn:initialise()
    WeTabPanel:addChild(closeBtn)

    -- ── Faction tab (MP only) ────────────────────────────────────────────────
    if not isSP then
        if ISFactionUI.instance then ISFactionUI.instance:close() end
        if ISCreateFactionUI and ISCreateFactionUI.instance then
            ISCreateFactionUI.instance:close()
        end

        local factionView
        if Faction.isAlreadyInFaction(player) then
            factionView = ISFactionUI:new(0, 0, PANEL_W, VIEW_H,
                Faction.getPlayerFaction(player), player)
            factionView.close = function(self) self:setVisible(false) end
            ISFactionUI.instance = factionView
        else
            factionView = ISCreateFactionUI:new(0, 0, PANEL_W, VIEW_H, player)
            factionView.close = function(self) self:setVisible(false) end
            if ISCreateFactionUI then ISCreateFactionUI.instance = factionView end
        end
        factionView:initialise()
        WeTabPanel:addView(We.getText("UI_We_Tab_Faction"), factionView)
    end

    -- ── Characters tab ───────────────────────────────────────────────────────
    local rosterView = WeRosterPanel:new(0, 0, PANEL_W, VIEW_H)
    rosterView:initialise()
    WeTabPanel:addView(We.getText("UI_We_Tab_Characters"), rosterView)
    WeTabPanel:activateView(We.getText("UI_We_Tab_Characters"))
end

-- ─── Monkey-patch ISUserPanelUI ───────────────────────────────────────────────

local origOnOptionMouseDown = ISUserPanelUI.onOptionMouseDown

function ISUserPanelUI:onOptionMouseDown(button, x, y)
    if button.internal == "FACTIONPANEL" then
        openWeTabPanel(self)
        return
    end
    origOnOptionMouseDown(self, button, x, y)
end

local origCreate = ISUserPanelUI.create

function ISUserPanelUI:create()
    origCreate(self)
    if self.safehouseBtn and (isClient() or isServer()) then
        self.safehouseBtn:setVisible(false)
    end
end
