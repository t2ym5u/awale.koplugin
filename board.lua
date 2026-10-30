-- ---------------------------------------------------------------------------
-- AwaleBoard — game logic and AI for Awalé / Oware (abapa rules)
--
-- pits[1..12], numbered in sowing (counter-clockwise) order:
--   pits 1..6  belong to South (player 1), the bottom row, left to right;
--   pits 7..12 belong to North (player 2), the top row, right to left.
-- So on screen the top row reads 12 11 10 9 8 7 and the bottom 1 2 3 4 5 6,
-- and sowing always goes to the next index (12 wraps to 1).
--
-- Rules (abapa):
--   * Pick one of your non-empty pits and sow its seeds one by one into the
--     following pits. A pit of 12+ seeds laps the board: the origin pit is
--     skipped and stays empty.
--   * If the last seed lands in an opponent pit that now holds 2 or 3, those
--     seeds are captured, and so are the preceding opponent pits (going
--     backwards) while they hold 2 or 3.
--   * Grand slam: a move that would capture every seed on the opponent's side
--     is allowed but captures nothing.
--   * If the opponent's side is empty you must play a move that gives them
--     seeds. If no move can, the game ends and you take the seeds left.
--   * First to 25 seeds wins (24-24 is a draw).
--   * Endless cycles: a position seen for the third time, or 100 plies with
--     no capture, ends the game; each player takes the seeds on their side.
-- ---------------------------------------------------------------------------

local AwaleBoard = {}
AwaleBoard.__index = AwaleBoard

local NPITS            = 12
local SEEDS_PER_PIT    = 4
local WIN_STORE        = 25     -- more than half of the 48 seeds
local REPEAT_LIMIT     = 3      -- third occurrence of a position ends the game
local NO_CAPTURE_LIMIT = 100    -- plies without a capture end the game

AwaleBoard.NPITS            = NPITS
AwaleBoard.WIN_STORE        = WIN_STORE
AwaleBoard.NO_CAPTURE_LIMIT = NO_CAPTURE_LIMIT

-- ---------------------------------------------------------------------------
-- Pure rule helpers, shared by the board and the search. They work on a bare
-- pits array so the search can copy 12 numbers per node and nothing else.
-- ---------------------------------------------------------------------------

local function sideRange(p)
    if p == 1 then return 1, 6 end
    return 7, 12
end

local function sideSum(pits, p)
    local lo, hi = sideRange(p)
    local s = 0
    for i = lo, hi do s = s + pits[i] end
    return s
end

-- Legal moves for player p. When the opponent's side is empty, only moves
-- that reach it (seeds > distance to the end of our own row) are legal.
local function legalMoves(pits, p)
    local lo, hi = sideRange(p)
    local must_feed = sideSum(pits, 3 - p) == 0
    local moves = {}
    for i = lo, hi do
        local s = pits[i]
        if s > 0 and (not must_feed or s > hi - i) then
            moves[#moves + 1] = i
        end
    end
    return moves
end

-- Sow pit m for player p, then capture. Mutates pits.
-- Returns captured, last_pit, grand_slam (true when a capture was cancelled).
local function sowAndCapture(pits, p, m)
    local seeds = pits[m]
    pits[m] = 0
    local pos = m
    while seeds > 0 do
        pos = pos % NPITS + 1
        if pos ~= m then                -- laps of 12+ skip the origin pit
            pits[pos] = pits[pos] + 1
            seeds = seeds - 1
        end
    end
    local olo, ohi = sideRange(3 - p)
    if pos < olo or pos > ohi then return 0, pos, false end
    local total, i = 0, pos
    while i >= olo and (pits[i] == 2 or pits[i] == 3) do
        total = total + pits[i]
        i = i - 1
    end
    if total == 0 then return 0, pos, false end
    if total == sideSum(pits, 3 - p) then
        return 0, pos, true             -- grand slam: allowed, captures nothing
    end
    for j = pos, i + 1, -1 do pits[j] = 0 end
    return total, pos, false
end

AwaleBoard.sideRange     = sideRange
AwaleBoard.sideSum       = sideSum
AwaleBoard.legalMovesOf  = legalMoves
AwaleBoard.sowAndCapture = sowAndCapture

local function copyPits(pits)
    local t = {}
    for i = 1, NPITS do t[i] = pits[i] end
    return t
end

-- ---------------------------------------------------------------------------
-- Constructor / reset
-- ---------------------------------------------------------------------------

function AwaleBoard:new()
    local o = setmetatable({}, self)
    o:reset()
    return o
end

function AwaleBoard:reset()
    self.pits = {}
    for i = 1, NPITS do self.pits[i] = SEEDS_PER_PIT end
    self.stores       = { 0, 0 }
    self.turn         = 1
    self.status       = "playing"   -- "playing" | "over"
    self.winner       = nil         -- 1, 2, or 0 for a draw
    self.end_reason   = nil         -- "score" | "starved" | "repetition" | "limit"
    self.last_move    = nil
    self.last_capture = 0
    self.last_slam    = false
    self.no_capture   = 0
    self.history      = {}          -- snapshots before each move (undo + repetition)
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

function AwaleBoard:legalMoves()
    if self.status ~= "playing" then return {} end
    return legalMoves(self.pits, self.turn)
end

function AwaleBoard:isLegal(m)
    for _, v in ipairs(self:legalMoves()) do
        if v == m then return true end
    end
    return false
end

-- Which player owns pit i.
function AwaleBoard.owner(i)
    return i <= 6 and 1 or 2
end

function AwaleBoard:seedsOnSide(p)
    return sideSum(self.pits, p)
end

-- Repetition key: the pits and who is to move. Stores are implied (the seed
-- total is fixed and a capture can never be undone), so they are left out.
local function positionKey(pits, turn)
    return table.concat(pits, ",") .. "/" .. turn
end

function AwaleBoard:_repetitions()
    local key = positionKey(self.pits, self.turn)
    local n = 1
    for _, snap in ipairs(self.history) do
        if positionKey(snap.pits, snap.turn) == key then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Playing a move
-- ---------------------------------------------------------------------------

function AwaleBoard:_snapshot()
    return {
        pits         = copyPits(self.pits),
        stores       = { self.stores[1], self.stores[2] },
        turn         = self.turn,
        last_move    = self.last_move,
        last_capture = self.last_capture,
        last_slam    = self.last_slam,
        no_capture   = self.no_capture,
    }
end

-- Each player takes the seeds left on their own side.
function AwaleBoard:_sweepSides()
    for p = 1, 2 do
        local lo, hi = sideRange(p)
        for i = lo, hi do
            self.stores[p] = self.stores[p] + self.pits[i]
            self.pits[i] = 0
        end
    end
end

function AwaleBoard:_finish(reason)
    self.status     = "over"
    self.end_reason = reason
    local a, b = self.stores[1], self.stores[2]
    self.winner = (a > b) and 1 or (b > a) and 2 or 0
end

-- Called with the next player to move already set.
function AwaleBoard:_checkEnd()
    if self.stores[1] >= WIN_STORE or self.stores[2] >= WIN_STORE then
        self:_finish("score")
    elseif #legalMoves(self.pits, self.turn) == 0 then
        -- The player to move cannot feed an empty opponent: the seeds left
        -- are all on their own side, and they keep them.
        self:_sweepSides()
        self:_finish("starved")
    elseif self:_repetitions() >= REPEAT_LIMIT then
        self:_sweepSides()
        self:_finish("repetition")
    elseif self.no_capture >= NO_CAPTURE_LIMIT then
        self:_sweepSides()
        self:_finish("limit")
    end
end

-- Returns "invalid", "ok" or "over".
function AwaleBoard:play(m)
    if self.status ~= "playing" or not self:isLegal(m) then return "invalid" end
    self.history[#self.history + 1] = self:_snapshot()
    local p = self.turn
    local captured, _, slam = sowAndCapture(self.pits, p, m)
    self.stores[p]    = self.stores[p] + captured
    self.last_move    = m
    self.last_capture = captured
    self.last_slam    = slam
    self.no_capture   = (captured > 0) and 0 or (self.no_capture + 1)
    self.turn         = 3 - p
    self:_checkEnd()
    return self.status == "over" and "over" or "ok"
end

-- Take back one move. Returns false when there is nothing to undo.
function AwaleBoard:undo()
    local snap = table.remove(self.history)
    if not snap then return false end
    self.pits         = snap.pits
    self.stores       = snap.stores
    self.turn         = snap.turn
    self.last_move    = snap.last_move
    self.last_capture = snap.last_capture
    self.last_slam    = snap.last_slam
    self.no_capture   = snap.no_capture
    self.status       = "playing"
    self.winner       = nil
    self.end_reason   = nil
    return true
end

function AwaleBoard:canUndo()
    return #self.history > 0
end

-- ---------------------------------------------------------------------------
-- AI — negamax with alpha-beta, iterative deepening and a time budget
--
-- Score is in seeds (store difference) from the side to move; a decided
-- game is worth WIN_SCORE minus the distance to it, so the engine prefers the
-- quickest win and the slowest loss.
-- ---------------------------------------------------------------------------

local WIN_SCORE = 1000
local INF       = 1e9

-- Difficulty levels. depth is the deepest iteration, budget the think time
-- in seconds (CPU time, so a slower device simply searches less deep), noise
-- a random bonus in seeds added to each root move's score before choosing.
AwaleBoard.LEVELS = {
    easy   = { depth = 2,  budget = 0.2, noise = 4 },
    medium = { depth = 6,  budget = 0.4, noise = 1 },
    hard   = { depth = 40, budget = 1.0, noise = 0 },
}

local function evaluate(mine, theirs)
    return mine - theirs
end

local function finalScore(mine, theirs, ply)
    if mine > theirs then return WIN_SCORE - ply end
    if mine < theirs then return -(WIN_SCORE - ply) end
    return 0
end

local function search(ctx, pits, p, mine, theirs, depth, alpha, beta, ply)
    ctx.nodes = ctx.nodes + 1
    if ctx.abortable and ctx.nodes % 512 == 0 and ctx.clock() > ctx.deadline then
        ctx.aborted = true
    end
    if ctx.aborted then return 0 end

    local moves = legalMoves(pits, p)
    if #moves == 0 then
        return finalScore(mine + sideSum(pits, p), theirs + sideSum(pits, 3 - p), ply)
    end
    if depth <= 0 then return evaluate(mine, theirs) end

    local best = -INF
    for k = 1, #moves do
        local child = copyPits(pits)
        local cap   = sowAndCapture(child, p, moves[k])
        local nm    = mine + cap
        local v
        if nm >= WIN_STORE then
            v = WIN_SCORE - ply - 1
        else
            v = -search(ctx, child, 3 - p, theirs, nm, depth - 1, -beta, -alpha, ply + 1)
        end
        if ctx.aborted then return 0 end
        if v > best then best = v end
        if v > alpha then alpha = v end
        if alpha >= beta then break end
    end
    return best
end

-- Score every root move at a given depth. With exact = true each move gets a
-- full window (noise needs true scores to compare); otherwise alpha carries
-- over between siblings, so only the best move's score is exact.
local function searchRoot(ctx, pits, p, mine, theirs, order, depth, exact)
    local scores = {}
    local alpha, best = -INF, nil
    for k = 1, #order do
        local m = order[k]
        local child = copyPits(pits)
        local cap   = sowAndCapture(child, p, m)
        local nm    = mine + cap
        local v
        if nm >= WIN_STORE then
            v = WIN_SCORE - 1
        else
            local a = exact and -INF or alpha
            v = -search(ctx, child, 3 - p, theirs, nm, depth - 1, -INF, -a, 1)
        end
        if ctx.aborted then return nil end
        scores[m] = v
        -- Strictly better only: a sibling that failed low can return a bound
        -- equal to alpha, and must not displace the move that set it.
        if v > alpha then alpha, best = v, m end
    end
    return scores, best
end

-- Pure entry point (no board object needed), used by the board and the specs.
-- opts: level table ({depth, budget, noise}), rng (returns [0,1)), clock.
-- Returns move, info {depth, nodes, score}.
function AwaleBoard.chooseMove(pits, p, mine, theirs, opts)
    local moves = legalMoves(pits, p)
    if #moves == 0 then return nil end
    local level = opts.level or AwaleBoard.LEVELS.medium
    local rng   = opts.rng or math.random
    local clock = opts.clock or os.clock
    if #moves == 1 then return moves[1], { depth = 0, nodes = 0 } end

    local start = clock()
    local ctx = {
        nodes = 0, clock = clock, deadline = start + level.budget,
        aborted = false, abortable = false,
    }
    local exact = (level.noise or 0) > 0
    local order = {}
    for i = 1, #moves do order[i] = moves[i] end
    local scores, reached

    for d = 1, level.depth do
        ctx.abortable = d > 1           -- depth 1 always completes
        local s, bm = searchRoot(ctx, pits, p, mine, theirs, order, d, exact)
        if not s then break end
        scores, reached = s, d
        -- Best first for the next iteration: that is where alpha-beta cuts.
        table.sort(order, function(a, b)
            if a == bm or b == bm then return a == bm end
            return s[a] > s[b]
        end)
        if s[order[1]] >= WIN_SCORE - 100 then break end       -- forced win found
        if clock() - start > level.budget * 0.5 then break end  -- next one won't fit
    end

    local best, best_v = order[1], -INF
    if exact then
        for _, m in ipairs(order) do
            local v = scores[m] + rng() * level.noise
            if v > best_v then best, best_v = m, v end
        end
    end
    return best, { depth = reached, nodes = ctx.nodes, score = scores[order[1]] }
end

-- AI move for the side to play. level_id: "easy" | "medium" | "hard".
function AwaleBoard:getAIMove(level_id, rng, clock)
    if self.status ~= "playing" then return nil end
    local p = self.turn
    return AwaleBoard.chooseMove(self.pits, p, self.stores[p], self.stores[3 - p], {
        level = AwaleBoard.LEVELS[level_id] or AwaleBoard.LEVELS.medium,
        rng = rng, clock = clock,
    })
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

local function validPits(t)
    if type(t) ~= "table" then return false end
    for i = 1, NPITS do
        if type(t[i]) ~= "number" or t[i] < 0 then return false end
    end
    return true
end

function AwaleBoard:serialize()
    local hist = {}
    for i, snap in ipairs(self.history) do
        hist[i] = {
            pits = copyPits(snap.pits), stores = { snap.stores[1], snap.stores[2] },
            turn = snap.turn, last_move = snap.last_move,
            last_capture = snap.last_capture, last_slam = snap.last_slam,
            no_capture = snap.no_capture,
        }
    end
    return {
        pits = copyPits(self.pits), stores = { self.stores[1], self.stores[2] },
        turn = self.turn, status = self.status, winner = self.winner,
        end_reason = self.end_reason, last_move = self.last_move,
        last_capture = self.last_capture, last_slam = self.last_slam,
        no_capture = self.no_capture, history = hist,
    }
end

function AwaleBoard:load(data)
    if type(data) ~= "table" or not validPits(data.pits)
            or type(data.stores) ~= "table" then
        return false
    end
    local total = (tonumber(data.stores[1]) or -1) + (tonumber(data.stores[2]) or -1)
    for i = 1, NPITS do total = total + data.pits[i] end
    if total ~= NPITS * SEEDS_PER_PIT then return false end

    self:reset()
    self.pits         = copyPits(data.pits)
    self.stores       = { data.stores[1], data.stores[2] }
    self.turn         = (data.turn == 2) and 2 or 1
    self.status       = (data.status == "over") and "over" or "playing"
    self.winner       = data.winner
    self.end_reason   = data.end_reason
    self.last_move    = data.last_move
    self.last_capture = data.last_capture or 0
    self.last_slam    = data.last_slam or false
    self.no_capture   = data.no_capture or 0
    if type(data.history) == "table" then
        for i, snap in ipairs(data.history) do
            if not validPits(snap.pits) or type(snap.stores) ~= "table" then break end
            self.history[i] = {
                pits = copyPits(snap.pits), stores = { snap.stores[1], snap.stores[2] },
                turn = snap.turn, last_move = snap.last_move,
                last_capture = snap.last_capture or 0, last_slam = snap.last_slam or false,
                no_capture = snap.no_capture or 0,
            }
        end
    end
    return true
end

return AwaleBoard
