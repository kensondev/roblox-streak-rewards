--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("StreakRewards"):WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))

type Record = Types.Record

local RecordCodec = {}
RecordCodec.Version = 1

local MAX_SAFE_INTEGER = 9007199254740991

local function integer(value: any, name: string): number
	if type(value) ~= "number" or value ~= value or value < 0 or value > MAX_SAFE_INTEGER or value % 1 ~= 0 then
		error(`StreakRewards record has an invalid {name}`, 3)
	end
	return value
end

function RecordCodec.New(freezeAvailable: boolean): Record
	return {
		version = RecordCodec.Version,
		lastClaimTime = 0,
		streak = 0,
		freezeAvailable = freezeAvailable,
	}
end

function RecordCodec.Decode(value: any, initialFreeze: boolean): Record
	if value == nil then
		return RecordCodec.New(initialFreeze)
	end
	if type(value) ~= "table" then
		error("StreakRewards record must be a table", 2)
	end

	local version = value.version
	if version == nil then
		version = 0
	end
	version = integer(version, "version")
	if version > RecordCodec.Version then
		error("StreakRewards record uses a newer schema; refusing to overwrite it", 2)
	end

	-- Version 0 stored the same timestamp and streak without a freeze field.
	-- A malformed existing record is never treated as a new player.
	local lastClaimTime = integer(value.lastClaimTime, "lastClaimTime")
	local streak = integer(value.streak, "streak")
	if (lastClaimTime == 0) ~= (streak == 0) then
		error("StreakRewards record timestamp and streak disagree", 2)
	end

	local freezeAvailable = value.freezeAvailable
	if version == 0 and freezeAvailable == nil then
		freezeAvailable = initialFreeze
	end
	if type(freezeAvailable) ~= "boolean" then
		error("StreakRewards record has an invalid freezeAvailable", 2)
	end

	return {
		version = RecordCodec.Version,
		lastClaimTime = lastClaimTime,
		streak = streak,
		freezeAvailable = freezeAvailable,
	}
end

function RecordCodec.Copy(record: Record): Record
	return {
		version = record.version,
		lastClaimTime = record.lastClaimTime,
		streak = record.streak,
		freezeAvailable = record.freezeAvailable,
	}
end

function RecordCodec.Equal(left: Record, right: Record): boolean
	return left.version == right.version
		and left.lastClaimTime == right.lastClaimTime
		and left.streak == right.streak
		and left.freezeAvailable == right.freezeAvailable
end

return RecordCodec
