-- Difficulty guarantees of the Awale computer opponent: the level table is
-- ordered, every level plays legal moves, takes a winning capture and keeps
-- the opponent from one, plays the same game under the same seed, and stays
-- within its think time at Kobo speed. No full matches (too slow, too noisy).
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("Awale difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local IDS = { "easy", "medium", "hard" }
    local KOBO = 25     -- a Kobo Aura runs this Lua about 25x slower

    -- A board in an arbitrary position (pits listed 1..12).
    local function at(pits, stores, turn)
        local b = Board:new()
        b.pits   = pits
        b.stores = stores or { 0, 0 }
        b.turn   = turn or 1
        return b
    end

    local function total(b)
        local s = b.stores[1] + b.stores[2]
        for i = 1, 12 do s = s + b.pits[i] end
        return s
    end

    local function copy(t)
        local o = {}
        for i = 1, #t do o[i] = t[i] end
        return o
    end

    -- A clock that only moves when read: the search is then the same on
    -- every machine, so moves depend on the rng alone.
    local function fixedClock()
        local t = 0
        return function() t = t + 1e-6; return t end
    end

    -- Same idea with a coarser tick: a budget of B seconds is about
    -- B / 0.01 clock reads (one every 512 nodes), so the deep levels stop
    -- after a bounded node count instead of searching for minutes.
    local function countClock()
        local t = 0
        return function() t = t + 0.01; return t end
    end

    -- Deterministic [0,1) generator.
    local function lcg(seed)
        local x = seed
        return function()
            x = (x * 1103515245 + 12345) % 2147483648
            return x / 2147483648
        end
    end

    -- Moves of p that capture enough to reach WIN_STORE right now.
    local function winningMoves(pits, p, store)
        local out = {}
        for _, m in ipairs(Board.legalMovesOf(pits, p)) do
            local child = copy(pits)
            if store + Board.sowAndCapture(child, p, m) >= Board.WIN_STORE then
                out[#out + 1] = m
            end
        end
        return out
    end

    -- Positions from seeded random games where the side to move cannot win
    -- at once, some of its moves let the opponent win at once and at least
    -- one does not. Returns { board, safe = {move = true} }.
    local function threatPositions(want, seed)
        math.randomseed(seed)
        local out = {}
        for _ = 1, 400 do
            local b = Board:new()
            local plies = 0
            while b.status == "playing" and plies < 200 and #out < want do
                local p, q = b.turn, 3 - b.turn
                if #winningMoves(b.pits, p, b.stores[p]) == 0 then
                    local safe, unsafe = {}, 0
                    for _, m in ipairs(b:legalMoves()) do
                        local child = copy(b.pits)
                        local cap = Board.sowAndCapture(child, p, m)
                        if #winningMoves(child, q, b.stores[q]) > 0 then
                            unsafe = unsafe + 1
                        else
                            safe[m] = cap
                        end
                    end
                    if unsafe > 0 and next(safe) then
                        out[#out + 1] = { pits = copy(b.pits), stores = copy(b.stores),
                                          turn = p, safe = safe }
                    end
                end
                local mv = b:legalMoves()
                b:play(mv[math.random(#mv)])
                plies = plies + 1
            end
            if #out >= want then break end
        end
        return out
    end

    it("orders the level table: deeper, longer and less noisy from Easy to Hard", function()
        local L = Board.LEVELS
        for i = 2, #IDS do
            local a, b = L[IDS[i - 1]], L[IDS[i]]
            assert.is_true(a.depth < b.depth)
            assert.is_true(a.budget <= b.budget)
            assert.is_true(a.noise > b.noise)
        end
        assert.are.equal(0, L.hard.noise)
        for _, id in ipairs(IDS) do assert.is_true(L[id].budget <= 2.5) end
    end)

    it("takes a winning capture", function()
        local b = at({ 0, 0, 0, 1, 0, 2, 1, 2, 0, 0, 3, 4 }, { 21, 14 })
        for _, lvl in ipairs(IDS) do
            local m = b:getAIMove(lvl, function() return 0 end, fixedClock())
            if lvl ~= "easy" then assert.are.equal(6, m) end
            assert.is_true(b:isLegal(m))
        end
    end)

    it("every level takes an immediate win in random positions", function()
        math.randomseed(17)
        local checked = 0
        for _ = 1, 300 do
            if checked >= 12 then break end
            local b = Board:new()
            local plies = 0
            while b.status == "playing" and plies < 200 do
                local p = b.turn
                local wins = winningMoves(b.pits, p, b.stores[p])
                if #wins > 0 then
                    for seed, lvl in ipairs(IDS) do
                        local m = b:getAIMove(lvl, lcg(seed), countClock())
                        local child = copy(b.pits)
                        local cap = Board.sowAndCapture(child, p, m)
                        assert.is_true(b.stores[p] + cap >= Board.WIN_STORE,
                            lvl .. " missed a win at " .. table.concat(b.pits, ","))
                    end
                    checked = checked + 1
                    break
                end
                local mv = b:legalMoves()
                b:play(mv[math.random(#mv)])
                plies = plies + 1
            end
        end
        assert.is_true(checked >= 5, "only " .. checked .. " positions found")
    end)

    it("every level keeps the opponent from winning at once", function()
        local positions = threatPositions(10, 23)
        assert.is_true(#positions >= 5, "only " .. #positions .. " positions found")
        for _, pos in ipairs(positions) do
            for seed, lvl in ipairs(IDS) do
                local p = pos.turn
                local m = Board.chooseMove(pos.pits, p, pos.stores[p], pos.stores[3 - p], {
                    level = Board.LEVELS[lvl], rng = lcg(seed), clock = countClock() })
                assert.is_not_nil(pos.safe[m],
                    lvl .. " let the opponent win at " .. table.concat(pos.pits, ","))
            end
        end
    end)

    it("always returns a legal move, at every level, over random games", function()
        math.randomseed(42)
        for _ = 1, 15 do
            local b = Board:new()
            local plies = 0
            while b.status == "playing" and plies < 200 do
                local m
                if plies % 3 == 0 then
                    -- Each level's own depth and noise, on a short
                    -- budget so the spec stays quick.
                    local id = IDS[math.floor(plies % 9 / 3) + 1]
                    local L = Board.LEVELS[id]
                    local p = b.turn
                    m = Board.chooseMove(b.pits, p, b.stores[p], b.stores[3 - p], {
                        level = { depth = L.depth, budget = 0.01, noise = L.noise },
                    })
                else
                    local mv = b:legalMoves()
                    m = mv[math.random(#mv)]
                end
                assert.is_true(b:isLegal(m))
                b:play(m)
                plies = plies + 1
            end
            assert.are.equal(48, total(b))
        end
    end)

    it("plays the same moves under the same seed, and Easy varies with it", function()
        local function line(lvl, seed)
            local b = Board:new()
            local rng = lcg(seed)
            local seq = {}
            for _ = 1, 12 do
                if b.status ~= "playing" then break end
                local m = b:getAIMove(lvl, rng, countClock())
                seq[#seq + 1] = m
                b:play(m)
            end
            return table.concat(seq, ",")
        end
        for _, lvl in ipairs(IDS) do
            assert.are.equal(line(lvl, 5), line(lvl, 5))
        end
        local seen, distinct = {}, 0
        for seed = 1, 5 do
            local s = line("easy", seed)
            if not seen[s] then seen[s] = true; distinct = distinct + 1 end
        end
        assert.is_true(distinct >= 2, "Easy played the same line for every seed")
    end)

    it("stays within its time budget", function()
        local level = { depth = 40, budget = 0.05, noise = 0 }
        local t0 = os.clock()
        local m = Board.chooseMove(Board:new().pits, 1, 0, 0, { level = level })
        assert.is_not_nil(m)
        assert.is_true(os.clock() - t0 < 0.5)
    end)

    it("keeps every level within its budget at Kobo speed", function()
        -- A clock running 25x fast makes the search stop where a Kobo's
        -- would; the real time spent, scaled back, is the Kobo's wait.
        local kobo_clock = function() return os.clock() * KOBO end
        math.randomseed(9)
        local worst = 0
        for _ = 1, 3 do
            local b = Board:new()
            for _ = 1, math.random(4, 20) do
                if b.status ~= "playing" then break end
                local mv = b:legalMoves()
                b:play(mv[math.random(#mv)])
            end
            if b.status == "playing" then
                for _, lvl in ipairs(IDS) do
                    local t0 = os.clock()
                    local m = b:getAIMove(lvl, nil, kobo_clock)
                    local dt = (os.clock() - t0) * KOBO
                    assert.is_true(b:isLegal(m))
                    if dt > worst then worst = dt end
                end
            end
        end
        assert.is_true(worst <= 2.5, string.format("slowest Kobo move %.2f s", worst))
    end)
end)
