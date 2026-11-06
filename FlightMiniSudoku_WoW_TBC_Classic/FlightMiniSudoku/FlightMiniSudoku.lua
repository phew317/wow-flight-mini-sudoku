--------------------------------------------------------------------------------
-- FlightMiniSudoku
-- World of Warcraft Classic / Burning Crusade Classic Anniversary
-- Author: skippzy
-- License: MIT
--------------------------------------------------------------------------------

local ADDON_NAME = ...
local PREFIX = "FMS_HS"

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------

local defaults = {
    autoOpen = true,
    minimapPos = 45,
    completedGames = 0,
    highscores = {},
    ownedCharacters = {},
}

-- SavedVariables can originate from older addon versions. Normalize the
-- existing table instead of replacing it, preserving highscores and options.
local function EnsureDatabase()
    if type(FlightMiniSudokuDB) ~= "table" then
        FlightMiniSudokuDB = {}
    end

    for key, value in pairs(defaults) do
        if FlightMiniSudokuDB[key] == nil then
            if type(value) == "table" then
                FlightMiniSudokuDB[key] = {}
            else
                FlightMiniSudokuDB[key] = value
            end
        end
    end

    if type(FlightMiniSudokuDB.highscores) ~= "table" then
        FlightMiniSudokuDB.highscores = {}
    end
    if type(FlightMiniSudokuDB.ownedCharacters) ~= "table" then
        FlightMiniSudokuDB.ownedCharacters = {}
    end

    local completed = tonumber(FlightMiniSudokuDB.completedGames)
    if not completed or completed < 0 then
        completed = 0
    end
    FlightMiniSudokuDB.completedGames = math.floor(completed)
end

EnsureDatabase()

local function CurrentCharacterKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "")
end

local function RegisterCurrentCharacter()
    local key = CurrentCharacterKey()
    FlightMiniSudokuDB.ownedCharacters[key] = true

    -- Existing local records from older versions become identifiable as
    -- account-owned when that character next logs in.
    local record = FlightMiniSudokuDB.highscores[key]
    if type(record) == "table" then
        record.owner = "local"
        if not record.class and UnitClass then
            local _, classToken = UnitClass("player")
            record.class = classToken
        end
    end
end

-- ---------------------------------------------------------------------------
-- Localization
-- ---------------------------------------------------------------------------

local L = {
    deDE = {
        title = "Flight Mini Sudoku",
        startGame = "Spiel beginnen",
        newGame = "Neues Spiel",
        reset = "Zurücksetzen",
        clearTooltip = "Ausgewähltes Feld leeren",
        hint = "Tipp",
        clearCell = "Feld leeren",
        solvedTitle = "Sudoku gelöst!",
        solvedText = "Du hast das Sudoku in %s gelöst.\nVerwendete Tipps: %d\nZeitstrafe: +%d Sekunden",
        timeLabel = "Zeit: ",
        hintsLabel = "Tipps: ",
        completedGames = "Abgeschlossene Spiele: %d",
        settingsAutoOpen = "Sudoku automatisch beim Start eines Fluges öffnen",
        highscoresTitle = "Highscores (Freunde / Gilde)",
        noHighscores = "Noch keine Highscores vorhanden.",
        winMessage = "Sudoku gelöst in %s! (Tipps: %d, Strafe: +%ds)",
        bestMessage = "Neue persönliche Bestzeit!",
        hintUsed = "Tipp verwendet! (+15 Sekunden Strafe)",
        minimapTooltip = "Flight Mini Sudoku\nLinksklick: Fenster öffnen/schließen\nRechtsklick: Einstellungen\nBefehl: /fms",
        resetPosMsg = "Position des Minimap-Icons zurückgesetzt.",
        settingsUnavailable = "Die Einstellungen sind in dieser WoW-Version nicht verfügbar.",
        addonMessageUnavailable = "Addon-Nachrichten sind in dieser WoW-Version nicht verfügbar.",
    },
    enUS = {
        title = "Flight Mini Sudoku",
        startGame = "Start Game",
        newGame = "New Game",
        reset = "Reset",
        clearTooltip = "Clear selected cell",
        hint = "Hint",
        clearCell = "Clear cell",
        solvedTitle = "Sudoku solved!",
        solvedText = "You solved the Sudoku in %s.\nHints used: %d\nTime penalty: +%d seconds",
        timeLabel = "Time: ",
        hintsLabel = "Hints: ",
        completedGames = "Games completed: %d",
        settingsAutoOpen = "Automatically open when a flight starts",
        highscoresTitle = "Highscores (Friends / Guild)",
        noHighscores = "No highscores recorded yet.",
        winMessage = "Sudoku solved in %s! (Hints: %d, penalty: +%ds)",
        bestMessage = "New personal best!",
        hintUsed = "Hint used! (+15 seconds penalty)",
        minimapTooltip = "Flight Mini Sudoku\nLeft-click: Toggle window\nRight-click: Settings\nCommand: /fms",
        resetPosMsg = "Minimap icon position reset.",
        settingsUnavailable = "Settings are not available in this WoW version.",
        addonMessageUnavailable = "Addon messages are not available in this WoW version.",
    },
}

local loc = L[GetLocale()] or L.enUS

-- ---------------------------------------------------------------------------
-- Game state and helpers
-- ---------------------------------------------------------------------------

local currentPuzzle = {}
local originalPuzzle = {}
local solution = {}
local selectedCell
for i = 1, 36 do
    currentPuzzle[i] = 0
    originalPuzzle[i] = 0
    solution[i] = 0
end
local secondsElapsed = 0
local hintsUsed = 0
local hintCooldownTimer = 0
local gameActive = false
local gameStarted = false
local timerRunning = false
local timerAccumulator = 0
local timerFrame = CreateFrame("Frame")
local hsText
local btnHint
local btnNew
local settingsPanel
local solvedDialog

local function PrintMessage(message)
    print("|cFF00FF00[FlightMiniSudoku]|r " .. message)
end

local function FormatTime(seconds)
    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60
    return string.format("%d:%02d", minutes, remainder)
end

local baseGrids = {
    {
        1,2,3,4,5,6,
        4,5,6,1,2,3,
        2,3,1,5,6,4,
        5,6,4,2,3,1,
        3,1,2,6,4,5,
        6,4,5,3,1,2,
    },
    {
        3,1,2,6,4,5,
        6,4,5,3,1,2,
        1,2,3,4,5,6,
        4,5,6,1,2,3,
        2,3,1,5,6,4,
        5,6,4,2,3,1,
    },
    {
        2,3,1,5,6,4,
        5,6,4,2,3,1,
        3,1,2,6,4,5,
        6,4,5,3,1,2,
        1,2,3,4,5,6,
        4,5,6,1,2,3,
    },
}

local function Shuffle(values)
    for i = #values, 2, -1 do
        local j = math.random(1, i)
        values[i], values[j] = values[j], values[i]
    end
end

local function CountSolutions(grid, limit)
    local work = {}
    for i = 1, 36 do
        work[i] = grid[i]
    end

    local function IsValid(index, value)
        local row = math.floor((index - 1) / 6) + 1
        local col = ((index - 1) % 6) + 1

        for other = 1, 36 do
            if other ~= index and work[other] == value then
                local otherRow = math.floor((other - 1) / 6) + 1
                local otherCol = ((other - 1) % 6) + 1

                if otherRow == row or otherCol == col or
                    (math.floor((otherRow - 1) / 2) == math.floor((row - 1) / 2) and
                     math.floor((otherCol - 1) / 3) == math.floor((col - 1) / 3)) then
                    return false
                end
            end
        end

        return true
    end

    local function Search()
        local bestIndex
        local bestOptions

        -- Minimum-remaining-values heuristic keeps the uniqueness check fast.
        for index = 1, 36 do
            if work[index] == 0 then
                local options = {}
                for value = 1, 6 do
                    if IsValid(index, value) then
                        table.insert(options, value)
                    end
                end

                if #options == 0 then
                    return 0
                end

                if not bestOptions or #options < #bestOptions then
                    bestIndex = index
                    bestOptions = options
                    if #bestOptions == 1 then
                        break
                    end
                end
            end
        end

        if not bestIndex then
            return 1
        end

        local found = 0
        for _, value in ipairs(bestOptions) do
            work[bestIndex] = value
            found = found + Search()
            work[bestIndex] = 0

            if found >= limit then
                return found
            end
        end

        return found
    end

    return Search()
end

local function GenerateNewSudoku()
    -- Build a fresh valid 6x6 solution by permuting bands, rows, stacks,
    -- columns and symbols of a valid base grid.
    local base = baseGrids[1]
    local bandOrder = { 0, 1, 2 }
    local stackOrder = { 0, 1 }
    Shuffle(bandOrder)
    Shuffle(stackOrder)

    local rowOrder = {}
    for _, band in ipairs(bandOrder) do
        local within = { 0, 1 }
        Shuffle(within)
        for _, offset in ipairs(within) do
            table.insert(rowOrder, band * 2 + offset + 1)
        end
    end

    local colOrder = {}
    for _, stack in ipairs(stackOrder) do
        local within = { 0, 1, 2 }
        Shuffle(within)
        for _, offset in ipairs(within) do
            table.insert(colOrder, stack * 3 + offset + 1)
        end
    end

    local symbols = { 1, 2, 3, 4, 5, 6 }
    Shuffle(symbols)

    solution = {}
    currentPuzzle = {}
    originalPuzzle = {}

    for row = 1, 6 do
        for col = 1, 6 do
            local sourceRow = rowOrder[row]
            local sourceCol = colOrder[col]
            local sourceValue = base[(sourceRow - 1) * 6 + sourceCol]
            local value = symbols[sourceValue]
            local index = (row - 1) * 6 + col
            solution[index] = value
            currentPuzzle[index] = value
        end
    end

    -- Remove clues only when the resulting puzzle still has exactly one
    -- solution. A target of 15-17 givens makes the puzzle materially harder
    -- than the previous random 18-22-cell removal.
    local indices = {}
    for i = 1, 36 do
        indices[i] = i
    end
    Shuffle(indices)

    local targetClues = math.random(15, 17)
    local clueCount = 36

    for _, index in ipairs(indices) do
        if clueCount <= targetClues then
            break
        end

        local previous = currentPuzzle[index]
        currentPuzzle[index] = 0

        if CountSolutions(currentPuzzle, 2) == 1 then
            clueCount = clueCount - 1
        else
            currentPuzzle[index] = previous
        end
    end

    for i = 1, 36 do
        originalPuzzle[i] = currentPuzzle[i]
    end

    secondsElapsed = 0
    hintsUsed = 0
    hintCooldownTimer = 0
    selectedCell = nil
    gameActive = true
end

local function CheckWinCondition()
    for i = 1, 36 do
        if currentPuzzle[i] ~= solution[i] then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local mainFrame = CreateFrame(
    "Frame",
    "FlightMiniSudokuMainFrame",
    UIParent,
    "BasicFrameTemplateWithInset"
)
mainFrame:SetSize(650, 450)
mainFrame:SetPoint("CENTER")
mainFrame:SetMovable(true)
mainFrame:EnableMouse(true)
mainFrame:RegisterForDrag("LeftButton")
mainFrame:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
mainFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)
mainFrame:Hide()

local titleText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
titleText:SetPoint("TOP", mainFrame, "TOP", 0, -6)
titleText:SetText(loc.title)

local statsText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statsText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 16, -32)

local completedGamesText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
completedGamesText:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -18, 14)
completedGamesText:SetTextColor(0.72, 0.78, 0.82)

-- Separate inset surfaces create a clearer visual hierarchy without changing
-- any game controls or puzzle behavior.
local boardContainer = CreateFrame("Frame", nil, mainFrame, "InsetFrameTemplate")
boardContainer:SetSize(340, 370)
boardContainer:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 12, -52)
boardContainer:SetFrameLevel(mainFrame:GetFrameLevel() + 1)

local cells = {}
local cellSize = 45
local gridStartX = 44 -- centered 6x6 board inside the left panel
local controlsStartX = 22 -- centered keypad and action row
local gridStartY = -68

local function SetCellColor(button, r, g, b)
    if button.valueText then
        button.valueText:SetTextColor(r, g, b)
    end
end

local function CellHasConflict(index)
    local value = currentPuzzle[index]
    if not value or value == 0 then
        return false
    end

    local row = math.floor((index - 1) / 6) + 1
    local col = ((index - 1) % 6) + 1
    local blockRow = math.floor((row - 1) / 2)
    local blockCol = math.floor((col - 1) / 3)

    for other = 1, 36 do
        if other ~= index and currentPuzzle[other] == value then
            local otherRow = math.floor((other - 1) / 6) + 1
            local otherCol = ((other - 1) % 6) + 1
            local sameRow = otherRow == row
            local sameCol = otherCol == col
            local sameBlock =
                math.floor((otherRow - 1) / 2) == blockRow and
                math.floor((otherCol - 1) / 3) == blockCol

            if sameRow or sameCol or sameBlock then
                return true
            end
        end
    end

    return false
end

local function RefreshCellSelection()
    for i = 1, 36 do
        local cell = cells[i]
        local conflict = CellHasConflict(i)

        if conflict then
            cell.highlight:SetVertexColor(0.72, 0.20, 0.18, 0.38)
            cell.highlight:Show()
            SetCellColor(cell, 1, 0.62, 0.58)
        elseif i == selectedCell then
            cell.highlight:SetVertexColor(0.22, 0.48, 0.66, 0.42)
            cell.highlight:Show()
            SetCellColor(cell, 0.78, 0.91, 1)
        else
            cell.highlight:Hide()
            if cell.isOriginal then
                SetCellColor(cell, 0.94, 0.82, 0.58)
            else
                SetCellColor(cell, 0.82, 0.90, 0.94)
            end
        end
    end
end

for row = 1, 6 do
    for col = 1, 6 do
        local index = (row - 1) * 6 + col
        local button = CreateFrame("Button", nil, mainFrame)
        button:SetSize(cellSize, cellSize)

        button.background = button:CreateTexture(nil, "BACKGROUND")
        button.background:SetTexture("Interface\\Buttons\\WHITE8X8")
        button.background:SetAllPoints(button)
        button.background:SetVertexColor(0.105, 0.12, 0.135, 0.98)

        button.hover = button:CreateTexture(nil, "HIGHLIGHT")
        button.hover:SetTexture("Interface\\Buttons\\WHITE8X8")
        button.hover:SetAllPoints(button)
        button.hover:SetVertexColor(0.30, 0.43, 0.52, 0.24)

        local function AddCellEdge(point, relativePoint, width, height)
            local edge = button:CreateTexture(nil, "BORDER")
            edge:SetTexture("Interface\\Buttons\\WHITE8X8")
            edge:SetPoint(point, button, relativePoint)
            edge:SetSize(width, height)
            edge:SetVertexColor(0.38, 0.43, 0.47, 0.95)
        end
        AddCellEdge("TOPLEFT", "TOPLEFT", cellSize, 1)
        AddCellEdge("BOTTOMLEFT", "BOTTOMLEFT", cellSize, 1)
        AddCellEdge("TOPLEFT", "TOPLEFT", 1, cellSize)
        AddCellEdge("TOPRIGHT", "TOPRIGHT", 1, cellSize)

        local extraX = math.floor((col - 1) / 3) * 6
        local extraY = math.floor((row - 1) / 2) * 6
        button:SetPoint(
            "TOPLEFT",
            mainFrame,
            "TOPLEFT",
            gridStartX + (col - 1) * cellSize + extraX,
            gridStartY - (row - 1) * cellSize - extraY
        )

        -- Do not rely on GetNormalFontString(): it can be nil for this template
        -- in the TBC client. An explicit FontString works across the target UI.
        button.valueText = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        button.valueText:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.valueText:SetFont("Fonts\\FRIZQT__.TTF", 18, "OUTLINE")
        button.valueText:SetText("")

        button.highlight = button:CreateTexture(nil, "ARTWORK")
        button.highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
        button.highlight:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -4)
        button.highlight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 4)
        button.highlight:Hide()

        button:SetScript("OnClick", function()
            if not gameActive then
                return
            end
            selectedCell = index
            RefreshCellSelection()
        end)

        cells[index] = button
    end
end

-- Block separators are drawn on a dedicated frame above the cells so that
-- no button can cover them. Coordinates are centered in the 6px gutters.
local dividerFrame = CreateFrame("Frame", nil, mainFrame)
dividerFrame:SetFrameLevel(mainFrame:GetFrameLevel() + 20)
dividerFrame:SetAllPoints(mainFrame)

local function AddDivider(x, y, width, height)
    local line = dividerFrame:CreateTexture(nil, "OVERLAY")
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetPoint("TOPLEFT", dividerFrame, "TOPLEFT", x, y)
    line:SetSize(width, height)
    line:SetVertexColor(0.72, 0.62, 0.40, 0.9)
end

-- The grid uses 6px gaps after column 3 and after rows 2 and 4.
local gridWidth = (6 * cellSize) + 6
local gridHeight = (6 * cellSize) + 12
AddDivider(gridStartX + (3 * cellSize) + 2, gridStartY, 2, gridHeight)
AddDivider(gridStartX + 1, gridStartY - (2 * cellSize) - 2, gridWidth - 2, 2)
AddDivider(gridStartX + 1, gridStartY - (4 * cellSize) - 8, gridWidth - 2, 2)

local numPadButtons = {}

-- Forward declarations: the list is filtered to friends and guild members only.
local IsGuildContact
local IsFriendContact

local function GetClassColorCode(classToken)
    if type(classToken) ~= "string" or classToken == "" then
        return "FFFFFFFF"
    end

    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if color and color.r and color.g and color.b then
        return string.format(
            "FF%02X%02X%02X",
            math.floor(color.r * 255 + 0.5),
            math.floor(color.g * 255 + 0.5),
            math.floor(color.b * 255 + 0.5)
        )
    end

    return "FFFFFFFF"
end

local function UpdateHighscoreList()
    if not hsText then
        return
    end

    local sorted = {}
    local ownKey = (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "")
    for player, data in pairs(FlightMiniSudokuDB.highscores) do
        local isOwnRecord = player == ownKey
            or FlightMiniSudokuDB.ownedCharacters[player] == true
            or (type(data) == "table" and data.owner == "local")
        local isAllowed = isOwnRecord
            or (IsGuildContact and IsGuildContact(player))
            or (IsFriendContact and IsFriendContact(player))
        if isAllowed and type(data) == "table" and tonumber(data.time) then
            table.insert(sorted, {
                name = player,
                time = tonumber(data.time),
                hints = tonumber(data.hints) or 0,
                class = data.class,
                formatted = data.formatted or FormatTime(tonumber(data.time)),
            })
        end
    end

    table.sort(sorted, function(a, b)
        if a.time == b.time then
            return a.hints < b.hints
        end
        return a.time < b.time
    end)

    if #sorted == 0 then
        hsText:SetText(loc.noHighscores)
        return
    end

    local lines = {}
    for i = 1, math.min(20, #sorted) do
        local entry = sorted[i]
        local cleanName = entry.name:match("^([^%-]+)") or entry.name
        local coloredName = "|c" .. GetClassColorCode(entry.class) .. cleanName .. "|r"
        local hintWord = entry.hints == 1 and (loc == L.deDE and "Tipp" or "hint")
            or (loc == L.deDE and "Tipps" or "hints")
        table.insert(
            lines,
            string.format("%d. %s – %s (%d %s)", i, coloredName, entry.formatted, entry.hints, hintWord)
        )
    end

    hsText:SetText(table.concat(lines, "\n"))
end

local function UpdateUI()
    local timeText = FormatTime(secondsElapsed)
    statsText:SetText(
        loc.timeLabel .. timeText .. " | " ..
        loc.hintsLabel .. hintsUsed .. " (Strafe: +" .. (hintsUsed * 15) .. "s)"
    )
    EnsureDatabase()
    completedGamesText:SetText(
        string.format(loc.completedGames, FlightMiniSudokuDB.completedGames)
    )

    if hintCooldownTimer > 0 then
        btnHint:SetText(tostring(hintCooldownTimer) .. "s")
        btnHint:Disable()
    else
        btnHint:SetText(loc.hint)
        btnHint:Enable()
    end

    for i = 1, 36 do
        local value = currentPuzzle[i] or 0
        cells[i].valueText:SetText(value ~= 0 and tostring(value) or "")
        cells[i].isOriginal = (originalPuzzle[i] or 0) ~= 0
    end

    if btnNew then
        btnNew:SetText(gameStarted and loc.newGame or loc.startGame)
    end

    RefreshCellSelection()
end

local function StopTimer()
    timerRunning = false
    timerAccumulator = 0
end

local function StartTimer()
    timerAccumulator = 0
    timerRunning = true
end

-- OnUpdate is available on the TBC client and does not depend on C_Timer.NewTicker.
timerFrame:SetScript("OnUpdate", function(_, elapsed)
    if not timerRunning or not gameActive then
        return
    end

    timerAccumulator = timerAccumulator + elapsed
    while timerAccumulator >= 1 do
        timerAccumulator = timerAccumulator - 1
        secondsElapsed = secondsElapsed + 1

        if hintCooldownTimer > 0 then
            hintCooldownTimer = hintCooldownTimer - 1
        end

        UpdateUI()
    end
end)

-- ---------------------------------------------------------------------------
-- Private highscore synchronization (friends + guild only)
-- ---------------------------------------------------------------------------

local function SendAddonPayload(message, channel, target)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, message, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, message, channel, target)
    end
end

local function ShortPlayerName(name)
    if type(name) ~= "string" then return "" end
    return (name:match("^([^%-]+)") or name):lower()
end

IsGuildContact = function(sender)
    if not sender or not (IsInGuild and IsInGuild()) then return false end
    local wanted = ShortPlayerName(sender)
    if wanted == "" then return false end
    if GetNumGuildMembers and GetGuildRosterInfo then
        for i = 1, GetNumGuildMembers() do
            local name = GetGuildRosterInfo(i)
            if name and ShortPlayerName(name) == wanted then
                return true
            end
        end
    end
    return false
end

IsFriendContact = function(sender)
    if not sender then return false end
    local wanted = ShortPlayerName(sender)
    if wanted == "" then return false end
    if GetNumFriends and GetFriendInfo then
        for i = 1, GetNumFriends() do
            local name = GetFriendInfo(i)
            if name and ShortPlayerName(name) == wanted then
                return true
            end
        end
    end
    return false
end

local function IsAllowedHighscoreContact(sender, channel)
    if channel == "GUILD" then
        return IsGuildContact(sender)
    elseif channel == "WHISPER" then
        return IsFriendContact(sender) or IsGuildContact(sender)
    end
    return false
end

local function SendHighscoreToGuild(recordKey, totalTime, hintCount, classToken)
    if IsInGuild and IsInGuild() then
        SendAddonPayload(string.format("HS|%s|%d|%d|%s", recordKey, totalTime, hintCount, classToken or "UNKNOWN"), "GUILD")
    end
end

local function SendHighscoreToOnlineFriends(recordKey, totalTime, hintCount, classToken)
    if not (GetNumFriends and GetFriendInfo) then return end
    local sent = {}
    for i = 1, GetNumFriends() do
        local name, _, _, _, connected = GetFriendInfo(i)
        if name and connected then
            local shortName = ShortPlayerName(name)
            if shortName ~= "" and not sent[shortName] then
                sent[shortName] = true
                SendAddonPayload(string.format("HS|%s|%d|%d|%s", recordKey, totalTime, hintCount, classToken or "UNKNOWN"), "WHISPER", name)
            end
        end
    end
end

local function SendAllHighscoresTo(sender)
    local records = {}
    local ownKey = (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "")
    for key, data in pairs(FlightMiniSudokuDB.highscores) do
        local isAllowed = key == ownKey
            or FlightMiniSudokuDB.ownedCharacters[key] == true
            or (type(data) == "table" and data.owner == "local")
            or IsGuildContact(key)
            or IsFriendContact(key)
        local recordTime = type(data) == "table" and tonumber(data.time)
        if isAllowed and recordTime and recordTime > 0 then
            table.insert(records, {
                key = key,
                time = recordTime,
                hints = tonumber(data.hints) or 0,
                class = data.class,
            })
        end
    end
    table.sort(records, function(a, b) return a.time < b.time end)

    -- The UI displays twenty entries; exchange each client's best twenty.
    for i = 1, math.min(20, #records) do
        local record = records[i]
        SendAddonPayload(string.format(
            "HS|%s|%d|%d|%s", record.key, record.time, record.hints, record.class or "UNKNOWN"
        ), "WHISPER", sender)
    end
end

local function RequestHighscoreSync()
    -- A single guild request reaches all online guild members without visible
    -- chat output. Friends outside the guild are contacted by hidden whispers.
    if IsInGuild and IsInGuild() then
        SendAddonPayload("REQ", "GUILD")
    end
    if GetNumFriends and GetFriendInfo then
        local sent = {}
        for i = 1, GetNumFriends() do
            local name, _, _, _, connected = GetFriendInfo(i)
            if name and connected then
                local shortName = ShortPlayerName(name)
                if shortName ~= "" and not sent[shortName] then
                    sent[shortName] = true
                    SendAddonPayload("REQ", "WHISPER", name)
                end
            end
        end
    end
end

local function SaveHighscore()
    local penalty = hintsUsed * 15
    local totalTime = secondsElapsed + penalty
    local formatted = FormatTime(totalTime)
    local playerName = UnitName("player") or "Unknown"
    local realmName = GetRealmName() or ""
    local key = CurrentCharacterKey()
    local _, playerClassToken = UnitClass("player")
    FlightMiniSudokuDB.ownedCharacters[key] = true

    local old = FlightMiniSudokuDB.highscores[key]
    local oldTime = old and tonumber(old.time)
    -- Earlier addon builds could save a bogus 0:00 record. Treat that as
    -- invalid so the first real completion can replace it.
    local isPersonalBest = not oldTime or oldTime <= 0 or totalTime < oldTime

    if isPersonalBest then
        FlightMiniSudokuDB.highscores[key] = {
            time = totalTime,
            hints = hintsUsed,
            formatted = formatted,
            class = playerClassToken,
            owner = "local",
        }
    elseif old then
        old.owner = "local"
        if not old.class and playerClassToken then
            old.class = playerClassToken
        end
    end

    PrintMessage(string.format(loc.winMessage, formatted, hintsUsed, penalty))
    if isPersonalBest then
        PrintMessage(loc.bestMessage)
    end
    UpdateHighscoreList()

    -- Create a fresh dialog for each completion. This avoids stale hidden-frame
    -- state in some Classic UI builds and guarantees every completed run gets
    -- its own visible result window.
    local resultDialog = CreateFrame(
        "Frame",
        nil,
        UIParent,
        "BasicFrameTemplateWithInset"
    )
    resultDialog:SetSize(340, 180)
    resultDialog:SetPoint("CENTER")
    resultDialog:SetFrameStrata("DIALOG")
    resultDialog:SetClampedToScreen(true)

    local resultTitle = resultDialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    resultTitle:SetPoint("TOP", resultDialog, "TOP", 0, -6)
    resultTitle:SetText(loc.solvedTitle)

    local resultMessage = resultDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resultMessage:SetPoint("TOPLEFT", resultDialog, "TOPLEFT", 20, -45)
    resultMessage:SetPoint("RIGHT", resultDialog, "RIGHT", -20, 0)
    resultMessage:SetJustifyH("CENTER")
    resultMessage:SetJustifyV("TOP")
    resultMessage:SetText(string.format(loc.solvedText, formatted, hintsUsed, penalty))

    local resultOkay = CreateFrame("Button", nil, resultDialog, "UIPanelButtonTemplate")
    resultOkay:SetSize(100, 25)
    resultOkay:SetPoint("BOTTOM", resultDialog, "BOTTOM", 0, 15)
    resultOkay:SetText(OKAY or "OK")
    resultOkay:SetScript("OnClick", function()
        resultDialog:Hide()
    end)

    resultDialog:Show()
    if resultDialog.Raise then
        resultDialog:Raise()
    end

    if isPersonalBest then
        local recordKey = playerName .. "-" .. realmName
        -- Share only with guild members and online friends. Party/raid members
        -- are deliberately never included in the leaderboard or sync traffic.
        if SendHighscoreToGuild then
            SendHighscoreToGuild(recordKey, totalTime, hintsUsed, playerClassToken)
            SendHighscoreToOnlineFriends(recordKey, totalTime, hintsUsed, playerClassToken)
        end
    end
end

local function FinishGame()
    if not gameActive then
        return
    end

    gameActive = false
    StopTimer()
    EnsureDatabase()
    FlightMiniSudokuDB.completedGames = FlightMiniSudokuDB.completedGames + 1
    UpdateUI()
    SaveHighscore()
end

local function EnterNumber(number)
    if not gameActive or not selectedCell then
        return
    end

    local cell = cells[selectedCell]
    if cell.isOriginal then
        return
    end

    currentPuzzle[selectedCell] = number
    UpdateUI()

    if CheckWinCondition() then
        FinishGame()
    end
end

for number = 1, 6 do
    local button = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    button:SetSize(42, 35)
    button:SetPoint(
        "TOPLEFT",
        mainFrame,
        "TOPLEFT",
        controlsStartX + (number - 1) * 48,
        gridStartY - (6 * cellSize) - 20
    )
    button:SetText(tostring(number))
    button:SetScript("OnClick", function()
        EnterNumber(number)
    end)
    numPadButtons[number] = button
end

-- Compact red X next to the number pad clears only the selected editable cell.
local btnClear = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
btnClear:SetSize(32, 35)
btnClear:SetPoint(
    "LEFT",
    numPadButtons[6],
    "RIGHT",
    5,
    0
)
btnClear:SetText("X")
local clearText = btnClear:GetFontString()
if clearText then
    clearText:SetTextColor(1, 0.12, 0.12)
end
btnClear:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(loc.clearTooltip)
    GameTooltip:Show()
end)
btnClear:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)
btnClear:SetScript("OnClick", function()
    if not gameActive or not selectedCell then
        return
    end
    if cells[selectedCell].isOriginal then
        return
    end

    currentPuzzle[selectedCell] = 0
    UpdateUI()
end)

btnNew = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
btnNew:SetSize(100, 25)
btnNew:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", controlsStartX, gridStartY - (6 * cellSize) - 55)
btnNew:SetText(loc.startGame)
btnNew:SetScript("OnClick", function()
    GenerateNewSudoku()
    gameStarted = true
    btnNew:SetText(loc.newGame)
    UpdateUI()
    StartTimer()
end)

local btnReset = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
btnReset:SetSize(100, 25)
btnReset:SetPoint("LEFT", btnNew, "RIGHT", 10, 0)
btnReset:SetText(loc.reset)
btnReset:SetScript("OnClick", function()
    if not gameActive then
        return
    end

    for i = 1, 36 do
        if not cells[i].isOriginal then
            currentPuzzle[i] = 0
        end
    end

    selectedCell = nil
    UpdateUI()
end)

btnHint = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
btnHint:SetSize(100, 25)
btnHint:SetPoint("LEFT", btnReset, "RIGHT", 10, 0)
btnHint:SetText(loc.hint)
btnHint:SetScript("OnClick", function()
    if not gameActive or hintCooldownTimer > 0 then
        return
    end

    local candidates = {}
    for i = 1, 36 do
        if currentPuzzle[i] ~= solution[i] then
            table.insert(candidates, i)
        end
    end

    if #candidates == 0 then
        return
    end

    local target = candidates[math.random(1, #candidates)]
    currentPuzzle[target] = solution[target]
    hintsUsed = hintsUsed + 1
    hintCooldownTimer = 10

    PrintMessage(loc.hintUsed)
    UpdateUI()

    if CheckWinCondition() then
        FinishGame()
    end
end)

-- Highscore panel
local hsContainer = CreateFrame("Frame", nil, mainFrame, "InsetFrameTemplate")
hsContainer:SetSize(265, 370)
hsContainer:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 370, -52)

local hsTitle = hsContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
hsTitle:SetPoint("TOP", hsContainer, "TOP", 0, -8)
hsTitle:SetText(loc.highscoresTitle)

local hsSeparator = hsContainer:CreateTexture(nil, "ARTWORK")
hsSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
hsSeparator:SetPoint("TOPLEFT", hsContainer, "TOPLEFT", 12, -27)
hsSeparator:SetSize(241, 1)
hsSeparator:SetVertexColor(0.42, 0.46, 0.48, 0.75)

hsText = hsContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hsText:SetPoint("TOPLEFT", hsContainer, "TOPLEFT", 12, -34)
hsText:SetWidth(235)
hsText:SetJustifyH("LEFT")
hsText:SetJustifyV("TOP")
hsText:SetSpacing(1) -- Slightly more breathing room while keeping 20 rows in view.

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------

local minimapButton = CreateFrame("Button", "FlightMiniSudokuMinimapButton", Minimap)
minimapButton:SetSize(31, 31)
minimapButton:SetFrameLevel(Minimap:GetFrameLevel() + 5)
minimapButton:SetMovable(true)
minimapButton:EnableMouse(true)
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapButton:RegisterForDrag("LeftButton")

-- Custom Sudoku glyph: every tile is anchored to the exact button center.
-- This avoids the off-center artwork/transparent padding in some book icons.
local sudokuTileColors = {
    { 0.88, 0.72, 0.40 }, { 0.88, 0.72, 0.40 }, { 0.88, 0.72, 0.40 },
    { 0.88, 0.72, 0.40 }, { 0.48, 0.70, 0.82 }, { 0.88, 0.72, 0.40 },
    { 0.88, 0.72, 0.40 }, { 0.88, 0.72, 0.40 }, { 0.88, 0.72, 0.40 },
}

for row = 1, 3 do
    for col = 1, 3 do
        local index = (row - 1) * 3 + col
        local tile = minimapButton:CreateTexture(nil, "ARTWORK")
        tile:SetTexture("Interface\\Buttons\\WHITE8X8")
        tile:SetSize(5, 5)
        tile:SetPoint(
            "CENTER",
            minimapButton,
            "CENTER",
            (col - 2) * 5.5,
            (2 - row) * 5.5
        )
        local color = sudokuTileColors[index]
        tile:SetVertexColor(color[1], color[2], color[3], 1)
    end
end

local borderTexture = minimapButton:CreateTexture(nil, "OVERLAY")
borderTexture:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
borderTexture:SetSize(53, 53)
-- Blizzard's tracking-border artwork has transparent padding. LibDBIcon's
-- established layout anchors this overlay at TOPLEFT, not CENTER.
borderTexture:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)

local function UpdateMinimapPosition()
    local angle = math.rad(tonumber(FlightMiniSudokuDB.minimapPos) or 45)
    local mapWidth = Minimap:GetWidth()
    if not mapWidth or mapWidth <= 0 then
        mapWidth = 140
    end

    -- Match LibDBIcon's established radial placement: button centers sit
    -- 80 UI units from the minimap center on a round minimap.
    local radius = 80
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Show the minimap launcher immediately; ADDON_LOADED also refreshes its position.
UpdateMinimapPosition()
minimapButton:Show()

local function OpenSettings()
    if InterfaceOptionsFrame_OpenToCategory and settingsPanel then
        InterfaceOptionsFrame_OpenToCategory(settingsPanel)
        -- Some Classic clients need the category call twice to select it.
        InterfaceOptionsFrame_OpenToCategory(settingsPanel)
    elseif Settings and Settings.OpenToCategory and settingsPanel.categoryID then
        Settings.OpenToCategory(settingsPanel.categoryID)
    else
        PrintMessage(loc.settingsUnavailable)
    end
end

minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local cursorX, cursorY = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        local centerX, centerY = Minimap:GetCenter()

        if centerX and centerY then
            centerX = centerX * scale
            centerY = centerY * scale
            local angle = math.atan2(cursorY - centerY, cursorX - centerX)
            FlightMiniSudokuDB.minimapPos = math.deg(angle)
            UpdateMinimapPosition()
        end
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

minimapButton:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then
        OpenSettings()
    else
        if mainFrame:IsShown() then
            mainFrame:Hide()
        else
            mainFrame:Show()
        end
    end
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(loc.minimapTooltip, nil, nil, nil, nil, true)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

SLASH_FLIGHTMINISUDOKU1 = "/fms"
SlashCmdList["FLIGHTMINISUDOKU"] = function(message)
    local command = (message or ""):lower():match("^%s*(.-)%s*$")

    if command == "reset" then
        FlightMiniSudokuDB.minimapPos = 45
        UpdateMinimapPosition()
        PrintMessage(loc.resetPosMsg)
    else
        if mainFrame:IsShown() then
            mainFrame:Hide()
        else
            mainFrame:Show()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Settings panel
-- ---------------------------------------------------------------------------

settingsPanel = CreateFrame("Frame", "FlightMiniSudokuSettingsPanel", UIParent)
settingsPanel.name = "FlightMiniSudoku"

local settingsTitle = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
settingsTitle:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 16, -16)
settingsTitle:SetText(loc.title)

local checkbox = CreateFrame(
    "CheckButton",
    "FlightMiniSudokuAutoOpenCheck",
    settingsPanel,
    "InterfaceOptionsCheckButtonTemplate"
)
checkbox:SetPoint("TOPLEFT", settingsTitle, "BOTTOMLEFT", 0, -16)

if checkbox.Text then
    checkbox.Text:SetText(loc.settingsAutoOpen)
elseif _G["FlightMiniSudokuAutoOpenCheckText"] then
    _G["FlightMiniSudokuAutoOpenCheckText"]:SetText(loc.settingsAutoOpen)
end

checkbox:SetChecked(FlightMiniSudokuDB.autoOpen)
checkbox:SetScript("OnClick", function(self)
    FlightMiniSudokuDB.autoOpen = self:GetChecked() and true or false
end)

if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(settingsPanel)
elseif Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local category = Settings.RegisterCanvasLayoutCategory(settingsPanel, loc.title)
    Settings.RegisterAddOnCategory(category)
    settingsPanel.categoryID = category:GetID()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_CONTROL_LOST")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("FRIENDLIST_UPDATE")

local lastTaxiNodeSelection = 0

-- TakeTaxiNode runs when a flight destination is selected. PLAYER_CONTROL_LOST
-- follows at taxi departure; correlating the two avoids unrelated control loss.
if type(TakeTaxiNode) == "function" and type(hooksecurefunc) == "function" then
    hooksecurefunc("TakeTaxiNode", function()
        lastTaxiNodeSelection = GetTime()
    end)
end

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureDatabase()
        UpdateMinimapPosition()
        minimapButton:Show()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, UpdateMinimapPosition)
        end

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(PREFIX)
        end

        -- The board starts empty. The player explicitly starts the first game.
        gameActive = false
        gameStarted = false
        secondsElapsed = 0
        hintsUsed = 0
        hintCooldownTimer = 0
        UpdateUI()
        UpdateHighscoreList()

    elseif event == "PLAYER_CONTROL_LOST" then
        -- Open only when control is lost immediately after selecting a taxi node.
        if FlightMiniSudokuDB.autoOpen
            and lastTaxiNodeSelection > 0
            and (GetTime() - lastTaxiNodeSelection) <= 3 then
            lastTaxiNodeSelection = 0
            if not mainFrame:IsShown() then
                mainFrame:Show()
            end
        end

    elseif event == "PLAYER_LOGIN" then
        RegisterCurrentCharacter()
        UpdateHighscoreList()
        if IsInGuild and IsInGuild() and GuildRoster then
            GuildRoster()
        end
        -- Give the guild/friend rosters time to populate before requesting data.
        if C_Timer and C_Timer.After then
            C_Timer.After(5, RequestHighscoreSync)
        else
            RequestHighscoreSync()
        end

    elseif event == "GUILD_ROSTER_UPDATE" or event == "FRIENDLIST_UPDATE" then
        -- Re-filter the board when membership changes; offline friends remain eligible.
        UpdateHighscoreList()

    elseif event == "CHAT_MSG_ADDON" and arg1 == PREFIX then
        local message = arg2 or ""
        local channel = arg3
        local sender = arg4
        if not IsAllowedHighscoreContact(sender, channel) then
            return
        end

        if message == "REQ" then
            -- Answer only the requesting friend/guild member via hidden addon whisper.
            SendAllHighscoresTo(sender)
        else
            local recordKey, timeString, hintsString, classToken =
                message:match("^HS|([^|]+)|(%d+)|(%d+)|([%a_]+)$")
            if not recordKey then
                recordKey, timeString, hintsString =
                    message:match("^HS|([^|]+)|(%d+)|(%d+)$")
            end
            local totalTime = tonumber(timeString)
            local hintCount = tonumber(hintsString)
            if recordKey and totalTime and totalTime > 0 and hintCount then
                local previous = FlightMiniSudokuDB.highscores[recordKey]
                if not previous or not tonumber(previous.time) or totalTime < tonumber(previous.time) then
                    FlightMiniSudokuDB.highscores[recordKey] = {
                        time = totalTime,
                        hints = hintCount,
                        formatted = FormatTime(totalTime),
                        class = classToken,
                        owner = previous and previous.owner or nil,
                    }
                    UpdateHighscoreList()
                elseif previous and not previous.class and classToken then
                    previous.class = classToken
                    UpdateHighscoreList()
                end
            end
        end
    end
end)
