--!strict

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("StreakRewards"):WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local RecordCodec = require(script.Parent:WaitForChild("RecordCodec"))

type Config = Types.Config
type Record = Types.Record
type Adapter = Types.Adapter

type Backend = "Unknown" | "Live" | "Studio"

local DataStoreAdapter = {}

local function apiDisabledInStudio(message: string): boolean
	local lower = string.lower(message)
	return string.find(lower, "studioaccesstoapisnotallowed", 1, true) ~= nil
		or (
			string.find(lower, "studio", 1, true) ~= nil
			and string.find(lower, "api", 1, true) ~= nil
			and (
				string.find(lower, "not enabled", 1, true) ~= nil
				or string.find(lower, "not allowed", 1, true) ~= nil
				or string.find(lower, "disabled", 1, true) ~= nil
			)
		)
end

function DataStoreAdapter.new(config: Config): Adapter
	local store = DataStoreService:GetDataStore(config.DataStoreName)
	local studio = RunService:IsStudio()
	local random = Random.new()
	local backend: Backend = "Unknown"
	local memory: { [number]: Record } = {}

	local function key(userId: number): string
		return `User_{userId}`
	end

	-- Only the initial, explicit Studio API-disabled error enables memory mode.
	-- A live adapter never changes backend after a successful cloud operation.
	local function request(operation: () -> any, callbackFailure: (() -> string?)?): (any, boolean)
		local failure = "DataStore request failed"
		for attempt = 1, config.RetryAttempts do
			local ok, result = pcall(operation)
			if ok then
				if backend == "Studio" then
					error("StreakRewards concurrent Studio requests selected inconsistent storage backends", 0)
				end
				backend = "Live"
				return result, false
			end

			failure = tostring(result)
			if callbackFailure then
				local transformFailure = callbackFailure()
				if transformFailure then
					error(transformFailure, 0)
				end
			end
			if studio and backend == "Unknown" and apiDisabledInStudio(failure) then
				backend = "Studio"
				warn("StreakRewards: Studio API access is disabled; using non-persistent session data.")
				return nil, true
			end
			if studio and backend == "Studio" then
				if apiDisabledInStudio(failure) then
					return nil, true
				end
				error(`StreakRewards persistence unavailable: {failure}`, 0)
			end
			if attempt < config.RetryAttempts then
				local delaySeconds = math.min(config.RetryBaseSeconds * 2 ^ (attempt - 1), 30)
				task.wait(delaySeconds * random:NextNumber(0.75, 1.25))
			end
		end
		error(`StreakRewards persistence unavailable: {failure}`, 0)
	end

	local adapter: Adapter
	adapter = {
		Load = function(userId: number): Record
			if backend == "Studio" then
				return RecordCodec.Copy(memory[userId] or RecordCodec.New(config.StreakFreeze))
			end

			local value, fallback = request(function(): any
				return store:GetAsync(key(userId))
			end, nil)
			if fallback then
				return RecordCodec.Copy(memory[userId] or RecordCodec.New(config.StreakFreeze))
			end
			return RecordCodec.Decode(value, config.StreakFreeze)
		end,

		Update = function(userId: number, transform: (Record) -> Record): Record
			local function memoryUpdate(): Record
				local current = RecordCodec.Copy(memory[userId] or RecordCodec.New(config.StreakFreeze))
				local updated = RecordCodec.Decode(transform(current), config.StreakFreeze)
				memory[userId] = updated
				return RecordCodec.Copy(updated)
			end

			if backend == "Studio" then
				return memoryUpdate()
			end

			local transformFailure: string? = nil
			local value, fallback = request(function(): any
				transformFailure = nil
				return store:UpdateAsync(key(userId), function(current: any): any
					-- UpdateAsync may invoke this more than once. The transform must
					-- not yield, send events, pay rewards, or mutate external state.
					local ok, updated = pcall(function(): Record
						local decoded = RecordCodec.Decode(current, config.StreakFreeze)
						return RecordCodec.Decode(transform(decoded), config.StreakFreeze)
					end)
					if not ok then
						transformFailure = tostring(updated)
						error(transformFailure, 0)
					end
					return updated
				end)
			end, function(): string?
				return transformFailure
			end)
			if fallback then
				return memoryUpdate()
			end
			return RecordCodec.Decode(value, config.StreakFreeze)
		end,

		-- Re-read through UpdateAsync. Never replay a stale Load result on leave.
		Save = function(userId: number): ()
			adapter.Update(userId, function(current: Record): Record
				return current
			end)
		end,

		-- This adapter holds no session locks. Studio data survives a rejoin.
		Release = function(_userId: number): () end,
	}

	return adapter
end

return DataStoreAdapter
