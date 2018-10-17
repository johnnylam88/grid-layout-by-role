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

local GridLayoutByRole = Grid:NewModule("GridLayoutByRole", "AceTimer-3.0")
--@debug@
_G.GridLayoutByRole = GridLayoutByRole
--@end-debug@

local ceil = math.ceil
local floor = math.floor
local ipairs = ipairs
local next = next
local pairs = pairs
local setmetatable = setmetatable
local strsub = string.sub
local tconcat = table.concat
local tinsert = table.insert
local tonumber = tonumber
local wipe = table.wipe
-- GLOBALS: CanInspect
-- GLOBALS: CheckInteractDistance
-- GLOBALS: GetClassInfo
-- GLOBALS: GetInspectSpecialization
-- GLOBALS: GetInstanceInfo
-- GLOBALS: NotifyInspect
-- GLOBALS: UnitClass
-- GLOBALS: UnitGUID
-- GLOBALS: UnitGroupRolesAssigned
-- GLOBALS: UnitIsConnected
local MAX_RAID_MEMBERS = MAX_RAID_MEMBERS -- FrameXML/RaidFrame.lua
local MEMBERS_PER_RAID_GROUP = MEMBERS_PER_RAID_GROUP -- FrameXML/RaidFrame.lua

-- The localized string table.
local L = setmetatable({}, { __index = function(t, k) return k end })

-- String constants for roles.
local TANK = "TANK"
local MELEE = "MELEE"
local HEALER = "HEALER"
local RANGED = "RANGED"
local PET = "PET"

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
	[PET] = {},
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
		-- Ignore Blizzard roles.
		useBlizzardRole = false,
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
		PRIEST = GetClassInfo(5),
		SHAMAN = GetClassInfo(7),
		MONK = GetClassInfo(10),
		DRUID = GetClassInfo(11),
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
					GridLayoutByRole.db.profile.role[index] = v
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
				desc = L["Healer classes to display in the melee role."],
				order = 20,
				type = "multiselect",
				values = healerClassLocalization,
				get = function(info, k)
					return GridLayoutByRole.db.profile.meleeHealer[k]
				end,
				set = function(info, k, v)
					GridLayoutByRole.db.profile.meleeHealer[k] = v
					GridLayoutByRole:InspectUnits()
				end,
			},
			useBlizzardRole = {
				name = L["Use Blizzard role"],
				desc = L["Enable the Blizzard-assigned role to supersede the specialization role."],
				order = 30,
				type = "toggle",
				get = function(info)
					return GridLayoutByRole.db.profile.useBlizzardRole
				end,
				set = function(info, value)
					GridLayoutByRole.db.profile.useBlizzardRole = value
					GridLayoutByRole:InspectUnits()
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

-- Returns true if unit is a pet, or nil otherwise.
local function isPetUnit(unit)
	return GridRoster:GetOwnerUnitidByUnitid(unit) and true or nil
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
	self:RegisterEvent("PLAYER_REGEN_DISABLED")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "UnitSpecializationChanged")
	self:RegisterEvent("ROLE_CHANGED_INFORM")
	self:RegisterEvent("UNIT_CONNECTION")
	self:RegisterMessage("Grid_UnitChanged", "UnitChanged")
	self:RegisterMessage("Grid_UnitJoined", "UnitJoined")
	self:RegisterMessage("Grid_UnitLeft", "UnitLeft")
	self:RegisterMessage("Grid_UnitRoleChanged", "UnitRoleChanged")
end

function GridLayoutByRole:PostDisable()
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	self:UnregisterEvent("PLAYER_REGEN_DISABLED")
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	self:UnregisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	self:UnregisterEvent("ROLE_CHANGED_INFORM")
	self:UnregisterEvent("UNIT_CONNECTION")
	self:UnregisterMessage("Grid_UnitChanged")
	self:UnregisterMessage("Grid_UnitJoined")
	self:UnregisterMessage("Grid_UnitLeft")
	self:UnregisterMessage("Grid_UnitRoleChanged")
end

--[[------------------
	Public methods
--]]------------------

--[[
	The QueueRoleCheck, NotifyInspect, INSPECT_READY, and UpdateRole
	methods work together to update the role for a group unit.
	QueueRoleCheck is the entry point, which triggers NotifyInspect,
	which sets up a listener for INSPECT_READY to call UpdateRole.
--]]
do
	local inspectPending = {} -- inspectPending[guid] = true if an inspection is pending for the guid
	local timer -- timer for requesting notifications for pending inspections
	local eventRegistered -- true if INSPECT_READY is registered

	-- Export for debugging.
	GridLayoutByRole.inspectPending = inspectPending

	function GridLayoutByRole:QueueRoleCheck(event, guid, unit)
		if inspectPending[guid] then
			self:Debug("QueueRoleCheck", event, guid, unit, "pending")
		else
			self:Debug("QueueRoleCheck", event, guid, unit)
			if isPetUnit(unit) then
				-- Pets don't need to be inspected; their role is always "PET".
				self:UpdateRole(guid, unit, PET)
			else
				inspectPending[guid] = true
				self:NotifyInspect()
			end
		end
	end

	function GridLayoutByRole:UnqueueRoleCheck(guid)
		inspectPending[guid] = nil
		self:PendingInspectionCheck()
	end

	function GridLayoutByRole:NotifyInspect()
		for guid in pairs(inspectPending) do
			local unit = GridRoster:GetUnitidByGUID(guid)
			if unit and UnitIsConnected(unit) then
				if not eventRegistered then
					self:Debug("NotifyInspect", "INSPECT_READY")
					self:RegisterEvent("INSPECT_READY", "InspectReady")
					eventRegistered = true
				end
				NotifyInspect(unit)
			else
				-- Prune pending inspections for units that are no longer in group or are disconnected.
				self:Debug("NotifyInspect", guid, "pruned")
				inspectPending[guid] = nil
			end
		end
		self:PendingInspectionCheck()
	end

	function GridLayoutByRole:PendingInspectionCheck()
		if next(inspectPending) then
			-- Start a repeating timer to request notification for each pending inspection.
			timer = timer or self:StartTimer("NotifyInspect", 0.3, true)
		else
			self:PauseInspections()
		end
	end

	function GridLayoutByRole:PauseInspections()
		-- Unregister INSPECT_READY event and stop the timer.
		if eventRegistered then
			self:Debug("PendingInspectionCheck", "INSPECT_READY")
			self:UnregisterEvent("INSPECT_READY")
			eventRegistered = nil
		end
		if timer then
			self:StopTimer("NotifyInspect")
			timer = nil
		end
	end

	function GridLayoutByRole:InspectReady(event, guid)
		if inspectPending[guid] then
			local unit = GridRoster:GetUnitidByGUID(guid)
			if unit then
				local specialization, class = self:GetUnitSpecialization(unit)
				-- Only removing pending inspection if the specialization information is available.
				if specialization and class then
					self:Debug("InspectReady", event, guid, class, specialization)
					self:UnqueueRoleCheck(guid)
					local role = self:GetRole(guid, unit, class, specialization)
					self:UpdateRole(guid, unit, role)
				end
			else
				-- GUID is no longer in the group.
				self:UnitLeft(event, guid)
			end
		end
	end

	function GridLayoutByRole:PLAYER_REGEN_DISABLED(event)
		self:PauseInspections()
	end

	function GridLayoutByRole:PLAYER_REGEN_ENABLED(event)
		self:PendingInspectionCheck()
	end
end

function GridLayoutByRole:PLAYER_ENTERING_WORLD(event)
	self:UnitSpecializationChanged(event, "player")
end

function GridLayoutByRole:ROLE_CHANGED_INFORM(event, changedPlayer, changedBy, oldRole, newRole)
	self:Debug(event, changedPlayer, changedBy, oldRole, newRole)
	local guid = GridRoster:GetGUIDByFullName(changedPlayer)
	if guid then
		local unit = GridRoster:GetUnitidByGUID(guid)
		if unit then
			if self.blizzardRoleByGUID[guid] ~= newRole then
				self.blizzardRoleByGUID[guid] = newRole
			end
			self:QueueRoleCheck(event, guid, unit)
		else
			-- GUID is no longer in the group.
			self:UnitLeft(event, guid)
		end
	end
end

function GridLayoutByRole:UNIT_CONNECTION(event, unit, isConnected)
	self:UnitSpecializationChanged(event, unit)
end

function GridLayoutByRole:UnitChanged(event, guid, unit)
	self:Debug("UnitChanged", event, guid, unit)
	-- Force layout update due to changes.
	self:UpdateLayout()
end

function GridLayoutByRole:UnitJoined(event, guid, unit)
	self:Debug("UnitJoined", event, guid, unit)
	-- Initialize to a default role.
	local role = self:GetDefaultRole(unit)
	self:UpdateRole(guid, unit, role)
	-- Queue a check for the correct role.
	self:QueueRoleCheck("UnitJoined", guid, unit)
end

function GridLayoutByRole:UnitLeft(event, guid)
	self:Debug("UnitLeft", event, guid)
	self:UnqueueRoleCheck(guid)
	self.blizzardRoleByGUID[guid] = nil
	self.roleByGUID[guid] = nil
	for _, group in pairs(self.roleGroup) do
		group[guid] = nil
	end
	self:UpdateLayout()
end

function GridLayoutByRole:UnitRoleChanged(event, guid, unit, oldRole, newRole)
	self:Debug("UnitRoleChanged", event, guid, unit, oldRole, newRole)
	self:UpdateLayout()
end

function GridLayoutByRole:UnitSpecializationChanged(event, unit)
	self:Debug("UnitSpecializationChanged", event, unit)
	local guid = UnitGUID(unit)
	if guid then
		self:QueueRoleCheck(event, guid, unit)
	end
end

-- Get the Blizzard role of the GUID.
function GridLayoutByRole:GetBlizzardRole(guid, unit)
	-- Get and cache the Blizzard role.
	local role = self.blizzardRoleByGUID[guid]
	if not role then
		role = UnitGroupRolesAssigned(unit)
		self.blizzardRoleByGUID[guid] = role
	end
	return role
end

do
	-- Default roles for each class.
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

	function GridLayoutByRole:GetDefaultRole(unit, class)
		local role
		if isPetUnit(unit) then
			role = PET
		else
			if not class then
				local _, classFile = UnitClass(unit)
				class = classFile
			end
			-- Initialize to a default role.
			role = class and roleByClass[class] or RANGED
		end
		return role
	end
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
		[255] = MELEE,	-- Survival
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

	-- Returns the specialization ID and class of the unit if available, or nil otherwise.
	function GridLayoutByRole:GetUnitSpecialization(unit)
		local specialization = GetInspectSpecialization(unit)
		-- Validate the return value against the table of possible IDs.
		if not roleBySpecialization[specialization] then
			specialization = nil
		end
		local class = UnitClass(unit)
		return specialization, class
	end

	-- Get the role of the GUID as determined by class and specialization.
	function GridLayoutByRole:GetRole(guid, unit, class, specialization)
		local role = self:GetDefaultRole(unit, class)
		local specRole = roleBySpecialization[specialization]
		if specRole then
			role = specRole
		else
			self:Debug("GetRole", guid, unit, class, specialization, "UNKNOWN SPECIALIZATION")
		end
		-- Adjust raid role if this healer is a "melee healer".
		if role == HEALER and self.db.profile.meleeHealer[class] then
			role = MELEE
		end
		-- Prefer the Blizzard role for tanks and healers if requested.
		if self.db.profile.useBlizzardRole then
			local blizzardRole = self:GetBlizzardRole(guid, unit)
			if blizzardRole == "TANK" or blizzardRole == "HEALER" then
				role = blizzardRole
			end
		end
		return role
	end
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
function GridLayoutByRole:UpdateRole(guid, unit, role)
	self:Debug("UpdateRole", guid, unit, role)
	local oldRole = self.roleByGUID[guid]
	if oldRole ~= role then
		self.roleByGUID[guid] = role
		if oldRole then
			self.roleGroup[oldRole][guid] = nil
		end
		self.roleGroup[role][guid] = true
		-- Fire a message that the unit's role has changed.
		self:SendMessage("Grid_UnitRoleChanged", guid, unit, oldRole, role)
	end
end

function GridLayoutByRole:InspectUnits()
	for guid, unit in GridRoster:IterateRoster() do
		self:QueueRoleCheck("InspectUnits", guid, unit)
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