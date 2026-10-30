-- ---------------------------------------------------------------------------
-- AwaleBoardWidget — draws the 2x6 pits and the two stores
--
-- Eight columns: North's store on the left, six pits, South's store on the
-- right (each player sows towards their own store). The top row shows pits
-- 12..7, the bottom row pits 1..6, so seeds always travel counter-clockwise.
--
-- Pits are not square cells, and the stores span both rows, so this widget
-- lays itself out rather than using GridWidgetBase's square grid.
-- ---------------------------------------------------------------------------

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

local Screen = Device.screen

local C_BG       = Blitbuffer.COLOR_WHITE
local C_INK      = Blitbuffer.COLOR_BLACK
local C_DIM      = Blitbuffer.COLOR_GRAY_9     -- frame of a pit that can't be played
local C_LAST     = Blitbuffer.COLOR_GRAY_D     -- background of the pit just played
local C_STORE_BG = Blitbuffer.COLOR_GRAY_E

local DOTS_COLS = 4
local DOTS_MAX  = 16    -- above this, the number alone stays readable

local AwaleBoardWidget = InputContainer:extend{
    board        = nil,
    max_width    = 600,
    max_height   = 400,
    labels       = nil,     -- { south_label, north_label } written under each store
    playable     = nil,     -- function() -> set of tappable pits, or nil
    onPitAction  = nil,     -- function(pit)
}

-- Largest face of `font` whose rendering of `sample` fits in w x h.
local function fitFace(font, sample, w, h, bold)
    local lo, hi, best = 8, math.max(8, math.floor(h)), 8
    while lo <= hi do
        local mid  = math.floor((lo + hi) / 2)
        local face = Font:getFace(font, mid)
        local m    = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, sample, true, bold)
        if m.x <= w and (m.y_top + m.y_bottom) <= h then
            best, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    return Font:getFace(font, best)
end

local function drawText(bb, text, face, cx, cy, bold, color)
    local m = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, bold)
    local x = math.floor(cx - m.x / 2)
    local baseline = math.floor(cy + (m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, x, baseline, face, text, true, bold, color or C_INK)
end

function AwaleBoardWidget:init()
    -- Pits a little taller than wide: the number sits on top, the dots below.
    local col_w = math.floor(self.max_width / 8)
    local pit_h = math.floor(col_w * 1.7)
    if 2 * pit_h > self.max_height then
        -- Short (landscape) budget: never let a pit get wider than tall.
        pit_h = math.floor(self.max_height / 2)
        col_w = math.min(col_w, pit_h)
    end
    self.col_w = col_w
    self.pit_h = pit_h
    local w, h = 8 * col_w, 2 * pit_h
    self.dimen      = Geom:new{ w = w, h = h }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = w, h = h }

    self.pad        = math.max(3, math.floor(col_w * 0.06))
    local inner_w   = col_w - 2 * self.pad
    self.num_face   = fitFace("cfont", "88", inner_w * 0.75, pit_h * 0.3, true)
    self.store_face = fitFace("cfont", "88", inner_w * 0.95, pit_h * 0.5, true)
    -- Fit the store labels on the longest one actually shown, with a margin.
    local sample = "North"
    for _, l in ipairs(self.labels or {}) do
        if #l > #sample then sample = l end
    end
    self.label_face = fitFace("smallinfofont", sample, inner_w * 0.85, pit_h * 0.16, false)

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.paint_rect end } },
    }
end

-- Pit under a screen point, or nil (stores and gaps are not pits).
function AwaleBoardWidget:pitAt(x, y)
    local lx = x - self.paint_rect.x
    local ly = y - self.paint_rect.y
    local col = math.floor(lx / self.col_w)          -- 0..7
    if col < 1 or col > 6 or ly < 0 or ly >= 2 * self.pit_h then return nil end
    if ly < self.pit_h then return 13 - col end       -- top row: 12..7
    return col                                        -- bottom row: 1..6
end

-- Top-left corner of pit i, in widget coordinates.
function AwaleBoardWidget:pitOrigin(i)
    if i <= 6 then return i * self.col_w, self.pit_h end
    return (13 - i) * self.col_w, 0
end

function AwaleBoardWidget:onTap(_, ges)
    if not (ges and ges.pos) then return false end
    local pit = self:pitAt(ges.pos.x, ges.pos.y)
    if pit and self.onPitAction then self.onPitAction(pit) end
    return true
end

function AwaleBoardWidget:_drawDots(bb, n, x, y, w, h)
    if n == 0 or n > DOTS_MAX then return end
    local rows    = math.ceil(n / DOTS_COLS)
    local step    = math.floor(math.min(w / DOTS_COLS, h / 4))
    local r       = math.max(2, math.floor(step * 0.34))
    local top     = y + math.floor((h - rows * step) / 2)
    local k = 0
    for row = 1, rows do
        local in_row = math.min(DOTS_COLS, n - k)
        local left = x + math.floor((w - in_row * step) / 2)
        for col = 1, in_row do
            local cx = left + math.floor((col - 0.5) * step)
            local cy = top + math.floor((row - 0.5) * step)
            bb:paintCircle(cx, cy, r, C_INK)
            k = k + 1
        end
    end
end

function AwaleBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    local board = self.board
    local cw, ph, pad = self.col_w, self.pit_h, self.pad
    local thick = math.max(2, math.floor(cw * 0.035))
    local radius = math.floor(cw * 0.18)

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    local playable = self.playable and self.playable() or {}

    -- Pits
    for i = 1, 12 do
        local ox, oy = self:pitOrigin(i)
        local px, py = x + ox + pad, y + oy + pad
        local pw, pht = cw - 2 * pad, ph - 2 * pad
        if board.last_move == i then
            bb:paintRoundedRect(px, py, pw, pht, C_LAST, radius)
        end
        if playable[i] then
            bb:paintBorder(px, py, pw, pht, thick + 1, C_INK, radius)
        else
            bb:paintBorder(px, py, pw, pht, math.max(1, math.floor(thick / 2)), C_DIM, radius)
        end
        local n = board.pits[i]
        local num_cy = py + math.floor(pht * 0.22)
        drawText(bb, tostring(n), self.num_face, px + pw / 2, num_cy, true)
        self:_drawDots(bb, n, px + pad, py + math.floor(pht * 0.42),
                       pw - 2 * pad, math.floor(pht * 0.54))
    end

    -- Stores: North's on the left, South's on the right, both rows tall.
    local labels = self.labels or {}
    for p = 1, 2 do
        local ox = (p == 1) and 7 * cw or 0
        local px, py = x + ox + pad, y + pad
        local pw, pht = cw - 2 * pad, 2 * ph - 2 * pad
        bb:paintRoundedRect(px, py, pw, pht, C_STORE_BG, radius)
        bb:paintBorder(px, py, pw, pht, thick, C_INK, radius)
        drawText(bb, tostring(board.stores[p]), self.store_face,
                 px + pw / 2, py + pht / 2, true)
        if labels[p] then
            local label_cy = (p == 2) and (py + math.floor(pht * 0.12))
                                       or (py + math.floor(pht * 0.88))
            drawText(bb, labels[p], self.label_face, px + pw / 2, label_cy, false)
        end
    end
end

function AwaleBoardWidget:refresh()
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = self.paint_rect.x, y = self.paint_rect.y,
                               w = self.dimen.w, h = self.dimen.h }
    end)
end

return AwaleBoardWidget
