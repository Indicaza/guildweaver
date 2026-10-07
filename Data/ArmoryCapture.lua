local _, GW = ...

local function safeCall(func, ...)
    if type(func) ~= "function" then
        return nil
    end

    local ok, value = pcall(func, ...)
    if not ok then
        return nil
    end

    return value
end

local function tooltipData(item)
    if not C_TooltipInfo then
        return nil
    end

    local data = nil
    if type(C_TooltipInfo.GetInventoryItem) == "function" and item.slotId then
        data = safeCall(C_TooltipInfo.GetInventoryItem, "player", item.slotId)
    end
    if type(data) ~= "table" and type(C_TooltipInfo.GetHyperlink) == "function" and item.itemLink then
        data = safeCall(C_TooltipInfo.GetHyperlink, item.itemLink)
    end
    if type(data) ~= "table" then
        return nil
    end

    local lines = {}
    for _, line in ipairs(data.lines or {}) do
        if type(line) == "table" then
            local left = line.leftText or line.text
            local right = line.rightText
            if (type(left) == "string" and left ~= "") or (type(right) == "string" and right ~= "") then
                table.insert(lines, {
                    left = type(left) == "string" and left or nil,
                    right = type(right) == "string" and right or nil,
                    type = line.type,
                })
            end
        end
    end

    return #lines > 0 and lines or nil
end

local function instantItemInfo(item)
    local infoFunction = nil
    if C_Item and type(C_Item.GetItemInfoInstant) == "function" then
        infoFunction = C_Item.GetItemInfoInstant
    elseif type(GetItemInfoInstant) == "function" then
        infoFunction = GetItemInfoInstant
    end

    if not infoFunction then
        return nil
    end

    local source = item.itemLink or item.itemId
    if not source then
        return nil
    end

    local ok, itemId, itemType, itemSubType, equipLocation, icon, classId, subclassId = pcall(infoFunction, source)
    if not ok or not itemId then
        return nil
    end

    return {
        itemId = itemId,
        class = itemType,
        subclass = itemSubType,
        equipLocation = equipLocation,
        icon = icon,
        classId = classId,
        subclassId = subclassId,
    }
end

local function enrichEquipmentItem(item)
    if type(item) ~= "table" then
        return
    end

    local instant = instantItemInfo(item)
    if instant then
        item.itemId = item.itemId or instant.itemId
        item.class = item.class or instant.class
        item.subclass = item.subclass or instant.subclass
        item.equipLocation = item.equipLocation or instant.equipLocation
        item.classId = item.classId or instant.classId
        item.subclassId = item.subclassId or instant.subclassId
        item.icon = item.icon or instant.icon
    end

    if type(item.icon) == "number" then
        item.iconFileDataId = item.icon
    elseif type(item.icon) == "string" and item.icon ~= "" then
        item.iconTexture = item.icon
    end

    if instant and type(instant.icon) == "number" then
        item.iconFileDataId = item.iconFileDataId or instant.icon
    elseif instant and type(instant.icon) == "string" and instant.icon ~= "" then
        item.iconTexture = item.iconTexture or instant.icon
    end

    item.tooltipLines = tooltipData(item) or item.tooltipLines
end

local originalSetCharacterSnapshot = GW.Store.SetCharacterSnapshot

function GW.Store.SetCharacterSnapshot(characterKey, snapshot)
    if type(snapshot) == "table" then
        for _, item in ipairs(snapshot.equipment or {}) do
            enrichEquipmentItem(item)
        end
    end

    return originalSetCharacterSnapshot(characterKey, snapshot)
end
