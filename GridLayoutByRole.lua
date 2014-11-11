--[[--------------------------------------------------------------------
    Copyright (C) 2014 Johnny C. Lam.
    See the file LICENSE.txt for copying permission.
--]]--------------------------------------------------------------------

GridLayoutByRole = Grid:NewModule("GridLayoutByRole", "AceHook-3.0")

local GridLayout = Grid:GetModule("GridLayout")
local GridLayoutByRole = GridLayoutByRole
local GridRoster = Grid:GetModule("GridRoster")
local LibGroupInSpecT = LibStub:GetLibrary("LibGroupInSpecT-1.1")

local ceil = math.ceil
local pairs = pairs
local select = select
local setmetatable = setmetatable
local strfind = string.find
local tconcat = table.concat
local tinsert = table.insert
local wipe = table.wipe

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
local roleNameList = {
	tank = {},
	melee = {},
	healer = {},
	ranged = {},
}

-- Map GUIDs to roles.
local roleByGUID
do
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

	-- Ask LibGroupInSpecT for the guid's cached role if not already cached in the table.
	local function GetRole(t, guid)
		local info = LibGroupInSpecT:GetCachedInfo(guid)
		local role = info and info.spec_role_detailed
		if not role then
			local class = info and info.class
			if not class then
				local unitId = LibGroupInSpecT:GuidToUnit(guid)
				if unitId then
					class = select(2, UnitClass(unitId))
				end
			end
			role = class and DEFAULT_ROLE[class]
		end
		return role or "ranged"
	end

	roleByGUID = setmetatable({}, { __index = GetRole })
end

-- Map GUIDs to Blizzard roles ("TANK", "DAMAGER", "HEALER", "NONE").
local blizzardRoleByGUID
do
	local function GetBlizzardRole(t, guid)
		local info = LibGroupInSpecT:GetCachedInfo(guid)
		local role = info and info.spec_role
		if not role then
			local unitId = LibGroupInSpecT:GuidToUnit(guid)
			if unitId then
				role = UnitGroupRolesAssigned(unitId)
			end
		end
		return role or "NONE"
	end

	blizzardRoleByGUID = setmetatable({}, { __index = GetBlizzardRole })
end

-- Map Blizzard roles to LibGroupInSpecT roles.
local ROLE_BY_BLIZZARD = {
	TANK = "tank",
	DAMAGER = "ranged",	-- unused entry
	HEALER = "healer",
	NONE = "ranged", -- unused entry
}

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

--[[---------------------
    Public properties
--]]---------------------

-- Layout tables registered with GridLayout.
GridLayoutByRole.layout = {}
-- Layout tables by name.
GridLayoutByRole.layoutByName = {}

--[[------------------
	Initialization
--]]------------------

function GridLayoutByRole:PostInitialize()
	-- Localization.
	L = setmetatable({}, { __index = function(t, k) return k end })

	-- Add layouts to GridLayout.
	self.layout[1] = {
		[1] = {},	-- tanks
		[2] = {},	-- melee
		[3] = {},	-- healers
		[4] = {},	-- ranged
	}
	self.layoutByName[L["By Role"]] = self.layout[1]
	self.layout[2] = {
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
	self:RegisterMessage("Grid_RosterUpdated", "UpdateGroups")
	LibGroupInSpecT.RegisterCallback(self, "GroupInSpecT_Update", "GroupInSpecT_Update")
	LibGroupInSpecT.RegisterCallback(self, "GroupInSpecT_Remove", "GroupInSpecT_Remove")
	self:Hook(GridLayout, "ReloadLayout")
	self:UpdateGroups("PostEnable")
end

function GridLayoutByRole:PostDisable()
	self:Unhook(GridLayout, "ReloadLayout")
	self:UnregisterEvent("ROLE_CHANGED_INFORM")
	self:UnregisterMessage("Grid_RosterUpdated")
	LibGroupInSpecT.UnregisterCallback(self, "GroupInSpecT_Update")
	LibGroupInSpecT.UnregisterCallback(self, "GroupInSpecT_Remove")
end

--[[----------
	Events
--]]----------

function GridLayoutByRole:ROLE_CHANGED_INFORM(event, changedPlayer, changedBy, oldRole, newRole)
	local guid = GridRoster:GetGUIDByFullName(changedPlayer)
	if guid then
		local oldBlizzardRole = blizzardRoleByGUID[guid]
		blizzardRoleByGUID[guid] = newRole
		if oldBlizzardRole ~= newRole then
			self:UpdateGroups(event)
		end
	end
end

function GridLayoutByRole:GroupInSpecT_Update(event, guid, unit, info)
	local oldBlizzardRole = blizzardRoleByGUID[guid]
	local oldRole = roleByGUID[guid]
	blizzardRoleByGUID[guid] = info.spec_role
	roleByGUID[guid] = info.spec_role_detailed
	if oldBlizzardRole ~= blizzardRoleByGUID[guid] or oldRole ~= roleByGUID[guid] then
		self:UpdateGroups(event)
	end
end

function GridLayoutByRole:GroupInSpecT_Remove(event, guid)
	blizzardRoleByGUID[guid] = nil
	roleByGUID[guid] = nil
	self:UpdateGroups(event)
end

--[[------------------
	Public methods
--]]------------------

function GridLayoutByRole:GetRole(guid)
	local blizzardRole = blizzardRoleByGUID[guid]
	local role = roleByGUID[guid]
	if blizzardRole == "NONE" then
		return role
	elseif blizzardRole == "DAMAGER" then
		return role
	end
	return ROLE_BY_BLIZZARD[blizzardRole]
end

function GridLayoutByRole:ActiveLayoutByRole()
	return self.layoutByName[GridLayout.db.profile.layout]
end

-- Hook for GridLayout:ReloadLayout()
-- Force updating the groups when reloading the layout to ensure the information is accurate.
function GridLayoutByRole:ReloadLayout()
	self:UpdateGroups("ReloadLayout")
end

function GridLayoutByRole:UpdateGroups(event)
	self:Debug("UpdateGroups", event)
	-- Update the name lists for each role.
	for _, nameList in pairs(roleNameList) do
		wipe(nameList)
	end
	for guid, unit in GridRoster:IterateRoster() do
		if not strfind(unit, "pet") then
			local role = self:GetRole(guid)
			local name = GridRoster:GetFullNameByGUID(guid)
			tinsert(roleNameList[role], name)
		end
	end
	-- Update the default unitsPerColumn and maxColumns attributes.
	do
		local unitsPerColumn = 5
		local partyState = GridRoster:GetPartyState()
		local maxColumns = ceil(MAX_UNITS[partyState] / unitsPerColumn)
		for _, layout in pairs(self.layout) do
			for _, group in pairs(layout) do
				group.unitsPerColumn = unitsPerColumn
				group.maxColumns = maxColumns
			end
		end
	end
	-- Update the nameList attribute in each layout group.
	for i, group in pairs(self.layout[1]) do
		local role = groupRole[i]
		local nameList = roleNameList[role]
		group.nameList = tconcat(nameList, ",")
	end
	for i, group in pairs(self.layout[2]) do
		if not group.isPetGroup then
			group.nameList = self.layout[1][i].nameList
		end
	end

	-- Update the attributes in the GridLayout secure group headers.
	local activeLayout = self:ActiveLayoutByRole()
	if activeLayout then
		local hasGroupsChanged = false
		for i, group in pairs(activeLayout) do
			local layoutGroup = GridLayout.layoutGroups[i]
			if layoutGroup then
				for attr, value in pairs(group) do
					local oldValue = layoutGroup:GetAttribute(attr)
					if not oldValue or value ~= oldValue then
						layoutGroup:SetAttribute(attr, value)
						hasGroupsChanged = true
					end
				end
			end
		end
		if hasGroupsChanged then
			GridLayout:PartyMembersChanged()
		end
	end
end
