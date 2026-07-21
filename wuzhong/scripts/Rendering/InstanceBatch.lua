local InstanceBatch = {}

---Create a native instanced group from a documented ProceduralGeometry object.
---@param parent Node
---@param geometry ProceduralGeometry
---@param material Material
---@param transforms table[]
---@param name? string
---@return StaticModelGroup|nil
function InstanceBatch.Add(parent, geometry, material, transforms, name)
    if #transforms == 0 then return nil end

    local root = parent:CreateChild(name or "Instances")
    local group = root:CreateComponent("StaticModelGroup")
    group.model = geometry:ToModel()
    group.material = material
    group.castShadows = true

    for index, transform in ipairs(transforms) do
        local node = root:CreateChild((name or "instance") .. "-" .. index)
        node.position = Vector3(transform.x or 0, transform.y or 0, transform.z or 0)
        node.scale = Vector3(transform.sx or 1, transform.sy or 1, transform.sz or 1)
        group:AddInstanceNode(node)
    end
    return group
end

return InstanceBatch
