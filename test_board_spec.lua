local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("AwaleBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

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

    describe("reset", function()
        it("starts with 4 seeds in each of the 12 pits, South to move", function()
            local b = Board:new()
            for i = 1, 12 do assert.are.equal(4, b.pits[i]) end
            assert.are.same({ 0, 0 }, b.stores)
            assert.are.equal(1, b.turn)
            assert.are.equal("playing", b.status)
            assert.are.same({ 1, 2, 3, 4, 5, 6 }, b:legalMoves())
        end)
    end)

    describe("sowing", function()
        it("sows counter-clockwise, one seed per pit", function()
            local b = Board:new()
            assert.are.equal("ok", b:play(3))
            assert.are.same({ 4, 4, 0, 5, 5, 5, 5, 4, 4, 4, 4, 4 }, b.pits)
            assert.are.equal(2, b.turn)
        end)

        it("wraps from pit 12 to pit 1", function()
            local b = Board:new()
            b:play(1)
            b:play(12)
            assert.are.equal(1, b.pits[1])     -- emptied by South, then fed by North
            assert.are.equal(0, b.pits[12])
            assert.are.equal(6, b.pits[2])
        end)

        it("skips the origin pit on a lap of 12 or more", function()
            local b = at({ 12, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 })
            b:play(1)
            assert.are.equal(0, b.pits[1])     -- the 12th seed went to pit 2
            assert.are.equal(2, b.pits[2])
            for i = 3, 6 do assert.are.equal(1, b.pits[i]) end
        end)

        it("refuses an empty pit or an opponent pit", function()
            local b = Board:new()
            assert.are.equal("invalid", b:play(7))
            b.pits[2] = 0
            assert.are.equal("invalid", b:play(2))
        end)
    end)

    describe("captures", function()
        it("captures 2s and 3s going backwards from the last pit", function()
            -- Pit 6 (2 seeds) lands in 7 and 8: 1->2 and 2->3, both taken.
            local b = at({ 0, 0, 0, 0, 0, 2, 1, 2, 0, 0, 0, 4 })
            b:play(6)
            assert.are.equal(5, b.stores[1])
            assert.are.equal(0, b.pits[7])
            assert.are.equal(0, b.pits[8])
            assert.are.equal(5, b.last_capture)
        end)

        it("stops the chain at a pit that does not hold 2 or 3", function()
            -- Pit 5 (3 seeds) lands in 6, 7, 8: 8 becomes 2, 7 becomes 6.
            local b = at({ 0, 0, 0, 0, 3, 0, 5, 1, 0, 0, 0, 4 })
            b:play(5)
            assert.are.equal(2, b.stores[1])
            assert.are.equal(6, b.pits[7])
            assert.are.equal(0, b.pits[8])
        end)

        it("never captures on the mover's own side", function()
            local b = at({ 1, 1, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4 })
            b:play(1)                           -- lands in pit 2, now 2: own side
            assert.are.equal(0, b.stores[1])
            assert.are.equal(2, b.pits[2])
        end)

        it("grand slam: capturing every opponent seed captures nothing", function()
            local b = at({ 5, 0, 0, 0, 0, 2, 1, 1, 0, 0, 0, 0 })
            b:play(6)
            assert.are.equal(0, b.stores[1])
            assert.are.equal(2, b.pits[7])
            assert.are.equal(2, b.pits[8])
            assert.is_true(b.last_slam)
        end)
    end)

    describe("feeding", function()
        it("only allows moves that reach an empty opponent", function()
            local b = at({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, { 23, 23 })
            assert.are.same({ 6 }, b:legalMoves())
            assert.are.equal("invalid", b:play(1))
        end)

        it("ends the game when no move can feed, the mover keeping their seeds", function()
            -- North plays its last seed into pit 1; South (1, 1 in pits 1-2)
            -- cannot reach North's side.
            local b = at({ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, { 22, 24 }, 2)
            assert.are.equal("over", b:play(12))
            assert.are.equal("starved", b.end_reason)
            assert.are.same({ 24, 24 }, b.stores)
            assert.are.equal(0, b.winner)
            assert.are.equal(48, total(b))
        end)
    end)

    describe("game end", function()
        it("wins at 25 seeds", function()
            local b = at({ 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 4 }, { 23, 19 })
            assert.are.equal("over", b:play(6))
            assert.are.equal(25, b.stores[1])
            assert.are.equal(1, b.winner)
            assert.are.equal("score", b.end_reason)
        end)

        it("ends after 100 plies without a capture, each side keeping its seeds", function()
            local b = at({ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0 }, { 20, 24 })
            b.no_capture = Board.NO_CAPTURE_LIMIT - 1
            assert.are.equal("over", b:play(1))
            assert.are.equal("limit", b.end_reason)
            assert.are.same({ 21, 27 }, b.stores)
            assert.are.equal(2, b.winner)
        end)

        it("ends on the third occurrence of a position", function()
            -- Two lone seeds chasing each other never capture: positions
            -- come back, and the third occurrence ends the game.
            local b = at({ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1 }, { 23, 23 })
            local plies = 0
            while b.status == "playing" and plies < 60 do
                b:play(b:legalMoves()[1])
                plies = plies + 1
            end
            assert.are.equal("over", b.status)
            assert.are.equal(48, total(b))
            assert.is_true(b.end_reason == "repetition" or b.end_reason == "starved")
        end)

        it("detects a repeated position from the history", function()
            local b = Board:new()
            local snap = b:_snapshot()
            b.history = { snap, snap }
            assert.are.equal(3, b:_repetitions())
        end)
    end)

    describe("undo", function()
        it("restores the position before the last move", function()
            local b = Board:new()
            b:play(3)
            b:play(9)
            assert.is_true(b:undo())
            assert.are.equal(2, b.turn)
            assert.are.same({ 4, 4, 0, 5, 5, 5, 5, 4, 4, 4, 4, 4 }, b.pits)
            assert.is_true(b:undo())
            assert.is_false(b:undo())
        end)

        it("reopens a finished game", function()
            local b = at({ 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 4 }, { 23, 19 })
            b:play(6)
            b:undo()
            assert.are.equal("playing", b.status)
            assert.are.equal(23, b.stores[1])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips the position and the history", function()
            local b = Board:new()
            for _, m in ipairs({ 3, 9, 4, 12, 1 }) do b:play(m) end
            local b2 = Board:new()
            assert.is_true(b2:load(b:serialize()))
            assert.are.same(b.pits, b2.pits)
            assert.are.same(b.stores, b2.stores)
            assert.are.equal(b.turn, b2.turn)
            assert.are.equal(#b.history, #b2.history)
            b2:undo()
            b:undo()
            assert.are.same(b.pits, b2.pits)
        end)

        it("rejects missing or inconsistent data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
            local data = Board:new():serialize()
            data.pits[1] = 9                    -- 53 seeds
            assert.is_false(b:load(data))
        end)
    end)

    describe("AI", function()
        local function fixedClock()
            local t = 0
            return function() t = t + 1e-6; return t end
        end

        it("takes a winning capture", function()
            local b = at({ 0, 0, 0, 1, 0, 2, 1, 2, 0, 0, 3, 4 }, { 21, 14 })
            for _, lvl in ipairs({ "easy", "medium", "hard" }) do
                local m = b:getAIMove(lvl, function() return 0 end, fixedClock())
                if lvl ~= "easy" then assert.are.equal(6, m) end
                assert.is_true(b:isLegal(m))
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
                        local id = ({ "easy", "medium", "hard" })[math.floor(plies % 9 / 3) + 1]
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

        it("stays within its time budget", function()
            local level = { depth = 40, budget = 0.05, noise = 0 }
            local t0 = os.clock()
            local m = Board.chooseMove(Board:new().pits, 1, 0, 0, { level = level })
            assert.is_not_nil(m)
            assert.is_true(os.clock() - t0 < 0.5)
        end)
    end)
end)
