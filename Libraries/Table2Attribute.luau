-- // About //
-- Made By: JackaBoi
-- Last Updated: 10/5/2026

local Table2Attribute = {}

-- Converts a table with elements and value into attributes for an object
function Table2Attribute.Convert2Attribute(parent, table: {})

	for element,value in table do
		if typeof(value)=="table" then continue end
		parent:SetAttribute(element, value)
	end

end

-- Converts attributes from an object to elements in a table
function Table2Attribute.Covert2Table(parent: BasePart): {}

	local table = {}

	for attributeName,value in parent:GetAttributes() do
		table[attributeName] = value
	end

	return table

end

return Table2Attribute
