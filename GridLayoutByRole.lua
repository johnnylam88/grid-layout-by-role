--[[--------------------------------------------------------------------
    Copyright (C) 2014 Johnny C. Lam.
    See the file LICENSE.txt for copying permission.
--]]--------------------------------------------------------------------

--[[
	GridLayoutByRole is a Grid layout plugin that groups roster members by role.

	GridLayoutByRole manipulates the "nameList" attribute of layout groups used
	by the secure group headers in GridLayout to place members into different
	groups based on their role.  GridLayoutByRole differentiates between melee
	and ranged DPS for raid roles.
--]]

GridLayoutByRole = Grid:NewModule("GridLayoutByRole")

local GridLayout = Grid:GetModule("GridLayout")
local GridLayoutByRole = GridLayoutByRole
local GridRoster = Grid:GetModule("GridRoster")
local LibGroupInSpecT = LibStub:GetLibrary("LibGroupInSpecT-1.1")

local ceil = math.ceil
local floor = math.floor
local ipairs = ipairs
local pairs = pairs
local select = select
local setmetatable = setmetatable
local strfind = string.find
local tconcat = table.concat
local tinsert = table.insert
local tremove = table.remove
local wipe = table.wipe
-- local GetSpellInfo = GetSpellInfo
-- local UnitBuff = UnitBuff
-- local UnitClass = UnitClass
-- local UnitGUID = UnitGUID
-- local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UNKNOWN = UNKNOWN		-- FrameXML/GlobalStrings.lua

-- The localized string table.
local L

-- Map layout group to role.
local groupRole = {
	[1] = "tank",
	[2] = "melee",
	[3] = "healer",
	[4] = "ranged",
}

-- Map role to array of names of roster members in that role.
-- Arrays are maintained in alphabetical order.
local roleNameList = {
	tank = {},
	melee = {},
	healer = {},
	ranged = {},
}

-- Default roles for each class in the absence of other information.
local DEFAULT_ROLE = {
	DEATHKNIGHT = "melee",
	DRUID = "ranged",
	HUNTER = "ranged",
	MAGE = "ranged",
	MONK = "melee",
	PALADIN = "melee",
	PRIEST = "ranged",
	ROGUE = "melee",
	SHAMAN = "ranged",
	WARLOCK = "ranged",
	WARRIOR = "melee",
}

-- Map GUIDs to roles ("tank", "melee", "healer", "ranged").
local roleByGUID = {}
-- Map GUIDs to Blizzard roles ("TANK", "DAMAGER", "HEALER", "NONE").
local blizzardRoleByGUID = {}

-- Map GridRoster party states to the maximum number of units.
local MAX_UNITS = {
	arena = 5,
	bg = 40,
	party = 5,
	raid_10 = 10,
	raid_25 = 25,
	raid_40 = 40,
	raid_flex = 30,
	solo = 1,
}

-- Global specialization ID for protection warriors.
local WARRIOR_PROTECTION_SPEC_ID = 73
-- Talent IDs for level-100 protection warrior talents.
local ANGER_MANAGEMENT_TALENT = 21204
local RAVAGER_TALENT = 21205
local GLADIATORS_RESOLVE_TALENT = 21206
-- Localized name of Gladiator Stance buff.
local GLADIATOR_STANCE = GetSpellInfo(156291)

--[[---------------------
	Public properties
--]]---------------------

-- Layout tables registered with GridLayout.
GridLayoutByRole.layout = {}
-- Layout tables by name.
GridLayoutByRole.layoutByName = {}

--[[-------------------
	Local functions
--]]-------------------

local binaryInsert
local binarySearch
do
	-- Binary search algorithm pseudocode from: http://rosettacode.org/wiki/Binary_search

	local compareDefault = function(a, b) return a < b end

	-- Insert the value at the rightmost insertion point of a sorted array using binary search.
	function binaryInsert(t, value, compare)
		compare = compare or compareDefault
		local low, high = 1, #t
		while low <= high do
			-- invariants: value >= t[i] for all i < low
			--             value < t[i] for all i > high
			local mid = floor((low + high) / 2)
			if compare(value, t[mid]) then
				high = mid - 1
			else
				low = mid + 1
			end
		end
		tinsert(t, low, value)
		return low
	end

	-- Return the index of the value in a sorted array using binary search.
	function binarySearch(t, value, compare)
		compare = compare or compareDefault
		local low, high = 1, #t
		while low <= high do
			-- invariants: value > t[i] for all i < low
			--             value < t[i] for all i > high
			local mid = floor((low + high) / 2)
			if compare(value, t[mid]) then
				high = mid - 1
			elseif compare(t[mid], value) then
				low = mid + 1
			else
				return mid
			end
		end
		return nil
	end
end

--[[
	Filter return values from LibGroupInSpecT-1.1 to fix up the "spec_role_detailed"
	returned via the "info" table for protection warrior tanks talented into
	Gladiator's Resolve.
--]]
local function LibGroupInSpecT_GetRole(guid, unitId, info)
	info = info or LibGroupInSpecT:GetCachedInfo(guid)
	local role = info and info.spec_role_detailed
	-- Fixup role if unit is a protection warrior in Gladiator Stance.
	if info and info.global_spec_id == WARRIOR_PROTECTION_SPEC_ID then
		-- Check for "not the other two level-100 talents" in case talent info isn't ready.
		local talents = info.talents
		if talents[GLADIATORS_RESOLVE_TALENT] or not talents[ANGER_MANAGEMENT_TALENT] and not talents[RAVAGER_TALENT] then
			-- If the Gladiator Stance buff is present, then this is a melee DPS protection warrior.
			unitId = unitId or LibGroupInSpecT:GuidToUnit(guid)
			if unitId and UnitBuff(unitId, GLADIATOR_STANCE) then
				role = "melee"
			end
		end
	end
	return role
end

--[[------------------
	Initialization
--]]------------------

function GridLayoutByRole:PostInitialize()
	-- Localization.
	L = setmetatable({}, { __index = function(t, k) return k end })

	-- Add layouts to GridLayout.
	self.layout[1] = {
		defaults = {},
		[1] = {},	-- tanks
		[2] = {},	-- melee
		[3] = {},	-- healers
		[4] = {},	-- ranged
	}
	self.layoutByName[L["By Role"]] = self.layout[1]
	self.layout[2] = {
		defaults = {},
		[1] = {},	-- tanks
		[2] = {},	-- melee
		[3] = {},	-- healers
		[4] = {},	-- ranged
		[5] = {		-- pets
			isPetGroup = true,
		},
	}
	self.layoutByName[L["By Role w/Pets"]] = self.layout[2]
	for name, layout in pairs(self.layoutByName) do
		GridLayout:AddLayout(name, layout)
	end
end

function GridLayoutByRole:PostEnable()
	self:RegisterEvent("ROLE_CHANGED_INFORM")
	self:RegisterEvent("PLAYER_REGEN_DISABLED")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	self:RegisterEvent("UNIT_AURA")
	self:RegisterMessage("Grid_UnitChanged", "UpdateGUID")
	self:RegisterMessage("Grid_UnitJoined", "UpdateGUID")
	LibGroupInSpecT.RegisterCallback(self, "GroupInSpecT_Update", "UpdateRoleByGUID")
	LibGroupInSpecT.RegisterCallback(self, "GroupInSpecT_Remove", "GroupInSpecT_Remove")
end

function GridLayoutByRole:PostDisable()
	self:UnregisterEvent("ROLE_CHANGED_INFORM")
	self:UnregisterEvent("PLAYER_REGEN_DISABLED")
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	self:UnregisterEvent("UNIT_AURA")
	self:UnregisterMessage("Grid_UnitChanged")
	self:UnregisterMessage("Grid_UnitJoined")
	LibGroupInSpecT.UnregisterCallback(self, "GroupInSpecT_Update")
	LibGroupInSpecT.UnregisterCallback(self, "GroupInSpecT_Remove")
end

--[[----------
	Events
--]]----------

function GridLayoutByRole:ROLE_CHANGED_INFORM(event, changedPlayer, changedBy, oldRole, newRole)
	self:Debug(event, changedPlayer, changedBy, oldRole, newRole)
	local guid = GridRoster:GetGUIDByFullName(changedPlayer)
	if guid and blizzardRoleByGUID[guid] ~= newRole then
		blizzardRoleByGUID[guid] = newRole
		self:UpdateGUID(event, guid)
	end
end

function GridLayoutByRole:PLAYER_REGEN_DISABLED(event)
	self:Debug(event)
	-- Unregister UNIT_AURA event handler when combat begins since protection warriors can't
	-- change out of Gladiator Stance during combat.
	self:UnregisterEvent("UNIT_AURA")
end

function GridLayoutByRole:PLAYER_REGEN_ENABLED(event)
	self:Debug(event)
	-- Register UNIT_AURA event handler when combat ends to watch for protection warriors
	-- switching between Gladiator Stance and Defensive Stance.
	self:RegisterEvent("UNIT_AURA")
end

function GridLayoutByRole:UNIT_AURA(event, unitId)
	local guid = UnitGUID(unitId)
	if LibGroupInSpecT:GuidToUnit(guid) then
		local info = LibGroupInSpecT:GetCachedInfo(guid)
		if info then
			self:UpdateRoleByGUID(event, guid, unitId, info)
		end
	end
end

function GridLayoutByRole:UpdateRoleByGUID(event, guid, unitId, info)
	local hasChanged = false
	local role = LibGroupInSpecT_GetRole(guid, unitId, info)
	if roleByGUID[guid] ~= role then
		roleByGUID[guid] = role
		hasChanged = true
	end
	if hasChanged then
		self:Debug("UpdateRoleByGUID", unitId, role)
		self:UpdateGUID(event, guid)
	end
end

function GridLayoutByRole:GroupInSpecT_Remove(event, guid)
	self:Debug(event, guid)
	blizzardRoleByGUID[guid] = nil
	roleByGUID[guid] = nil
	self:UpdateAllGUIDs(event)
end

--[[------------------
	Public methods
--]]------------------

-- Get the role of the GUID, preferring the Blizzard role for tanks and healers.
function GridLayoutByRole:GetRole(guid)
	local unitId
	local info = LibGroupInSpecT:GetCachedInfo(guid)
	-- Get and cache the Blizzard role.
	local blizzardRole = blizzardRoleByGUID[guid]
	if not blizzardRole then
		unitId = unitId or LibGroupInSpecT:GuidToUnit(guid)
		if unitId then
			blizzardRole = UnitGroupRolesAssigned(unitId)
			blizzardRoleByGUID[guid] = blizzardRole
		else
			blizzardRole = "NONE"
		end
	end
	-- Get the LibGroupInSpecT role.
	local role = roleByGUID[guid]
	if not role then
		unitId = unitId or LibGroupInSpecT:GuidToUnit(guid)
		role = LibGroupInSpecT_GetRole(guid, unitId, info)
		if not role then
			local class = info and info.class
			if not class then
				class = unitId and select(2, UnitClass(unitId))
			end
			role = class and DEFAULT_ROLE[class] or "ranged"
		end
	end
	if blizzardRole == "TANK" then
		return "tank"
	elseif blizzardRole == "HEALER" then
		return "healer"
	end
	return role
end

function GridLayoutByRole:RemoveName(name)
	-- Remove the name from all role name lists.
	for _, nameList in pairs(roleNameList) do
		local i = binarySearch(nameList, name)
		if i then
			tremove(nameList, i)
			break
		end
	end
end

function GridLayoutByRole:UpdateGUID(event, guid)
	self:Debug("UpdateGUID", event, guid)
	local name, realm = GridRoster:GetNameByGUID(guid)
	if name == UNKNOWN then
		self:UpdateAllGUIDs()
	else
		if realm then
			name = name .. "-" .. realm
		end
		self:RemoveName(name)
		-- Add the name to the correct role name list.
		local role = self:GetRole(guid)
		binaryInsert(roleNameList[role], name)
		self:UpdateLayout()
	end
end

function GridLayoutByRole:UpdateAllGUIDs(event)
	self:Debug("UpdateAllGUIDs", event)
	-- Update the name lists for each role.
	for _, nameList in pairs(roleNameList) do
		wipe(nameList)
	end
	for guid, unit in GridRoster:IterateRoster() do
		if not strfind(unit, "pet") then
			local role = self:GetRole(guid)
			local name = GridRoster:GetFullNameByGUID(guid)
			binaryInsert(roleNameList[role], name)
		end
	end
	self:UpdateLayout()
end

function GridLayoutByRole:UpdateLayout()
	self:Debug("UpdateLayout")
	local hasLayoutChanged = false
	-- Update the default unitsPerColumn and maxColumns attributes.
	do
		local unitsPerColumn = 5
		local partyState = GridRoster:GetPartyState()
		local maxColumns = ceil(MAX_UNITS[partyState] / unitsPerColumn)
		for _, layout in pairs(self.layout) do
			local defaults = layout.defaults
			if defaults.unitsPerColumn ~= unitsPerColumn then
				defaults.unitsPerColumn = unitsPerColumn
				hasLayoutChanged = true
			end
			if defaults.maxColumns ~= maxColumns then
				defaults.maxColumns = maxColumns
				hasLayoutChanged = true
			end
		end
	end
	-- Update the nameList attribute in each layout group.
	for i, group in ipairs(self.layout[1]) do
		local role = groupRole[i]
		local nameList = tconcat(roleNameList[role], ",")
		if group.nameList ~= nameList then
			group.nameList = nameList
			hasLayoutChanged = true
		end
	end
	for i, group in ipairs(self.layout[2]) do
		if not group.isPetGroup then
			group.nameList = self.layout[1][i].nameList
		end
	end
	if hasLayoutChanged then
		self:SendMessage("Grid_ReloadLayout")
	end
end
