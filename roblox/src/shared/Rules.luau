--!nocheck
-- Rule-based shot evaluator (port of game/src/engine/rules.ts). It's the fallback scorer and it
-- supplies the execution odds (pErr, pWin) the simulation uses for every option.
-- Engine coordinates: x 0..20 across, y 0..44 along, net at y = 22, team 0 on y > 22.
local function req(name) if script then return require(script.Parent[name]) else return require("./" .. name) end end
local C = req("Config")

local R = {}
R.ORDER = { "dink", "drop", "drive", "speedup", "lob", "putaway" }
R.SHOTS = {
	dink = { name = "Dink", depths = { 0 } },
	drop = { name = "Drop", depths = { 0 } },
	drive = { name = "Drive", depths = { 1, 2 } },
	speedup = { name = "Speed-up", depths = { 1, 2 } },
	lob = { name = "Lob", depths = { 2 } },
	putaway = { name = "Put-away", depths = { 0, 1 } },
}
R.NET_Y = 22
R.DEPTH_BOUNDS = { { 0, 7 }, { 7, 14.5 }, { 14.5, 22 } }
local DEPTH_CENTER = { 3.5, 10.75, 18.25 }
local COL_NAMES = { "left", "middle", "right" }
local DEPTH_NAMES = { "kitchen", "mid-court", "deep" }

local function nd(y) return math.abs(y - R.NET_Y) end
local function sideY(team, dist) return if team == 0 then R.NET_Y + dist else R.NET_Y - dist end
local function isUp(p) return nd(p.y) <= C.UP_DIST end

function R.zoneCenter(team, col, depth)
	return { x = (col + 0.5) * 20 / 3, y = sideY(team, DEPTH_CENTER[depth + 1]) }
end

function R.zoneName(col, depth)
	return COL_NAMES[col + 1] .. " " .. DEPTH_NAMES[depth + 1]
end

function R.label(shotType, s)
	if shotType == "drop" and s.pace == 2 and s.shotNo ~= 2 then return "Reset" end
	if shotType == "speedup" and s.pace == 2 then return "Counter" end
	return R.SHOTS[shotType].name
end

function R.availability(s)
	local up = nd(s.ball.y) <= C.UP_DIST
	if s.shotNo == 2 then
		local no = { ok = false, why = "Not on the return" }
		return { dink = no, speedup = no, putaway = no, drive = { ok = true }, drop = { ok = true }, lob = { ok = true } }
	end
	return {
		dink = if up then (if s.pace <= 1 then { ok = true } else { ok = false, why = "Too fast to dink" }) else { ok = false, why = "Get to the line first" },
		drop = if (not up) or s.pace == 2 then { ok = true } else { ok = false, why = "At the line, dink instead" },
		drive = if not up then { ok = true } else { ok = false, why = "At the line, use a speed-up" },
		speedup = if up then { ok = true } else { ok = false, why = "Only from the kitchen line" },
		lob = { ok = true },
		putaway = if s.height == 2 then { ok = true } else { ok = false, why = "Needs a ball above the net" },
	}
end

function R.evaluate(s)
	local T = s.hitTeam
	local O = 1 - T
	local d, h, p = nd(s.ball.y), s.height, s.pace
	local opps = { s.players[O * 2 + 1], s.players[O * 2 + 2] }
	local mine = { s.players[T * 2 + 1], s.players[T * 2 + 2] }
	local oppUp = (if isUp(opps[1]) then 1 else 0) + (if isUp(opps[2]) then 1 else 0)
	local myUp = (if isUp(mine[1]) then 1 else 0) + (if isUp(mine[2]) then 1 else 0)
	local hitterCol = if s.ball.x < 20 / 3 then 0 elseif s.ball.x > 40 / 3 then 2 else 1
	local avail = R.availability(s)
	local ret = s.shotNo == 2
	local res = {}
	for _, shotType in R.ORDER do
		if not avail[shotType].ok then continue end
		for _, depth in R.SHOTS[shotType].depths do
			for col = 0, 2 do
				local tp = R.zoneCenter(O, col, depth)
				local dmin, nearest = math.huge, opps[1]
				for _, o in opps do
					local dd = math.sqrt((o.x - tp.x) ^ 2 + (o.y - tp.y) ^ 2)
					if dd < dmin then dmin = dd; nearest = o end
				end
				local open = C.clamp((dmin - 3) / 9, 0, 1)
				local targetBack = not isUp(nearest)
				local tb = if targetBack then 1 else 0
				local wide = if col ~= 1 then 1 else 0
				local middle = if col == 1 then 1 else 0
				local cross = if (hitterCol == 0 and col == 2) or (hitterCol == 2 and col == 0) then 1 else 0
				local pErr, pWin, v = 0, 0, 0.5
				if shotType == "dink" then
					pErr = 0.025 + (if p == 1 then 0.03 else 0) + (if wide == 1 and cross == 0 then 0.03 else 0) - 0.01 * cross + (if h == 0 then 0.01 else 0)
					pWin = 0.01 + 0.02 * open + 0.05 * tb
					v = 0.5 + 0.03 * cross + 0.015 * middle + 0.06 * tb + 0.04 * (myUp - oppUp) + (if h == 1 then 0.01 else 0)
				elseif shotType == "drop" then
					if ret then
						pErr = 0.07 + 0.0045 * d + 0.02 * wide; pWin = 0.01; v = 0.46 + 0.02 * middle
					else
						pErr = 0.05 + 0.0045 * d + (if p == 2 then 0.03 else 0) + 0.02 * wide - (if h == 2 then 0.02 else 0)
						pWin = 0.01 + (if oppUp < 2 then 0.02 else 0) + 0.03 * tb
						v = (if d > 16 then 0.46 elseif d > C.UP_DIST then 0.48 else 0.5) + 0.03 * middle + 0.07 * tb + 0.03 * (2 - oppUp)
					end
				elseif shotType == "drive" then
					if ret then
						pErr = 0.04 + 0.03 * wide + (if depth == 2 then 0.02 else 0); pWin = 0.02 + 0.02 * open
						v = (if depth == 2 then 0.58 else 0.52) + 0.02 * middle
					else
						pErr = 0.06 + 0.04 * wide + (if depth == 2 then 0.03 else 0) + (if h == 0 then (if d <= 13 then 0.05 else 0.02) else 0) - (if h == 2 then 0.02 else 0) + (if p == 2 then 0.03 else 0)
						pWin = 0.04 + 0.06 * open + (if h == 2 then 0.1 else 0) + (if h == 1 then 0.02 else 0)
						v = (if oppUp == 2 then 0.4 elseif oppUp == 1 then 0.46 else 0.52) + 0.04 * middle + (if h == 2 then 0.05 else 0) - (if h == 0 then 0.03 else 0) + (if targetBack and depth == 1 then 0.03 else 0)
					end
				elseif shotType == "speedup" then
					pErr = 0.07 + (if h == 0 then 0.1 else 0) - (if h == 2 then 0.03 else 0) + 0.03 * wide + (if depth == 2 then 0.04 else 0) + (if p == 2 then 0.04 else 0)
					pWin = 0.08 + (if h == 1 then 0.1 else 0) + (if h == 2 then 0.22 else 0) - (if h == 0 then 0.04 else 0) + 0.05 * open + 0.05 * tb
					v = 0.4 + 0.05 * h + 0.02 * middle
				elseif shotType == "lob" then
					pErr = 0.11 + 0.04 * wide + (if p == 2 then 0.06 else 0) + (if d > 16 then 0.02 else 0)
					pWin = (if oppUp == 2 and h == 0 and d <= C.UP_DIST then 0.08 else 0.03) + 0.02 * cross
					v = if ret then 0.4 elseif oppUp == 2 then (if d <= C.UP_DIST then 0.42 else 0.36) else 0.34
				elseif shotType == "putaway" then
					pErr = 0.05 + 0.03 * wide + (if depth == 0 then 0.02 else 0) + (if d > 16 then 0.04 else 0)
					pWin = 0.36 + 0.15 * open + 0.05 * tb + (if depth == 0 then 0.05 else 0) - (if d > 16 then 0.15 else 0)
					v = 0.58
				end
				pErr = C.clamp(pErr, 0.01, 0.6)
				pWin = C.clamp(pWin, 0, 0.9)
				local P = C.clamp(pWin + (1 - pErr - pWin) * v, 0.02, 0.97)
				table.insert(res, { type = shotType, label = R.label(shotType, s), col = col, depth = depth, zone = R.zoneName(col, depth), target = tp, pErr = pErr, pWin = pWin, v = v, P = P })
			end
		end
	end
	R.sortOptions(res)
	return res
end

-- Stable sort by P (descending) so results match the TypeScript engine.
function R.sortOptions(res)
	for i, o in res do o._i = i end
	table.sort(res, function(a, b)
		if a.P ~= b.P then return a.P > b.P end
		return a._i < b._i
	end)
	return res
end

R.GRADES = {
	{ max = 1.5, key = "best", name = "Best shot", glyph = "!" },
	{ max = 4, key = "good", name = "Good", glyph = "+" },
	{ max = 8, key = "inacc", name = "Inaccuracy", glyph = "?!" },
	{ max = 15, key = "mistake", name = "Mistake", glyph = "?" },
	{ max = math.huge, key = "blunder", name = "Blunder", glyph = "??" },
}
function R.grade(lossPts)
	for _, g in R.GRADES do
		if lossPts <= g.max then return g end
	end
	return R.GRADES[#R.GRADES]
end
function R.accuracy(lossPts) return math.max(0, 100 - 5 * lossPts) end

-- Softmax pick. tau ~0.012 plays like a pro, ~0.045 like a club player.
function R.choose(opts, tau, rng)
	local best = opts[1].P
	local w, sum = {}, 0
	for i, o in opts do w[i] = math.exp((o.P - best) / tau); sum += w[i] end
	local r = rng() * sum
	for i, o in opts do
		r -= w[i]
		if r <= 0 then return o end
	end
	return opts[1]
end

-- Starting positions with rally scoring (server side depends on the serving team's score).
function R.rallyStart(serverTeam, serverScore)
	local odd = serverScore % 2 == 1
	local P = {}
	local server, receiver
	if serverTeam == 0 then
		P[1] = { x = 5, y = 45 }; P[2] = { x = 15, y = 45 }
		server = if odd then 1 else 2
		receiver = if odd then 4 else 3
		P[3] = { x = 5, y = if receiver == 3 then -1 else 14 }; P[4] = { x = 15, y = if receiver == 4 then -1 else 14 }
	else
		P[3] = { x = 5, y = -1 }; P[4] = { x = 15, y = -1 }
		server = if odd then 4 else 3
		receiver = if odd then 1 else 2
		P[1] = { x = 5, y = if receiver == 1 then 45 else 30 }; P[2] = { x = 15, y = if receiver == 2 then 45 else 30 }
	end
	return server, receiver, P
end

return R
