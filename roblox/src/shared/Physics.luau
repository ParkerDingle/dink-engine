--!nocheck
-- Ball flight (port of game/src/sim/physics.ts). Gravity-only ballistic steps are exact for any step
-- size, so the analytic shot solver and the simulation always agree, and clients can replay the
-- server's ball exactly from a position and velocity.
local function req(name) if script then return require(script.Parent[name]) else return require("./" .. name) end end
local C = req("Config")

local P = {}

function P.stepBall(q, h, ev)
	local pz, py = q.p.z, q.p.y
	q.p.x += q.v.x * h
	q.p.z += q.v.z * h
	if q.rolling then
		q.p.y = C.BALL_R; q.v.y = 0; q.v.x *= 0.992; q.v.z *= 0.992
	else
		q.p.y += q.v.y * h - 0.5 * C.GRAV * h * h
		q.v.y -= C.GRAV * h
	end
	if not q.netted and pz ~= 0 and (pz > 0) ~= (q.p.z > 0) and math.abs(q.p.x) < 11 then
		local f = pz / (pz - q.p.z)
		local yc = py + (q.p.y - py) * f
		if yc < C.NET_H + C.BALL_R * 0.3 then
			q.netted = true
			local s = if pz > 0 then 1 else -1
			q.p.z = s * 0.22; q.v.z = -q.v.z * 0.12; q.v.x *= 0.3; q.v.y = math.min(q.v.y, 0) * 0.4
			if ev then table.insert(ev, { type = "net" }) end
		end
	end
	if not q.rolling and q.p.y < C.BALL_R and q.v.y < 0 then
		q.p.y = C.BALL_R
		local roll = q.v.y > -2.2
		if ev then table.insert(ev, { type = "bounce", p = { x = q.p.x, z = q.p.z }, side = if q.p.z > 0 then 0 else 1, roll = roll, speed = -q.v.y }) end
		if not roll then
			q.v.y = -q.v.y * C.COR; q.v.x *= C.FRIC; q.v.z *= C.FRIC
		else
			q.v.y = 0; q.rolling = true
		end
	end
end

function P.copyBall(b)
	return { p = { x = b.p.x, y = b.p.y, z = b.p.z }, v = { x = b.v.x, y = b.v.y, z = b.v.z }, netted = b.netted, rolling = b.rolling }
end

function P.predict(b, bouncesSoFar, t0, maxT)
	maxT = maxT or 3.4
	local q = P.copyBall(b)
	local samples, firstBounce = {}, nil
	local t, bounces, h = t0, bouncesSoFar, 1 / 120
	for _ = 1, math.floor(maxT / h) do
		local ev = {}
		P.stepBall(q, h, ev)
		t += h
		for _, e in ev do
			if e.type == "bounce" then
				bounces += if e.roll then 2 else 1
				if not firstBounce then firstBounce = { t = t, x = e.p.x, z = e.p.z, side = e.side } end
			end
		end
		table.insert(samples, { t = t, x = q.p.x, y = q.p.y, z = q.p.z, vx = q.v.x, vy = q.v.y, vz = q.v.z, bounces = bounces, netted = q.netted })
		if bounces >= 2 then break end
	end
	return { samples = samples, firstBounce = firstBounce }
end

local CLEAR = { dink = 0.95, drop = 1.5, lob = 9.5 }
local SPEED = { drive = 50, speedup = 46, putaway = 60 }
local SIGMA = { dink = 0.45, drop = 0.75, drive = 0.9, speedup = 0.8, lob = 1.2, putaway = 0.7, serve = 0.95 }

-- Launch velocity that lands at `target` (court x,z), with execution scatter and optional forced fault.
function P.launchVelocity(from, target, shotType, o, rng)
	local function gauss() return C.gauss(rng) end
	local exact = o.exact == true
	local mult = (o.mult or 1) * (1 + 1.3 * (1 - (o.q or 0.9)))
	local inSpeed = o.inSpeed or 0
	if inSpeed > 42 then mult *= 1.3 end
	local attacking = shotType == "drive" or shotType == "speedup" or shotType == "putaway"
	if attacking and from.y < 2.0 then mult *= 1.35 end
	if shotType == "putaway" and from.y > 4.5 then mult *= 0.8 end
	local sig = if exact then 0 else (SIGMA[shotType] or 1) * mult
	local tg = { x = target.x + gauss() * sig * 0.8, z = target.z + gauss() * sig }
	local away = -C.sideSign(o.T)
	if o.fault == "long" then tg.z = away * (C.L + 1.2 + rng() * 3) end
	if o.fault == "wide" then tg.x = (if tg.x >= 0 then 1 else -1) * (C.W + 0.8 + rng() * 2) end
	if o.fault == "popup" then tg.z = away * C.clamp(math.abs(tg.z) + 5 + rng() * 3, 6, 15) end
	local soft = shotType == "dink" or shotType == "drop" or shotType == "lob"
	local dx, dz = tg.x - from.x, tg.z - from.z
	local f = C.clamp(-from.z / dz, 0.04, 0.96)
	local function tClear(c)
		local num = C.NET_H + c - from.y * (1 - f) - C.BALL_R * f
		return if num <= 0 then 0 else math.sqrt(num / (0.5 * C.GRAV * f * (1 - f)))
	end
	local t
	if soft then
		local c = (CLEAR[shotType] or 1) * (if shotType == "drop" and inSpeed > 42 then 0.65 else 1) * (o.clearMul or 1)
		if not exact then
			c += (if shotType == "dink" then math.abs(gauss()) * 0.55 - 0.12 else gauss() * 0.2) * mult
		end
		if o.fault == "net" then c = -0.4 - rng() * 0.6 end
		if o.fault == "popup" then c += 3 + rng() * 1.5 end
		t = math.max(0.42, tClear(c))
	else
		local hs
		if shotType == "serve" then hs = o.serveSpeed or 40
		else hs = (if o.isReturn and shotType == "drive" then 40 else (SPEED[shotType] or 45)) * (o.speedMul or 1) end
		t = math.max(math.sqrt(dx * dx + dz * dz) / hs, tClear(if shotType == "serve" then 1.0 else 0.35))
	end
	local v = { x = dx / t, z = dz / t, y = (C.BALL_R - from.y + 0.5 * C.GRAV * t * t) / t }
	if not soft and not exact then v.y += gauss() * 0.45 * mult end
	if not soft and o.fault == "net" then v.y -= 2.6 + rng() * 1.5 end
	return v
end

-- Clamp an aim point to where a shot type can land, on the side opposite team T.
function P.clampAim(shotType, a, T, serveBoxSign)
	local s = -C.sideSign(T)
	local lo, hi, xlo, xhi = 7.4, 21.2, -9.4, 9.4
	if shotType == "dink" or shotType == "drop" then lo, hi = 0.9, 6.6
	elseif shotType == "lob" then lo, hi = 15, 21.2
	elseif shotType == "putaway" then lo, hi = 1, 21.2
	elseif shotType == "serve" then
		lo, hi = C.K + 1.2, 20.8
		if (serveBoxSign or 1) > 0 then xlo, xhi = 0.6, 9.0 else xlo, xhi = -9.0, -0.6 end
	end
	return { x = C.clamp(a.x, xlo, xhi), z = s * C.clamp(a.z * s, lo, hi) }
end

return P
