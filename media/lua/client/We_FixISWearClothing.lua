-- Vanilla ISWearClothing:perform line 92 triggerEvent("OnClothingUpdated") hits ReturnValues.put NPE on B42 after slot switch.
-- Wrapping the whole perform in pcall still logs Java exceptions. Reimplement perform: defer clothing UI event + isolate Java bits.

local function applyPatch()
    if ISWearClothing and ISWearClothing._wePatchedWearClothing then
        return
    end
    require "TimedActions/ISWearClothing"
    if not ISWearClothing then
        return
    end

    function ISWearClothing:perform()
        self:stopSound()
        if not self.item or not self.character then
            pcall(ISBaseTimedAction.perform, self)
            return
        end

        pcall(function() self.item:setJobDelta(0.0) end)
        pcall(function()
            local c = self.item:getContainer()
            if c and c.setDrawDirty then
                c:setDrawDirty(true)
            end
        end)
        pcall(function()
            if (self.item:IsInventoryContainer() or self.item:hasTag(ItemTag.WEARABLE))
                and self.item:canBeEquipped() ~= "" then
                local pi = getPlayerInventory(self.character:getPlayerNum())
                if pi and pi.refreshBackpacks then
                    pi:refreshBackpacks()
                end
            end
        end)

        local chr = self.character
        local once
        once = function()
            Events.OnTick.Remove(once)
            if chr then
                pcall(function()
                    triggerEvent("OnClothingUpdated", chr)
                end)
            end
        end
        Events.OnTick.Add(once)

        ISInventoryPage.renderDirty = true
        pcall(ISBaseTimedAction.perform, self)
    end

    ISWearClothing._wePatchedWearClothing = true
end

Events.OnGameStart.Add(applyPatch)
