local _, GW = ...

GW.Quests = GW.Quests or {}

local priorityOrder = {
    Gold = 1,
    Red = 2,
    Blue = 3,
    Green = 4,
}

local function assignmentStatus(objective)
    return objective.assignment and objective.assignment.status or "available"
end

local function questIsMine(quest)
    for _, objective in ipairs(quest.objectives or {}) do
        local assignment = objective.assignment or {}
        if assignment.me or assignment.status == "assigned" or assignment.status == "pending-join" or assignment.status == "pending-leave" then
            return true
        end
    end

    return false
end

local function includeQuest(quest, tab)
    if tab == "completed" then
        return quest.status == "complete"
    end

    if quest.status == "complete" then
        return false
    end

    if tab == "my" then
        return questIsMine(quest)
    end

    return true
end

local function sortedCopy(quests)
    local result = {}

    for _, quest in ipairs(quests or {}) do
        table.insert(result, quest)
    end

    table.sort(result, function(left, right)
        local leftPriority = priorityOrder[left.priority] or 99
        local rightPriority = priorityOrder[right.priority] or 99

        if leftPriority ~= rightPriority then
            return leftPriority < rightPriority
        end

        return (left.title or "") < (right.title or "")
    end)

    return result
end

function GW.Quests.GetSnapshot()
    local database = GW.Store.GetDatabase()
    return database.sync.inbound.quests
end

function GW.Quests.HasLiveData()
    local snapshot = GW.Quests.GetSnapshot()
    return snapshot and type(snapshot.items) == "table" and #snapshot.items > 0
end

function GW.Quests.GetSource()
    local snapshot = GW.Quests.GetSnapshot()

    if snapshot and type(snapshot.items) == "table" and #snapshot.items > 0 then
        return snapshot.items, "live"
    end

    return GW.MockData.Quests or {}, "mock"
end

function GW.Quests.GetQuests(tab)
    local source = GW.Quests.GetSource()
    local filtered = {}

    for _, quest in ipairs(source) do
        if includeQuest(quest, tab) then
            table.insert(filtered, quest)
        end
    end

    return sortedCopy(filtered)
end

function GW.Quests.GetQuestById(questId)
    local source = GW.Quests.GetSource()

    for _, quest in ipairs(source) do
        if quest.id == questId then
            return quest
        end
    end

    return nil
end

function GW.Quests.SetInboundSnapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.items) ~= "table" then
        return false, "invalid_snapshot"
    end

    local database = GW.Store.GetDatabase()
    local current = database.sync.inbound.quests
    local nextRevision = tonumber(snapshot.revision) or 0
    local currentRevision = tonumber(current.revision) or 0

    if nextRevision < currentRevision then
        return false, "stale_revision"
    end

    database.sync.inbound.quests = snapshot

    if GW.QuestLog and GW.QuestLog.Refresh then
        GW.QuestLog:Refresh()
    end

    return true
end

function GW.Quests.QueueAction(actionType, questId, objectiveId)
    if not GW.Quests.HasLiveData() then
        return false, "preview_only"
    end

    local quest = GW.Quests.GetQuestById(questId)
    if not quest then
        return false, "quest_not_found"
    end

    local objective = nil
    for _, candidate in ipairs(quest.objectives or {}) do
        if candidate.id == objectiveId then
            objective = candidate
            break
        end
    end

    if not objective then
        return false, "objective_not_found"
    end

    local database = GW.Store.GetDatabase()
    database.sync.outbound.nextQuestActionId = (tonumber(database.sync.outbound.nextQuestActionId) or 0) + 1

    local actionId = tostring(GetServerTime()) .. ":" .. tostring(database.sync.outbound.nextQuestActionId)
    database.sync.outbound.questActions[actionId] = {
        id = actionId,
        action = actionType,
        questId = questId,
        objectiveId = objectiveId,
        createdAt = GetServerTime(),
        character = {
            name = UnitName("player"),
            realm = GetRealmName(),
        },
    }

    objective.assignment = objective.assignment or {}
    if actionType == "join" then
        objective.assignment.status = "pending-join"
        objective.assignment.me = true
    elseif actionType == "leave" then
        objective.assignment.status = "pending-leave"
    end

    if GW.QuestLog and GW.QuestLog.Refresh then
        GW.QuestLog:Refresh()
    end

    return true, actionId
end

function GW.Quests.JoinObjective(questId, objectiveId)
    return GW.Quests.QueueAction("join", questId, objectiveId)
end

function GW.Quests.LeaveObjective(questId, objectiveId)
    return GW.Quests.QueueAction("leave", questId, objectiveId)
end

function GW.Quests.ObjectiveActionLabel(objective)
    local status = assignmentStatus(objective)

    if status == "assigned" then
        return "Leave Objective", true, "leave"
    end

    if status == "pending-join" or status == "pending-leave" then
        return "Pending Sync", false, nil
    end

    if status == "complete" then
        return "Complete", false, nil
    end

    return "Accept Objective", true, "join"
end
