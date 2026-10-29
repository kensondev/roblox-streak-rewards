--!strict

local Types = require(script.Parent.Types)

local config: Types.Config = {
	CycleLength = 7,
	CycleMode = "Loop",
	TimeMode = "UTC",
	GracePeriodHours = 0,
	StreakFreeze = false,
	NotifyOnJoin = true,
	DataStoreName = "StreakRewards_v1",
	RetryAttempts = 4,
	RetryBaseSeconds = 0.5,
	RemoteCooldownSeconds = 1,
	Rewards = {
		{ kind = "Attribute", name = "Coins", amount = 100, label = "100 Coins" },
		{ kind = "Attribute", name = "Coins", amount = 150, label = "150 Coins" },
		{ kind = "Attribute", name = "Coins", amount = 200, label = "200 Coins" },
		{ kind = "Attribute", name = "Coins", amount = 250, label = "250 Coins" },
		{ kind = "Attribute", name = "Coins", amount = 300, label = "300 Coins" },
		{ kind = "Attribute", name = "Coins", amount = 400, label = "400 Coins" },
		{ kind = "Attribute", name = "Coins", amount = 750, label = "750 Coins" },
	},
}

return config
