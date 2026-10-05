local _, GW = ...

GW.QuestLog = GW.QuestLog or {}

local visibleQuestRows = 8
local visibleObjectiveRows = 5

local function rewardText(quest)
    local rewards = {}

    for _, reward in ipairs(quest.rewards or {}) do
        local amount = reward.amount and tostring(reward.amount) .. " " or ""
        table.insert(rewards, amount .. (reward.label or reward.type or "Reward"))
    end

    if #rewards == 0 then
        return "No configured rewards"
    end

    return table.concat(rewards, "  •  ")
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
        return "Assigned to you"
    end

    if status == "pending-join" then
        return "Joining when bridge syncs"
    end

    if status == "pending-leave" then
        return "Leaving when bridge syncs"
    end

    if status == "complete" then
        return "Complete"
    end

    local count = #(assignment.members or {})
    if count > 0 then
        return tostring(count) .. " guildmate" .. (count == 1 and "" or "s") .. " assigned"
    end

    return "Available"
end

local function createTab(parent, label, x, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(112, 24)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -4)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

local function createQuestRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(286, 46)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 48))
    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2")

    local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -7)
    title:SetPoint("RIGHT", -8, 0)
    title:SetJustifyH("LEFT")

    local meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    meta:SetPoint("BOTTOMLEFT", 8, 7)
    meta:SetPoint("RIGHT", -8, 0)
    meta:SetJustifyH("LEFT")

    row.title = title
    row.meta = meta
    return row
end

local function createObjectiveRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(452, 54)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 56))
    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2")

    local title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 8, -7)
    title:SetPoint("RIGHT", -8, 0)
    title:SetJustifyH("LEFT")

    local status = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("BOTTOMLEFT", 8, 7)
    status:SetPoint("RIGHT", -8, 0)
    status:SetJustifyH("LEFT")

    row.title = title
    row.status = status
    return row
end

function GW.QuestLog:Initialize(parent)
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", 14, -34)
    frame:SetPoint("BOTTOMRIGHT", -14, 14)

    self.activeTab = "available"
    self.page = 1

    self.tabs = {
        available = createTab(frame, "Available", 0, function()
            self:SetTab("available")
        end),
        my = createTab(frame, "My Quests", 118, function()
            self:SetTab("my")
        end),
        completed = createTab(frame, "Completed", 236, function()
            self:SetTab("completed")
        end),
    }

    local sourceText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sourceText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -11)
    self.sourceText = sourceText

    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.35, 0.30, 0.20, 0.6)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", 302, -36)
    divider:SetPoint("BOTTOMLEFT", 302, 36)

    local listHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    listHeader:SetPoint("TOPLEFT", 4, -42)
    listHeader:SetText("GUILD QUESTS")

    local list = CreateFrame("Frame", nil, frame)
    list:SetPoint("TOPLEFT", 4, -64)
    list:SetSize(286, 384)
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

    local previous = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    previous:SetSize(72, 22)
    previous:SetPoint("BOTTOMLEFT", 4, 4)
    previous:SetText("Previous")
    previous:SetScript("OnClick", function()
        self.page = math.max(1, self.page - 1)
        self:Refresh()
    end)
    self.previousButton = previous

    local pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    pageText:SetPoint("LEFT", previous, "RIGHT", 10, 0)
    self.pageText = pageText

    local nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    nextButton:SetSize(72, 22)
    nextButton:SetPoint("BOTTOMLEFT", 214, 4)
    nextButton:SetText("Next")
    nextButton:SetScript("OnClick", function()
        self.page = self.page + 1
        self:Refresh()
    end)
    self.nextButton = nextButton

    local details = CreateFrame("Frame", nil, frame)
    details:SetPoint("TOPLEFT", 318, -38)
    details:SetPoint("BOTTOMRIGHT", -4, 4)
    self.details = details

    local campaign = details:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    campaign:SetPoint("TOPLEFT", 0, 0)
    campaign:SetPoint("RIGHT", 0, 0)
    campaign:SetJustifyH("LEFT")
    self.campaignText = campaign

    local title = details:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", campaign, "BOTTOMLEFT", 0, -6)
    title:SetPoint("RIGHT", 0, 0)
    title:SetJustifyH("LEFT")
    self.titleText = title

    local description = details:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    description:SetWidth(452)
    description:SetJustifyH("LEFT")
    description:SetJustifyV("TOP")
    self.descriptionText = description

    local rewardLabel = details:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rewardLabel:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -16)
    rewardLabel:SetText("REWARDS")

    local rewards = details:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rewards:SetPoint("TOPLEFT", rewardLabel, "BOTTOMLEFT", 0, -5)
    rewards:SetWidth(452)
    rewards:SetJustifyH("LEFT")
    self.rewardsText = rewards

    local objectivesLabel = details:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    objectivesLabel:SetPoint("TOPLEFT", rewards, "BOTTOMLEFT", 0, -18)
    objectivesLabel:SetText("OBJECTIVES")

    local objectives = CreateFrame("Frame", nil, details)
    objectives:SetPoint("TOPLEFT", objectivesLabel, "BOTTOMLEFT", 0, -8)
    objectives:SetSize(452, 280)
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

    local action = CreateFrame("Button", nil, details, "UIPanelButtonTemplate")
    action:SetSize(154, 26)
    action:SetPoint("BOTTOMRIGHT", 0, 0)
    action:SetScript("OnClick", function()
        self:RunSelectedAction()
    end)
    self.actionButton = action

    local hint = details:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("RIGHT", action, "LEFT", -10, 0)
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

    self.sourceText:SetText(source == "live" and "Synced with Holdfast" or "Preview data")

    for tab, button in pairs(self.tabs) do
        button:SetEnabled(tab ~= self.activeTab)
    end

    local startIndex = ((self.page - 1) * visibleQuestRows) + 1
    for rowIndex, row in ipairs(self.questRows) do
        local quest = quests[startIndex + rowIndex - 1]
        if quest then
            row.questId = quest.id
            row.title:SetText(quest.title or "Untitled Quest")
            row.meta:SetText((quest.priority or "Normal") .. "  •  " .. (quest.campaign or "Guild Quest"))
            row:Show()
        else
            row.questId = nil
            row:Hide()
        end
    end

    self.pageText:SetText(tostring(self.page) .. " / " .. tostring(pageCount))
    self.previousButton:SetEnabled(self.page > 1)
    self.nextButton:SetEnabled(self.page < pageCount)

    local selected = self.selectedQuestId and GW.Quests.GetQuestById(self.selectedQuestId) or nil
    if not selected then
        selected = quests[startIndex]
        self.selectedQuestId = selected and selected.id or nil
        self.selectedObjectiveId = nil
    end

    self:UpdateDetails(selected, source)
end

function GW.QuestLog:UpdateDetails(quest, source)
    if not quest then
        self.campaignText:SetText("")
        self.titleText:SetText("No quests here yet")
        self.descriptionText:SetText("Guild quests synced from your website will appear here.")
        self.rewardsText:SetText("")
        for _, row in ipairs(self.objectiveRows) do
            row:Hide()
        end
        self.actionButton:SetText("No Objective")
        self.actionButton:Disable()
        self.actionHint:SetText("")
        self.selectedAction = nil
        return
    end

    self.campaignText:SetText((quest.campaign or "Guild Quest") .. "  •  " .. (quest.priority or "Normal") .. " Priority")
    self.titleText:SetText(quest.title or "Untitled Quest")
    self.descriptionText:SetText(quest.description or "")
    self.rewardsText:SetText(rewardText(quest))

    local selectedObjective = nil
    for index, row in ipairs(self.objectiveRows) do
        local objective = (quest.objectives or {})[index]
        if objective then
            row.objectiveId = objective.id
            row.title:SetText(objective.title or "Objective")
            local progress = objectiveProgressText(objective)
            local status = assignmentText(objective)
            row.status:SetText(progress ~= "" and (status .. "  •  " .. progress) or status)
            row:Show()

            if self.selectedObjectiveId == objective.id then
                selectedObjective = objective
            end
        else
            row.objectiveId = nil
            row:Hide()
        end
    end

    if not selectedObjective and #(quest.objectives or {}) > 0 then
        selectedObjective = quest.objectives[1]
        self.selectedObjectiveId = selectedObjective.id
    end

    if not selectedObjective then
        self.actionButton:SetText("No Objective")
        self.actionButton:Disable()
        self.actionHint:SetText("")
        self.selectedAction = nil
        return
    end

    local label, enabled, action = GW.Quests.ObjectiveActionLabel(selectedObjective)
    self.actionButton:SetText(source == "mock" and "Preview Only" or label)
    self.selectedAction = source == "mock" and nil or action

    if source == "mock" or not enabled then
        self.actionButton:Disable()
    else
        self.actionButton:Enable()
    end

    self.actionHint:SetText(selectedObjective.description or "")
end
