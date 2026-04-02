-- We: Faction tab integration
-- Hooks the Faction button in ISUserPanelUI to open a tabbed window that
-- contains both the standard Faction panel and our Characters roster.
require "ISUI/ISUI3DModel"
require "XpSystem/ISUI/ISCharacterScreen"
pcall(require, "We_NPC")

-- Inactive portrait: prefer setCharacter(WeNPC.Cache[slot]) — real world resident has full visuals. Else setSurvivorDesc(desc).
-- (Preview-only IsoSurvivor + setCharacter tracked the local player mesh in B42.)

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

local function moodleLevelFrom01(v)
    v = tonumber(v or 0) or 0
    if v < 0 then v = 0 end
    if v > 1 then v = 1 end
    if v <= 0.10 then return 0 end
    if v <= 0.30 then return 1 end
    if v <= 0.55 then return 2 end
    if v <= 0.80 then return 3 end
    return 4
end

--- World resident for this slot (NPC stand-in). Full visuals + inventory; UI3DModel follows real IsoGameCharacter better than SurvivorDesc alone.
local function getLiveResidentForPortrait(slotIndex, activeSlot)
    if not slotIndex or slotIndex == activeSlot or not WeNPC or not WeNPC.Cache then
        return nil
    end
    local c = WeNPC.Cache[slotIndex]
    if not c or c == "pending" then
        return nil
    end
    if not instanceof(c, "IsoGameCharacter") then
        return nil
    end
    if c.isDead and c:isDead() then
        return nil
    end
    return c
end

-- ─── WeRosterPanel ────────────────────────────────────────────────────────────
-- Shows only used character slots + one empty "Create" row, up to MAX_SLOTS.
-- When the list is taller than the visible area a scrollbar appears.

WeRosterPanel = ISPanel:derive("WeRosterPanel")

function WeRosterPanel:new(x, y, w, h)
    local o = ISPanel.new(self, x, y, w, h)
    o.backgroundColor = {r=0.08, g=0.08, b=0.12, a=0.94}
    return o
end

function WeRosterPanel:removeFromUIManager()
    ISPanel.removeFromUIManager(self)
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

local function slotHasCharacterData(slot)
    if not slot then return false end
    if (tonumber(slot.health) or 100) <= 0 then return false end
    if slot.x ~= nil then return true end
    if slot.npcId ~= nil then return true end
    if slot.creation ~= nil then return true end
    if slot.profession ~= nil then return true end
    if slot.traits and #slot.traits > 0 then return true end
    if slot.inventory and #slot.inventory > 0 then return true end
    if slot.skillsList and #slot.skillsList > 0 then return true end
    return false
end

-- Returns [{slotIndex, isAddRow}] — used slots + one empty slot (unless full)
function WeRosterPanel:getVisibleSlots()
    local data   = WeData.getData()
    local result = {}
    local usedCount = 0
    if not data.slots then
        data.slots = {}
        for i = 1, We.MAX_SLOTS do
            data.slots[i] = We.defaultSlot(i)
        end
    end
    for i = 1, We.MAX_SLOTS do
        local slot = data.slots[i]
        if slotHasCharacterData(slot) then
            usedCount = usedCount + 1
            table.insert(result, {slotIndex = i, isAddRow = false})
        end
    end
    if usedCount < We.MAX_SLOTS then
        for i = 1, We.MAX_SLOTS do
            if not slotHasCharacterData(data.slots[i]) then
                table.insert(result, {slotIndex = i, isAddRow = true})
                break
            end
        end
    end
    if #result == 0 then
        table.insert(result, {slotIndex = 1, isAddRow = true})
    end
    return result
end

function WeRosterPanel:initialise()
    ISPanel.initialise(self)
    -- Keep roster content panel fixed inside tab container.
    self.moveWithMouse = false

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
    local ENABLE_PORTRAIT = true
    local portraitX = self.slotList.width + 8
    local portraitY = STATUS_H + 4
    if ENABLE_PORTRAIT and ISCharacterScreenAvatar then
        self.portraitPanel = ISCharacterScreenAvatar:new(
            portraitX,
            portraitY,
            PORTRAIT_W,
            PORTRAIT_H
        )
    end
    self._portraitDisabled = (self.portraitPanel == nil)
    if self.portraitPanel then
        self.portraitPanel:initialise()
        self.portraitPanel:instantiate()
        self.portraitPanel:setVisible(true)
        self:addChild(self.portraitPanel)
    end
    if self.portraitPanel and self.portraitPanel.render then
        local baseRender = self.portraitPanel.render
        local owner = self
        self.portraitPanel.render = function(panel, ...)
            if owner._portraitDisabled then return end
            local ok, err = pcall(baseRender, panel, ...)
            if not ok then
                owner._portraitDisabled = true
                panel:setVisible(false)
                print("[We] portrait render disabled after error: " .. tostring(err))
            end
        end
    end
    if self.portraitPanel then
        self.portraitPanel:setState("idle")
        self.portraitPanel:setDirection(IsoDirections.S)
        self.portraitPanel:setIsometric(false)
        if self.portraitPanel.setDoRandomExtAnimations then self.portraitPanel:setDoRandomExtAnimations(true) end
        if self.portraitPanel.setZoom then self.portraitPanel:setZoom(14) end
        if self.portraitPanel.setYOffset then self.portraitPanel:setYOffset(-0.85) end
    end

    self.profLabel = ISLabel:new(portraitX, portraitY + PORTRAIT_H + 8, 16, We.getText("UI_We_Portrait_Profession"), 0.95, 0.85, 0.35, 1, UIFont.Small, true)
    self:addChild(self.profLabel)
    self.perksLabel = ISLabel:new(portraitX, self.profLabel.y + 24, 16, We.getText("UI_We_Portrait_Perks"), 0.75, 0.90, 0.75, 1, UIFont.Small, true)
    self:addChild(self.perksLabel)
    self.moodlesLabel = ISLabel:new(portraitX, self.perksLabel.y + 38, 16, We.getText("UI_We_Moodles"), 0.85, 0.80, 0.95, 1, UIFont.Small, true)
    self:addChild(self.moodlesLabel)
    self.profIcon = nil
    self.perkIcons = {}
    self.moodleIcons = {}
    self.selectedPortraitSlot = nil

    -- ── Custom row renderer ──────────────────────────────────────────────────
    function self.slotList:doDrawItem(y, item, alt)
        local d      = item.item
        local atBase = WeData.isAtHomeBase()
        local data   = WeData.getData()
        local canSwitch = atBase or (data and data._deathSelectionMode == true)

        if d.isAddRow then
            -- "Create new character" row
            self:drawText(
                We.getText("UI_We_EmptySlot"),
                PADDING, y + 20,
                0.50, 0.50, 0.60, 1, UIFont.Small)

            local btnX  = self.width - BTN_W - PADDING - 12
            local btnY2 = y + (ROW_H - BTN_H) / 2
            local a     = canSwitch and 1 or 0.30
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
                local a     = canSwitch and 1 or 0.30
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
        print("[We][DbgSwitch] slotList:onMouseDown x=" .. tostring(x) .. " y=" .. tostring(y)
            .. " selected=" .. tostring(self.selected) .. " items=" .. tostring(#self.items))

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
                print("[We][DbgSwitch] click create row slotIndex=" .. tostring(d.slotIndex))
                self.rosterPanel:onAddClick()
            elseif d.slotIndex ~= WeData.getActiveSlot() then
                print("[We][DbgSwitch] click switch slotIndex=" .. tostring(d.slotIndex)
                    .. " active=" .. tostring(WeData.getActiveSlot()))
                self.rosterPanel:onSwitchClick(d.slotIndex)
            end
        elseif not d.isAddRow and x >= kickX and x <= kickX + BTN_KICK_W then
            if d.slotIndex ~= WeData.getActiveSlot() then
                print("[We][DbgSwitch] click kick slotIndex=" .. tostring(d.slotIndex))
                self.rosterPanel:onKickClick(d.slotIndex)
            end
        end

        if d.isAddRow then
            self.rosterPanel._forceNoPortraitSelection = true
            self.rosterPanel.selectedPortraitSlot = nil
            self.rosterPanel:updatePortraitForSlot(nil)
        else
            self.rosterPanel._forceNoPortraitSelection = false
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

function WeRosterPanel:setPortraitDetailsVisible(visible)
    if self.profLabel then self.profLabel:setVisible(visible == true) end
    if self.perksLabel then self.perksLabel:setVisible(visible == true) end
    if self.moodlesLabel then self.moodlesLabel:setVisible(visible == true) end
end

function WeRosterPanel:addTraitIcons(slot)
    self:clearTraitIcons()
    if not slot then return end

    local x = (self.portraitPanel and self.portraitPanel.x) or (self.slotList.width + 8)
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
    local portraitX = (self.portraitPanel and self.portraitPanel.x) or (self.slotList.width + 8)
    local portraitW = (self.portraitPanel and self.portraitPanel.width) or PORTRAIT_W
    local minX = portraitX + 2
    local maxX = portraitX + portraitW - iconW - 2
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
        { key = "Hungry", text = We.getText("UI_We_Moodle_Hunger"), mt = MoodleType.HUNGRY, stat = "Hunger", textureKeys = {"Hungry"} },
        { key = "Thirst", text = We.getText("UI_We_Moodle_Thirst"), mt = MoodleType.THIRST, stat = "Thirst", textureKeys = {"Thirst", "Thirsty"} },
        { key = "Endurance", text = We.getText("UI_We_Moodle_Exertion"), mt = MoodleType.ENDURANCE, stat = "Endurance", textureKeys = {"Endurance", "HeavyLoad"} },
        { key = "Tired", text = We.getText("UI_We_Moodle_Fatigue"), mt = MoodleType.TIRED, stat = "Fatigue", textureKeys = {"Tired"} },
        { key = "Stress", text = We.getText("UI_We_Moodle_Stress"), mt = MoodleType.STRESS, stat = "Stress", textureKeys = {"Stress"} },
        { key = "Pain", text = We.getText("UI_We_Moodle_Pain"), mt = MoodleType.PAIN, stat = "Pain", textureKeys = {"Pain"} },
        { key = "Bored", text = We.getText("UI_We_Moodle_Boredom"), mt = MoodleType.BORED, stat = "Boredom", textureKeys = {"Bored", "Unhappy"} },
        { key = "Unhappy", text = We.getText("UI_We_Moodle_Unhappy"), mt = MoodleType.UNHAPPY, textureKeys = {"Unhappy", "Bored"} },
        { key = "Panic", text = We.getText("UI_We_Moodle_Panic"), mt = MoodleType.PANIC, textureKeys = {"Panic"} },
        { key = "Sick", text = We.getText("UI_We_Moodle_Sick"), mt = MoodleType.SICK, textureKeys = {"Sick"} },
        { key = "Hyperthermia", text = We.getText("UI_We_Moodle_Hyperthermia"), mt = MoodleType.HYPERTHERMIA, textureKeys = {"Hyperthermia"} },
        { key = "Hypothermia", text = We.getText("UI_We_Moodle_Hypothermia"), mt = MoodleType.HYPOTHERMIA, textureKeys = {"Hypothermia", "Cold"} },
        { key = "HeavyLoad", text = We.getText("UI_We_Moodle_HeavyLoad"), mt = MoodleType.HEAVY_LOAD, textureKeys = {"HeavyLoad", "Endurance"} },
        { key = "Bleeding", text = We.getText("UI_We_Moodle_Bleeding"), mt = MoodleType.BLEEDING, textureKeys = {"Bleeding", "Pain"} },
        { key = "Wet", text = We.getText("UI_We_Moodle_Wet"), mt = MoodleType.WET, textureKeys = {"Wet", "Sick"} },
        { key = "HasACold", text = We.getText("UI_We_Moodle_Cold"), mt = MoodleType.HAS_A_COLD, textureKeys = {"HasACold", "Sick"} },
        { key = "Windchill", text = We.getText("UI_We_Moodle_Windchill"), mt = MoodleType.WINDCHILL, textureKeys = {"Windchill", "Cold"} },
        { key = "Injured", text = We.getText("UI_We_Moodle_Injured"), mt = MoodleType.INJURED, textureKeys = {"Injured", "Pain"} },
    }

    local function getMoodleTexture(def)
        for _, k in ipairs(def.textureKeys or {}) do
            local tx = getTexture("media/ui/Moodles/Moodle_Icon_" .. tostring(k) .. ".png")
            if tx then return tx end
        end
        return FALLBACK_ICON
    end

    local x = (self.portraitPanel and self.portraitPanel.x) or (self.slotList.width + 8)
    local y = self.moodlesLabel.y + 18
    local size = 16
    local spacing = 2
    local idx = 0
    local active = WeData.getActiveSlot()
    local player = getSpecificPlayer(0)
    local moodles = player and player:getMoodles()
    local shownKeys = {}
    for _, m in ipairs(moodleDefs) do
        local level = 0
        if slotIndex == active and moodles and m.mt then
            level = moodles:getMoodleLevel(m.mt) or 0
        else
            local savedMoodles = slot.moodles or {}
            local computedLevel = 0
            local savedLevel = savedMoodles[m.key]
            if savedLevel == nil and m.key == "Stress" then
                savedLevel = savedMoodles.Stressed
            end
            if savedLevel ~= nil then
                -- Inactive slot: trust saved/simulated moodle level first.
                level = tonumber(savedLevel) or 0
            else
                local s = getLiveStatsForSlot(slotIndex or -1, slot)
                local raw = s and s[m.stat] or nil
                local hasStat = (m.stat ~= nil and raw ~= nil)
                if not hasStat then
                    level = 0
                else
                    local value = tonumber(raw or 0) or 0
                    if m.stat == "Endurance" then
                        value = 1 - value
                    end
                    computedLevel = moodleLevelFrom01(value)
                    level = computedLevel
                end
            end
            if m.key == "Stress" then
                local s2 = getLiveStatsForSlot(slotIndex or -1, slot)
                local stress01 = s2 and tonumber(s2.Stress or 0) or 0
                computedLevel = moodleLevelFrom01(stress01)
                local alt = tonumber(savedMoodles.Stressed or -1) or -1
                if alt > computedLevel then computedLevel = alt end
                if computedLevel > level then level = computedLevel end
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
                img:setMouseOverText(m.text .. " " .. We.getText("UI_We_Health_Level", tostring(level)))
            end
            self:addChild(img)
            self.moodleIcons[#self.moodleIcons + 1] = img
            idx = idx + 1
            shownKeys[m.key] = true
        end
    end

    -- Also show any saved/simulated moodles not listed above.
    if slotIndex ~= active then
        for k, v in pairs(slot.moodles or {}) do
            if not shownKeys[k] then
                local level = tonumber(v) or 0
                if level > 0 then
                    local texture = FALLBACK_ICON
                    local tx = getTexture("media/ui/Moodles/Moodle_Icon_" .. tostring(k) .. ".png")
                    if tx then texture = tx end
                    local col = idx % 7
                    local row = math.floor(idx / 7)
                    local ix = x + col * (size + spacing)
                    local iy = y + row * (size + spacing)
                    local img = ISImage:new(ix, iy, size, size, texture)
                    img:initialise()
                    img:setVisible(true)
                    if img.setMouseOverText then
                        img:setMouseOverText(tostring(k) .. " " .. We.getText("UI_We_Health_Level", tostring(level)))
                    end
                    self:addChild(img)
                    self.moodleIcons[#self.moodleIcons + 1] = img
                    idx = idx + 1
                end
            end
        end
    end
end

function WeRosterPanel:updatePortraitForSlot(slotIndex)
    if not slotIndex then
        self.profLabel.name = We.getText("UI_We_Portrait_Profession")
        self.perksLabel.name = We.getText("UI_We_Portrait_Perks")
        self.moodlesLabel.name = We.getText("UI_We_Moodles")
        self:clearProfessionIcon()
        self:clearTraitIcons()
        self:clearMoodleIcons()
        self._portraitShowIn = nil
        if self.portraitPanel then self.portraitPanel:setVisible(false) end
        self:setPortraitDetailsVisible(false)
        return
    end
    local slot = WeData.getSlot(slotIndex)
    if not slot then return end

    self._lastPortraitSlot = slotIndex

    local active = WeData.getActiveSlot()
    local player = getSpecificPlayer(0)
    if self.portraitPanel and not self._portraitDisabled and slotIndex == active and player and self.portraitPanel.setCharacter then
        local okChar = pcall(function() self.portraitPanel:setCharacter(player) end)
        if not okChar then
            self._portraitDisabled = true
            self.portraitPanel:setVisible(false)
            print("[We] portrait disabled: setCharacter failed")
            return
        end
    elseif self.portraitPanel and not self._portraitDisabled then
        local usedLiveNpc = false
        local npc = getLiveResidentForPortrait(slotIndex, active)
        if npc and self.portraitPanel.setCharacter then
            pcall(function() self.portraitPanel:setCharacter(nil) end)
            local okNpc = pcall(function() self.portraitPanel:setCharacter(npc) end)
            if okNpc then
                usedLiveNpc = true
                if We and We.logAppearance then
                    We.logAppearance(string.format("portrait inactive liveNPC slot=%s", tostring(slotIndex)))
                end
            end
        end

        if not usedLiveNpc then
        local app = slot.appearance or {}
        local desc = SurvivorFactory.CreateSurvivor()
        desc:setFemale(app.female or false)

        -- Full-body LS fixes wrong face/body on CreateSurvivor() (same idea as LastStandSetup.loadLastStandPlayerVisuals).
        local vis = desc:getHumanVisual()
        if vis then
            local hvOk = false
            if app.humanVisualLS and type(app.humanVisualLS) == "string" and app.humanVisualLS ~= "" and vis.loadLastStandString then
                hvOk = select(1, pcall(function() vis:loadLastStandString(app.humanVisualLS) end))
            end
            if not hvOk then
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
        end

        -- Worn clothes: merge inventory rows with appearance.clothingVisuals by fullType when lastStandStr is missing.
        if desc.getWornItems and desc.setWornItem then
            local function portraitWearSortKey(locStr)
                local l = tostring(locStr or "")
                if l == "Back" then return 950 end
                if l:find("Holster", 1, true) then return 880 end
                if l == "Belt" or l:find("Belt", 1, true) then return 860 end
                if l:find("Jacket", 1, true) then return 780 end
                if l:find("Sweater", 1, true) then return 760 end
                if l == "Torso" or l == "ShortSleeveShirt" or l == "Tshirt" or l == "TankTop" then return 720 end
                if l:find("Dress", 1, true) or l:find("FullSuit", 1, true) then return 710 end
                if l == "Pants" or l == "Skirt" then return 400 end
                if l == "Shoes" then return 350 end
                if l == "Socks" then return 320 end
                if l:find("Underwear", 1, true) then return 280 end
                return 500
            end

            local function inferSortLocStr(itemData)
                if itemData.wornLoc and tostring(itemData.wornLoc) ~= "" then
                    return tostring(itemData.wornLoc)
                end
                if itemData.lastStandStr and ItemVisual and ItemVisual.createLastStandItem then
                    local ok, it = pcall(function() return ItemVisual.createLastStandItem(itemData.lastStandStr) end)
                    if ok and it and it.getBodyLocation then
                        local ok2, loc = pcall(function() return it:getBodyLocation() end)
                        if ok2 and loc then return tostring(loc) end
                    end
                end
                return ""
            end

            local function inferSortLocFromLsString(ls)
                if not ls or not ItemVisual or not ItemVisual.createLastStandItem then return "" end
                local ok, it = pcall(function() return ItemVisual.createLastStandItem(ls) end)
                if ok and it and it.getBodyLocation then
                    local ok2, loc = pcall(function() return it:getBodyLocation() end)
                    if ok2 and loc then return tostring(loc) end
                end
                return ""
            end

            local function resolveDescBodyLoc(rawLoc, item)
                if rawLoc ~= nil and type(rawLoc) ~= "string" then
                    return rawLoc
                end
                local s = rawLoc
                if (s == nil or s == "") and item and item.getBodyLocation then
                    local ok, bl = pcall(function() return item:getBodyLocation() end)
                    if ok and bl then
                        s = bl
                    end
                end
                if s == nil or s == "" then return nil end
                if type(s) ~= "string" then
                    return s
                end
                local ok, enum = pcall(function()
                    return ItemBodyLocation.get(ResourceLocation.of(s))
                end)
                if ok and enum then return enum end
                return s
            end

            local function applyWornItemToDesc(item)
                if not item then return end
                local loc = item.getBodyLocation and item:getBodyLocation()
                if not loc or loc == "" then return end
                local bodyLoc = resolveDescBodyLoc(loc, item)
                if bodyLoc then
                    pcall(function() desc:setWornItem(bodyLoc, item) end)
                end
            end

            local worn = desc:getWornItems()
            if worn and worn.clear then worn:clear() end

            local lsByFullType = {}
            if type(app.clothingVisuals) == "table" then
                for _, ls in ipairs(app.clothingVisuals) do
                    if type(ls) == "string" and ls ~= "" and ItemVisual and ItemVisual.createLastStandItem then
                        local ok, it = pcall(function() return ItemVisual.createLastStandItem(ls) end)
                        if ok and it and it.getFullType then
                            local okf, ft = pcall(function() return it:getFullType() end)
                            if okf and type(ft) == "string" and ft ~= "" and not lsByFullType[ft] then
                                lsByFullType[ft] = ls
                            end
                        end
                    end
                end
            end

            local wornRows = {}
            for _, itemData in ipairs(slot.inventory or {}) do
                local wl = itemData.wornLoc
                local hasWl = wl ~= nil and tostring(wl) ~= ""
                if itemData.lastStandStr or (itemData.fullType and hasWl) then
                    wornRows[#wornRows + 1] = itemData
                end
            end

            local nLsMap = 0
            for _ in pairs(lsByFullType) do
                nLsMap = nLsMap + 1
            end
            local invRows = #(slot.inventory or {})
            local nLsInv = 0
            for _, r in ipairs(slot.inventory or {}) do
                if r and r.lastStandStr and r.lastStandStr ~= "" then nLsInv = nLsInv + 1 end
            end
            if We and We.logAppearance then
                We.logAppearance(string.format(
                    "portrait inactive slot=%s invRows=%d wornRows=%d clothingVisuals=%d lsMapByFullType=%d invRowsWithLS=%d humanVisualLS=%s",
                    tostring(slotIndex),
                    invRows,
                    #wornRows,
                    type(app.clothingVisuals) == "table" and #app.clothingVisuals or 0,
                    nLsMap,
                    nLsInv,
                    (app.humanVisualLS and type(app.humanVisualLS) == "string" and #app.humanVisualLS > 0) and ("yes,len=" .. tostring(#app.humanVisualLS)) or "no"
                ))
            end

            if #wornRows > 0 then
                local wearDbgLeft = 10
                table.sort(wornRows, function(a, b)
                    return portraitWearSortKey(inferSortLocStr(a)) < portraitWearSortKey(inferSortLocStr(b))
                end)
                for _, itemData in ipairs(wornRows) do
                    local ls = itemData.lastStandStr
                    local fromMap = false
                    if (not ls or ls == "") and itemData.fullType then
                        ls = lsByFullType[itemData.fullType]
                        fromMap = ls ~= nil
                    end
                    local item = nil
                    if ls and ItemVisual and ItemVisual.createLastStandItem then
                        local okLs, it = pcall(function() return ItemVisual.createLastStandItem(ls) end)
                        if okLs then item = it end
                    end
                    if not item and itemData.fullType and itemData.wornLoc and tostring(itemData.wornLoc) ~= "" then
                        item = instanceItem(itemData.fullType)
                        if item and item.setCondition and itemData.condition ~= nil then
                            pcall(item.setCondition, item, tonumber(itemData.condition) or 100)
                        end
                    end
                    if We and We.logAppearance and wearDbgLeft > 0 then
                        wearDbgLeft = wearDbgLeft - 1
                        We.logAppearance(string.format(
                            "portrait wear: ft=%s loc=%s ls=%s fromMap=%s item=%s",
                            tostring(itemData.fullType),
                            tostring(itemData.wornLoc),
                            ls and "yes" or "no",
                            tostring(fromMap),
                            item and "ok" or "nil"
                        ))
                    end
                    applyWornItemToDesc(item)
                end
            elseif type(app.clothingVisuals) == "table" and #app.clothingVisuals > 0 then
                local lsOnly = {}
                for _, ls in ipairs(app.clothingVisuals) do
                    if type(ls) == "string" and ls ~= "" then
                        lsOnly[#lsOnly + 1] = ls
                    end
                end
                table.sort(lsOnly, function(a, b)
                    return portraitWearSortKey(inferSortLocFromLsString(a))
                        < portraitWearSortKey(inferSortLocFromLsString(b))
                end)
                for _, ls in ipairs(lsOnly) do
                    if ItemVisual and ItemVisual.createLastStandItem then
                        local ok, item = pcall(function() return ItemVisual.createLastStandItem(ls) end)
                        if ok and item then applyWornItemToDesc(item) end
                    end
                end
            end
        end

        local attachRows = (WeNPC and WeNPC.collectHotbarAttachRows) and WeNPC.collectHotbarAttachRows(slot.inventory) or {}

        pcall(function() self.portraitPanel:setCharacter(nil) end)

        local attOk, attWhy = false, "none"
        if #attachRows > 0 and WeNPC and WeNPC.applyAttachmentsToDescForPreview then
            attOk, attWhy = WeNPC.applyAttachmentsToDescForPreview(desc, attachRows)
        end
        if We and We.logAppearance then
            We.logAppearance(string.format(
                "portrait inactive setSurvivorDesc slot=%s attachRows=%d descAttachPreview=%s %s",
                tostring(slotIndex),
                #attachRows,
                tostring(attOk),
                tostring(attWhy)
            ))
        end

        local okSet = pcall(self.portraitPanel.setSurvivorDesc, self.portraitPanel, desc)

        if not okSet then
            self._portraitDisabled = true
            self.portraitPanel:setVisible(false)
            print("[We] portrait disabled: setSurvivorDesc/setCharacter failed")
            return
        end
        -- Do NOT call setOutfitName("Foreman") here: it resets the preview to a clean default outfit.
        end
    end
    if self.portraitPanel and self.portraitPanel.setZoom then self.portraitPanel:setZoom(14) end
    if self.portraitPanel and self.portraitPanel.setYOffset then self.portraitPanel:setYOffset(-0.85) end

    self.profLabel.name = We.getText("UI_We_Portrait_Profession")
    self:addProfessionIcon(slot)
    self.perksLabel.name = We.getText("UI_We_Portrait_Perks")
    self:addTraitIcons(slot)
    local traitCount = #(slot.traits or {})
    local traitRows = math.max(1, math.ceil(traitCount / 3))
    self.moodlesLabel:setY(self.perksLabel.y + 20 + traitRows * 18 + 4)
    self.moodlesLabel.name = We.getText("UI_We_Moodles")
    self:addMoodleIcons(slot, slotIndex)
    if self.portraitPanel and not self._portraitDisabled then
        self.portraitPanel:setVisible(true)
        self:setPortraitDetailsVisible(true)
    else
        self:clearProfessionIcon()
        self:clearTraitIcons()
        self:clearMoodleIcons()
        self:setPortraitDetailsVisible(false)
    end
end

function WeRosterPanel:refreshRows()
    local data   = WeData.getData()
    local atBase = WeData.isAtHomeBase()
    local deathMode = data and data._deathSelectionMode == true
    if WeTabPanel then
        WeTabPanel.moveWithMouse = not deathMode
        if WeTabPanel._closeBtn then
            WeTabPanel._closeBtn:setVisible(not deathMode)
        end
        if deathMode then
            local sw = getCore():getScreenWidth()
            local sh = getCore():getScreenHeight()
            local px = math.floor(sw / 2 - WeTabPanel.width / 2)
            local py = math.floor(sh / 2 - WeTabPanel.height / 2)
            WeTabPanel:setX(px)
            WeTabPanel:setY(py)
        end
    end

    -- Keep portrait/traits/moodles behavior identical for alive and post-death modes.
    if self.slotList then
        self.slotList:setWidth(self.width - PORTRAIT_W - PADDING - 8)
    end

    -- Status label
    if deathMode then
        self.baseStatusLabel.name = We.getText("UI_We_Status_PostDeath")
        self.baseStatusLabel.r, self.baseStatusLabel.g, self.baseStatusLabel.b = 0.3, 0.9, 0.4
    elseif atBase then
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
    local selectedValid = selected and slotHasCharacterData(WeData.getSlot(selected))
    if self._forceNoPortraitSelection then
        self.selectedPortraitSlot = nil
        self:updatePortraitForSlot(nil)
    elseif selectedValid then
        self:updatePortraitForSlot(selected)
    elseif active and slotHasCharacterData(WeData.getSlot(active)) then
        self.selectedPortraitSlot = active
        self:updatePortraitForSlot(active)
    else
        self.selectedPortraitSlot = nil
        self:updatePortraitForSlot(nil)
    end

    -- Remove button: SP only, when home is set, player alive and currently at safehouse.
    local isMP = getWorld and getWorld():getGameMode() == "Multiplayer"
    local p = getSpecificPlayer(0)
    local alive = p and (not (p.isDead and p:isDead()))
    self.removeHomeBtn:setVisible(not isMP and data.homeX ~= nil and atBase and alive == true)
end

function WeRosterPanel:update()
    local data = WeData and WeData.getData and WeData.getData()
    local deathMode = data and data._deathSelectionMode == true
    if WeTabPanel and deathMode then
        WeTabPanel.moveWithMouse = false
        local sw = getCore():getScreenWidth()
        local sh = getCore():getScreenHeight()
        local px = math.floor(sw / 2 - WeTabPanel.width / 2)
        local py = math.floor(sh / 2 - WeTabPanel.height / 2)
        if WeTabPanel:getX() ~= px or WeTabPanel:getY() ~= py then
            WeTabPanel:setX(px)
            WeTabPanel:setY(py)
        end
    end

    -- Fast-path: keep active selected portrait live (clothes/moodles change in real time).
    self._portraitTick = (self._portraitTick or 0) + 1
    if self._portraitTick >= 20 then
        self._portraitTick = 0
        if self._forceNoPortraitSelection then
            self:updatePortraitForSlot(nil)
            return
        end
        local selected = self.selectedPortraitSlot
        local active = WeData.getActiveSlot()
        if selected and selected == active and WeData.getSlot(selected) then
            self:updatePortraitForSlot(selected)
        end
    end

    -- Full row rebuild less frequently to avoid UI churn.
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
    local p = getSpecificPlayer(0)
    if not p or (p.isDead and p:isDead()) or not WeData.isAtHomeBase() then
        return
    end
    WeData.clearHome()
    self:refreshRows()
    if p then
        HaloTextHelper.addText(p, We.getText("UI_We_HomeRemoved"))
    end
end

function WeRosterPanel:onSwitchClick(slotIndex)
    print("[We][DbgSwitch] onSwitchClick slot=" .. tostring(slotIndex)
        .. " activeBefore=" .. tostring(WeData.getActiveSlot()))
    local data = WeData and WeData.getData and WeData.getData()
    if data and data._deathSelectionMode == true and WeData.requestVanillaRespawnForDeathSlot then
        local ok = WeData.requestVanillaRespawnForDeathSlot(slotIndex)
        print("[We][DbgSwitch] onSwitchClick(deathMode) result=" .. tostring(ok))
        self:refreshRows()
        if ok and WeTabPanel then
            WeTabPanel:setVisible(false)
        end
        return
    end

    local ok = WeData.switchTo(slotIndex)
    print("[We][DbgSwitch] onSwitchClick result=" .. tostring(ok)
        .. " activeAfter=" .. tostring(WeData.getActiveSlot()))
    if ok then
        self._forceNoPortraitSelection = false
        self.selectedPortraitSlot = WeData.getActiveSlot()
        self:updatePortraitForSlot(self.selectedPortraitSlot)
    end
    self:refreshRows()
    if ok and WeTabPanel then
        WeTabPanel:setVisible(false)
    end
end

function WeRosterPanel:onAddClick()
    -- Find the first unused slot and switch to it (triggers character creation)
    local data = WeData.getData()
    local deathMode = data and data._deathSelectionMode == true
    print("[We][DbgSwitch] onAddClick begin active=" .. tostring(WeData.getActiveSlot()))
    for i = 1, We.MAX_SLOTS do
        if not data.slots[i] or data.slots[i].x == nil then
            print("[We][DbgSwitch] onAddClick picked slot=" .. tostring(i))
            local ok = nil
            if deathMode and WeData.requestVanillaRespawnForDeathSlot then
                ok = WeData.requestVanillaRespawnForDeathSlot(i)
            else
                ok = WeData.switchTo(i)
            end
            print("[We][DbgSwitch] onAddClick result=" .. tostring(ok)
                .. " activeAfter=" .. tostring(WeData.getActiveSlot()))
            if ok then
                self._forceNoPortraitSelection = false
                self.selectedPortraitSlot = WeData.getActiveSlot()
                self:updatePortraitForSlot(self.selectedPortraitSlot)
            end
            self:refreshRows()
            if ok and WeTabPanel then
                WeTabPanel:setVisible(false)
            end
            return
        end
    end
end

function WeRosterPanel:onKickClick(slotIndex)
    local actor = getSpecificPlayer(0)
    if not actor or (actor.isDead and actor:isDead()) then return end
    local slot = WeData.getSlot(slotIndex)
    if not slot then return end
    if slotIndex == WeData.getActiveSlot() then return end

    local displayName = tostring(slot.name or We.getText("UI_We_SlotFallback", tostring(slotIndex)))
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

function openWeTabPanel(userPanel, forceOpen)
    -- Toggle: close if already open (skip when forceOpen — e.g. post-death roster must show, not hide).
    forceOpen = forceOpen == true
    -- Death flow often leaves ISUIHandler.allUIVisible false / HUD hidden; restore before showing panel.
    if forceOpen and WeData and WeData.restoreGameHudVisibility then
        WeData.restoreGameHudVisibility()
    end
    if not forceOpen and WeTabPanel and WeTabPanel:isVisible() then
        local dataNow = WeData and WeData.getData and WeData.getData()
        if dataNow and dataNow._deathSelectionMode == true then
            return
        end
        WeTabPanel:setVisible(false)
        return
    end

    if forceOpen and WeTabPanel then
        local dataNow = WeData and WeData.getData and WeData.getData()
        local deathModeNow = dataNow and dataNow._deathSelectionMode == true
        local sw = getCore():getScreenWidth()
        local sh = getCore():getScreenHeight()
        local px = math.floor(sw / 2 - WeTabPanel.width / 2)
        local py = math.floor(sh / 2 - WeTabPanel.height / 2)
        WeTabPanel:setX(px)
        WeTabPanel:setY(py)
        WeTabPanel.moveWithMouse = not deathModeNow
        if WeTabPanel._closeBtn then
            WeTabPanel._closeBtn:setVisible(not deathModeNow)
        end
        -- If already open, re-open to force a clean refresh of row content/state.
        if WeTabPanel:isVisible() then
            WeTabPanel:setVisible(false)
        end
        WeTabPanel:setVisible(true)
        if WeTabPanel.weRosterPanel and WeTabPanel.weRosterPanel.refreshRows then
            WeTabPanel.weRosterPanel:refreshRows()
        end
        if WeTabPanel.setAlwaysOnTop then WeTabPanel:setAlwaysOnTop(true) end
        if WeTabPanel.bringToTop then WeTabPanel:bringToTop() end
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
        if key == Keyboard.KEY_ESCAPE then
            local dataNow = WeData and WeData.getData and WeData.getData()
            if dataNow and dataNow._deathSelectionMode == true then
                return
            end
            self:setVisible(false)
        end
    end
    WeTabPanel:initialise()
    WeTabPanel:addToUIManager()

    -- Close button in the tab bar
    local closeBtn = ISButton:new(PANEL_W - 22, 2, 18, TAB_H - 4, "x", WeTabPanel,
        function(panel)
            local dataNow = WeData and WeData.getData and WeData.getData()
            if dataNow and dataNow._deathSelectionMode == true then
                return
            end
            panel:setVisible(false)
        end)
    closeBtn.backgroundColor          = {r=0.5, g=0.1, b=0.1, a=1}
    closeBtn.backgroundColorMouseOver = {r=0.8, g=0.2, b=0.2, a=1}
    closeBtn:initialise()
    WeTabPanel:addChild(closeBtn)
    WeTabPanel._closeBtn = closeBtn

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
    WeTabPanel.weRosterPanel = rosterView
    WeTabPanel:activateView(We.getText("UI_We_Tab_Characters"))
end

-- Death swap / switch: visible ISTabPanel captures WASD for UI; IsoPlayer flags stay false — looks like "movement broken".
function We.closeWeTabPanelIfOpen()
    if not WeTabPanel then return end
    if WeTabPanel:isVisible() then
        WeTabPanel:setVisible(false)
        print("[We] WeTabPanel closed (keyboard was likely captured by the Characters UI)")
    end
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
