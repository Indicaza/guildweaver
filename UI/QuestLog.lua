local _, GW = ...

-- The guild quest log, shown in the dashboard's Guild Quests view: tabs
-- for available, mine and completed quests, a paged list, and the selected
-- quest with its rewards and objectives. Joining or leaving an objective is
-- queued for the bridge (GW.Quests); preview data cannot be acted on.
GW.QuestLog = GW.QuestLog or {}

local UI, Theme = GW.UI, GW.Theme

local visibleQuestRows = 7
local visibleObjectiveRows = 4
local LIST_WIDTH = 204
local ROW_HEIGHT = 40
local OBJECTIVE_HEIGHT = 34
local TABS = { { "available", "Available" }, { "my", "My Quests" }, { "completed", "Completed" } }
local BULLET = "  \226\128\162  "

local function rewardText(quest)
    local rewards = {}

    for _, reward in ipairs(quest.rewards or {}) do
        local amount = reward.amount and tostring(reward.amount) .. " " or ""
        table.insert(rewards, amount .. (reward.label or reward.type or "Reward"))
    end

    if #rewards == 0 then
        return "No configured rewards"
    end

    return table.concat(rewards, BULLET)
end

local function objectiveProgressText(objective)
    local progress = objective.progress
    if not progress then
        return ""
    end

    return tostring(progress.current or 0)
        .. "/"
        .. tostring(progress.target or 0)
        .. " "
        .. tostring(progress.label or "")
end

local function assignmentText(objective)
    local assignment = objective.assignment or {}
    local status = assignment.status or "available"

    if status == "assigned" then
        return "Assigned to you", "good"
    end

    if status == "pending-join" then
        return "Joining when bridge syncs", "warn"
    end

    if status == "pending-leave" then
        return "Leaving when bridge syncs", "warn"
    end

    if status == "complete" then
        return "Complete", "gold"
    end

    local count = #(assignment.members or {})
    if count > 0 then
        return tostring(count) .. " guildmate" .. (count == 1 and "" or "s") .. " assigned", "textMuted"
    end

    return "Available", "textMuted"
end
GW.QuestLog.AssignmentText = assignmentText

-- A selectable list row: background on hover, gold edge when selected.
local function selectableRow(parent, height)
    local row = UI.CreateFrame("Button", parent)
    row:SetHeight(height)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    Theme.Fill(row.bg, "bgHover")
    row.bg:Hide()
    row.edge = row:CreateTexture(nil, "ARTWORK")
    row.edge:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.edge:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.edge:SetWidth(2)
    Theme.Fill(row.edge, "gold")
    row.edge:Hide()
    row.selected = false
    pcall(row.RegisterForClicks, row, "LeftButtonUp")
    row:SetScript("OnEnter", function(self) if not self.selected then self.bg:Show() end end)
    row:SetScript("OnLeave", function(self) if not self.selected then self.bg:Hide() end end)
    function row:SetSelected(selected)
        self.selected = selected == true
        Theme.Fill(self.bg, selected and "bgActive" or "bgHover")
        UI.SetShown(self.bg, selected)
        UI.SetShown(self.edge, selected)
    end
    return row
end

local function createQuestRow(parent, index)
    local row = selectableRow(parent, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (ROW_HEIGHT + 2)))
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    local title = UI.Text(row, "label", "text")
    title:SetPoint("TOPLEFT", 10, -6)
    title:SetPoint("RIGHT", -8, 0)
    pcall(title.SetWordWrap, title, false)

    local meta = UI.Text(row, "small", "textFaint")
    meta:SetPoint("BOTTOMLEFT", 10, 6)
    meta:SetPoint("RIGHT", -8, 0)
    pcall(meta.SetWordWrap, meta, false)

    row.title = title
    row.meta = meta
    return row
end

local function createObjectiveRow(parent, index)
    local row = selectableRow(parent, OBJECTIVE_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (OBJECTIVE_HEIGHT + 2)))
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    local title = UI.Text(row, "label", "text")
    title:SetPoint("TOPLEFT", 10, -4)
    title:SetPoint("RIGHT", -8, 0)
    pcall(title.SetWordWrap, title, false)

    local status = UI.Text(row, "small", "textMuted")
    status:SetPoint("BOTTOMLEFT", 10, 4)
    status:SetPoint("RIGHT", -8, 0)
    pcall(status.SetWordWrap, status, false)

    row.title = title
    row.status = status
    return row
end

function GW.QuestLog:Initialize(parent)
    if self.frame then
        return
    end

    local frame = UI.CreateFrame("Frame", parent)
    frame:SetAllPoints(parent)

    self.activeTab = "available"
    self.page = 1

    self.tabs = UI.Segmented(frame, TABS, function() return self.activeTab end, function(tab) self:SetTab(tab) end,
        { segmentWidth = 88, height = 22 })
    self.tabs:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)

    local sourceDot = UI.Dot(frame, 7)
    self.sourceDot = sourceDot
    local sourceText = UI.Text(frame, "small", "textMuted", "RIGHT")
    sourceText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -5)
    sourceDot:SetPoint("RIGHT", sourceText, "LEFT", -6, 0)
    self.sourceText = sourceText

    -- The list, on an inset panel, with its pager.
    local listPanel = UI.CreateFrame("Frame", frame)
    listPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -34)
    listPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    listPanel:SetWidth(LIST_WIDTH)
    Theme.Skin(listPanel, "bgInset", "border")

    local list = UI.CreateFrame("Frame", listPanel)
    list:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 1, -1)
    list:SetPoint("RIGHT", listPanel, "RIGHT", -1, 0)
    list:SetHeight(visibleQuestRows * (ROW_HEIGHT + 2))
    self.list = list
    self.questRows = {}

    for index = 1, visibleQuestRows do
        local row = createQuestRow(list, index)
        row:SetScript("OnClick", function(button)
            if button.questId then
                self:SelectQuest(button.questId)
            end
        end)
        table.insert(self.questRows, row)
    end

    local previous = UI.IconButton(listPanel, "\226\128\185", { size = 22, tooltip = "Previous page", onClick = function()
        self.page = math.max(1, self.page - 1)
        self:Refresh()
    end })
    previous:SetPoint("BOTTOMLEFT", listPanel, "BOTTOMLEFT", 6, 6)
    self.previousButton = previous

    local nextButton = UI.IconButton(listPanel, "\226\128\186", { size = 22, tooltip = "Next page", onClick = function()
        self.page = self.page + 1
        self:Refresh()
    end })
    nextButton:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -6, 6)
    self.nextButton = nextButton

    local pageText = UI.Text(listPanel, "small", "textFaint", "CENTER")
    pageText:SetPoint("BOTTOM", listPanel, "BOTTOM", 0, 11)
    self.pageText = pageText

    self.emptyText = UI.Text(listPanel, "label", "textFaint", "CENTER")
    self.emptyText:SetPoint("TOP", listPanel, "TOP", 0, -24)
    self.emptyText:SetWidth(LIST_WIDTH - 24)

    -- The selected quest.
    local details = UI.CreateFrame("Frame", frame)
    details:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", 18, -2)
    details:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    self.details = details

    local campaign = UI.Text(details, "caps", "textFaint")
    campaign:SetPoint("TOPLEFT", 0, 0)
    campaign:SetPoint("RIGHT", 0, 0)
    pcall(campaign.SetWordWrap, campaign, false)
    self.campaignText = campaign

    local title = UI.Text(details, "title", "goldBright")
    title:SetPoint("TOPLEFT", campaign, "BOTTOMLEFT", 0, -6)
    title:SetPoint("RIGHT", 0, 0)
    pcall(title.SetWordWrap, title, false)
    self.titleText = title

    local description = UI.Text(details, "label", "text")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    description:SetPoint("RIGHT", 0, 0)
    description:SetHeight(46)
    pcall(description.SetWordWrap, description, true)
    pcall(description.SetJustifyV, description, "TOP")
    pcall(description.SetMaxLines, description, 3)
    self.descriptionText = description

    local rewardLabel = UI.Text(details, "caps", "goldDim")
    rewardLabel:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -8)
    rewardLabel:SetText("REWARDS")

    local rewards = UI.Text(details, "label", "text")
    rewards:SetPoint("TOPLEFT", rewardLabel, "BOTTOMLEFT", 0, -4)
    rewards:SetPoint("RIGHT", 0, 0)
    pcall(rewards.SetWordWrap, rewards, false)
    self.rewardsText = rewards

    local objectivesLabel = UI.Text(details, "caps", "goldDim")
    objectivesLabel:SetPoint("TOPLEFT", rewards, "BOTTOMLEFT", 0, -12)
    objectivesLabel:SetText("OBJECTIVES")

    local objectives = UI.CreateFrame("Frame", details)
    objectives:SetPoint("TOPLEFT", objectivesLabel, "BOTTOMLEFT", 0, -6)
    objectives:SetPoint("RIGHT", details, "RIGHT", 0, 0)
    objectives:SetHeight(visibleObjectiveRows * (OBJECTIVE_HEIGHT + 2))
    self.objectives = objectives
    self.objectiveRows = {}

    for index = 1, visibleObjectiveRows do
        local row = createObjectiveRow(objectives, index)
        row:SetScript("OnClick", function(button)
            if button.objectiveId then
                self:SelectObjective(button.objectiveId)
            end
        end)
        table.insert(self.objectiveRows, row)
    end

    local action = UI.Button(details, "No Objective", { width = 150, height = 26, variant = "primary", onClick = function()
        self:RunSelectedAction()
    end })
    action:SetPoint("BOTTOMRIGHT", 0, 0)
    self.actionButton = action

    local hint = UI.Text(details, "small", "textMuted")
    hint:SetPoint("RIGHT", action, "LEFT", -12, 0)
    hint:SetPoint("LEFT", details, "LEFT", 0, 0)
    pcall(hint.SetWordWrap, hint, false)
    hint:SetText("Select an objective")
    self.actionHint = hint

    self.frame = frame
    self:Refresh()
end

function GW.QuestLog:SetTab(tab)
    self.activeTab = tab
    self.page = 1
    self.selectedQuestId = nil
    self.selectedObjectiveId = nil
    self:Refresh()
end

function GW.QuestLog:SelectQuest(questId)
    self.selectedQuestId = questId
    self.selectedObjectiveId = nil
    self:Refresh()
end

function GW.QuestLog:SelectObjective(objectiveId)
    self.selectedObjectiveId = objectiveId
    self:Refresh()
end

function GW.QuestLog:RunSelectedAction()
    if not self.selectedQuestId or not self.selectedObjectiveId or not self.selectedAction then
        return
    end

    if self.selectedAction == "join" then
        GW.Quests.JoinObjective(self.selectedQuestId, self.selectedObjectiveId)
    elseif self.selectedAction == "leave" then
        GW.Quests.LeaveObjective(self.selectedQuestId, self.selectedObjectiveId)
    end
end

function GW.QuestLog:Refresh()
    if not self.frame then
        return
    end

    local quests = GW.Quests.GetQuests(self.activeTab)
    local _, source = GW.Quests.GetSource()
    local pageCount = math.max(1, math.ceil(#quests / visibleQuestRows))
    self.page = math.min(self.page, pageCount)

    UI.SetText(self.sourceText, source == "live" and "Synced with your guild" or "Preview data")
    self.sourceDot:SetStatus(source == "live" and "good" or "warn")
    self.tabs:Refresh()

    local startIndex = ((self.page - 1) * visibleQuestRows) + 1
    for rowIndex, row in ipairs(self.questRows) do
        local quest = quests[startIndex + rowIndex - 1]
        if quest then
            row.questId = quest.id
            UI.SetText(row.title, quest.title or "Untitled Quest")
            UI.SetText(row.meta, (quest.priority or "Normal") .. BULLET .. (quest.campaign or "Guild Quest"))
            row:Show()
        else
            row.questId = false
            row:Hide()
        end
    end

    UI.SetText(self.emptyText, #quests == 0 and (self.activeTab == "my" and "You have not joined any quests yet."
        or (self.activeTab == "completed" and "No completed quests yet." or "No quests here yet.")) or "")
    UI.SetText(self.pageText, pageCount > 1 and (tostring(self.page) .. " / " .. tostring(pageCount)) or "")
    self.previousButton:SetEnabled(self.page > 1)
    self.nextButton:SetEnabled(self.page < pageCount)
    UI.SetShown(self.previousButton, pageCount > 1)
    UI.SetShown(self.nextButton, pageCount > 1)

    local selected = self.selectedQuestId and GW.Quests.GetQuestById(self.selectedQuestId) or nil
    if not selected then
        selected = quests[startIndex]
        self.selectedQuestId = selected and selected.id or nil
        self.selectedObjectiveId = nil
    end
    for _, row in ipairs(self.questRows) do
        row:SetSelected(row.questId and row.questId == self.selectedQuestId)
    end

    self:UpdateDetails(selected, source)
end

function GW.QuestLog:UpdateDetails(quest, source)
    if not quest then
        UI.SetText(self.campaignText, "")
        UI.SetText(self.titleText, "No quests here yet")
        UI.SetText(self.descriptionText, "Guild quests synced from your guild's website will appear here.")
        UI.SetText(self.rewardsText, "")
        for _, row in ipairs(self.objectiveRows) do
            row:Hide()
        end
        self.actionButton:SetLabel("No Objective")
        self.actionButton:SetEnabled(false)
        UI.SetText(self.actionHint, "")
        self.selectedAction = nil
        return
    end

    UI.SetText(self.campaignText, string.upper((quest.campaign or "Guild Quest") .. BULLET .. (quest.priority or "Normal") .. " Priority"))
    UI.SetText(self.titleText, quest.title or "Untitled Quest")
    UI.SetText(self.descriptionText, quest.description or "")
    UI.SetText(self.rewardsText, rewardText(quest))

    local selectedObjective = nil
    for index, row in ipairs(self.objectiveRows) do
        local objective = (quest.objectives or {})[index]
        if objective then
            row.objectiveId = objective.id
            UI.SetText(row.title, objective.title or "Objective")
            local progress = objectiveProgressText(objective)
            local status, color = assignmentText(objective)
            UI.SetText(row.status, Theme.Colorize(status, color) .. (progress ~= "" and (BULLET .. progress) or ""))
            row:Show()

            if self.selectedObjectiveId == objective.id then
                selectedObjective = objective
            end
        else
            row.objectiveId = false
            row:Hide()
        end
    end

    if not selectedObjective and #(quest.objectives or {}) > 0 then
        selectedObjective = quest.objectives[1]
        self.selectedObjectiveId = selectedObjective.id
    end
    for _, row in ipairs(self.objectiveRows) do
        row:SetSelected(row.objectiveId and row.objectiveId == self.selectedObjectiveId)
    end

    if not selectedObjective then
        self.actionButton:SetLabel("No Objective")
        self.actionButton:SetEnabled(false)
        UI.SetText(self.actionHint, "")
        self.selectedAction = nil
        return
    end

    local label, enabled, action = GW.Quests.ObjectiveActionLabel(selectedObjective)
    self.actionButton:SetLabel(source == "mock" and "Preview Only" or label)
    self.selectedAction = source == "mock" and nil or action
    self.actionButton:SetEnabled(source ~= "mock" and enabled == true)

    UI.SetText(self.actionHint, selectedObjective.description or "")
end
