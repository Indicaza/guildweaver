local _, GW = ...

-- Publishes inventory_snapshot when bag contents or money change, without
-- recapturing the whole character.
--
-- Bag events arrive in bursts (looting, moving or splitting stacks), so
-- refreshes are debounced. BAG_UPDATE only marks its bag dirty; the
-- debounced refresh then reads just the dirty bags and rescans tooltips only
-- for items whose link, count, binding or durability changed. Money changes
-- reuse the last scan with the new amount and never read bags. Refreshes
-- wait for combat to end (ammo and consumables change bags constantly in
-- combat). Every 15 minutes, on entering the world and on bag swaps, all bags
-- are read again to repair any missed event. Unchanged results are deduped
-- by the store's fingerprint and never create a new revision.

local Globals = _G or {}

GW.InventoryCapture = GW.InventoryCapture or {}

local DEBOUNCE_SECONDS = 1.0
local ITEM_INFO_RETRY_SECONDS = 2.0
local MAX_ITEM_INFO_RETRIES = 3
local RECONCILE_SECONDS = 900

local function safeRegister(frame, event)
    return pcall(frame.RegisterEvent, frame, event)
end

local function serverTime()
    return type(GetServerTime) == "function" and GetServerTime() or nil
end

local function inCombat()
    local queue = GW.WorkQueue
    if queue and type(queue.InCombat) == "function" then
        return queue.InCombat()
    end
    local lockdown = Globals.InCombatLockdown
    if type(lockdown) == "function" then
        local ok, value = pcall(lockdown)
        return ok and value == true
    end
    return false
end

-- Scans and publishes the inventory domain. mode "money" reuses the last
-- scan with fresh money; "incremental" reads dirty bags only; anything else
-- reads every bag. Returns the domain's publish result, or nil when there is
-- no character snapshot yet (the first character capture publishes
-- inventory along with every other domain), and whether item info is still
-- loading.
function GW.InventoryCapture.Publish(reason, mode)
    local snapshot = GW.Character and GW.Character.GetCurrentSnapshot and GW.Character.GetCurrentSnapshot()
    local domain = GW.TelemetryDomains and GW.TelemetryDomains.Inventory
    if type(snapshot) ~= "table" or not snapshot.characterKey or not domain then
        return nil
    end

    local perf = GW.Perf
    local category = mode == "money" and "inventory_money" or "inventory_scan"
    local started = perf and perf.Begin and perf.Begin() or nil
    local telemetry = GW.InventoryTelemetry
    local refreshed, pending, _
    if mode == "money" and type(telemetry.RefreshMoney) == "function" then
        refreshed, pending = telemetry.RefreshMoney(snapshot.characterKey)
    end
    if not refreshed then
        _, pending = telemetry.Refresh(snapshot.characterKey, { incremental = mode == "incremental" })
    end

    -- The envelope takes its capture time from the snapshot it is given; the
    -- cached character snapshot can be old, so stamp this observation now.
    local context = {}
    for key, value in pairs(snapshot) do
        context[key] = value
    end
    context.capturedAt = serverTime() or snapshot.capturedAt
    context.reason = reason

    local ok, result = pcall(domain.Publish, context)
    if perf and perf.End then
        perf.End(category, started)
    end
    if not ok then
        return nil, pending
    end
    return result, pending
end

local function reconcileDue()
    local telemetry = GW.InventoryTelemetry
    local since = type(telemetry.SecondsSinceFullRead) == "function" and telemetry.SecondsSinceFullRead() or nil
    return since ~= nil and since >= RECONCILE_SECONDS
end

function GW.InventoryCapture:Run()
    self.pending = false
    local latest = self.latestReason or "BAG_UPDATE"
    local moneyOnly = self.moneyOnly
    self.latestReason = nil
    self.moneyOnly = nil

    local mode = "incremental"
    if moneyOnly then
        mode = "money"
    elseif reconcileDue() then
        mode = "full"
    end
    local _, itemInfoPending = GW.InventoryCapture.Publish(latest, mode)

    -- Items the client had not cached yet are described again when their
    -- info arrives (GET_ITEM_INFO_RECEIVED), with a few timed retries for
    -- clients that never send it.
    if itemInfoPending and (self.itemInfoRetries or 0) < MAX_ITEM_INFO_RETRIES then
        self.itemInfoRetries = (self.itemInfoRetries or 0) + 1
        C_Timer.After(ITEM_INFO_RETRY_SECONDS, function()
            self:Schedule("ITEM_INFO_RETRY")
        end)
    elseif not itemInfoPending then
        self.itemInfoRetries = 0
    end
end

-- kind "money" requests a money-only refresh; it is upgraded to a bag
-- refresh if bags changed too.
function GW.InventoryCapture:Schedule(reason, kind)
    self.latestReason = reason
    if kind == "money" then
        if self.moneyOnly == nil then
            self.moneyOnly = true
        end
    else
        self.moneyOnly = false
    end
    if inCombat() then
        self.afterCombat = true
        return
    end
    if self.pending then
        return
    end
    self.pending = true
    C_Timer.After(DEBOUNCE_SECONDS, function()
        if inCombat() then
            self.pending = false
            self.afterCombat = true
            return
        end
        self:Run()
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
    -- BAG_UPDATE_DELAYED fires once after a burst of BAG_UPDATEs, which only
    -- mark their bag dirty; clients without it debounce the BAG_UPDATEs.
    local hasDelayed = safeRegister(frame, "BAG_UPDATE_DELAYED")
    safeRegister(frame, "BAG_UPDATE")
    safeRegister(frame, "PLAYER_MONEY")
    safeRegister(frame, "PLAYER_ENTERING_WORLD")
    safeRegister(frame, "BAG_CONTAINER_UPDATE")
    safeRegister(frame, "UPDATE_INVENTORY_DURABILITY")
    safeRegister(frame, "GET_ITEM_INFO_RECEIVED")
    safeRegister(frame, "PLAYER_REGEN_ENABLED")

    local telemetry = GW.InventoryTelemetry
    frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "BAG_UPDATE" then
            telemetry.MarkBagDirty(arg1)
            if not hasDelayed then
                self:Schedule(event)
            end
            return
        end
        if event == "PLAYER_MONEY" then
            self:Schedule(event, "money")
            return
        end
        if event == "GET_ITEM_INFO_RECEIVED" then
            -- Item info arrives for every item the client loads anywhere;
            -- only an incomplete description of a carried item cares.
            if telemetry.NoteItemInfo(arg1) then
                self:Schedule(event)
            end
            return
        end
        if event == "PLAYER_REGEN_ENABLED" then
            if self.afterCombat then
                self.afterCombat = false
                self:Schedule(self.latestReason or "AFTER_COMBAT", self.moneyOnly and "money" or nil)
            end
            return
        end
        if event == "PLAYER_ENTERING_WORLD" or event == "BAG_CONTAINER_UPDATE" or event == "UPDATE_INVENTORY_DURABILITY" then
            telemetry.MarkAllDirty()
        end
        self:Schedule(event)
    end)

    self.eventFrame = frame
end

GW.InventoryCapture:Initialize()
