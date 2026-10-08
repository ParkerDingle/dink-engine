--!strict
-- Court and physics constants. Units are feet (1 stud = 1 ft) and seconds.
-- Court axes: x across (sidelines at ±10), z along (net at 0, team 0 on +z), y up from the court surface.
-- Player slots: 1 team 0 left, 2 team 0 right, 3 team 1 left, 4 team 1 right (left/right as seen from the +z baseline).
local C = {}

C.W = 10
C.L = 22
C.K = 7
C.NET_H = 2.86
C.BALL_R = 0.125
C.GRAV = 32.2
C.COR = 0.6
C.FRIC = 0.84
C.REACH = 3.1
C.REACH_H = 7.4
C.SUB = 1 / 240
C.UP_DIST = 9.5
-- Roblox world: court x/z map straight to studs, court surface top at y = SURFACE_Y.
C.SURFACE_Y = 0.21
C.WALK_SPEED = 15

function C.teamOf(slot: number): number
	return if slot <= 2 then 0 else 1
end

function C.sideSign(team: number): number
	return if team == 0 then 1 else -1
end

function C.partner(slot: number): number
	return bit32.bxor(slot - 1, 1) + 1
end

function C.clamp(v: number, a: number, b: number): number
	return math.max(a, math.min(b, v))
end

function C.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Park–Miller generator: exact in double precision, reproducible in tests and self-play.
function C.seeded(seed: number): () -> number
	local s = (math.floor(seed) % 2147483646) + 1
	return function()
		s = (s * 16807) % 2147483647
		return s / 2147483647
	end
end

function C.gauss(rng: () -> number): number
	local u, v = 0, 0
	while u == 0 do u = rng() end
	while v == 0 do v = rng() end
	return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v)
end

return C
