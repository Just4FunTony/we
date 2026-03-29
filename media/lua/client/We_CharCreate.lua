-- We: New character creation — random profession + balanced traits.
-- Called when a player first switches into an empty slot.

WeCharCreate = WeCharCreate or {}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function pickRandom(pool, n)
    local copy   = {table.unpack(pool)}
    local result = {}
    n = math.min(n, #copy)
    for _ = 1, n do
        local idx    = ZombRand(#copy) + 1
        result[#result+1] = copy[idx]
        table.remove(copy, idx)
    end
    return result
end

local function collectPositiveTraits()
    local out = {}
    local all = TraitFactory.getTraits()
    for i = 0, all:size()-1 do
        local t = all:get(i)
        if t:getCost() > 0 then out[#out+1] = t:getType() end
    end
    return out
end

local function collectNegativeTraits()
    local out = {}
    local all = TraitFactory.getTraits()
    for i = 0, all:size()-1 do
        local t = all:get(i)
        if t:getCost() < 0 then out[#out+1] = t:getType() end
    end
    return out
end

local function collectProfessions()
    local out  = {}
    local all  = ProfessionFactory.getProfessions()
    for i = 0, all:size()-1 do
        out[#out+1] = all:get(i):getType()
    end
    return out
end

local function traitName(typeStr)
    local t = TraitFactory.getTrait(typeStr)
    return t and t:getName() or typeStr
end

local function profName(typeStr)
    local p = ProfessionFactory.getProfession(typeStr)
    return p and p:getName() or typeStr
end

-- ─── Core: apply random loadout to player ────────────────────────────────────

function WeCharCreate.randomize(player)
    local desc = player:getDescriptor()
    local n    = 1 + ZombRand(3)   -- 1, 2 or 3

    -- Random profession
    local profs    = collectProfessions()
    local profType = profs[ZombRand(#profs) + 1]

    -- Random balanced traits
    local posTraits = pickRandom(collectPositiveTraits(), n)
    local negTraits = pickRandom(collectNegativeTraits(), n)

    -- Clear any existing selectable traits
    local allTraits = TraitFactory.getTraits()
    for i = 0, allTraits:size()-1 do
        local t = allTraits:get(i)
        if desc:hasTrait(t:getType()) then
            desc:removeTrait(t:getType())
        end
    end

    -- Set profession
    desc:setProfession(profType)

    -- Apply profession's free traits and XP boosts
    local prof = ProfessionFactory.getProfession(profType)
    if prof then
        local freeTraits = prof:getFreeTraits()
        if freeTraits then
            for i = 0, freeTraits:size()-1 do
                local ft = freeTraits:get(i)
                if not desc:hasTrait(ft) then desc:addTrait(ft) end
            end
        end
        local xpBoosts = prof:getXPBoostList()
        if xpBoosts then
            local xpSys = player:getXp()
            for i = 0, xpBoosts:size()-1 do
                local boost = xpBoosts:get(i)
                local perk  = boost:getPerk()
                local amt   = boost:getBoost()
                if perk and amt then xpSys:AddXP(perk, amt) end
            end
        end
    end

    -- Apply selected traits
    for _, t in ipairs(posTraits) do
        if not desc:hasTrait(t) then desc:addTrait(t) end
    end
    for _, t in ipairs(negTraits) do
        if not desc:hasTrait(t) then desc:addTrait(t) end
    end

    -- Reset stats to a clean start
    local stats = player:getStats()
    stats:setHunger(0.1)
    stats:setThirst(0.1)
    stats:setFatigue(0)
    stats:setBoredom(0)
    stats:setStress(0)
    stats:setPanic(0)
    stats:setPain(0)
    stats:setEndurance(1)
    stats:setUnhappiness(0)

    -- Fresh inventory
    player:getInventory():clear()

    return {
        profession = profType,
        positive   = posTraits,
        negative   = negTraits,
    }
end

-- ─── Notification popup ───────────────────────────────────────────────────────
-- Shows a small panel with the new character's rolled loadout.

local WeCharCreatePopup = ISPanel:derive("WeCharCreatePopup")

function WeCharCreatePopup:new(summary)
    local lines = {}
    lines[#lines+1] = profName(summary.profession)
    for _, t in ipairs(summary.positive) do
        lines[#lines+1] = "+ " .. traitName(t)
    end
    for _, t in ipairs(summary.negative) do
        lines[#lines+1] = "- " .. traitName(t)
    end

    local W    = 240
    local LH   = 18
    local H    = 36 + #lines * LH + 12
    local sw   = getCore():getScreenWidth()
    local sh   = getCore():getScreenHeight()
    local o    = ISPanel.new(self, (sw - W) / 2, sh * 0.18, W, H)
    o.backgroundColor = {r=0.05, g=0.05, b=0.10, a=0.95}
    o.borderColor     = {r=0.4,  g=0.7,  b=0.4,  a=1}
    o.moveWithMouse   = true
    o.lines           = lines
    o.summary         = summary
    return o
end

function WeCharCreatePopup:initialise()
    ISPanel.initialise(self)

    local title = ISLabel:new(12, 8, 20,
        getText("UI_We_NewChar_Title"), 0.4, 0.9, 0.4, 1, UIFont.Small, true)
    self:addChild(title)

    local closeBtn = ISButton:new(self.width - 24, 4, 20, 20, "x", self,
        function(btn) btn:getParent():setVisible(false) end)
    closeBtn.backgroundColor          = {r=0.5, g=0.1, b=0.1, a=1}
    closeBtn.backgroundColorMouseOver = {r=0.8, g=0.2, b=0.2, a=1}
    self:addChild(closeBtn)

    local LH = 18
    local y  = 30
    for i, line in ipairs(self.lines) do
        local r, g, b = 1, 1, 1
        if line:sub(1,1) == "+" then r,g,b = 0.4, 0.9, 0.4
        elseif line:sub(1,1) == "-" then r,g,b = 0.9, 0.4, 0.4
        else r,g,b = 0.9, 0.8, 0.3  -- profession line
        end
        local lbl = ISLabel:new(12, y, LH, line, r, g, b, 1, UIFont.Small, true)
        self:addChild(lbl)
        y = y + LH
    end
end

function WeCharCreate.showPopup(summary)
    local popup = WeCharCreatePopup:new(summary)
    popup:initialise()
    popup:addToUIManager()
end
