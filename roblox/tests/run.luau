--!nocheck
-- Headless tests for the Roblox port. Run from the repo root:  luau roblox/tests/run.luau
-- The shared modules don't touch Roblox APIs, so the same code that runs on the game server is tested here.
local C = require("../src/shared/Config")
local R = require("../src/shared/Rules")
local F = require("../src/shared/Features")
local P = require("../src/shared/Physics")
local D = require("../src/shared/Drills")
local S = require("../src/shared/Scorer")
local Model = require("../src/shared/ShotModel")
local Match = require("../src/shared/Match")
local ModelFixture = require("./fixtures/ModelFixture")
local FeatureFixture = require("./fixtures/FeatureFixture")

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  ok    " .. name)
	else
		failed += 1
		print("  FAIL  " .. name .. "\n        " .. tostring(err))
	end
end
local function check(cond, msg)
	if not cond then error(msg or "check failed", 2) end
end
local function near(a, b, tol, msg)
	if math.abs(a - b) > tol then error(string.format("%s: %.9g vs %.9g", msg or "values differ", a, b), 2) end
end

print("Dink Engine · Roblox port tests")

test("model export matches LightGBM on the fixture rows", function()
	check(#ModelFixture >= 20, "fixture is empty")
	local worst = 0
	for _, row in ModelFixture do worst = math.max(worst, math.abs(Model.predict(row.x) - row.p)) end
	check(worst < 1e-9, "max diff " .. worst)
	check(Model.featureVersion == F.VERSION and Model.nFeatures == F.N, "model contract mismatch")
	check(S.enabled, "scorer did not load the model")
end)

test("features match the TypeScript/Python contract", function()
	check(FeatureFixture.version == F.VERSION, "fixture version")
	for k, c in FeatureFixture.cases do
		local x = F.featuresFor(c.state, c.type, c.target)
		check(#x == F.N, "feature count " .. #x)
		for j = 1, F.N do near(x[j], c.features[j], 1e-9, "case " .. k .. " feature " .. j) end
	end
end)

test("rule engine ranks options like the TypeScript engine", function()
	for k, c in FeatureFixture.cases do
		local opts = R.evaluate(c.state)
		local o = opts[((k - 1) % 3) + 1] or opts[1]
		check(o.type == c.type, string.format("case %d: %s vs %s", k, o.type, c.type))
		near(o.target.x, c.target.x, 1e-9, "case " .. k .. " target x")
		near(o.target.y, c.target.y, 1e-9, "case " .. k .. " target y")
	end
end)

test("shot solver lands on target and clears the net", function()
	local rng = C.seeded(3)
	for _, shot in { "dink", "drop", "drive", "speedup", "lob", "serve" } do
		for k = 1, 30 do
			local from = { x = -8 + rng() * 16, y = 0.8 + rng() * 3, z = if shot == "dink" or shot == "speedup" then 7 + rng() * 3 else 8 + rng() * 14 }
			if shot == "serve" then from.z = 22.5; from.y = 1.7 end
			local raw = { x = -8 + rng() * 16, z = -(1 + rng() * 20) }
			local tgt = P.clampAim(shot, raw, 0, if from.x > 0 then -1 else 1)
			local v = P.launchVelocity(from, tgt, shot, { T = 0, exact = true, serveSpeed = 40 }, rng)
			local b = { p = from, v = v, netted = false, rolling = false }
			local pr = P.predict(b, 0, 0)
			local fb = pr.firstBounce
			check(fb ~= nil, shot .. " never bounced")
			check(fb.side == 1, shot .. " landed on the hitter's side")
			-- prediction steps at 120 Hz, so the detected bounce can be up to one step past the target
			local tol = math.sqrt(v.x * v.x + v.z * v.z) / 120 + 0.02
			near(fb.x, tgt.x, tol, shot .. " landing x")
			near(fb.z, tgt.z, tol, shot .. " landing z")
			for _, s in pr.samples do check(not s.netted, shot .. " hit the net") end
		end
	end
end)

test("clients can replay the ball exactly from launch state", function()
	-- the server sends position + velocity; a client stepping at its own frame rate must agree
	local from = { x = 2, y = 1.2, z = 15 }
	local v = P.launchVelocity(from, { x = -3, z = -5 }, "drop", { T = 0, exact = true }, math.random)
	local a = { p = table.clone(from), v = table.clone(v), netted = false, rolling = false }
	local b = { p = table.clone(from), v = table.clone(v), netted = false, rolling = false }
	for _ = 1, 240 do P.stepBall(a, 1 / 240) end
	for _ = 1, 60 do P.stepBall(b, 1 / 60) end
	-- the 60 Hz client only differs after a bounce (bounce detection quantizes to the step)
	near(a.p.x, b.p.x, 0.6, "x"); near(a.p.z, b.p.z, 0.6, "z")
end)

test("two-bounce rule and kitchen volleys", function()
	local m = Match.new(C.seeded(1))
	m.ball.lastHitTeam = 1
	-- a serve or return can't be volleyed
	check(not m:contactAllowed({ x = 0, y = 2, z = 12, bounces = 0, netted = false }, 0, 1), "volleyed the serve")
	check(not m:contactAllowed({ x = 0, y = 2, z = 12, bounces = 0, netted = false }, 0, 2), "volleyed the return")
	check(m:contactAllowed({ x = 0, y = 2, z = 12, bounces = 0, netted = false }, 0, 3), "third-shot volley refused")
	-- no volleys in the kitchen, groundstrokes there are fine
	check(not m:contactAllowed({ x = 0, y = 2, z = 5, bounces = 0, netted = false }, 0, 5), "kitchen volley allowed")
	check(m:contactAllowed({ x = 0, y = 2, z = 5, bounces = 1, netted = false }, 0, 5), "kitchen groundstroke refused")
	check(not m:contactAllowed({ x = 0, y = 2, z = -5, bounces = 1, netted = false }, 0, 5), "hit on the wrong side")
end)

test("rally scoring and serving positions", function()
	local s, r, pts = R.rallyStart(0, 0)
	check(s == 2 and r == 3, "even score serves from the right")
	check(pts[2].y > 44 and pts[3].y < 0, "server and receiver at baselines")
	s, r = R.rallyStart(0, 3)
	check(s == 1 and r == 4, "odd score serves from the left")
	s, r = R.rallyStart(1, 2)
	check(s == 3 and r == 2, "team 1 even")
	local m = Match.new(C.seeded(2))
	m:startMatch()
	m.score = { 10, 9 }
	m:point(0, "test")
	check(m.gameOver and m.score[1] == 11, "11-9 should end the game")
	m:startMatch()
	m.score = { 10, 10 }
	m:point(0, "test")
	check(not m.gameOver, "11-10 is not win by two")
end)

test("AI self-play produces realistic rallies and training rows", function()
	local res = Match.runSelfPlay(300, 5, 0.012)
	local avg = res.shots / res.rallies
	local sw = res.serverWins / res.rallies
	print(string.format("        %d rallies · %.1f shots/rally · server wins %.0f%% · %d rows", res.rallies, avg, sw * 100, #res.rows))
	local top = {}
	for k, n in res.reasons do table.insert(top, { k = k, n = n }) end
	table.sort(top, function(a, b) return a.n > b.n end)
	for i = 1, math.min(6, #top) do print(string.format("          %-34s %d", top[i].k, top[i].n)) end
	check(avg > 5 and avg < 25, "rally length " .. avg)
	check(sw > 0.3 and sw < 0.7, "server win rate " .. sw)
	check((res.reasons["Rally reset"] or 0) < res.rallies * 0.03, "too many stuck rallies")
	check(#res.rows > res.rallies * 3, "too few rows")
	for _, row in res.rows do check(#row.features == F.N, "row width") end
end)

-- Drives a match with human slots the way the Roblox server does: the "human" walks to the stand
-- marker it is shown, serves when asked, and calls a shot whenever a decision opens.
local function playHuman(m, slots, chooser, seconds, dt)
	local plans, decisions, serves, shots = {}, 0, 0, {}
	local minScale = 1
	m.on.plan = function(i, st) plans[i] = st end
	m.on.serveTurn = function(i) m:userServe(i, { x = 0, z = -C.sideSign(C.teamOf(i)) * 16 }); serves += 1 end
	m.on.decision = function(i, d)
		decisions += 1
		minScale = math.min(minScale, m.timeTarget)
		local typ, aim = chooser(i, d)
		if typ == "leave" then m:leaveIt(i) else check(m:commit(i, typ, aim), "commit refused") end
	end
	m.on.userShot = function(i, rec) table.insert(shots, rec) end
	local t = 0
	while t < seconds do
		for _, i in slots do
			local pl = m.players[i]
			local goal = plans[i] or m:homeFor(pl)
			local dx, dz = goal.x - pl.x, goal.z - pl.z
			local d = math.sqrt(dx * dx + dz * dz)
			local sp = if d > 0.1 then math.min(15, d * 5) else 0
			local vx, vz = if d > 0.1 then dx / d * sp else 0, if d > 0.1 then dz / d * sp else 0
			m:setHuman(i, pl.x + vx * dt, pl.z + vz * dt, vx, vz)
		end
		m:update(dt)
		if m.rallyOver then
			plans = {}
			if m.mode == "drill" or m.gameOver then break end
			m:newRally()
		end
		t += dt
	end
	return { decisions = decisions, serves = serves, shots = shots, minScale = minScale }
end
local function bestCall(i, d)
	local o = d.evals[1]
	local t = Match.worldTarget(o)
	-- options are scored in engine coordinates; the human aims in world coordinates
	return o.type, { x = t.x, z = t.z }
end

test("solo match: decisions slow time, shots are graded, game finishes", function()
	local m = Match.new(C.seeded(11))
	m.human[2] = true
	m:startMatch()
	local r = playHuman(m, { 2 }, bestCall, 900, 1 / 30)
	print(string.format("        score %d-%d · %d serves · %d decisions · %d graded shots", m.score[1], m.score[2], r.serves, r.decisions, #r.shots))
	check(m.gameOver, "game did not finish")
	check(r.decisions > 10, "too few decisions")
	check(#r.shots > 10, "too few graded shots")
	check(r.minScale < 0.1, "time didn't slow for the shot call")
	local exact = 0
	for _, s in r.shots do if s.opt == s.best then exact += 1 end end
	check(exact / #r.shots > 0.8, "best calls matched to other zones: " .. exact .. "/" .. #r.shots)
	local best = 0
	for _, s in r.shots do if s.g.key == "best" or s.g.key == "good" then best += 1 end end
	check(best / #r.shots > 0.6, "calling the engine's best shot should grade well")
end)

test("team 1 human: aims are mirrored correctly", function()
	local m = Match.new(C.seeded(12))
	m.human[3] = true
	m:startMatch()
	local r = playHuman(m, { 3 }, bestCall, 600, 1 / 30)
	check(#r.shots > 5, "too few shots")
	-- aiming at the engine's best option must be matched to exactly that option
	local exact = 0
	for _, s in r.shots do if s.opt == s.best then exact += 1 end end
	check(exact / #r.shots > 0.8, "best calls matched to other zones from the far side: " .. exact .. "/" .. #r.shots)
end)

test("aiming at a side zone is graded as that zone, for both teams", function()
	for _, slot in { 2, 3 } do
		local m = Match.new(C.seeded(20 + slot))
		m.human[slot] = true
		m:startMatch()
		local want = {}
		local r = playHuman(m, { slot }, function(i, d)
			for _, o in d.evals do
				if o.col ~= 1 and d.avail[o.type].ok then
					want[#want + 1] = o
					return o.type, Match.worldTarget(o)
				end
			end
			want[#want + 1] = d.evals[1]
			return d.evals[1].type, Match.worldTarget(d.evals[1])
		end, 300, 1 / 30)
		check(#r.shots > 5, "too few shots")
		local same = 0
		for k, s in r.shots do
			local w = want[k]
			if w and s.opt.type == w.type and s.opt.col == w.col and s.opt.depth == w.depth then same += 1 end
		end
		check(same / #r.shots > 0.8, string.format("slot %d: %d/%d shots graded in the aimed zone", slot, same, #r.shots))
	end
end)

test("four humans: no slow-motion, everyone gets shots", function()
	local m = Match.new(C.seeded(13))
	for i = 1, 4 do m.human[i] = true end
	m:startMatch()
	local r = playHuman(m, { 1, 2, 3, 4 }, bestCall, 400, 1 / 30)
	check(r.minScale == 1, "time slowed with several humans")
	local by = {}
	for _, s in r.shots do by[s.slot] = (by[s.slot] or 0) + 1 end
	for i = 1, 4 do check((by[i] or 0) > 0, "slot " .. i .. " never hit") end
end)

test("idle server is auto-served after 12 s", function()
	local m = Match.new(C.seeded(14))
	m.human[2] = true
	m.score = { 0, 0 }
	m.server = 0
	m:newRally()
	check(m.serveWait == 2, "human should serve first")
	for _ = 1, 13 * 30 do m:update(1 / 30) end
	check(m.serveWait == nil and m.ball.shotNo >= 1, "serve did not happen")
end)

test("every drill opens a decision for the human, in either slot", function()
	for _, slot in { 2, 1 } do
		for i = 1, #D do
			local m = Match.new(C.seeded(100 + i))
			m.human[slot] = true
			local opened = false
			m.on.decision = function(s, d) if s == slot then opened = true end; m:commit(s, d.evals[1].type, Match.worldTarget(d.evals[1])) end
			m:startDrill(i, slot)
			for _ = 1, 120 do
				m:update(1 / 60)
				if opened or m.rallyOver then break end
			end
			check(opened, string.format("drill %d (%s) slot %d: no decision", i, D[i].key, slot))
		end
	end
end)

test("bad input from a client is rejected", function()
	local m = Match.new(C.seeded(15))
	m.human[2] = true
	m:startMatch()
	check(not m:commit(2, "teleport", { x = 0, z = 0 }), "unknown shot accepted")
	check(not m:commit(2, "dink", { x = 0 / 0, z = 0 }), "NaN aim accepted")
	check(not m:commit(2, "dink", "x"), "non-table aim accepted")
	check(not m:userServe(1, { x = 0, z = -16 }), "wrong player served")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error("tests failed") end
