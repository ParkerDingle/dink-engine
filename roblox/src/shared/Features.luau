--!nocheck
-- Model input contract (port of game/src/engine/features.ts, mirrored in ml/dink_ml/features.py).
local function req(name) if script then return require(script.Parent[name]) else return require("./" .. name) end end
local C = req("Config")
local R = req("Rules")

local F = {}
F.VERSION = "dink-features-v1"
F.N = 21
local HEIGHT_FT = { 1.3, 3.1, 5.0 }
local PACE_FTS = { 18, 34, 50 }

function F.featuresFor(s, shotType, target)
	local T = s.hitTeam
	local O = 1 - T
	local function mx(x) return if T == 0 then x - 10 else 10 - x end
	local function d(y) return math.abs(y - R.NET_Y) end
	local function up(p) return if d(p.y) <= C.UP_DIST then 1 else 0 end
	local partner = s.players[C.partner(s.hitter)]
	local a, b = s.players[O * 2 + 1], s.players[O * 2 + 2]
	if mx(b.x) < mx(a.x) then a, b = b, a end
	local m1, m2 = s.players[T * 2 + 1], s.players[T * 2 + 2]
	local x = {
		mx(s.ball.x), d(s.ball.y),
		s.contactHeightFt or HEIGHT_FT[s.height + 1],
		s.incomingSpeed or PACE_FTS[s.pace + 1],
		math.min(s.shotNo, 12),
		mx(partner.x), d(partner.y),
		mx(a.x), d(a.y), mx(b.x), d(b.y),
		up(a) + up(b), up(m1) + up(m2),
	}
	for _, t in R.ORDER do table.insert(x, if t == shotType then 1 else 0) end
	table.insert(x, mx(target.x))
	table.insert(x, d(target.y))
	return x
end

return F
