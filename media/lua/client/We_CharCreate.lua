-- We: New character creation — random profession + balanced traits (B42 API).
-- Called when a player first switches into an empty slot.

WeCharCreate = WeCharCreate or {}

-- ─── Name tables ──────────────────────────────────────────────────────────────

local MALE_NAMES   = {"James","John","Robert","Michael","William","David","Richard","Joseph","Thomas","Charles","Daniel","Matthew","Anthony","Mark","Donald","Steven","Paul","Andrew","Kenneth","George"}
local FEMALE_NAMES = {"Mary","Patricia","Jennifer","Linda","Barbara","Elizabeth","Susan","Jessica","Sarah","Karen","Lisa","Nancy","Betty","Margaret","Sandra","Ashley","Dorothy","Kimberly","Emily","Donna"}
local SURNAMES     = {"Smith","Johnson","Williams","Brown","Jones","Davis","Miller","Wilson","Moore","Taylor","Anderson","Thomas","Jackson","White","Harris","Martin","Clark","Lewis","Walker","Hall"}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function pickRandom(pool, n)
    local copy   = {unpack(pool)}
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
    local all = CharacterTraitDefinition.getTraits()
    for i = 0, all:size()-1 do
        local t = all:get(i)
        if not t:isFree() and t:getCost() > 0 then out[#out+1] = t end
    end
    return out
end

local function collectNegativeTraits()
    local out = {}
    local all = CharacterTraitDefinition.getTraits()
    for i = 0, all:size()-1 do
        local t = all:get(i)
        if not t:isFree() and t:getCost() < 0 then out[#out+1] = t end
    end
    return out
end

local function collectProfessions()
    local out = {}
    local all = CharacterProfessionDefinition.getProfessions()
    for i = 0, all:size()-1 do
        out[#out+1] = all:get(i)
    end
    return out
end

-- ─── Core: apply random loadout to player ────────────────────────────────────

function WeCharCreate.randomize(player)
    local desc = player:getDescriptor()
    local n    = 1 + ZombRand(3)   -- 1, 2 or 3

    -- ── Gender ────────────────────────────────────────────────────────────────
    local isFemale = (ZombRand(2) == 0)
    player:setFemale(isFemale)
    if desc then
        desc:setFemale(isFemale)
        desc:setVoicePrefix(isFemale and "VoiceFemale" or "VoiceMale")
    end

    -- ── Name ──────────────────────────────────────────────────────────────────
    local namePool = isFemale and FEMALE_NAMES or MALE_NAMES
    local forename = namePool[ZombRand(#namePool) + 1]
    local surname  = SURNAMES[ZombRand(#SURNAMES) + 1]
    if desc then
        desc:setForename(forename)
        desc:setSurname(surname)
    end

    -- ── Appearance ────────────────────────────────────────────────────────────
    local vis = player:getHumanVisual()
    if vis then
        -- Random skin tone (B42 uses index, 0-based; ~8 tones available)
        vis:setSkinTextureIndex(ZombRand(8))

        -- Random hair from available styles
        local hairStyles = getAllHairStyles and getAllHairStyles(isFemale)
        if hairStyles and hairStyles:size() > 0 then
            local style = hairStyles:get(ZombRand(hairStyles:size()))
            vis:setHairModel(style)
        end

        -- Random hair colour
        local r = 0.1 + ZombRand(100) / 120.0
        local g = 0.05 + ZombRand(80) / 160.0
        local b = 0.02 + ZombRand(60) / 200.0
        vis:setHairColor(ImmutableColor.new(r, g, b, 1))

        if not isFemale then
            -- Optional random beard (50 % chance)
            if ZombRand(2) == 0 then
                local beardStyles = getAllHairStyles and getAllHairStyles(false)
                if beardStyles and beardStyles:size() > 0 then
                    vis:setBeardModel(beardStyles:get(ZombRand(beardStyles:size())))
                end
            else
                vis:setBeardModel("")
            end
            vis:setBeardColor(ImmutableColor.new(r, g, b, 1))
        end
    end

    -- Random profession
    local profs  = collectProfessions()
    local profDef = profs[ZombRand(#profs) + 1]

    -- Random balanced traits
    local posTraitDefs = pickRandom(collectPositiveTraits(), n)
    local negTraitDefs = pickRandom(collectNegativeTraits(), n)

    -- Clear all current traits
    player:getCharacterTraits():getKnownTraits():clear()

    -- Set profession
    desc:setCharacterProfession(profDef:getType())

    -- Apply granted (free) traits from profession
    local grantedTraits = profDef:getGrantedTraits()
    if grantedTraits then
        local knownTraits = player:getCharacterTraits():getKnownTraits()
        for i = 0, grantedTraits:size()-1 do
            local traitEnum = grantedTraits:get(i)
            if not player:hasTrait(traitEnum) then
                knownTraits:add(traitEnum)
            end
        end
    end

    -- Apply XP boosts from profession
    local xpBoostRaw = profDef:getXpBoosts()
    if xpBoostRaw then
        local xpBoosts = transformIntoKahluaTable(xpBoostRaw)
        local xpSys = player:getXp()
        for perk, level in pairs(xpBoosts) do
            if perk and level then
                xpSys:AddXP(perk, level:intValue())
            end
        end
    end

    -- Apply selected traits
    local knownTraits = player:getCharacterTraits():getKnownTraits()
    for _, t in ipairs(posTraitDefs) do
        if not player:hasTrait(t:getType()) then knownTraits:add(t:getType()) end
    end
    for _, t in ipairs(negTraitDefs) do
        if not player:hasTrait(t:getType()) then knownTraits:add(t:getType()) end
    end

    -- Reset stats to a clean start (B42 API: stats:set(CharacterStat.X, value))
    local stats = player:getStats()
    stats:set(CharacterStat.HUNGER,      0.1)
    stats:set(CharacterStat.THIRST,      0.1)
    stats:set(CharacterStat.FATIGUE,     0)
    stats:set(CharacterStat.BOREDOM,     0)
    stats:set(CharacterStat.STRESS,      0)
    stats:set(CharacterStat.PANIC,       0)
    stats:set(CharacterStat.PAIN,        0)
    stats:set(CharacterStat.UNHAPPINESS, 0)

    -- ── Starting clothing ─────────────────────────────────────────────────────
    -- Clear inventory and add a basic random outfit
    player:getInventory():clear()
    -- Item names verified against B42 generated/items/clothing.txt
    local clothingSets
    if isFemale then
        clothingSets = {
            {"Base.Tshirt_ArmyGreen",  "Base.Trousers_Denim",     "Base.Shoes_Brown"},
            {"Base.Shirt_Denim",       "Base.Trousers_JeanBaggy", "Base.Shoes_BlueTrainers"},
            {"Base.Jumper_VNeck",      "Base.Trousers_OliveDrab", "Base.Shoes_WorkBoots"},
        }
    else
        clothingSets = {
            {"Base.Tshirt_OliveDrab",  "Base.Trousers_Denim",     "Base.Shoes_Brown"},
            {"Base.Shirt_FormalWhite", "Base.Trousers_JeanBaggy", "Base.Shoes_WorkBoots"},
            {"Base.Jumper_RoundNeck",  "Base.Trousers_OliveDrab", "Base.Shoes_BlueTrainers"},
        }
    end
    local chosenSet = clothingSets[ZombRand(#clothingSets) + 1]
    if player.clearWornItems then player:clearWornItems() end
    local inv = player:getInventory()
    for _, itemType in ipairs(chosenSet) do
        local item = instanceItem(itemType)
        if item then
            inv:AddItem(item)
            local loc = item.getBodyLocation and item:getBodyLocation()
            if loc then
                pcall(player.setWornItem, player, loc, item)
            end
        end
    end
    player:resetModelNextFrame()
    player:resetModel()

    -- Build serializable summary (display strings only, no Java objects)
    local posNames = {}
    for _, t in ipairs(posTraitDefs) do posNames[#posNames+1] = t:getLabel() end
    local negNames = {}
    for _, t in ipairs(negTraitDefs) do negNames[#negNames+1] = t:getLabel() end

    return {
        profName = profDef:getUIName(),
        charName = forename .. " " .. surname,
        positive = posNames,
        negative = negNames,
    }
end

-- ─── Notification popup ───────────────────────────────────────────────────────

local WeCharCreatePopup = ISPanel:derive("WeCharCreatePopup")

function WeCharCreatePopup:new(summary)
    local lines = {}
    if summary.charName then lines[#lines+1] = summary.charName end
    lines[#lines+1] = summary.profName
    for _, t in ipairs(summary.positive) do lines[#lines+1] = "+ " .. t end
    for _, t in ipairs(summary.negative) do lines[#lines+1] = "- " .. t end

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
        We.getText("UI_We_NewChar_Title"), 0.4, 0.9, 0.4, 1, UIFont.Small, true)
    self:addChild(title)

    local closeBtn = ISButton:new(self.width - 24, 4, 20, 20, "x", self,
        function(target) target:setVisible(false) end)
    closeBtn.backgroundColor          = {r=0.5, g=0.1, b=0.1, a=1}
    closeBtn.backgroundColorMouseOver = {r=0.8, g=0.2, b=0.2, a=1}
    self:addChild(closeBtn)

    local LH = 18
    local y  = 30
    for i, line in ipairs(self.lines) do
        local r, g, b = 1, 1, 1
        if line:sub(1,1) == "+" then r,g,b = 0.4, 0.9, 0.4
        elseif line:sub(1,1) == "-" then r,g,b = 0.9, 0.4, 0.4
        else r,g,b = 0.9, 0.8, 0.3
        end
        local lbl = ISLabel:new(12, y, LH, line, r, g, b, 1, UIFont.Small, true)
        self:addChild(lbl)
        y = y + LH
    end
end

function WeCharCreatePopup:onKeyPressed(key)
    if key == Keyboard.KEY_ESCAPE then self:setVisible(false) end
end

function WeCharCreate.showPopup(summary)
    local popup = WeCharCreatePopup:new(summary)
    popup:initialise()
    popup:addToUIManager()
end
