-- We: Faction tab integration
-- Hooks the Faction button in ISUserPanelUI to open a tabbed window that
-- contains both the standard Faction panel and our Characters roster.
require "ISUI/ISUI3DModel"

local PANEL_W  = 520
local VIEW_H   = 450
local TAB_H    = getTextManager():getFontHeight(UIFont.Small) + 6
local PANEL_H  = TAB_H + VIEW_H

local PADDING  = 10
local ROW_H    = 58
local BTN_W    = 80
local BTN_KICK_W = 74
local BTN_H    = 28
local STATUS_H = 26    -- fixed status bar at top
local REMOVE_H = BTN_H + 16  -- reserved height at bottom for remove button
local PORTRAIT_W = 130
local PORTRAIT_H = 190
local HOVER_ICON = getTexture("media/ui/ArrowRight.png")
local FALLBACK_ICON = getTexture("media/ui/ArrowRight.png")

-- ─── WeRosterPanel ────────────────────────────────────────────────────────────
-- Shows only used character slots + one empty "Create" row, up to MAX_SLOTS.
-- When the list is taller than the visible area a scrollbar appears.

WeRosterPanel = ISPanel:derive("WeRosterPanel")

function WeRosterPanel:new(x, y, w, h)
    local o = ISPanel.new(self, x, y, w, h)
    o.backgroundColor = {r=0.08, g=0.08, b=0.12, a=0.94}
    return o
end

local function getLiveStatsForSlot(slotIndex, slot)
    local active = WeData.getActiveSlot()
    if slotIndex ~= active then
        return slot and slot.stats or {}
    end
    local player = getSpecificPlayer(0)
    if not player then
        return slot and slot.stats or {}
    end
    local stats = player:getStats()
    local live = {
        Hunger      = stats:get(CharacterStat.HUNGER),
        Thirst      = stats:get(CharacterStat.THIRST),
        Fatigue     = stats:get(CharacterStat.FATIGUE),
        Boredom     = stats:get(CharacterStat.BOREDOM),
        Stress      = stats:get(CharacterStat.STRESS),
        Pain        = stats:get(CharacterStat.PAIN),
        Unhappiness = stats:get(CharacterStat.UNHAPPINESS),
    }
    if slot then
        slot.stats = slot.stats or {}
        for k, v in pairs(live) do
            slot.stats[k] = v
        end
    end
    return live
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
    self.moveWithMouse = true

    -- Fixed status label at top
    self.baseStatusLabel = ISLabel:new(PADDING, 6, 14, "", 1, 1, 1, 1, UIFont.Small, true)
    self:addChild(self.baseStatusLabel)

    -- Scrollable slot list
    local listH = self.height - STATUS_H - REMOVE_H
    local listW = self.width - PORTRAIT_W - PADDING - 8
    self.slotList = ISScrollingListBox:new(0, STATUS_H, listW, listH)
    self.slotList.font        = UIFont.Small
    self.slotList.itemheight  = ROW_H
    self.slotList.drawBorder  = false
    self.slotList.backgroundColor = {r=0, g=0, b=0, a=0}
    self.slotList.rosterPanel = self

    -- Portrait (selected slot)
    if ISCharacterScreenAvatar then
        self.portraitPanel = ISCharacterScreenAvatar:new(
            self.slotList.width + 8,
            STATUS_H + 4,
            PORTRAIT_W,
            PORTRAIT_H
        )
    else
        self.portraitPanel = ISUI3DModel:new(
            self.slotList.width + 8,
            STATUS_H + 4,
            PORTRAIT_W,
            PORTRAIT_H
        )
    end
    self.portraitPanel:initialise()
    self.portraitPanel:instantiate()
    self.portraitPanel:setVisible(true)
    self:addChild(self.portraitPanel)
    self.portraitPanel:setState("idle")
    self.portraitPanel:setDirection(IsoDirections.S)
    self.portraitPanel:setIsometric(false)
    if self.portraitPanel.setDoRandomExtAnimations then self.portraitPanel:setDoRandomExtAnimations(true) end
    if self.portraitPanel.setZoom then self.portraitPanel:setZoom(14) end
    if self.portraitPanel.setYOffset then self.portraitPanel:setYOffset(-0.85) end

    self.profLabel = ISLabel:new(self.portraitPanel.x, self.portraitPanel.y + PORTRAIT_H + 8, 16, We.getText("UI_We_Portrait_Profession"), 0.95, 0.85, 0.35, 1, UIFont.Small, true)
    self:addChild(self.profLabel)
    self.perksLabel = ISLabel:new(self.portraitPanel.x, self.profLabel.y + 24, 16, We.getText("UI_We_Portrait_Perks"), 0.75, 0.90, 0.75, 1, UIFont.Small, true)
    self:addChild(self.perksLabel)
    self.moodlesLabel = ISLabel:new(self.portraitPanel.x, self.perksLabel.y + 38, 16, "Moodles", 0.85, 0.80, 0.95, 1, UIFont.Small, true)
    self:addChild(self.moodlesLabel)
    self.profIcon = nil
    self.perkIcons = {}
    self.moodleIcons = {}
    self.selectedPortraitSlot = nil

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
            if self.mouseoverselected == item.index then
                if HOVER_ICON then
                    self:drawTexture(HOVER_ICON, PADDING - 8, y + 6, 1, 1, 1, 0.95)
                else
                    self:drawText(">", PADDING - 8, y + 4, 1, 1, 1, 0.95, UIFont.Small)
                end
            end

            -- Profession label
            if slot.creation and slot.creation.profName then
                self:drawText(slot.creation.profName,
                    PADDING + 4, y + 18, 0.9, 0.8, 0.3, 1, UIFont.Small)
            end

            -- Status line
            local statusText, sr, sg, sb
            if slotIndex == active then
                statusText = ""
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
                local btnX  = self.width - BTN_W - BTN_KICK_W - 6 - PADDING - 12
                local btnY2 = y + (ROW_H - BTN_H) / 2
                local a     = atBase and 1 or 0.30
                self:drawRect(btnX, btnY2, BTN_W, BTN_H, a, 0.12, 0.30, 0.55)
                local label = We.getText("UI_We_Switch")
                local lw    = getTextManager():MeasureStringX(UIFont.Small, label)
                self:drawText(label, btnX + (BTN_W - lw) / 2, btnY2 + 7,
                    1, 1, 1, a, UIFont.Small)

                local kickX = btnX + BTN_W + 6
                self:drawRect(kickX, btnY2, BTN_KICK_W, BTN_H, 1, 0.45, 0.12, 0.12)
                local kickLabel = We.getText("UI_We_Kick")
                local klw = getTextManager():MeasureStringX(UIFont.Small, kickLabel)
                self:drawText(kickLabel, kickX + (BTN_KICK_W - klw) / 2, btnY2 + 7,
                    1, 1, 1, 1, UIFont.Small)
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
        local btnX = self.width - BTN_W - BTN_KICK_W - 6 - PADDING - 12
        if d.isAddRow then
            btnX = self.width - BTN_W - PADDING - 12
        end
        local kickX = btnX + BTN_W + 6

        if x >= btnX and x <= btnX + BTN_W then
            -- Right zone → switch / create
            if d.isAddRow then
                self.rosterPanel:onAddClick()
            elseif d.slotIndex ~= WeData.getActiveSlot() then
                self.rosterPanel:onSwitchClick(d.slotIndex)
            end
        elseif not d.isAddRow and x >= kickX and x <= kickX + BTN_KICK_W then
            if d.slotIndex ~= WeData.getActiveSlot() then
                self.rosterPanel:onKickClick(d.slotIndex)
            end
        end

        if d.isAddRow then
            self.rosterPanel.selectedPortraitSlot = nil
            self.rosterPanel:updatePortraitForSlot(nil)
        else
            self.rosterPanel.selectedPortraitSlot = d.slotIndex
            self.rosterPanel:updatePortraitForSlot(d.slotIndex)
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

function WeRosterPanel:clearTraitIcons()
    if not self.perkIcons then return end
    for _, img in ipairs(self.perkIcons) do
        self:removeChild(img)
    end
    self.perkIcons = {}
end

function WeRosterPanel:clearMoodleIcons()
    if not self.moodleIcons then return end
    for _, img in ipairs(self.moodleIcons) do
        self:removeChild(img)
    end
    self.moodleIcons = {}
end

function WeRosterPanel:clearProfessionIcon()
    if self.profIcon then
        self:removeChild(self.profIcon)
        self.profIcon = nil
    end
end

function WeRosterPanel:addTraitIcons(slot)
    self:clearTraitIcons()
    if not slot then return end

    local x = self.portraitPanel.x
    local y = self.perksLabel.y + 20
    local iconSize = 16
    local spacing = 2
    local maxPerRow = 3
    local idx = 0

    for _, t in ipairs(slot.traits or {}) do
        local trait = CharacterTrait.get(ResourceLocation.of(t))
        local def = trait and CharacterTraitDefinition.getCharacterTraitDefinition(trait)
        local tx = def and def:getTexture()
        if tx then
            local col = idx % maxPerRow
            local row = math.floor(idx / maxPerRow)
            local img = ISImage:new(x + col * (iconSize + spacing), y + row * (iconSize + spacing), iconSize, iconSize, tx)
            img:initialise()
            img:setVisible(true)
            if img.setMouseOverText then
                img:setMouseOverText((def:getLabel() or "") .. "\n" .. (def:getDescription() or ""))
            end
            self:addChild(img)
            self.perkIcons[#self.perkIcons + 1] = img
            idx = idx + 1
        end
    end
end

function WeRosterPanel:addProfessionIcon(slot)
    self:clearProfessionIcon()
    if not slot or not slot.profession then return end

    local prof = CharacterProfession.get(ResourceLocation.of(slot.profession))
    local def = prof and CharacterProfessionDefinition.getCharacterProfessionDefinition(prof)
    local tx = def and def:getTexture()
    if not tx then return end

    local iconW, iconH = 18, 18
    local minX = self.portraitPanel.x + 2
    local maxX = self.portraitPanel.x + self.portraitPanel.width - iconW - 2
    local desiredX = self.profLabel.x + 78
    local iconX = math.max(minX, math.min(desiredX, maxX))
    local img = ISImage:new(iconX, self.profLabel.y - 1, iconW, iconH, tx)
    img:initialise()
    img:setVisible(true)
    if img.setMouseOverText then
        img:setMouseOverText(def:getUIName() or tostring(slot.profession))
    end
    self:addChild(img)
    self.profIcon = img
end

function WeRosterPanel:addMoodleIcons(slot, slotIndex)
    self:clearMoodleIcons()
    if not slot then return end

    local moodleDefs = {
        { key = "Hungry", text = "Hunger", mt = MoodleType.HUNGRY, stat = "Hunger", textureKeys = {"Hungry"} },
        { key = "Thirst", text = "Thirst", mt = MoodleType.THIRST, stat = "Thirst", textureKeys = {"Thirst", "Thirsty"} },
        { key = "Endurance", text = "Exertion", mt = MoodleType.ENDURANCE, stat = "Endurance", textureKeys = {"Endurance", "HeavyLoad"} },
        { key = "Tired", text = "Fatigue", mt = MoodleType.TIRED, stat = "Fatigue", textureKeys = {"Tired"} },
        { key = "Stress", text = "Stress", mt = MoodleType.STRESS, stat = "Stress", textureKeys = {"Stress"} },
        { key = "Pain", text = "Pain", mt = MoodleType.PAIN, stat = "Pain", textureKeys = {"Pain"} },
        { key = "Bored", text = "Boredom", mt = MoodleType.BORED, stat = "Boredom", textureKeys = {"Bored", "Unhappy"} },
        { key = "Unhappy", text = "Unhappy", mt = MoodleType.UNHAPPY, textureKeys = {"Unhappy", "Bored"} },
        { key = "Panic", text = "Panic", mt = MoodleType.PANIC, textureKeys = {"Panic"} },
        { key = "Sick", text = "Sick", mt = MoodleType.SICK, textureKeys = {"Sick"} },
        { key = "Hyperthermia", text = "Hyperthermia", mt = MoodleType.HYPERTHERMIA, textureKeys = {"Hyperthermia"} },
        { key = "Hypothermia", text = "Hypothermia", mt = MoodleType.HYPOTHERMIA, textureKeys = {"Hypothermia", "Cold"} },
        { key = "HeavyLoad", text = "Heavy Load", mt = MoodleType.HEAVY_LOAD, textureKeys = {"HeavyLoad", "Endurance"} },
    }

    local function getMoodleTexture(def)
        for _, k in ipairs(def.textureKeys or {}) do
            local tx = getTexture("media/ui/Moodles/Moodle_Icon_" .. tostring(k) .. ".png")
            if tx then return tx end
        end
        return FALLBACK_ICON
    end

    local x = self.portraitPanel.x
    local y = self.moodlesLabel.y + 18
    local size = 16
    local spacing = 2
    local idx = 0
    local active = WeData.getActiveSlot()
    local player = getSpecificPlayer(0)
    local moodles = player and player:getMoodles()
    for _, m in ipairs(moodleDefs) do
        local level = 0
        if slotIndex == active and moodles and m.mt then
            level = moodles:getMoodleLevel(m.mt) or 0
        else
            local savedMoodles = slot.moodles or {}
            if savedMoodles[m.key] ~= nil then
                level = tonumber(savedMoodles[m.key]) or 0
            else
                local s = getLiveStatsForSlot(slotIndex or -1, slot)
                local raw = s and s[m.stat] or nil
                local value = tonumber(raw or 0) or 0
                if m.stat == "Endurance" then
                    value = 1 - value
                end
                if value > 0 then
                    level = math.max(1, math.min(4, math.floor(value * 4 + 0.5)))
                end
            end
        end
        if slotIndex == active and m.key == "Hypothermia" and level <= 0 and player and player.getTemperature then
            local t = player:getTemperature()
            if t and t < 35.5 then level = 1 end
        end
        if level > 0 then
            local texture = getMoodleTexture(m)
            local col = idx % 7
            local row = math.floor(idx / 7)
            local ix = x + col * (size + spacing)
            local iy = y + row * (size + spacing)
            local img = ISImage:new(ix, iy, size, size, texture)
            img:initialise()
            img:setVisible(true)
            if img.setMouseOverText then
                img:setMouseOverText(m.text .. " Lv." .. tostring(level))
            end
            self:addChild(img)
            self.moodleIcons[#self.moodleIcons + 1] = img
            idx = idx + 1
        end
    end
end

function WeRosterPanel:updatePortraitForSlot(slotIndex)
    if not self.portraitPanel then return end
    if not slotIndex then
        self.profLabel.name = We.getText("UI_We_Portrait_Profession")
        self.perksLabel.name = We.getText("UI_We_Portrait_Perks")
        self.moodlesLabel.name = "Moodles"
        self:clearProfessionIcon()
        self:clearTraitIcons()
        self:clearMoodleIcons()
        return
    end
    local slot = WeData.getSlot(slotIndex)
    if not slot then return end

    local active = WeData.getActiveSlot()
    local player = getSpecificPlayer(0)
    if slotIndex == active and player and self.portraitPanel.setCharacter then
        self.portraitPanel:setCharacter(player)
    else
        local app = slot.appearance or {}
        local desc = SurvivorFactory.CreateSurvivor()
        desc:setFemale(app.female or false)

        local vis = desc:getHumanVisual()
        if vis then
            if app.skinTexture and app.skinTexture ~= "" and vis.setSkinTextureName then
                vis:setSkinTextureName(app.skinTexture)
            end
            if app.hairStyle and vis.setHairModel then
                vis:setHairModel(app.hairStyle)
            end
            if app.hairColor and vis.setHairColor then
                vis:setHairColor(ImmutableColor.new(app.hairColor.r, app.hairColor.g, app.hairColor.b, 1))
            end
            if app.beardStyle and vis.setBeardModel then
                vis:setBeardModel(app.beardStyle)
            end
            if app.beardColor and vis.setBeardColor then
                vis:setBeardColor(ImmutableColor.new(app.beardColor.r, app.beardColor.g, app.beardColor.b, 1))
            end
        end
        -- Restore saved worn clothes from slot inventory so portrait uses actual outfit.
        if desc.getWornItems and desc.setWornItem and slot.inventory then
            local worn = desc:getWornItems()
            if worn and worn.clear then worn:clear() end
            for _, itemData in ipairs(slot.inventory) do
                if itemData.lastStandStr then
                    local item = ItemVisual.createLastStandItem and ItemVisual.createLastStandItem(itemData.lastStandStr)
                    if item then
                        local loc = item.getBodyLocation and item:getBodyLocation()
                        if loc and loc ~= "" then
                            local bodyLoc = nil
                            if type(loc) == "string" then
                                bodyLoc = ItemBodyLocation.get(ResourceLocation.of(loc))
                            else
                                bodyLoc = loc
                            end
                            if bodyLoc then
                                desc:setWornItem(bodyLoc, item)
                            end
                        end
                    end
                end
            end
        end

        self.portraitPanel:setSurvivorDesc(desc)
        -- Only fallback when no saved clothing exists.
        if self.portraitPanel.setOutfitName and (not slot.inventory or #slot.inventory == 0) then
            self.portraitPanel:setOutfitName("Foreman", false, false)
        end
    end
    if self.portraitPanel.setZoom then self.portraitPanel:setZoom(14) end
    if self.portraitPanel.setYOffset then self.portraitPanel:setYOffset(-0.85) end

    self.profLabel.name = We.getText("UI_We_Portrait_Profession")
    self:addProfessionIcon(slot)
    self.perksLabel.name = We.getText("UI_We_Portrait_Perks")
    self:addTraitIcons(slot)
    local traitCount = #(slot.traits or {})
    local traitRows = math.max(1, math.ceil(traitCount / 3))
    self.moodlesLabel:setY(self.perksLabel.y + 20 + traitRows * 18 + 4)
    self.moodlesLabel.name = "Moodles"
    self:addMoodleIcons(slot, slotIndex)
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

    local active = WeData.getActiveSlot()
    local selected = self.selectedPortraitSlot
    local selectedValid = selected and WeData.getSlot(selected) and WeData.getSlot(selected).x ~= nil
    if selectedValid then
        self:updatePortraitForSlot(selected)
    elseif active and WeData.getSlot(active) and WeData.getSlot(active).x ~= nil then
        self.selectedPortraitSlot = active
        self:updatePortraitForSlot(active)
    else
        self.selectedPortraitSlot = nil
        self:updatePortraitForSlot(nil)
    end

    -- Remove button: SP only, when home is set
    local isMP = getWorld and getWorld():getGameMode() == "Multiplayer"
    self.removeHomeBtn:setVisible(not isMP and data.homeX ~= nil)
end

function WeRosterPanel:update()
    -- Refresh less frequently to avoid recreating moodle icons during hover.
    self._tick = (self._tick or 0) + 1
    if self._tick >= 300 then
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

function WeRosterPanel:onKickClick(slotIndex)
    local slot = WeData.getSlot(slotIndex)
    if not slot then return end
    if slotIndex == WeData.getActiveSlot() then return end

    local displayName = tostring(slot.name or ("Slot " .. tostring(slotIndex)))
    local msg = We.getText("UI_We_Kick_Confirm", displayName)
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 170,
        getCore():getScreenHeight() / 2 - 60,
        340, 120,
        msg,
        true,
        self,
        function(target, button)
            if button.internal ~= "YES" then return end
            local currentSlot = WeData.getSlot(slotIndex)
            if not currentSlot then return end
            if slotIndex == WeData.getActiveSlot() then return end

            if currentSlot.npcId then
                WeNPC.despawnForSlot(slotIndex)
            end
            WeData.killSlot(slotIndex)
            target:refreshRows()

            local player = getSpecificPlayer(0)
            if player then
                HaloTextHelper.addGoodText(player, We.getText("UI_We_Kick_Done", displayName))
            end
        end
    )
    modal.moveWithMouse = true
    modal:setCapture(true)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    modal:bringToTop()
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
