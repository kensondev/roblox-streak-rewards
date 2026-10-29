--!strict

-- Documentation-only integration. This file is not mapped by default.project.json.
-- Install MadStudioRoblox/ProfileStore yourself and pass its required module to
-- this factory, then call StreakRewards.SetAdapter before StreakRewards.Start.
-- API reference: https://github.com/MadStudioRoblox/ProfileStore
--
-- Use a DIFFERENT DataStore name from the built-in raw-record adapter. ProfileStore
-- stores an envelope, not a raw StreakRewards record. Migrate old data separately.
-- Do not let any other code edit this adapter's StreakRewards field or hold the
-- same ProfileStore session. Existing games should integrate these guarantees
-- into their existing profile owner instead of starting a second session.
--
-- Profile:Save() schedules a save and does not acknowledge durability. This
-- adapter waits for OnAfterSave with its exact record before returning Update.
-- Session locking excludes other servers, and every transform runs synchronously
-- while the profile is active. Never yield or grant rewards inside a transform.
-- Save timeout is an ambiguous commit: it throws and the server fails closed.
-- External payouts are still not atomic with a profile save.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("StreakRewards"):WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))

type Record = Types.Record
type Adapter = Types.Adapter

type Connection = { Disconnect: (self: Connection) -> () }
type Signal = { Connect: (self: Signal, callback: (...any) -> ()) -> Connection }
type Profile = {
	Data: { [string]: any },
	OnAfterSave: Signal,
	OnSessionEnd: Signal,
	IsActive: (self: Profile) -> boolean,
	AddUserId: (self: Profile, userId: number) -> (),
	Save: (self: Profile) -> (),
	EndSession: (self: Profile) -> (),
}
type Store = {
	StartSessionAsync: (self: Store, key: string, parameters: { Cancel: () -> boolean }) -> Profile?,
}
export type ProfileStoreModule = {
	New: (name: string, template: { [string]: any }) -> Store,
	DataStoreState: string,
}
export type Options = {
	DataStoreName: string,
	InitialFreezeAvailable: boolean,
	SaveTimeoutSeconds: number?,
	LoadTimeoutSeconds: number?,
}

type Entry = {
	profile: Profile,
	lost: boolean,
	releasing: boolean,
	busy: boolean,
	endedConnection: Connection?,
}

local MAX_SAFE_INTEGER = 9007199254740991
local VERSION = 1

local function integer(value: any): number
	assert(
		type(value) == "number" and value == value and value >= 0 and value <= MAX_SAFE_INTEGER and value % 1 == 0,
		"Invalid StreakRewards profile integer"
	)
	return value
end

local function decode(value: any, initialFreeze: boolean): Record
	if value == nil then
		return { version = VERSION, lastClaimTime = 0, streak = 0, freezeAvailable = initialFreeze }
	end
	assert(type(value) == "table", "StreakRewards profile record must be a table")
	local version = integer(if value.version == nil then 0 else value.version)
	assert(version <= VERSION, "Newer StreakRewards schema; refusing to overwrite")
	local lastClaimTime = integer(value.lastClaimTime)
	local streak = integer(value.streak)
	assert((lastClaimTime == 0) == (streak == 0), "StreakRewards profile timestamp and streak disagree")
	local freezeAvailable = value.freezeAvailable
	if version == 0 and freezeAvailable == nil then
		freezeAvailable = initialFreeze
	end
	assert(type(freezeAvailable) == "boolean", "Invalid StreakRewards profile freezeAvailable")
	return { version = VERSION, lastClaimTime = lastClaimTime, streak = streak, freezeAvailable = freezeAvailable }
end

local function same(value: any, expected: Record): boolean
	return type(value) == "table"
		and value.version == expected.version
		and value.lastClaimTime == expected.lastClaimTime
		and value.streak == expected.streak
		and value.freezeAvailable == expected.freezeAvailable
end

return function(ProfileStore: ProfileStoreModule, options: Options): Adapter
	assert(#options.DataStoreName > 0, "A dedicated ProfileStore name is required")
	local saveTimeout = options.SaveTimeoutSeconds or 20
	local loadTimeout = options.LoadTimeoutSeconds or 60
	assert(
		saveTimeout > 0 and saveTimeout < math.huge and loadTimeout > 0 and loadTimeout < math.huge,
		"ProfileStore timeouts must be finite and positive"
	)
	local store = ProfileStore.New(options.DataStoreName, {})
	local entries: { [number]: Entry } = {}

	local function active(userId: number): Entry
		local entry = entries[userId]
		assert(
			entry ~= nil and not entry.lost and not entry.releasing and entry.profile:IsActive(),
			"StreakRewards ProfileStore session is unavailable"
		)
		return entry
	end

	local function saveAndConfirm(entry: Entry, expected: Record): ()
		assert(not entry.lost and entry.profile:IsActive(), "ProfileStore session ended before save")
		local confirmed = false
		local connection = entry.profile.OnAfterSave:Connect(function(saved: any): ()
			if type(saved) == "table" and same(saved.StreakRewards, expected) then
				confirmed = true
			end
		end)
		local saved, failure = pcall(function(): ()
			local deadline = os.clock() + saveTimeout
			entry.profile:Save()
			while not confirmed do
				if entry.lost or not entry.profile:IsActive() then
					error("ProfileStore session ended before the save was confirmed", 0)
				end
				if os.clock() >= deadline then
					error("ProfileStore save acknowledgement timed out; commit may have succeeded", 0)
				end
				task.wait()
			end
		end)
		connection:Disconnect()
		if not saved then
			error(tostring(failure), 0)
		end
		assert(not entry.lost and entry.profile:IsActive(), "ProfileStore session ended after saving")
	end

	local function serial(userId: number, operation: (Entry) -> Record): Record
		local entry = active(userId)
		while entry.busy do
			task.wait()
			active(userId)
		end
		entry.busy = true
		local ok, result = pcall(operation, entry)
		entry.busy = false
		if not ok then
			error(tostring(result), 0)
		end
		return result
	end

	local adapter: Adapter
	adapter = {
		Load = function(userId: number): Record
			assert(entries[userId] == nil, "ProfileStore session is already loaded")
			local deadline = os.clock() + loadTimeout
			while ProfileStore.DataStoreState == "NotReady" and os.clock() < deadline do
				task.wait()
			end
			-- ProfileStore itself can silently use mock storage when API access is
			-- unavailable. This example rejects it rather than claiming durability.
			assert(ProfileStore.DataStoreState == "Access", "ProfileStore live DataStore access is unavailable")
			local profile = store:StartSessionAsync(`User_{userId}`, {
				Cancel = function(): boolean
					return os.clock() >= deadline
				end,
			})
			assert(profile ~= nil, "ProfileStore could not acquire the player session")
			local entry: Entry = {
				profile = profile,
				lost = false,
				releasing = false,
				busy = false,
				endedConnection = nil,
			}
			entries[userId] = entry
			entry.endedConnection = profile.OnSessionEnd:Connect(function(): ()
				entry.lost = true
			end)
			local loaded, result = pcall(function(): Record
				profile:AddUserId(userId)
				assert(profile:IsActive(), "ProfileStore session ended during load")
				return decode(profile.Data.StreakRewards, options.InitialFreezeAvailable)
			end)
			if not loaded then
				adapter.Release(userId)
				error(tostring(result), 0)
			end
			return result
		end,

		Update = function(userId: number, transform: (Record) -> Record): Record
			return serial(userId, function(entry: Entry): Record
				local current = decode(entry.profile.Data.StreakRewards, options.InitialFreezeAvailable)
				local updated = decode(transform(current), options.InitialFreezeAvailable)
				assert(not entry.lost and entry.profile:IsActive(), "ProfileStore session ended before update")
				entry.profile.Data.StreakRewards = updated
				saveAndConfirm(entry, updated)
				return decode(updated, options.InitialFreezeAvailable)
			end)
		end,

		Save = function(userId: number): ()
			adapter.Update(userId, function(current: Record): Record
				return current
			end)
		end,

		Release = function(userId: number): ()
			local entry = entries[userId]
			if entry == nil or entry.releasing then
				return
			end
			entry.releasing = true
			while entry.busy do
				task.wait()
			end
			local released = not entry.profile:IsActive()
			local savedConnection = entry.profile.OnAfterSave:Connect(function(): ()
				if not entry.profile:IsActive() then
					released = true
				end
			end)
			local ok, failure = pcall(function(): ()
				if not released then
					entry.profile:EndSession()
					local deadline = os.clock() + saveTimeout
					while not released and os.clock() < deadline do
						task.wait()
					end
					assert(released, "ProfileStore final release save timed out")
				end
			end)
			savedConnection:Disconnect()
			if entry.endedConnection then
				entry.endedConnection:Disconnect()
			end
			entries[userId] = nil
			if not ok then
				error(tostring(failure), 0)
			end
		end,
	}
	return adapter
end
