-- ---------------------------------------------------------------------------
-- AwaleScreen — Awalé / Oware game screen (vs AI or two players)
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local MenuHelper  = require("menu_helper")
local ScreenBase  = require("screen_base")

local AwaleBoard       = lrequire("board")
local AwaleBoardWidget = lrequire("board_widget")

local GAME_RULES_EN = _([[
Awalé (Oware) — Rules

Two players face each other across two rows of six pits; each owns the row nearest to them. Every pit starts with 4 seeds.

On your turn:
• Tap one of your pits. Its seeds are sown one by one, counter-clockwise, into the following pits. With 12 seeds or more the sowing laps the board and skips the pit it started from.
• If the last seed lands in an opponent pit that now holds 2 or 3 seeds, you capture them, and also the seeds of the opponent pits just before it, going backwards, as long as each holds 2 or 3.
• A move that would capture every seed on the opponent's side (grand slam) is allowed, but captures nothing.
• If your opponent has no seeds left, you must play a move that gives them some. If you can't, the game ends and you keep the seeds left on your side.

The first player to capture 25 seeds wins; 24–24 is a draw.

If the same position comes back a third time, or 100 moves pass without a capture, the game ends and each player keeps the seeds on their own side.
]])

local GAME_RULES_FR = [[
Awalé — Règles

Deux joueurs se font face, chacun possédant la rangée de six cases la plus proche de lui. Chaque case commence avec 4 graines.

À votre tour :
• Touchez une de vos cases. Ses graines sont semées une à une, dans le sens inverse des aiguilles d'une montre, dans les cases suivantes. À partir de 12 graines, le semis fait le tour et saute la case de départ.
• Si la dernière graine tombe dans une case adverse qui contient alors 2 ou 3 graines, vous les prenez, ainsi que celles des cases adverses précédentes, en remontant, tant qu'elles contiennent 2 ou 3 graines.
• Un coup qui prendrait toutes les graines de l'adversaire (grand chelem) est permis, mais ne prend rien.
• Si votre adversaire n'a plus de graines, vous devez jouer un coup qui lui en donne. Si c'est impossible, la partie s'arrête et vous gardez les graines de votre côté.

Le premier à prendre 25 graines gagne ; 24–24 est un match nul.

Si une même position revient pour la troisième fois, ou après 100 coups sans prise, la partie s'arrête et chacun garde les graines de son côté.
]]

local AwaleScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AwaleScreen:init()
    local state = self.plugin:loadState()
    self.board  = AwaleBoard:new()
    if not self.board:load(state) then
        self.board:reset()
    end
    ScreenBase.init(self)  -- calls buildLayout()
    if self:_isAITurn() then
        UIManager:scheduleIn(0.1, function() self:triggerAI() end)
    end
end

function AwaleScreen:isRoundOver()
    return self.board.status ~= "playing"
end

function AwaleScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function AwaleScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Awalé"), function()
        local items = {
            { text = _("New game"),          callback = function() self:onNewGame() end },
            { text = self:_diffLabel(),      callback = function() self:openDifficultyMenu() end },
            { text = self:_playersLabel(),   callback = function() self:openPlayersMenu() end },
        }
        -- The side choice only means something against the AI.
        if self:_players() == 1 then
            items[#items + 1] = { text = self:_sideLabel(),
                                  callback = function() self:openSideMenu() end }
        end
        items[#items + 1] = self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR)
        return items
    end)

    local controls_w = self:getControlsWidth()
    self.status_text:setMaxWidth(controls_w)
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar({
            { text = _("Undo"), callback = function() self:onUndo() end },
        }),
    }

    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = AwaleBoardWidget:new{
        board       = self.board,
        max_width   = budget_w,
        max_height  = budget_h,
        labels      = self:_storeLabels(),
        playable    = function() return self:_playablePits() end,
        onPitAction = function(pit) self:onPitTap(pit) end,
    }
    local board_frame = FrameContainer:new{
        padding    = 0,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Turn helpers
-- ---------------------------------------------------------------------------

function AwaleScreen:_players()
    return self.plugin:getSetting("players", 1)
end

-- The side the human plays against the AI: 1 = South (moves first), 2 = North.
function AwaleScreen:_humanSide()
    return self.plugin:getSetting("side", 1)
end

function AwaleScreen:_isAITurn()
    return self:_players() == 1 and self.board.status == "playing"
        and self.board.turn ~= self:_humanSide()
end

-- Pits drawn with a bold frame: the legal moves, on a human's turn only.
function AwaleScreen:_playablePits()
    local set = {}
    if self:_isAITurn() or self.ai_pending then return set end
    for _, m in ipairs(self.board:legalMoves()) do set[m] = true end
    return set
end

function AwaleScreen:_sideName(p)
    return (p == 1) and _("South") or _("North")
end

function AwaleScreen:_storeLabels()
    if self:_players() == 1 then
        local h = self:_humanSide()
        return { h == 1 and _("You") or _("AI"), h == 2 and _("You") or _("AI") }
    end
    return { _("South"), _("North") }
end

-- ---------------------------------------------------------------------------
-- Moves
-- ---------------------------------------------------------------------------

function AwaleScreen:onPitTap(pit)
    local board = self.board
    if board.status ~= "playing" or self.ai_pending or self:_isAITurn() then return end

    if AwaleBoard.owner(pit) ~= board.turn then
        self:updateStatus(_("Play a pit on your own side."))
        return
    end
    if board.pits[pit] == 0 then
        self:updateStatus(_("That pit is empty."))
        return
    end
    if not board:isLegal(pit) then
        self:updateStatus(_("Your opponent has no seeds: play a move that gives them some."))
        return
    end
    self:_afterMove(board:play(pit))
end

function AwaleScreen:_afterMove(result)
    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())
    self:updateStatus()
    if result == "over" then
        self:showMessage(self:_resultText(), 4)
    elseif self:_isAITurn() then
        self:triggerAI()
    end
end

function AwaleScreen:triggerAI()
    if not self:_isAITurn() or self.ai_pending then return end
    self.ai_pending = true
    self.board_widget:refresh()
    self:updateStatus(_("AI is thinking..."))
    local level = self.plugin:getSetting("difficulty", "medium")
    UIManager:scheduleIn(0.05, function()
        self.ai_pending = false
        if not self:_isAITurn() then return end
        local m = self.board:getAIMove(level)
        if m then self:_afterMove(self.board:play(m)) end
    end)
end

-- Against the AI, undo takes back the AI's reply and the player's move, so
-- it is the player's turn again.
function AwaleScreen:onUndo()
    if self.ai_pending then return end
    local board = self.board
    if not board:canUndo() then
        self:updateStatus(_("Nothing to undo."))
        return
    end
    board:undo()
    if self:_players() == 1 then
        while board.turn ~= self:_humanSide() and board:canUndo() do
            board:undo()
        end
    end
    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())
    self:updateStatus()
    -- Undoing to the very start with the AI moving first: let it play again.
    if self:_isAITurn() then self:triggerAI() end
end

function AwaleScreen:onNewGame()
    self.board:reset()
    self.plugin:saveState(self:serializeState())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    if self:_isAITurn() then
        UIManager:scheduleIn(0.1, function() self:triggerAI() end)
    end
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function AwaleScreen:_resultText()
    local b = self.board
    local s1, s2 = b.stores[1], b.stores[2]
    local head
    if b.winner == 0 then
        head = T(_("Draw, %1–%2."), s1, s2)
    else
        local hi, lo = math.max(s1, s2), math.min(s1, s2)
        if self:_players() == 1 then
            head = (b.winner == self:_humanSide())
                and T(_("You win, %1–%2!"), hi, lo)
                or  T(_("The AI wins, %1–%2."), hi, lo)
        else
            head = T(_("%1 wins, %2–%3!"), self:_sideName(b.winner), hi, lo)
        end
    end
    local why
    if b.end_reason == "starved" then
        why = _("No move could feed the empty side.")
    elseif b.end_reason == "repetition" then
        why = _("Position repeated: each player keeps their own seeds.")
    elseif b.end_reason == "limit" then
        why = _("100 moves without a capture: each player keeps their own seeds.")
    end
    return why and (head .. " " .. why) or head
end

function AwaleScreen:_lastMoveText()
    local b = self.board
    if not b.last_move then return nil end
    if b.last_slam then return _("Grand slam: nothing captured") end
    if b.last_capture > 0 then return T(_("Captured %1"), b.last_capture) end
    return nil
end

function AwaleScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.status ~= "playing" then
        status = self:_resultText()
    else
        local b = self.board
        local turn
        if self:_players() == 1 then
            turn = (b.turn == self:_humanSide()) and _("Your turn") or _("AI is thinking...")
        else
            turn = (b.turn == 1) and _("South to move") or _("North to move")
        end
        local dlabel
        if self:_players() == 1 then
            local diff = self.plugin:getSetting("difficulty", "medium")
            dlabel = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        end
        status = self:joinStatus(dlabel, turn, self:_lastMoveText())
    end
    ScreenBase.updateStatus(self, status)
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function AwaleScreen:_playersLabel()
    return T(_("Players: %1"), self:_players())
end

function AwaleScreen:_diffLabel()
    local diff = self.plugin:getSetting("difficulty", "medium")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function AwaleScreen:_sideLabel()
    return T(_("Play as: %1"), self:_sideName(self:_humanSide()))
end

function AwaleScreen:openPlayersMenu()
    MenuHelper.openPickerMenu{
        title      = _("Players"),
        items      = {
            { id = 1, text = _("1 player (vs AI)") },
            { id = 2, text = _("2 players") },
        },
        current_id = self:_players(),
        on_select  = function(id)
            self.plugin:saveSetting("players", id)
            -- Store labels (You/AI vs South/North) change with the mode.
            self:buildLayout()
            UIManager:setDirty(self, function() return "ui", self.dimen end)
            if self:_isAITurn() then self:triggerAI() end
        end,
        parent = self,
    }
end

function AwaleScreen:openSideMenu()
    MenuHelper.openPickerMenu{
        title      = _("Play as"),
        items      = {
            { id = 1, text = _("South (plays first)") },
            { id = 2, text = _("North (plays second)") },
        },
        current_id = self:_humanSide(),
        on_select  = function(id)
            self.plugin:saveSetting("side", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

function AwaleScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:updateStatus()
        end,
        parent = self,
    }
end

return AwaleScreen
