local _, GW = ...

-- Publishes inventory_snapshot when bag contents or money change, without
-- recapturing the whole character. Bag events arrive in bursts (looting,
-- moving or splitting stacks), so scans are debounced; unchanged results are
-- deduped by the store's fingerprint and never create a new revision.

GW.InventoryCapture = GW.InventoryCapture or {}

local DEBOUNCE_SECONDS = 1.0
local ITEM_INFO_RETRY_SECONDS = 2.0
local MAX_ITEM_INFO_RETRIES = 3

local function safeRegister(frame, event)
    return pcall(frame.RegisterEvent, frame, event)
end

local function serverTime()
    return type(GetServerTime) == "function" and GetServerTime() or nil
end

-- Scans now and publishes the inventory domain. Returns the domain's publish
-- result, or nil when there is no character snapshot yet (the first character
-- capture publishes inventory along with every other domain).
function GW.InventoryCapture.Publish(reason)
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot()
    local domain = GW.TelemetryDomains and GW.TelemetryDomains.Inventory
    if type(snapshot) ~= "table" or not snapshot.characterKey or not domain then
        return nil
    end

    local _, pending = GW.InventoryTelemetry.Refresh(snapshot.characterKey)

    -- The envelope takes its capture time from the snapshot it is given; the
    -- cached character snapshot can be old, so stamp this observation now.
    local context = {}
    for key, value in pairs(snapshot) do
        context[key] = value
    end
    context.capturedAt = serverTime() or snapshot.capturedAt
    context.reason = reason

    local ok, result = pcall(domain.Publish, context)
    if not ok then
        return nil, pending
    end
    return result, pending
end

function GW.InventoryCapture:Schedule(reason)
    self.latestReason = reason
    if self.pending then
        return
    end
    self.pending = true
    C_Timer.After(DEBOUNCE_SECONDS, function()
        self.pending = false
        local latest = self.latestReason or "BAG_UPDATE"
        self.latestReason = nil
        local _, itemInfoPending = GW.InventoryCapture.Publish(latest)

        -- Items the client had not cached yet are described once their info
        -- arrives; retry a few times rather than listening forever.
        if itemInfoPending and (self.itemInfoRetries or 0) < MAX_ITEM_INFO_RETRIES then
            self.itemInfoRetries = (self.itemInfoRetries or 0) + 1
            C_Timer.After(ITEM_INFO_RETRY_SECONDS, function()
                self:Schedule("ITEM_INFO_RETRY")
            end)
        elseif not itemInfoPending then
            self.itemInfoRetries = 0
        end
    end)
end

function GW.InventoryCapture:Initialize()
    if self.eventFrame then
        return
    end
    if type(CreateFrame) ~= "function" or type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        return
    end

    local frame = CreateFrame("Frame")
    -- BAG_UPDATE_DELAYED fires once after a burst of BAG_UPDATEs; clients
    -- without it still debounce the individual updates.
    local hasDelayed = safeRegister(frame, "BAG_UPDATE_DELAYED")
    if not hasDelayed then
        safeRegister(frame, "BAG_UPDATE")
    end
    safeRegister(frame, "PLAYER_MONEY")
    safeRegister(frame, "PLAYER_ENTERING_WORLD")
    safeRegister(frame, "BAG_CONTAINER_UPDATE")

    frame:SetScript("OnEvent", function(_, event)
        self:Schedule(event)
    end)

    self.eventFrame = frame
end

GW.InventoryCapture:Initialize()
