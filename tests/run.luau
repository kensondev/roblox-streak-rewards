--!strict

local StreakLogic = require("../src/Shared/StreakLogic")
type Config = StreakLogic.Config
type ClaimState = StreakLogic.ClaimState

type Options = {
	TimeMode: ("UTC" | "Rolling")?,
	CycleMode: ("Loop" | "Cap")?,
	CycleLength: number?,
	GracePeriodHours: number?,
	StreakFreeze: boolean?,
}

type Test = {
	name: string,
	run: () -> (),
}

local DAY = 86400
local HOUR = 3600
local MIDNIGHT = 20000 * DAY
local tests: { Test } = {}
local assertions = 0

local function config(options: Options?): Config
	local values: Options = options or {}
	return {
		CycleLength = values.CycleLength or 7,
		CycleMode = values.CycleMode or "Loop",
		TimeMode = values.TimeMode or "UTC",
		GracePeriodHours = values.GracePeriodHours or 0,
		StreakFreeze = values.StreakFreeze == true,
	}
end

local function expectEqual<T>(actual: T, expected: T, label: string)
	assertions += 1
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
	end
end

local function expectState(
	actual: ClaimState,
	canClaim: boolean,
	nextClaimAt: number,
	newStreak: number,
	rewardIndex: number,
	streakBroken: boolean
)
	expectEqual(actual.canClaim, canClaim, "canClaim")
	expectEqual(actual.nextClaimAt, nextClaimAt, "nextClaimAt")
	expectEqual(actual.newStreak, newStreak, "newStreak")
	expectEqual(actual.rewardIndex, rewardIndex, "rewardIndex")
	expectEqual(actual.streakBroken, streakBroken, "streakBroken")
end

local function test(name: string, run: () -> ())
	table.insert(tests, { name = name, run = run })
end

test("first claim starts at one regardless of stale streak or freeze", function()
	for _, mode in { "UTC", "Rolling" } do
		local cfg = config({ TimeMode = mode :: "UTC" | "Rolling", StreakFreeze = true })
		expectState(StreakLogic.compute(0, 49, MIDNIGHT, cfg, true), true, MIDNIGHT, 1, 1, false)
	end
end)

test("first claim remains available at zero and negative epoch times", function()
	for _, now in { -DAY, -1, 0, 1 } do
		expectState(StreakLogic.compute(0, 0, now, config()), true, now, 1, 1, false)
	end
end)

test("UTC unlocks at midnight even one second after a claim", function()
	local last = MIDNIGHT + DAY - 1
	local cfg = config()
	expectState(StreakLogic.compute(last, 3, last, cfg), false, MIDNIGHT + DAY, 3, 3, false)
	expectState(StreakLogic.compute(last, 3, MIDNIGHT + DAY, cfg), true, MIDNIGHT + DAY, 4, 4, false)
end)

test("UTC midnight claim waits for the following midnight", function()
	local cfg = config()
	expectState(StreakLogic.compute(MIDNIGHT, 2, MIDNIGHT + DAY - 1, cfg), false, MIDNIGHT + DAY, 2, 2, false)
	expectState(StreakLogic.compute(MIDNIGHT, 2, MIDNIGHT + DAY, cfg), true, MIDNIGHT + DAY, 3, 3, false)
end)

test("rolling ignores midnight and waits a full twenty-four hours", function()
	local last = MIDNIGHT + DAY - 1
	local cfg = config({ TimeMode = "Rolling" })
	local nextAt = last + DAY
	expectState(StreakLogic.compute(last, 4, MIDNIGHT + DAY, cfg), false, nextAt, 4, 4, false)
	expectState(StreakLogic.compute(last, 4, nextAt - 1, cfg), false, nextAt, 4, 4, false)
	expectState(StreakLogic.compute(last, 4, nextAt, cfg), true, nextAt, 5, 5, false)
end)

test("UTC deadline includes the full next day and its exact end", function()
	local last = MIDNIGHT + 8 * HOUR
	local nextAt = MIDNIGHT + DAY
	local cfg = config()
	expectState(StreakLogic.compute(last, 5, nextAt + DAY - 1, cfg), true, nextAt, 6, 6, false)
	expectState(StreakLogic.compute(last, 5, nextAt + DAY, cfg), true, nextAt, 6, 6, false)
	expectState(StreakLogic.compute(last, 5, nextAt + DAY + 1, cfg), true, nextAt, 1, 1, true)
end)

test("rolling deadline is inclusive at forty-eight hours after the claim", function()
	local last = MIDNIGHT + 8 * HOUR
	local nextAt = last + DAY
	local cfg = config({ TimeMode = "Rolling" })
	expectState(StreakLogic.compute(last, 5, last + 2 * DAY, cfg), true, nextAt, 6, 6, false)
	expectState(StreakLogic.compute(last, 5, last + 2 * DAY + 1, cfg), true, nextAt, 1, 1, true)
end)

test("grace extends both deadlines and preserves the inclusive boundary", function()
	for _, mode in { "UTC", "Rolling" } do
		local cfg = config({ TimeMode = mode :: "UTC" | "Rolling", GracePeriodHours = 6 })
		local last = MIDNIGHT + 8 * HOUR
		local nextAt = if mode == "UTC" then MIDNIGHT + DAY else last + DAY
		local deadline = nextAt + DAY + 6 * HOUR
		expectState(StreakLogic.compute(last, 6, deadline - 1, cfg), true, nextAt, 7, 7, false)
		expectState(StreakLogic.compute(last, 6, deadline, cfg), true, nextAt, 7, 7, false)
		expectState(StreakLogic.compute(last, 6, deadline + 1, cfg), true, nextAt, 1, 1, true)
	end
end)

test("fractional grace hours preserve subsecond boundary comparisons", function()
	local cfg = config({ GracePeriodHours = 0.5 })
	local deadline = MIDNIGHT + 2 * DAY + HOUR / 2
	expectState(StreakLogic.compute(MIDNIGHT, 3, deadline, cfg), true, MIDNIGHT + DAY, 4, 4, false)
	expectState(StreakLogic.compute(MIDNIGHT, 3, deadline + 0.25, cfg), true, MIDNIGHT + DAY, 1, 1, true)
end)

test("multiple missed days reset instead of incrementing by elapsed days", function()
	for _, elapsed in { 3, 7, 365 } do
		expectState(
			StreakLogic.compute(MIDNIGHT, 29, MIDNIGHT + elapsed * DAY, config()),
			true,
			MIDNIGHT + DAY,
			1,
			1,
			true
		)
	end
end)

test("freeze rescues a broken interval only when both switches are true", function()
	local now = MIDNIGHT + 20 * DAY
	local enabled = config({ StreakFreeze = true })
	local disabled = config({ StreakFreeze = false })
	expectState(StreakLogic.compute(MIDNIGHT, 7, now, enabled, true), true, MIDNIGHT + DAY, 8, 1, false)
	expectState(StreakLogic.compute(MIDNIGHT, 7, now, enabled, false), true, MIDNIGHT + DAY, 1, 1, true)
	expectState(StreakLogic.compute(MIDNIGHT, 7, now, enabled), true, MIDNIGHT + DAY, 1, 1, true)
	expectState(StreakLogic.compute(MIDNIGHT, 7, now, disabled, true), true, MIDNIGHT + DAY, 1, 1, true)
end)

test("freeze does not change an unbroken or ineligible claim", function()
	local cfg = config({ StreakFreeze = true })
	for _, now in { MIDNIGHT - 1, MIDNIGHT, MIDNIGHT + DAY, MIDNIGHT + 2 * DAY } do
		local ordinary = StreakLogic.compute(MIDNIGHT, 5, now, cfg, false)
		expectState(
			StreakLogic.compute(MIDNIGHT, 5, now, cfg, true),
			ordinary.canClaim,
			ordinary.nextClaimAt,
			ordinary.newStreak,
			ordinary.rewardIndex,
			ordinary.streakBroken
		)
	end
end)

test("server can detect and consume a freeze without mutating compute inputs", function()
	local cfg = table.freeze(config({ StreakFreeze = true }))
	local now = MIDNIGHT + 5 * DAY
	local withoutFreeze = StreakLogic.compute(MIDNIGHT, 10, now, cfg, false)
	local rescued = StreakLogic.compute(MIDNIGHT, 10, now, cfg, true)
	expectEqual(withoutFreeze.streakBroken, true, "freeze consumption signal")
	expectEqual(rescued.streakBroken, false, "rescued interval")
	local nextBrokenClaim = StreakLogic.compute(now, rescued.newStreak, now + 4 * DAY, cfg, false)
	expectState(nextBrokenClaim, true, now + DAY, 1, 1, true)
	expectEqual(cfg.StreakFreeze, true, "config remains unchanged")
end)

test("loop wraps reward index without resetting the consecutive count", function()
	local cfg = config({ CycleLength = 3 })
	for _, streak in { 2, 3, 4, 8, 999999 } do
		local nextStreak = streak + 1
		expectState(
			StreakLogic.compute(MIDNIGHT, streak, MIDNIGHT + DAY, cfg),
			true,
			MIDNIGHT + DAY,
			nextStreak,
			(nextStreak - 1) % 3 + 1,
			false
		)
	end
end)

test("cap repeats the final reward while consecutive count increases", function()
	local cfg = config({ CycleMode = "Cap", CycleLength = 3 })
	for _, streak in { 1, 2, 3, 4, 999999 } do
		local nextStreak = streak + 1
		expectState(
			StreakLogic.compute(MIDNIGHT, streak, MIDNIGHT + DAY, cfg),
			true,
			MIDNIGHT + DAY,
			nextStreak,
			math.min(nextStreak, 3),
			false
		)
	end
end)

test("a one-reward cycle always returns reward one in either mode", function()
	for _, mode in { "Loop", "Cap" } do
		local cfg = config({ CycleMode = mode :: "Loop" | "Cap", CycleLength = 1 })
		for streak = 1, 20 do
			expectEqual(StreakLogic.compute(MIDNIGHT, streak, MIDNIGHT + DAY, cfg).rewardIndex, 1, "single reward")
		end
	end
end)

test("ineligible claims retain current count and its reward index", function()
	expectState(StreakLogic.compute(MIDNIGHT, 8, MIDNIGHT + 1, config()), false, MIDNIGHT + DAY, 8, 1, false)
	expectState(
		StreakLogic.compute(MIDNIGHT, 8, MIDNIGHT + 1, config({ CycleMode = "Cap" })),
		false,
		MIDNIGHT + DAY,
		8,
		7,
		false
	)
	expectState(StreakLogic.compute(MIDNIGHT, 0, MIDNIGHT + 1, config()), false, MIDNIGHT + DAY, 0, 1, false)
end)

test("backward clock skew denies without moving the scheduled next claim", function()
	for _, mode in { "UTC", "Rolling" } do
		local last = MIDNIGHT + 8 * HOUR
		local cfg = config({ TimeMode = mode :: "UTC" | "Rolling", StreakFreeze = true })
		local nextAt = if mode == "UTC" then MIDNIGHT + DAY else last + DAY
		for _, now in { -DAY, 0, last - DAY, last - 1 } do
			expectState(StreakLogic.compute(last, 9, now, cfg, true), false, nextAt, 9, 2, false)
		end
	end
end)

test("daily claims follow a complete loop and then reset after a missed interval", function()
	local cfg = config({ CycleLength = 3 })
	local last = 0
	local streak = 0
	for day = 0, 9 do
		local now = MIDNIGHT + day * DAY
		local state = StreakLogic.compute(last, streak, now, cfg)
		expectState(state, true, now, day + 1, day % 3 + 1, false)
		last = now
		streak = state.newStreak
		expectState(StreakLogic.compute(last, streak, now, cfg), false, now + DAY, streak, day % 3 + 1, false)
	end
	expectState(StreakLogic.compute(last, streak, last + 3 * DAY, cfg), true, last + DAY, 1, 1, true)
end)

test("UTC scheduling depends on the claim day, not its hour", function()
	for hour = 0, 23 do
		local last = MIDNIGHT + hour * HOUR
		local state = StreakLogic.compute(last, 4, MIDNIGHT + DAY, config())
		expectState(state, true, MIDNIGHT + DAY, 5, 5, false)
	end
end)

test("eligibility and reset transitions are monotonic across boundary samples", function()
	for _, mode in { "UTC", "Rolling" } do
		for _, grace in { 0, 0.5, 6, 36 } do
			local cfg = config({ TimeMode = mode :: "UTC" | "Rolling", GracePeriodHours = grace })
			local last = MIDNIGHT + 13 * HOUR
			local nextAt = if mode == "UTC" then MIDNIGHT + DAY else last + DAY
			local deadline = nextAt + DAY + grace * HOUR
			local sawEligible = false
			local sawBroken = false
			for _, now in
				{
					last - 1,
					last,
					nextAt - 1,
					nextAt,
					nextAt + 1,
					deadline - 1,
					deadline,
					deadline + 1,
					deadline + 100 * DAY,
				}
			do
				local state = StreakLogic.compute(last, 12, now, cfg)
				expectEqual(state.nextClaimAt, nextAt, "stable next claim threshold")
				if sawEligible then
					expectEqual(state.canClaim, true, "eligibility never reverses")
				end
				if sawBroken then
					expectEqual(state.streakBroken, true, "reset never reverses")
				end
				expectEqual(
					state.newStreak,
					if not state.canClaim then 12 elseif state.streakBroken then 1 else 13,
					"single claim increment or reset"
				)
				sawEligible = state.canClaim
				sawBroken = state.streakBroken
			end
			expectEqual(sawEligible, true, "eventually eligible")
			expectEqual(sawBroken, true, "eventually broken")
		end
	end
end)

test("reward bounds hold across cycle lengths, counts, modes, and claim states", function()
	for length = 1, 14 do
		for _, mode in { "Loop", "Cap" } do
			local cfg = config({ CycleLength = length, CycleMode = mode :: "Loop" | "Cap" })
			for streak = 0, 60 do
				for _, now in { MIDNIGHT, MIDNIGHT + DAY, MIDNIGHT + 3 * DAY } do
					local state = StreakLogic.compute(MIDNIGHT, streak, now, cfg)
					expectEqual(state.rewardIndex >= 1 and state.rewardIndex <= length, true, "reward is in range")
					expectEqual(state.rewardIndex % 1, 0, "reward is integral")
					if mode == "Cap" then
						expectEqual(
							state.rewardIndex,
							math.min(math.max(state.newStreak, 1), length),
							"cap maps count to reward"
						)
					end
				end
			end
		end
	end
end)

test("whole-day time translation preserves both modes", function()
	for _, mode in { "UTC", "Rolling" } do
		local cfg = config({ TimeMode = mode :: "UTC" | "Rolling", GracePeriodHours = 3 })
		local last = MIDNIGHT + 11 * HOUR
		for _, elapsed in { -DAY, 0, DAY - 1, DAY, 2 * DAY, 4 * DAY } do
			local baseline = StreakLogic.compute(last, 6, last + elapsed, cfg)
			for shiftDays = -10, 10 do
				local shift = shiftDays * DAY
				local shifted = StreakLogic.compute(last + shift, 6, last + elapsed + shift, cfg)
				expectState(
					shifted,
					baseline.canClaim,
					baseline.nextClaimAt + shift,
					baseline.newStreak,
					baseline.rewardIndex,
					baseline.streakBroken
				)
			end
		end
	end
end)

test("repeated pure calls return independent result tables", function()
	local cfg = table.freeze(config())
	local first = StreakLogic.compute(MIDNIGHT, 3, MIDNIGHT + DAY, cfg)
	first.newStreak = 999
	local second = StreakLogic.compute(MIDNIGHT, 3, MIDNIGHT + DAY, cfg)
	expectState(second, true, MIDNIGHT + DAY, 4, 4, false)
end)

local failures: { string } = {}
for _, entry in tests do
	local ok, problem = pcall(entry.run)
	if ok then
		print("PASS " .. entry.name)
	else
		local failure = entry.name .. ": " .. tostring(problem)
		table.insert(failures, failure)
		print("FAIL " .. failure)
	end
end

print(string.format("%d tests, %d assertions, %d failures", #tests, assertions, #failures))
if #failures > 0 then
	error(table.concat(failures, "\n"), 0)
end
