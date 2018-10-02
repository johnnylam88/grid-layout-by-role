--[[--------------------------------------------------------------------
    Copyright (C) 2014, 2018 Johnny C. Lam.
    See the file LICENSE.txt for copying permission.
--]]--------------------------------------------------------------------

--[[
	GridLayoutByRole is a Grid layout plugin that groups members as tanks,
	melee DPS, healers, and ranged DPS.

	GridLayoutByRole manipulates the "nameList" attribute of layout groups
	used by the secure group headers in GridLayout to place members into
	different groups based on their role.
--]]

local GridLayout = Grid:GetModule("GridLayout")
local GridRoster = Grid:GetModule("GridRoster")

local GridLayoutByRole = Grid:NewModule("GridLayoutByRole", "AceBucket-3.0", "AceTimer-3.0")
--@debug@
_G.GridLayoutByRole = GridLayoutByRole
--@end-debug@

local ceil = math.ceil
local floor = math.floor
local ipairs = ipairs
local next = next
local pairs = pairs
local select = select
local setmetatable = setmetatable
local strsub = string.sub
local tconcat = table.concat
local tinsert = table.insert
local tonumber = tonumber
local wipe = table.wipe
-- local CanInspect = CanInspect
-- local CheckInteractDistance = CheckInteractDistance
-- local GetClassInfo = GetClassInfo
-- local GetInspectSpecialization = GetInspectSpecialization
-- local GetInstanceInfo = GetInstanceInfo
-- local InCombatLockdown = InCombatLockdown
-- local NotifyInspect = NotifyInspect
-- local UnitClass = UnitClass
-- local UnitGUID = UnitGUID
-- local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local MAX_RAID_MEMBERS = MAX_RAID_MEMBERS -- FrameXML/RaidFrame
local MEMBERS_PER_RAID_GROUP = MEMBERS_PER_RAID_GROUP -- FrameXML/RaidFrame
local UNKNOWN = UNKNOWN -- FrameXML/GlobalStrings.lua

-- The localized string table.
local L = setmetatable({}, { __index = function(t, k) return k end })

-- String constants for roles.
local TANK = "TANK"
local MELEE = "MELEE"
local HEALER = "HEALER"
local RANGED = "RANGED"

-- Pet layout group.
local petGroup = {
	isPetGroup = true,
	groupBy = "CLASS",
	groupingOrder = "HUNTER,WARLOCK,MAGE,DEATHKNIGHT,DRUID,PRIEST,SHAMAN,MONK,PALADIN,DEMONHUNTER,ROGUE,WARRIOR",
}

--[[---------------------
	Public properties
--]]---------------------

-- Layout table registered with GridLayout.
GridLayoutByRole.layout = {}

-- Map GUIDs to Blizzard roles ("TANK", "DAMAGER", "HEALER", "NONE").
GridLayoutByRole.blizzardRoleByGUID = {}
-- Map GUIDs to roles (TANK, MELEE, HEALER, RANGED).
GridLayoutByRole.roleByGUID = {}
-- List of tables of GUIDs by role.
-- roleGroup[role][guid] is the full name for guid if guid is in that role.
GridLayoutByRole.roleGroup = {
	[TANK] = {},
	[MELEE] = {},
	[HEALER] = {},
	[RANGED] = {},
}

do
	GridLayoutByRole.defaultDB = {
		debug = false,
		-- Map layout groups to raid role.
		role = {
			[1] = TANK,
			[2] = MELEE,
			[3] = HEALER,
			[4] = RANGED,
		},
		-- Healer classes that should be displayed in the melee role.
		meleeHealer = {},
	}

	--[[
		1st group: [dropdown] (tank/melee/healer/ranged)
		2nd group: [dropdown] (tank/melee/healer/ranged)
		3rd group: [dropdown] (tank/melee/healer/ranged)
		4th group: [dropdown] (tank/melee/healer/ranged)

		Healers to display as melee role:
		[ ] Druid
		[ ] Monk
		[ ] Paladin
		[ ] Priest
		[ ] Shaman
	--]]

	local roleSelect = {
		[TANK] = L["Tank"],
		[MELEE] = L["Melee"],
		[HEALER] = L["Healer"],
		[RANGED] = L["Ranged"],
	}

	local healerClassLocalization = {
		PALADIN = GetClassInfo(2),
		--PRIEST = GetClassInfo(5),
		--SHAMAN = GetClassInfo(7),
		MONK = GetClassInfo(10),
		--DRUID = GetClassInfo(11),
	}

	GridLayoutByRole.options = {
		name = L["Raid Role Groups"],
		type = "group",
		args = {
			roles = {
				name = L["Group Roles"],
				desc = L["Assign roles to display in each group."],
				order = 10,
				type = "group",
				inline = true,
				get = function(info)
					-- Strip "group" from "groupN".
					local index = tonumber(strsub(info[#info], 6))
					return GridLayoutByRole.db.profile.role[index]
				end,
				set = function(info, v)
					-- Strip "group" from "groupN".
					local index = tonumber(strsub(info[#info], 6))
					GridLayoutByRole.db.profile.role[index] = v or nil
					GridLayoutByRole:UpdateLayout()
				end,
				args = {
					group1 = {
						name = L["Group 1"],
						order = 10,
						type = "select",
						values = roleSelect,
					},
					group2 = {
						name = L["Group 2"],
						order = 20,
						type = "select",
						values = roleSelect,
					},
					group3 = {
						name = L["Group 3"],
						order = 30,
						type = "select",
						values = roleSelect,
					},
					group4 = {
						name = L["Group 4"],
						order = 40,
						type = "select",
						values = roleSelect,
					},
				},
			},
			meleeHealer = {
				name = L["Melee healers"],
				desc = L["Healers to display in the melee role."],
				order = 20,
				type = "multiselect",
				values = healerClassLocalization,
				get = function(info, k)
					return GridLayoutByRole.db.profile.meleeHealer[k]
				end,
				set = function(info, k, v)
					GridLayoutByRole.db.profile.meleeHealer[k] = v or nil
					-- Re-check the roles for the entire group.
					for guid, unit in GridRoster:IterateRoster() do
						GridLayoutByRole:QueueRoleCheck(guid, unit)
					end
				end,
			},
		},
	}
end

--[[-------------------
	Local functions
--]]-------------------

-- Insert the value at the rightmost insertion point of a sorted array using
-- binary search.  Returns the array index at which the value was inserted.
-- Binary search algorithm pseudocode from: http://rosettacode.org/wiki/Binary_search
local function binaryInsert(t, value)
	local low, high = 1, #t
	while low <= high do
		-- invariants: value >= t[i] for all i < low
		--             value < t[i] for all i > high
		local mid = floor((low + high) / 2)
		if value < t[mid] then
			high = mid - 1
		else
			low = mid + 1
		end
	end
	tinsert(t, low, value)
	return low
end

-- Returns true if the GUID is on the roster and not a pet, or nil otherwise.
local function isGroupGUID(guid)
	return GridRoster:IsGUIDInGroup(guid) and not GridRoster:GetOwnerUnitidByGUID(guid)
end

--[[------------------
	Initialization
--]]------------------

function GridLayoutByRole:PostInitialize()
	-- Localization.
	L = setmetatable({}, { __index = function(t, k) return k end })

	local layout = self.layout
	layout.name = L["By Raid Role"]
	layout.defaults = {
		sortMethod = "NAME",
		unitsPerColumn = MEMBERS_PER_RAID_GROUP,
	}
	-- Initialize empty group for each role.
	for i in ipairs(self.db.profile.role) do
		layout[i] = {}
	end
	GridLayout:AddLayout("ByRaidRole", layout)
end

function GridLayoutByRole:PostEnable()
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_REGEN_DISABLED", "EnteringCombat")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "LeavingCombat")
	self:RegisterEvent("ROLE_CHANGED_INFORM")
	self:RegisterMessage("Grid_UnitChanged")
	self:RegisterMessage("Grid_UnitJoined")
	self:RegisterMessage("Grid_UnitLeft")
	self:RegisterMessage("Grid_UnitRoleChanged")
end

function GridLayoutByRole:PostDisable()
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	self:UnregisterEvent("PLAYER_REGEN_DISABLED")
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	self:UnregisterEvent("ROLE_CHANGED_INFORM")
	self:UnregisterMessage("Grid_UnitChanged")
	self:UnregisterMessage("Grid_UnitJoined")
	self:UnregisterMessage("Grid_UnitLeft")
	self:UnregisterMessage("Grid_UnitRoleChanged")
end

--[[----------
	Events
--]]----------

do
	-- inspectPending[guid] is true if an inspection is already pending for
	-- that GUID, or nil otherwise.
	local inspectPending = {}

	-- QueueRoleCheck() is called by events that need to update the role for
	-- a member.  An inspection requeust is fired off and an event handler
	-- to catch the ensuing INSPECT_READY event is registered.
	function GridLayoutByRole:QueueRoleCheck(guid, unit)
		if not inspectPending[guid] and isGroupGUID(guid) and CanInspect(unit) and CheckInteractDistance(unit, 1) then
			self:Debug("QueueRoleCheck", guid, unit)
			-- Add event handler if there are no other pending inspections.
			if not next(inspectPending) then
				self:RegisterEvent("INSPECT_READY")
			end
			inspectPending[guid] = true
			NotifyInspect(unit)
		end
	end

	function GridLayoutByRole:INSPECT_READY(event, guid)
		if inspectPending[guid] then
			self:Debug(event, guid)
			inspectPending[guid] = nil
			-- Remove event handler if there are no more pending inspections.
			if not next(inspectPending) then
				self:UnregisterEvent("INSPECT_READY")
			end
			self:UpdateRole(guid)
		end
	end
end

function GridLayoutByRole:PLAYER_ENTERING_WORLD(event)
	if InCombatLockdown() then
		self:EnteringCombat(event)
	else
		self:LeavingCombat(event)
	end
end

do
	-- bucket for UNIT_AURA events
	local bucket

	function GridLayoutByRole:EnteringCombat(event)
		self:Debug("EnteringCombat", event)
		-- Unregister UNIT_AURA event handler when combat begins as players can't
		-- change specializations during combat.
		if bucket then
			self:UnregisterBucket(bucket)
			bucket = nil
		end
	end

	function GridLayoutByRole:LeavingCombat(event)
		self:Debug("LeavingCombat", event)
		-- Register UNIT_AURA event handler when combat ends to watch for players
		-- changing specializations.
		if not bucket then
			bucket = self:RegisterBucketEvent("UNIT_AURA", 0.2, "InspectUnits")
		end
	end

	-- Bucket event handler for UNIT_AURA.
	function GridLayoutByRole:InspectUnits(units)
		self:Debug("InspectUnits")
		local guid
		for unit in pairs(units) do
			guid = UnitGUID(unit)
			if guid then
				self:QueueRoleCheck(guid, unit)
			end
		end
	end
end

function GridLayoutByRole:ROLE_CHANGED_INFORM(event, changedPlayer, changedBy, oldRole, newRole)
	self:Debug(event, changedPlayer, changedBy, oldRole, newRole)
	local guid = GridRoster:GetGUIDByFullName(changedPlayer)
	if guid and self.blizzardRoleByGUID[guid] ~= newRole then
		self.blizzardRoleByGUID[guid] = newRole
		local unit = GridRoster:GetUnitidByGUID(guid)
		if unit then
			self:QueueRoleCheck(guid, unit)
		end
	end
end

function GridLayoutByRole:Grid_UnitChanged(event, guid, unit)
	self:Grid_UnitJoined(event, guid, unit)
	-- Force layout update due to changes.
	self:UpdateLayout()
end

function GridLayoutByRole:Grid_UnitJoined(event, guid, unit)
	self:Debug(event, guid, unit)
	-- Initialize with a role, even if it's the default role.
	self:UpdateRole(guid)
	-- Queue a check for the correct role.
	self:QueueRoleCheck(guid, unit)
end

function GridLayoutByRole:Grid_UnitLeft(event, guid)
	self:Debug(event, guid)
	self.blizzardRoleByGUID[guid] = nil
	self.roleByGUID[guid] = nil
	for _, group in pairs(self.roleGroup) do
		group[guid] = nil
	end
	self:UpdateLayout()
end

function GridLayoutByRole:Grid_UnitRoleChanged(event, guid, unit, oldRole, newRole)
	self:Debug(event, guid, unit, oldRole, newRole)
	self:UpdateLayout()
end

--[[------------------
	Public methods
--]]------------------

-- Get the Blizzard role of the GUID.
function GridLayoutByRole:GetBlizzardRole(guid)
	-- Get and cache the Blizzard role.
	local role = self.blizzardRoleByGUID[guid]
	if not role then
		local unit = GridRoster:GetUnitidByGUID(guid)
		if unit then
			role = UnitGroupRolesAssigned(unit)
			self.blizzardRoleByGUID[guid] = role
		else
			role = "NONE"
		end
	end
	return role
end

do
	-- Map return values from GetInspectSpecialization() to roles.
	-- ref: https://www.wowpedia.org/API_GetInspectSpecialization
	local roleBySpecialization = {
		-- Death Knight
		[250] = TANK,	-- Blood
		[251] = MELEE,	-- Frost
		[252] = MELEE,	-- Unholy
		-- Demon Hunter
		[577] = MELEE,	-- Havoc
		[581] = TANK,	-- Vengeance
		-- Druid
		[102] = RANGED,	-- Balance
		[103] = MELEE,	-- Feral
		[104] = TANK,	-- Guardian
		[105] = HEALER,	-- Restoration
		-- Hunter
		[253] = RANGED,	-- Beast Mastery
		[254] = RANGED,	-- Marksmanship
		[255] = RANGED,	-- Survival
		-- Mage
		[62] = RANGED,	-- Arcane
		[63] = RANGED,	-- Fire
		[64] = RANGED,	-- Frost
		-- Monk
		[268] = TANK,	-- Brewmaster
		[270] = HEALER,	-- Mistweaver
		[269] = MELEE,	-- Windwalker
		-- Paladin
		[65] = HEALER,	-- "Holy
		[66] = TANK,	-- "Protection
		[67] = MELEE,	-- "Retribution
		-- Priest
		[256] = HEALER,	-- Discipline
		[257] = HEALER,	-- Holy
		[258] = RANGED,	-- Shadow
		-- Rogue
		[259] = MELEE,	-- Assassination
		[260] = MELEE,	-- Outlaw
		[261] = MELEE,	-- Subtlety
		-- Shaman
		[262] = RANGED,	-- Elemental
		[263] = MELEE,	-- Enhancement
		[264] = HEALER,	-- Restoration
		-- Warlock
		[265] = RANGED,	-- Affliction
		[266] = RANGED,	-- Demonology
		[267] = RANGED,	-- Destruction
		-- Warrior
		[71] = MELEE,	-- Arms
		[72] = MELEE,	-- Fury
		[73] = TANK,	-- Protection
	}

	-- Default roles for each class in the absence of other information.
	local roleByClass = {
		DEATHKNIGHT = MELEE,
		DEMONHUNTER = MELEE,
		DRUID = RANGED,
		HUNTER = RANGED,
		MAGE = RANGED,
		MONK = MELEE,
		PALADIN = MELEE,
		PRIEST = RANGED,
		ROGUE = MELEE,
		SHAMAN = RANGED,
		WARLOCK = RANGED,
		WARRIOR = MELEE,
	}

	-- Get the role of the GUID as determined by class and specialization.
	function GridLayoutByRole:GetSpecializationRole(guid)
		local unit = GridRoster:GetUnitidByGUID(guid)
		if unit then
			local class = select(2, UnitClass(unit))
			local specialization = GetInspectSpecialization(unit)
			local role = specialization and roleBySpecialization[specialization]
			if not role then
				role = class and roleByClass[class] or RANGED
			end
			-- Adjust raid role if this healer is a "melee healer".
			if role == HEALER and class and self.db.profile.meleeHealer[class] then
				role = MELEE
			end
			return role
		end
		return RANGED
	end
end

-- Get the role of the GUID; prefer the Blizzard role for tanks.
function GridLayoutByRole:GetRole(guid)
	local role = self:GetBlizzardRole(guid)
	if role == "TANK" then
		role = TANK
	else
		role = self:GetSpecializationRole(guid)
	end
	return role
end

do
	local t = {}	-- scratch array for NameList()

	-- Returns a string of names in that role sorted alphabetically and
	-- separated by commas.
	function GridLayoutByRole:NameList(role)
		wipe(t)
		for guid in pairs(self.roleGroup[role]) do
			binaryInsert(t, GridRoster:GetFullNameByGUID(guid))
		end
		return tconcat(t, ",")
	end
end

-- Update the role associated with the GUID.
-- QueueRoleCheck() should be called before this to ensure the role
-- information is correct.
function GridLayoutByRole:UpdateRole(guid)
	if not isGroupGUID(guid) then return end
	self:Debug("UpdateRole", guid)
	local oldRole = self.roleByGUID[guid]
	local newRole = self:GetRole(guid)
	if oldRole ~= newRole then
		self.roleByGUID[guid] = newRole
		if oldRole then
			self.roleGroup[oldRole][guid] = nil
		end
		self.roleGroup[newRole][guid] = true
		-- Fire a message that the unit's role has changed.
		local unit = GridRoster:GetUnitidByGUID(guid)
		self:SendMessage("Grid_UnitRoleChanged", guid, unit, oldRole, newRole)
	end
end

function GridLayoutByRole:UpdateLayout()
	self:Debug("UpdateLayout")
	-- Get the maximum number of players in the group.
	local _, instanceType, _, _, maxPlayers, _, _, _, instanceGroupSize = GetInstanceInfo()
	if instanceType == "none" then
		maxPlayers = MAX_RAID_MEMBERS
	else
		maxPlayers = maxPlayers < instanceGroupSize and maxPlayers or instanceGroupSize
	end
	local unitsPerColumn = MEMBERS_PER_RAID_GROUP
	local maxColumns = ceil(maxPlayers / unitsPerColumn)
	local changed

	-- Update the default attributes.
	local defaults = self.layout.defaults
	if defaults.unitsPerColumn ~= unitsPerColumn then
		defaults.unitsPerColumn = unitsPerColumn
		changed = true
	end
	if defaults.maxColumns ~= maxColumns then
		defaults.maxColumns = maxColumns
		changed = true
	end

	-- Update the nameList attribute in each layout group.
	for i, role in ipairs(self.db.profile.role) do
		local group = self.layout[i]
		local nameList = self:NameList(role)
		if group.nameList ~= nameList then
			self:Debug("UpdateLayout", "update", role, nameList)
			group.nameList = nameList
			changed = true
		end
	end

	-- Add the pet group if selected.
	local numGroups = #self.db.profile.role
	if GridLayout.db.profile.showPets then
		self.layout[numGroups + 1] = petGroup
	else
		self.layout[numGroups + 1] = nil
	end

	-- Apply changes.
	if changed then
		GridLayout:ReloadLayout()
	end
	return true
end