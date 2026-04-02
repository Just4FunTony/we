-- Vanilla ISAttachItemHotbar calls hotbar.chr:setAttachedItem(self.slot, self.item) without guards.
-- B42 often throws NPE in ReturnValues.put (LuaJavaInvoker) — queue is marked bugged and attachments strip.
-- We reimplement attachConnect / perform for the dangerous calls only, everything else matches vanilla.

local function applyPatch()
    if ISAttachItemHotbar and ISAttachItemHotbar._wePatchedAttachHotbar then
        return
    end
    require "TimedActions/ISAttachItemHotbar"
    if not ISAttachItemHotbar then
        return
    end

    local origAnimEvent = ISAttachItemHotbar.animEvent

    function ISAttachItemHotbar:animEvent(event, parameter)
        if event ~= "attachConnect" then
            return origAnimEvent(self, event, parameter)
        end

        -- Client: preview attach on model during animation (vanilla ISAttachItemHotbar.lua:84-88).
        -- Vanilla previewed attach here (hotbar.chr:setAttachedItem). That Java call often NPEs (ReturnValues.put) and still logs inside pcall.
        -- Final attach runs in perform(); skipping preview only affects one animation frame.
        if not isServer() and self.character then
            if self.item then
                local okId, id = pcall(function() return self.item:getID() end)
                if okId and id then
                    local inv = self.character.getInventory and self.character:getInventory()
                    if inv and inv.getItemById then
                        local fresh = inv:getItemById(id)
                        if fresh then
                            self.item = fresh
                        end
                    end
                end
            end
            pcall(function()
                self:setOverrideHandModels(nil, nil)
            end)
        end

        if self.character and self.item then
            pcall(function()
                if self.character:isEquipped(self.item) then
                    self.character:removeFromHands(self.item)
                end
            end)
        end

        if self.maxTime == -1 then
            if isServer() then
                pcall(function()
                    self.netAction:forceComplete()
                end)
            else
                pcall(function()
                    self:forceComplete()
                end)
            end
        end
    end

    function ISAttachItemHotbar:perform()
        -- Vanilla perform calls hotbar.chr:setAttachedItem (line 67). Reimplemented so a failed attach still completes the queue entry.
        if not self.hotbar or not self.character or not self.item or not self.slotDef then
            pcall(ISBaseTimedAction.perform, self)
            return
        end
        local prev = self.hotbar.attachedItems and self.hotbar.attachedItems[self.slotIndex]
        if prev then
            pcall(function()
                self.hotbar.chr:removeAttachedItem(prev)
            end)
            pcall(function()
                prev:setAttachedSlot(-1)
                prev:setAttachedSlotType(nil)
                prev:setAttachedToModel(nil)
            end)
        end
        if self.slotDef and self.slotDef.name == "Back" and self.hotbar and self.hotbar.replacements
            and self.item and self.hotbar.replacements[self.item:getAttachmentType()] then
            self.slot = self.hotbar.replacements[self.item:getAttachmentType()]
            if self.slot == "null" then
                self.hotbar:removeItem(self.item)
                pcall(ISBaseTimedAction.perform, self)
                return
            end
        end
        if self.slot == "null" then
            self.hotbar:removeItem(self.item)
            pcall(ISBaseTimedAction.perform, self)
            return
        end
        local okAttach = pcall(function()
            self.hotbar.chr:setAttachedItem(self.slot, self.item)
        end)
        if not okAttach then
            pcall(ISBaseTimedAction.perform, self)
            return
        end
        pcall(function()
            self.item:setAttachedSlot(self.slotIndex)
            self.item:setAttachedSlotType(self.slotDef.type)
            self.item:setAttachedToModel(self.slot)
        end)
        pcall(function()
            self.hotbar:reloadIcons()
        end)
        ISInventoryPage.renderDirty = true
        pcall(function()
            syncItemFields(self.character, self.item)
        end)
        pcall(ISBaseTimedAction.perform, self)
    end

    ISAttachItemHotbar._wePatchedAttachHotbar = true
end

Events.OnGameStart.Add(applyPatch)
