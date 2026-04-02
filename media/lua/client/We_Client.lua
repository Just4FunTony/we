-- We: Client entry point — initialisation and NPC startup.

local _initDone = false
local _initTries = 0
local MAX_INIT_TRIES = 300 -- ~5s at 60 FPS
local _postDeathHudRestoreTicks = 0

local function tryInit(tag)
    if _initDone then return true end
    _initTries = _initTries + 1

    local dataReady = WeData and WeData.init and WeData.getData
    local npcReady  = WeNPC and WeNPC.init
    if dataReady and npcReady then
        WeData.init()
        WeNPC.init()
        _initDone = true
        print("[We] Client ready (" .. tostring(tag) .. "). Press O to open the character panel.")
        return true
    end

    if _initTries == 1 or (_initTries % 30) == 0 then
        print("[We][Init] Waiting modules"
            .. " | try=" .. tostring(_initTries)
            .. " | WeData=" .. tostring(dataReady ~= nil and dataReady ~= false)
            .. " | WeNPC=" .. tostring(npcReady ~= nil and npcReady ~= false))
    end
    return false
end

local function onGameStart()
    if tryInit("OnGameStart") then return end
    print("[We][Init] Delayed init enabled")
end

local function onTick()
    -- Death flow override: hide vanilla death buttons and open roster menu.
    local pd = ISPostDeathUI and ISPostDeathUI.instance and ISPostDeathUI.instance[0]
    local rosterData = WeData and WeData.getData and WeData.getData()
    if pd and rosterData and rosterData._openDeathRoster then
        if pd.buttonRespawn then pd.buttonRespawn:setVisible(false) end
        if pd.buttonExit then pd.buttonExit:setVisible(false) end
        if pd.buttonQuit then pd.buttonQuit:setVisible(false) end
        if _initDone then
            print("[We][DbgSwitch] We_Client onTick open roster (no auto-switch)")
            -- IMPORTANT: do NOT revive here.
            -- Your requirement: vanilla death -> roster menu -> respawn/apply slot state only after user click.
            -- We keep ISPostDeathUI instance alive so our requestVanillaRespawnForDeathSlot(slotIndex)
            -- can call pd:onRespawn later.
            if pd.setVisible then pd:setVisible(false) end
            rosterData._openDeathRoster = false
            if WeData and WeData.restoreGameHudVisibility then
                WeData.restoreGameHudVisibility()
            end
            openWeTabPanel(nil, true)
            -- UIManager can still be one frame behind; re-apply HUD visibility briefly after death panel.
            _postDeathHudRestoreTicks = 10
        end
    end

    if _postDeathHudRestoreTicks > 0 then
        _postDeathHudRestoreTicks = _postDeathHudRestoreTicks - 1
        if WeData and WeData.restoreGameHudVisibility then
            WeData.restoreGameHudVisibility()
        end
    end

    if _initDone then return end
    if _initTries >= MAX_INIT_TRIES then
        print("[We][Init] Failed to initialize after " .. tostring(_initTries) .. " tries")
        return
    end
    tryInit("OnTick")
end

-- O opens the Characters panel in both SP and MP
local function onKeyPressed(key)
    if key == Keyboard.KEY_O then
        if getSpecificPlayer(0) then
            openWeTabPanel(nil)
        end
    end
end

Events.OnGameStart.Add(onGameStart)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnTick.Add(onTick)
