--!strict

export type Config = {
	CycleLength: number,
	CycleMode: "Loop" | "Cap",
	TimeMode: "UTC" | "Rolling",
	GracePeriodHours: number,
	StreakFreeze: boolean,
}

export type ClaimState = {
	canClaim: boolean,
	nextClaimAt: number,
	newStreak: number,
	rewardIndex: number,
	streakBroken: boolean,
}

local SECONDS_PER_DAY = 86400
local SECONDS_PER_HOUR = 3600

local function rewardIndex(streak: number, config: Config): number
	local positiveStreak = math.max(1, streak)
	if config.CycleMode == "Loop" then
		return (positiveStreak - 1) % config.CycleLength + 1
	end
	return math.min(positiveStreak, config.CycleLength)
end

local function compute(
	lastClaimTime: number,
	streak: number,
	now: number,
	config: Config,
	freezeAvailable: boolean?
): ClaimState
	if lastClaimTime == 0 then
		return {
			canClaim = true,
			nextClaimAt = now,
			newStreak = 1,
			rewardIndex = 1,
			streakBroken = false,
		}
	end

	local nextClaimAt = if config.TimeMode == "UTC"
		then math.floor(lastClaimTime / SECONDS_PER_DAY) * SECONDS_PER_DAY + SECONDS_PER_DAY
		else lastClaimTime + SECONDS_PER_DAY

	if now < lastClaimTime or now < nextClaimAt then
		return {
			canClaim = false,
			nextClaimAt = nextClaimAt,
			newStreak = streak,
			rewardIndex = rewardIndex(streak, config),
			streakBroken = false,
		}
	end

	local deadline = nextClaimAt + SECONDS_PER_DAY + config.GracePeriodHours * SECONDS_PER_HOUR
	local streakBroken = now > deadline and not (config.StreakFreeze and freezeAvailable == true)
	local newStreak = if streakBroken then 1 else streak + 1

	return {
		canClaim = true,
		nextClaimAt = nextClaimAt,
		newStreak = newStreak,
		rewardIndex = rewardIndex(newStreak, config),
		streakBroken = streakBroken,
	}
end

return table.freeze({
	compute = compute,
})
