--!strict

export type Reward = {
	kind: "Attribute" | "Leaderstats" | "Custom",
	name: string,
	amount: number,
	label: string,
}

export type Config = {
	CycleLength: number,
	CycleMode: "Loop" | "Cap",
	TimeMode: "UTC" | "Rolling",
	GracePeriodHours: number,
	StreakFreeze: boolean,
	NotifyOnJoin: boolean,
	Rewards: { Reward },
	DataStoreName: string,
	RetryAttempts: number,
	RetryBaseSeconds: number,
	RemoteCooldownSeconds: number,
}

export type Record = {
	version: number,
	lastClaimTime: number,
	streak: number,
	freezeAvailable: boolean,
}

export type ClaimState = {
	canClaim: boolean,
	nextClaimAt: number,
	newStreak: number,
	rewardIndex: number,
	streakBroken: boolean,
}

export type StatePacket = {
	canClaim: boolean,
	nextClaimAt: number,
	newStreak: number,
	rewardIndex: number,
	streakBroken: boolean,
	streak: number,
	serverTime: number,
	message: string?,
}

export type Adapter = {
	Load: (userId: number) -> Record,
	Update: (userId: number, transform: (Record) -> Record) -> Record,
	Save: (userId: number) -> (),
	Release: (userId: number) -> (),
}

return {}
