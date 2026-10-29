--!strict

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("StreakRewards"):WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local Config: Types.Config = require(Shared:WaitForChild("Config"))
local RemoteNames = require(Shared:WaitForChild("Remotes"))
local StreakLogic = require(Shared:WaitForChild("StreakLogic"))
local DataStoreAdapter = require(script.Parent:WaitForChild("DataStoreAdapter"))
local RecordCodec = require(script.Parent:WaitForChild("RecordCodec"))

export type Reward = Types.Reward
export type Record = Types.Record
export type Adapter = Types.Adapter
export type StatePacket = Types.StatePacket
export type RewardHandler = (Player, Reward, string) -> ()
export type API = {
	Claimed: RBXScriptSignal,
	GetState: (Player) -> StatePacket?,
	SetRewardHandler: (RewardHandler) -> (),
	SetAdapter: (Adapter) -> (),
	ResetPlayer: (Player) -> boolean,
	Start: () -> (),
}

type Session = {
	player: Player,
	record: Record?,
	available: boolean,
	busy: boolean,
	closing: boolean,
	releasing: boolean,
	lastClaimRequest: number,
	lastStateRequest: number,
}

local StreakRewards = {}
local claimedEvent = Instance.new("BindableEvent")
claimedEvent.Name = "StreakRewardsClaimed"
StreakRewards.Claimed = claimedEvent.Event

local sessions: { [number]: Session } = {}
local joining: { [Player]: boolean } = {}
local adapter: Adapter? = nil
local rewardHandler: RewardHandler? = nil
local stateUpdate: RemoteEvent? = nil
local started = false
local shuttingDown = false
local pendingLoads = 0

local function requireAdapter(): Adapter
	local current = adapter
	assert(current ~= nil, "StreakRewards.Start() must be called first")
	return current
end

local function sessionState(session: Session, message: string?): StatePacket?
	local record = session.record
	if not session.available or record == nil or session.closing then
		return nil
	end

	local now = os.time()
	local state = StreakLogic.compute(record.lastClaimTime, record.streak, now, Config, record.freezeAvailable)
	return {
		canClaim = state.canClaim,
		nextClaimAt = state.nextClaimAt,
		newStreak = state.newStreak,
		rewardIndex = state.rewardIndex,
		streakBroken = state.streakBroken,
		streak = record.streak,
		serverTime = now,
		message = message,
	}
end

local function sendState(session: Session, message: string?): ()
	local remote = stateUpdate
	if remote == nil or session.closing or session.player.Parent ~= Players then
		return
	end
	local packet = sessionState(session, message)
	if packet == nil then
		packet = {
			canClaim = false,
			nextClaimAt = 0,
			newStreak = 0,
			rewardIndex = 1,
			streakBroken = false,
			streak = 0,
			serverTime = os.time(),
			message = message or "Rewards data is unavailable. Please rejoin before claiming.",
		}
	end
	remote:FireClient(session.player, packet)
end

local function finite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function deliverDefault(player: Player, reward: Reward): ()
	if reward.kind == "Custom" then
		error("Custom rewards require StreakRewards.SetRewardHandler", 2)
	end

	if reward.kind == "Attribute" then
		local current = player:GetAttribute(reward.name)
		if current == nil then
			current = 0
		end
		if type(current) ~= "number" or not finite(current) or not finite(current + reward.amount) then
			error(`Currency attribute {reward.name} must be a finite number`, 2)
		end
		player:SetAttribute(reward.name, current + reward.amount)
		return
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats == nil then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		leaderstats = folder
	elseif not leaderstats:IsA("Folder") then
		error("Existing leaderstats must be a Folder", 2)
	end

	local stat = leaderstats:FindFirstChild(reward.name)
	if stat == nil then
		local value = Instance.new("NumberValue")
		value.Name = reward.name
		value.Value = reward.amount
		value.Parent = leaderstats
		return
	end
	if not stat:IsA("NumberValue") and not stat:IsA("IntValue") then
		error(`Leaderstat {reward.name} must be a NumberValue or IntValue`, 2)
	end
	local nextValue = stat.Value + reward.amount
	if not finite(stat.Value) or not finite(nextValue) then
		error(`Leaderstat {reward.name} must be finite`, 2)
	end
	if stat:IsA("IntValue") and nextValue % 1 ~= 0 then
		error(`Leaderstat {reward.name} cannot store a fractional reward`, 2)
	end
	stat.Value = nextValue
end

local function closeSession(session: Session): ()
	if session.releasing then
		return
	end
	session.releasing = true
	session.closing = true
	-- The lock covers persistence and delivery. Leave and shutdown cannot save
	-- or release a profile while its claim or reset is still running.
	while session.busy do
		task.wait()
	end
	session.busy = true
	local currentAdapter = requireAdapter()
	if session.record ~= nil then
		local saved, saveError = pcall(currentAdapter.Save, session.player.UserId)
		if not saved then
			warn(`StreakRewards save failed for {session.player.UserId}: {tostring(saveError)}`)
		end
	end
	local released, releaseError = pcall(currentAdapter.Release, session.player.UserId)
	if not released then
		warn(`StreakRewards release failed for {session.player.UserId}: {tostring(releaseError)}`)
	end
	session.record = nil
	session.available = false
	session.busy = false
	if sessions[session.player.UserId] == session then
		sessions[session.player.UserId] = nil
	end
end

local function beginJoin(player: Player): ()
	if shuttingDown or joining[player] then
		return
	end
	local currentSession = sessions[player.UserId]
	if currentSession and currentSession.player == player then
		return
	end
	joining[player] = true
	pendingLoads += 1
	task.spawn(function(): ()
		-- A fast rejoin waits for the prior session's claim and release.
		while sessions[player.UserId] ~= nil and not shuttingDown and player.Parent == Players do
			task.wait()
		end
		if shuttingDown or player.Parent ~= Players then
			joining[player] = nil
			pendingLoads -= 1
			return
		end

		local session: Session = {
			player = player,
			record = nil,
			available = false,
			busy = true,
			closing = false,
			releasing = false,
			lastClaimRequest = -math.huge,
			lastStateRequest = -math.huge,
		}
		sessions[player.UserId] = session
		local currentAdapter = requireAdapter()
		local loaded, result = pcall(function(): Record
			return RecordCodec.Decode(currentAdapter.Load(player.UserId), Config.StreakFreeze)
		end)
		if loaded then
			session.record = result
			session.available = true
		else
			warn(`StreakRewards load failed for {player.UserId}: {tostring(result)}`)
		end
		session.busy = false
		joining[player] = nil
		pendingLoads -= 1

		if session.closing or shuttingDown or player.Parent ~= Players then
			closeSession(session)
			return
		end
		if loaded then
			local packet = sessionState(session, nil)
			local message = if Config.NotifyOnJoin
					and packet
					and packet.canClaim
				then "Your daily reward is ready."
				else nil
			sendState(session, message)
		else
			sendState(session, "Rewards data could not be loaded. Please rejoin before claiming.")
		end
	end)
end

local function rateLimited(session: Session, action: "Claim" | "State"): boolean
	local now = os.clock()
	local previous = if action == "Claim" then session.lastClaimRequest else session.lastStateRequest
	if now - previous < Config.RemoteCooldownSeconds then
		return true
	end
	if action == "Claim" then
		session.lastClaimRequest = now
	else
		session.lastStateRequest = now
	end
	return false
end

local function claim(session: Session): ()
	if shuttingDown or session.closing then
		return
	end
	if session.busy then
		sendState(session, "A rewards operation is already in progress.")
		return
	end
	if not session.available or session.record == nil then
		sendState(session, "Rewards data is unavailable. Please rejoin before claiming.")
		return
	end

	session.busy = true
	local currentAdapter = requireAdapter()
	local now = os.time()
	local handler = rewardHandler
	local receipt = HttpService:GenerateGUID(false)
	local candidate: Record? = nil
	local selectedReward: Reward? = nil
	local missingHandler = false

	local persisted, result = pcall(function(): Record
		local committed = currentAdapter.Update(session.player.UserId, function(stored: Record): Record
			-- Only transaction-local bookkeeping changes here. UpdateAsync can
			-- re-run this callback, including after a conflicted or uncertain write.
			candidate = nil
			selectedReward = nil
			missingHandler = false
			local record = RecordCodec.Decode(stored, Config.StreakFreeze)
			local state = StreakLogic.compute(record.lastClaimTime, record.streak, now, Config, record.freezeAvailable)
			if not state.canClaim then
				return record
			end
			local reward = Config.Rewards[state.rewardIndex]
			if reward.kind == "Custom" and handler == nil then
				missingHandler = true
				return record
			end

			local withoutFreeze = StreakLogic.compute(record.lastClaimTime, record.streak, now, Config, false)
			local consumedFreeze = Config.StreakFreeze and record.freezeAvailable and withoutFreeze.streakBroken
			local nextRecord: Record = {
				version = RecordCodec.Version,
				lastClaimTime = now,
				streak = state.newStreak,
				freezeAvailable = record.freezeAvailable and not consumedFreeze,
			}
			candidate = nextRecord
			selectedReward = reward
			return nextRecord
		end)
		return RecordCodec.Decode(committed, Config.StreakFreeze)
	end)

	if not persisted then
		-- An error can follow a committed write. Never pay or blindly replay it.
		session.available = false
		session.busy = false
		warn(`StreakRewards claim persistence failed for {session.player.UserId}: {tostring(result)}`)
		sendState(
			session,
			"Your claim could not be confirmed. No reward was delivered; please rejoin. A claim may already have been recorded."
		)
		return
	end

	local committed: Record = result
	session.record = committed
	local accepted = candidate
	local reward = selectedReward
	if accepted == nil or reward == nil then
		session.busy = false
		if missingHandler then
			warn(`StreakRewards Custom reward has no handler for {session.player.UserId}`)
			sendState(session, "This reward is not configured. No claim was consumed; please contact the developer.")
		else
			sendState(session, "You have already claimed. Check the countdown for your next reward.")
		end
		return
	end
	if not RecordCodec.Equal(accepted, committed) then
		session.available = false
		session.busy = false
		warn(`StreakRewards adapter returned a mismatched committed claim for {session.player.UserId}`)
		sendState(session, "Your claim could not be confirmed. No reward was delivered; please rejoin.")
		return
	end

	-- Persistence and an external economy cannot commit atomically. This GUID
	-- identifies this delivery attempt, not a crash-recoverable payout journal.
	local delivered, deliveryError = pcall(function(): ()
		if handler then
			handler(session.player, reward, receipt)
		else
			deliverDefault(session.player, reward)
		end
	end)
	if not delivered then
		warn(`StreakRewards delivery failed for {session.player.UserId}; receipt {receipt}: {tostring(deliveryError)}`)
		session.busy = false
		sendState(
			session,
			"Your claim was recorded, but reward delivery failed. Please contact the developer; do not claim again."
		)
		return
	end

	claimedEvent:Fire(session.player, reward, committed.streak)
	session.busy = false
	sendState(session, `Claimed {reward.label}.`)
end

function StreakRewards.GetState(player: Player): StatePacket?
	local session = sessions[player.UserId]
	if session == nil or session.player ~= player then
		return nil
	end
	return sessionState(session, nil)
end

function StreakRewards.SetRewardHandler(handler: RewardHandler): ()
	assert(type(handler) == "function", "Reward handler must be a function")
	rewardHandler = handler
end

function StreakRewards.SetAdapter(customAdapter: Adapter): ()
	assert(not started, "SetAdapter must be called before Start")
	assert(type(customAdapter) == "table", "Adapter must be a table")
	assert(type(customAdapter.Load) == "function", "Adapter.Load is required")
	assert(type(customAdapter.Update) == "function", "Adapter.Update is required")
	assert(type(customAdapter.Save) == "function", "Adapter.Save is required")
	assert(type(customAdapter.Release) == "function", "Adapter.Release is required")
	adapter = customAdapter
end

function StreakRewards.ResetPlayer(player: Player): boolean
	local session = sessions[player.UserId]
	if session == nil or session.player ~= player or shuttingDown or session.closing then
		return false
	end
	while session.busy do
		task.wait()
		if shuttingDown or session.closing or sessions[player.UserId] ~= session then
			return false
		end
	end
	if not session.available or session.record == nil then
		return false
	end
	session.busy = true
	local currentAdapter = requireAdapter()
	local resetRecord = RecordCodec.New(Config.StreakFreeze)
	local saved, result = pcall(function(): Record
		return RecordCodec.Decode(
			currentAdapter.Update(player.UserId, function(stored: Record): Record
				RecordCodec.Decode(stored, Config.StreakFreeze)
				return RecordCodec.Copy(resetRecord)
			end),
			Config.StreakFreeze
		)
	end)
	if not saved or not RecordCodec.Equal(result, resetRecord) then
		session.available = false
		session.busy = false
		warn(`StreakRewards reset failed for {player.UserId}: {tostring(result)}`)
		sendState(session, "Your rewards reset could not be confirmed. Please rejoin before claiming.")
		return false
	end
	session.record = result
	session.busy = false
	sendState(session, "Your streak was reset.")
	return true
end

local function getRemote(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), `StreakRewards remote {name} must be a RemoteEvent`)
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

function StreakRewards.Start(): ()
	if started then
		return
	end
	if adapter == nil then
		adapter = DataStoreAdapter.new(Config)
	end

	local existing = ReplicatedStorage:FindFirstChild(RemoteNames.Folder)
	local folder: Folder
	if existing then
		assert(existing:IsA("Folder"), "StreakRewards remotes container must be a Folder")
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = RemoteNames.Folder
		folder.Parent = ReplicatedStorage
	end
	local claimRequest = getRemote(folder, RemoteNames.ClaimRequest)
	local stateRequest = getRemote(folder, RemoteNames.StateRequest)
	stateUpdate = getRemote(folder, RemoteNames.StateUpdate)
	started = true

	claimRequest.OnServerEvent:Connect(function(player: Player, ...: any): ()
		local session = sessions[player.UserId]
		if session == nil or session.player ~= player or rateLimited(session, "Claim") then
			return
		end
		-- The authenticated sender is the only accepted input. No client time,
		-- streak, reward, receipt, target player, or payload is trusted.
		if select("#", ...) ~= 0 then
			return
		end
		claim(session)
	end)
	stateRequest.OnServerEvent:Connect(function(player: Player, ...: any): ()
		local session = sessions[player.UserId]
		if session == nil or session.player ~= player or rateLimited(session, "State") then
			return
		end
		if select("#", ...) ~= 0 then
			return
		end
		sendState(session, if session.busy and session.record == nil then "Loading rewards data..." else nil)
	end)

	Players.PlayerAdded:Connect(beginJoin)
	Players.PlayerRemoving:Connect(function(player: Player): ()
		local session = sessions[player.UserId]
		if session and session.player == player then
			closeSession(session)
		end
	end)
	game:BindToClose(function(): ()
		shuttingDown = true
		for _, session in sessions do
			task.spawn(closeSession, session)
		end
		-- Roblox owns the shutdown deadline. Do not drop an in-flight claim or
		-- release its profile early to meet a shorter, artificial timeout.
		while pendingLoads > 0 or next(sessions) ~= nil do
			task.wait()
		end
	end)

	for _, player in Players:GetPlayers() do
		beginJoin(player)
	end
end

return StreakRewards
