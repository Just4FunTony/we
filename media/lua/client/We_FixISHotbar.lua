-- ISHotbar:attachItem (instant path) calls chr:setAttachedItem — B42 ReturnValues.put NPE even when slot is non-nil.
-- Do not call vanilla orig for the instant branch: duplicate logic and wrap only setAttachedItem in pcall; skip reload if it fails.

local function applyPatch()
    if ISHotbar and ISHotbar._wePatchedAttachItem then
        return
    end
    require "Hotbar/ISHotbar"
    if not ISHotbar or not ISHotbar.attachItem then
        return
    end

    local orig = ISHotbar.attachItem
    function ISHotbar:attachItem(item, slot, slotIndex, slotDef, doAnim)
        if doAnim then
            return orig(self, item, slot, slotIndex, slotDef, doAnim)
        end
        if not item or not slotDef or not self.chr then
            return
        end

        local s = slot
        if slotDef.name == "Back" and self.replacements and self.replacements[item:getAttachmentType()] then
            s = self.replacements[item:getAttachmentType()]
            if s == "null" then
                self:removeItem(item, false)
                return
            end
        end
        if s == "null" then
            self:removeItem(item, false)
            return
        end
        if s == nil or s == "" then
            return
        end

        local inv = self.chr.getInventory and self.chr:getInventory()
        if inv and inv.contains and not inv:contains(item) then
            return
        end

        local ok = pcall(function()
            self.chr:setAttachedItem(s, item)
        end)
        if not ok then
            return
        end
        pcall(function() item:setAttachedSlot(slotIndex) end)
        pcall(function() item:setAttachedSlotType(slotDef.type) end)
        pcall(function() item:setAttachedToModel(s) end)
        self:reloadIcons()
    end

    ISHotbar._wePatchedAttachItem = true
end

Events.OnGameStart.Add(applyPatch)
