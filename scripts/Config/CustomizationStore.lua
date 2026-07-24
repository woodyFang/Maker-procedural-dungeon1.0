local Themes = require("Config.Themes")
local PaletteData = require("Config.PaletteData")
local RoomGroupColors = require("Config.RoomGroupColors")
local MultiFloor = require("Generation.MultiFloor")
local TopicSeeds = require("Config.TopicSeeds")

local CustomizationStore = {}

CustomizationStore.SCHEMA_VERSION = 10
CustomizationStore.IMAGE_DIRECTORY = "customization-images"
CustomizationStore.MAX_SOURCE_BYTES = 20 * 1024 * 1024
CustomizationStore.MAX_IMAGE_BYTES = CustomizationStore.MAX_SOURCE_BYTES

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_DECODE = {}
for index = 1, #BASE64_ALPHABET do
    BASE64_DECODE[string.byte(BASE64_ALPHABET, index)] = index - 1
end

local function Trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function CustomizationStore.GetLocalPath(name)
    return name
end

function CustomizationStore.GetImageDirectory()
    return CustomizationStore.IMAGE_DIRECTORY
end

local function Contains(items, value)
    for _, item in ipairs(items or {}) do if item == value then return true end end
    return false
end

local function IsKnownSetting(key)
    return type(key) == "string" and Themes.settings[key] ~= nil
end

local function NormalizeImage(record)
    local imagePath = type(record.imagePath) == "string" and Trim(record.imagePath) or ""
    local imageName = type(record.imageName) == "string" and Trim(record.imageName) or ""
    local imageData = type(record.imageData) == "string" and record.imageData or nil
    if imagePath == "" then imagePath = nil end
    if imageName == "" then imageName = nil end
    if imageData == "" then imageData = nil end
    return imagePath, imageName, imageData
end

local function NormalizeStringList(values)
    local result, seen = {}, {}
    for _, value in ipairs(type(values) == "table" and values or {}) do
        value = Trim(value)
        if value ~= "" and not seen[value] then
            result[#result + 1], seen[value] = value, true
        end
    end
    return result
end

local function NormalizePropRules(values)
    local result = {}
    local validLayouts = { grid = true, perimeter = true, ring = true, fill = true, focal = true, edgeFocal = true }
    local validSides = { north = true, south = true, east = true, west = true }
    local function Number(source, target, key, minimum, maximum, integer)
        local value = tonumber(source[key])
        if value ~= nil then
            if integer then value = math.floor(value) end
            value = math.max(minimum, value)
            if maximum then value = math.min(maximum, value) end
            target[key] = value
        end
    end
    for _, source in ipairs(type(values) == "table" and values or {}) do
        local kind = type(source) == "table" and Trim(source.kind) or ""
        if kind ~= "" then
            local chanceValue = tonumber(source.chance) or 1.0
            local scaleMin = tonumber(source.scaleMin) or 0.92
            local scaleMax = tonumber(source.scaleMax) or scaleMin
            local rule = {
                kind = kind,
                count = math.max(1, math.floor(tonumber(source.count) or 1)),
                chance = math.max(0.0, math.min(1.0, chanceValue)),
                scaleMin = math.max(0.05, math.min(scaleMin, scaleMax)),
                scaleMax = math.max(0.05, math.max(scaleMin, scaleMax)),
            }
            local layout = Trim(source.layout)
            if validLayouts[layout] then rule.layout = layout end
            local side = Trim(source.side)
            if validSides[side] then rule.side = side end
            for _, key in ipairs({ "step", "rowStep", "colStep", "margin", "max", "stepThreshold",
                "stepBig", "stepSmall", "radius", "anchorMinDim", "tries", "edgeInset" }) do
                Number(source, rule, key, 0, 1000, key == "max" or key == "tries" or key:find("Step", 1, true) ~= nil)
            end
            for _, key in ipairs({ "rot", "angleSpan", "scale", "anchorScale", "anchorRot" }) do
                Number(source, rule, key, -1000, 1000, false)
            end
            for _, key in ipairs({ "centered", "skipCenter", "angleJitter", "anchorRotAxis" }) do
                if type(source[key]) == "boolean" then rule[key] = source[key] end
            end
            local anchor = Trim(source.anchor)
            if anchor ~= "" then rule.anchor = anchor end
            result[#result + 1] = rule
        end
    end
    return result
end

local function NormalizeRecords(items, kind)
    local result, ids, names = {}, {}, {}
    for _, source in ipairs(type(items) == "table" and items or {}) do
        if type(source) == "table" then
            local id = Trim(source.id)
            local name = Trim(kind == "theme" and source.label or source.name)
            local topicId = kind == "room" and Trim(source.topicId) or ""
            local folded = string.lower(name)
            local settingKey = kind == "room" and topicId == ""
                and (IsKnownSetting(source.settingKey) and source.settingKey or "dungeon") or ""
            local scopeKey = topicId ~= "" and ("topic:" .. topicId) or ("setting:" .. settingKey)
            local nameKey = kind == "room" and (scopeKey .. "\0" .. folded) or folded
            if id ~= "" and name ~= "" and not ids[id] and not names[nameKey] then
                local imagePath, imageName, imageData = NormalizeImage(source)
                local record = {
                    id = id,
                    prompt = Trim(source.prompt),
                    imagePath = imagePath,
                    imageName = imageName,
                    imageData = imageData,
                    imageMime = imageData and (source.imageMime or "image/jpeg") or nil,
                    imageBytes = imageData and math.max(0, math.floor(tonumber(source.imageBytes) or 0)) or nil,
                }
                if kind == "theme" then
                    record.label = name
                    record.baseSettingKey = IsKnownSetting(source.baseSettingKey) and source.baseSettingKey or "dungeon"
                    record.floorHeight = MultiFloor.NormalizeFloorHeight(source.floorHeight)
                    record.packStatus = source.packStatus == "draft" and "draft" or "ready"
                    record.plannerSource = Trim(source.plannerSource) ~= "" and Trim(source.plannerSource) or nil
                    if record.packStatus == "ready" then
                        if source.generationMode == "generic" or source.generationMode == "theme-pack" then
                            record.generationMode = source.generationMode
                        elseif record.plannerSource == "generic-programmatic-v1" then
                            record.generationMode = "generic"
                        else
                            record.generationMode = "theme-pack"
                        end
                    end
                    record.compiledFromRevision = math.max(0, math.floor(tonumber(source.compiledFromRevision) or 0))
                    record.compiledSpecVersion = math.max(0, math.floor(tonumber(source.compiledSpecVersion) or 0))
                    record.compiledRoomGroupCount = math.max(0, math.floor(tonumber(source.compiledRoomGroupCount) or 0))
                else
                    record.name = name
                    record.color = RoomGroupColors.Parse(source.color,
                        RoomGroupColors.Default(source, #result + 1))
                    record.topicId = topicId ~= "" and topicId or nil
                    record.settingKey = record.topicId == nil and settingKey or nil
                    if source.source == "builtin" then
                        record.source = "builtin"
                    elseif source.source == "seed" then
                        record.source = "seed"
                    elseif source.source == "ai" then
                        record.source = "ai"
                    else
                        record.source = "manual"
                    end
                    record.ruleClass = source.ruleClass == "specific-room" and "specific-room" or nil
                    record.locked = source.locked == true
                    record.plannerSource = Trim(source.plannerSource) ~= "" and Trim(source.plannerSource) or nil
                    record.compiledFromRevision = math.max(0, math.floor(tonumber(source.compiledFromRevision) or 0))
                    record.compiledSpecVersion = math.max(0, math.floor(tonumber(source.compiledSpecVersion) or 0))
                    record.sortOrder = math.max(0, math.floor(tonumber(source.sortOrder) or 0))
                    record.roleKeys = NormalizeStringList(source.roleKeys)
                    record.defaultGroup = source.defaultGroup == true
                    record.minCount = math.max(0, math.floor(tonumber(source.minCount) or 0))
                    record.maxCount = math.max(0, math.floor(tonumber(source.maxCount) or 0))
                    record.minArea = math.max(0, tonumber(source.minArea) or 0)
                    record.maxArea = math.max(0, tonumber(source.maxArea) or 0)
                    record.propRules = NormalizePropRules(source.propRules)
                end
                result[#result + 1] = record
                ids[id], names[nameKey] = true, true
            end
        end
    end
    return result
end

local function IsBuiltinPalette(key)
    for _, settingKey in ipairs(Themes.settingOrder) do
        for _, paletteKey in ipairs(Themes.GetBuiltinPalettes(settingKey)) do
            if paletteKey == key then return true end
        end
    end
    return false
end

local function NormalizePalettes(items)
    local result, ids, names = {}, {}, {}
    for _, source in ipairs(type(items) == "table" and items or {}) do
        if type(source) == "table" then
            local id = Trim(source.id)
            local label = Trim(source.label)
            local folded = string.lower(label)
            local explicitGroup = source.paletteGroup
            local paletteGroup = explicitGroup == "default" and "default"
                or (explicitGroup == "theme" and "theme"
                or (Contains(Themes.GetBuiltinDefaultPalettes(), source.basePaletteKey) and "default" or "theme"))
            local settingKey = IsKnownSetting(source.baseSettingKey) and source.baseSettingKey or "dungeon"
            local builtinPool = paletteGroup == "default"
                and Themes.GetBuiltinDefaultPalettes() or Themes.GetBuiltinThemePalettes(settingKey)
            if #builtinPool == 0 then builtinPool = Themes.GetBuiltinDefaultPalettes() end
            local basePaletteKey = source.basePaletteKey
            local validBase = false
            for _, key in ipairs(builtinPool) do if key == basePaletteKey then validBase = true; break end end
            if not validBase then basePaletteKey = builtinPool[1] end
            local colors = PaletteData.NormalizeColors(source.colors)
            if id ~= "" and label ~= "" and not IsBuiltinPalette(id)
                and colors and not ids[id] and not names[folded] then
                result[#result + 1] = {
                    schemaVersion = PaletteData.SCHEMA_VERSION,
                    id = id,
                    label = label,
                    prompt = Trim(source.prompt),
                    paletteGroup = paletteGroup,
                    baseSettingKey = settingKey,
                    basePaletteKey = basePaletteKey,
                    colors = colors,
                }
                ids[id], names[folded] = true, true
            end
        end
    end
    return result
end

local function NextId(items, prefix, requested)
    local nextId = math.max(1, math.floor(tonumber(requested) or 1))
    for _, item in ipairs(items) do
        local number = tonumber(string.match(item.id or "", "^" .. prefix .. "(%d+)$"))
        if number then nextId = math.max(nextId, number + 1) end
    end
    return nextId
end

function CustomizationStore.FindById(items, id)
    for _, item in ipairs(items or {}) do
        if item.id == id then return item end
    end
    return nil
end

function CustomizationStore.UpsertById(items, record)
    for index, item in ipairs(items) do
        if item.id == record.id then items[index] = record; return index, item end
    end
    items[#items + 1] = record
    return #items, nil
end

function CustomizationStore.UpsertFirstById(items, record)
    for index, item in ipairs(items) do
        if item.id == record.id then items[index] = record; return index, item end
    end
    table.insert(items, 1, record)
    return 1, nil
end

function CustomizationStore.DeleteById(items, id)
    for index, item in ipairs(items) do
        if item.id == id then return table.remove(items, index) end
    end
    return nil
end

local function MigrateRoomScopes(roomGroups)
    local idsBySetting = TopicSeeds.IdsBySetting()
    for _, room in ipairs(roomGroups) do
        if room.topicId == nil and room.settingKey and idsBySetting[room.settingKey] then
            room.topicId = idsBySetting[room.settingKey]
            room.settingKey = nil
        end
    end
    return roomGroups
end

function CustomizationStore.Normalize(data)
    data = type(data) == "table" and data or {}
    local customSettings = TopicSeeds.Ensure(NormalizeRecords(data.customSettings, "theme"))
    local roomGroups = MigrateRoomScopes(NormalizeRecords(data.roomGroups, "room"))
    local customPalettes = NormalizePalettes(data.customPalettes)
    local activeId = type(data.activeCustomSettingId) == "string" and data.activeCustomSettingId or nil
    if not activeId and type(data.settingKey) == "string" then
        activeId = TopicSeeds.IdForSetting(data.settingKey)
    end
    if activeId and not CustomizationStore.FindById(customSettings, activeId) then activeId = nil end
    if not activeId then activeId = TopicSeeds.DEFAULT_ID end
    return {
        version = CustomizationStore.SCHEMA_VERSION,
        customSettings = customSettings,
        roomGroups = roomGroups,
        customPalettes = customPalettes,
        nextCustomSettingId = NextId(customSettings, "custom%-", data.nextCustomSettingId),
        nextRoomGroupId = NextId(roomGroups, "room%-group%-", data.nextRoomGroupId),
        nextCustomPaletteId = NextId(customPalettes, "custom%-palette%-", data.nextCustomPaletteId),
        activeCustomSettingId = activeId,
        revision = math.max(0, math.floor(tonumber(data.revision) or 0)),
        updatedAt = type(data.updatedAt) == "string" and data.updatedAt or "",
    }
end

local function ReadJson(path)
    if not fileSystem:FileExists(path) then return nil, "file not found" end
    local file = File(path, FILE_READ)
    if not file or not file:IsOpen() then return nil, "cannot open file" end
    local raw = file:ReadString()
    file:Dispose()
    local ok, data = pcall(cjson.decode, raw)
    if not ok or type(data) ~= "table" then return nil, "invalid json" end
    return CustomizationStore.Normalize(data)
end

function CustomizationStore.Load(path)
    local data, reason = ReadJson(path)
    if data then return data, "primary" end
    local backup = ReadJson(path .. ".bak")
    if backup then return backup, "backup" end
    return nil, reason
end

local function WriteText(path, text)
    local file = File(path, FILE_WRITE)
    if not file or not file:IsOpen() then return false end
    local written = file:WriteString(text)
    file:Flush()
    file:Dispose()
    return written ~= false
end

function CustomizationStore.SaveAtomic(path, data)
    local ok, encoded = pcall(cjson.encode, CustomizationStore.Normalize(data))
    if not ok then return false, "encode failed" end
    local temporary, backup = path .. ".tmp", path .. ".bak"
    fileSystem:Delete(temporary)
    if not WriteText(temporary, encoded) then return false, "temporary write failed" end

    fileSystem:Delete(backup)
    local hadPrimary = fileSystem:FileExists(path)
    if hadPrimary and not fileSystem:Rename(path, backup) then
        fileSystem:Delete(temporary)
        return false, "backup rotation failed"
    end
    if not fileSystem:Rename(temporary, path) then
        if not fileSystem:Copy(temporary, path) then
            if hadPrimary then fileSystem:Rename(backup, path) end
            fileSystem:Delete(temporary)
            return false, "finalize failed"
        end
        fileSystem:Delete(temporary)
    end
    return true
end

local function Base64EncodeFile(path)
    local file = File(path, FILE_READ)
    if not file or not file:IsOpen() then return nil end
    local result, chunk, count = {}, {}, 0
    while not file:IsEof() do
        local a = file:ReadUByte()
        if file:IsEof() and file:GetPosition() == 0 then break end
        local hasB = not file:IsEof()
        local b = hasB and file:ReadUByte() or 0
        local hasC = not file:IsEof()
        local c = hasC and file:ReadUByte() or 0
        local packed = a * 65536 + b * 256 + c
        count = count + 1; chunk[count] = string.sub(BASE64_ALPHABET, ((packed >> 18) & 63) + 1, ((packed >> 18) & 63) + 1)
        count = count + 1; chunk[count] = string.sub(BASE64_ALPHABET, ((packed >> 12) & 63) + 1, ((packed >> 12) & 63) + 1)
        count = count + 1; chunk[count] = hasB and string.sub(BASE64_ALPHABET, ((packed >> 6) & 63) + 1, ((packed >> 6) & 63) + 1) or "="
        count = count + 1; chunk[count] = hasC and string.sub(BASE64_ALPHABET, (packed & 63) + 1, (packed & 63) + 1) or "="
        if count >= 4096 then result[#result + 1] = table.concat(chunk); chunk, count = {}, 0 end
    end
    file:Dispose()
    if count > 0 then result[#result + 1] = table.concat(chunk) end
    return table.concat(result)
end

local function Base64DecodeToFile(encoded, path)
    if type(encoded) ~= "string" or encoded == "" then return false end
    local file = File(path, FILE_WRITE)
    if not file or not file:IsOpen() then return false end
    local length = #encoded
    for index = 1, length, 4 do
        local a = BASE64_DECODE[string.byte(encoded, index)]
        local b = BASE64_DECODE[string.byte(encoded, index + 1)]
        local cByte, dByte = string.byte(encoded, index + 2), string.byte(encoded, index + 3)
        local c, d = BASE64_DECODE[cByte], BASE64_DECODE[dByte]
        if a == nil or b == nil then file:Dispose(); fileSystem:Delete(path); return false end
        c, d = c or 0, d or 0
        local packed = (a << 18) | (b << 12) | (c << 6) | d
        file:WriteUByte((packed >> 16) & 0xff)
        if cByte ~= string.byte("=") then file:WriteUByte((packed >> 8) & 0xff) end
        if dByte ~= string.byte("=") then file:WriteUByte(packed & 0xff) end
    end
    file:Flush()
    file:Dispose()
    return true
end

local function SafeId(value)
    local safe = string.lower(tostring(value or "item")):gsub("[^%w%-_]", "-")
    return safe ~= "" and safe or "item"
end

local function ImageOutputPath(kind, id, revision, extension)
    return string.format("%s/%s-%s-r%d%s", CustomizationStore.GetImageDirectory(),
        kind == "theme" and "theme" or "room", SafeId(id), math.max(1, revision or 1), extension)
end

local function DetectImageType(path)
    local file = File(path, FILE_READ)
    if not file or not file:IsOpen() then return nil end
    local bytes = {}
    for index = 1, math.min(12, file:GetSize()) do bytes[index] = file:ReadUByte() end
    file:Dispose()
    if bytes[1] == 0x89 and bytes[2] == 0x50 and bytes[3] == 0x4e and bytes[4] == 0x47 then
        return ".png", "image/png"
    end
    if bytes[1] == 0xff and bytes[2] == 0xd8 and bytes[3] == 0xff then
        return ".jpg", "image/jpeg"
    end
    if bytes[1] == 0x52 and bytes[2] == 0x49 and bytes[3] == 0x46 and bytes[4] == 0x46
        and bytes[9] == 0x57 and bytes[10] == 0x45 and bytes[11] == 0x42 and bytes[12] == 0x50 then
        return ".webp", "image/webp"
    end
    if bytes[1] == 0x47 and bytes[2] == 0x49 and bytes[3] == 0x46 and bytes[4] == 0x38 then
        return ".gif", "image/gif"
    end
    if bytes[1] == 0x42 and bytes[2] == 0x4d then return ".bmp", "image/bmp" end
    return nil
end

function CustomizationStore.PrepareImage(record, previous, kind, revision)
    local oldPath = previous and previous.imagePath or nil
    if not record.imagePath then return record, oldPath end
    if previous and record.imagePath == previous.imagePath then
        for _, field in ipairs({ "imageData", "imageMime", "imageBytes" }) do record[field] = previous[field] end
        return record, nil
    end

    local source = File(record.imagePath, FILE_READ)
    if not source or not source:IsOpen() then return nil, "无法读取所选图片。" end
    local sourceSize = source:GetSize()
    source:Dispose()
    if sourceSize <= 0 or sourceSize > CustomizationStore.MAX_SOURCE_BYTES then
        return nil, "图片为空或超过 Maker 的 20 MB 上限。"
    end
    local extension, mime = DetectImageType(record.imagePath)
    if not extension then return nil, "所选文件不是 Maker 可识别的常用图片格式。" end

    local imageDirectory = CustomizationStore.GetImageDirectory()
    if not fileSystem:DirExists(imageDirectory) then
        fileSystem:CreateDir(imageDirectory)
    end
    local output = ImageOutputPath(kind, record.id, revision, extension)
    fileSystem:Delete(output)
    if not fileSystem:Copy(record.imagePath, output) then return nil, "参考图复制保存失败。" end
    local encoded = Base64EncodeFile(output)
    if not encoded then fileSystem:Delete(output); return nil, "参考图编码失败。" end
    record.imagePath = output
    record.imageData = encoded
    record.imageMime = mime
    record.imageBytes = sourceSize
    return record, oldPath
end

function CustomizationStore.RestoreImages(data)
    local imageDirectory = CustomizationStore.GetImageDirectory()
    if not fileSystem:DirExists(imageDirectory) then
        fileSystem:CreateDir(imageDirectory)
    end
    local restored = 0
    for _, list in ipairs({ data.customSettings or {}, data.roomGroups or {} }) do
        for _, record in ipairs(list) do
            if record.imageData and (not record.imagePath or not fileSystem:FileExists(record.imagePath)) then
                local extension = record.imageMime == "image/png" and ".png"
                    or record.imageMime == "image/webp" and ".webp"
                    or record.imageMime == "image/gif" and ".gif"
                    or record.imageMime == "image/bmp" and ".bmp" or ".jpg"
                record.imagePath = string.format("%s/restored-%s%s", imageDirectory, SafeId(record.id), extension)
                if Base64DecodeToFile(record.imageData, record.imagePath) then restored = restored + 1 end
            end
        end
    end
    return restored
end

local function IsReferenced(path, data)
    if not path then return false end
    for _, list in ipairs({ data.customSettings or {}, data.roomGroups or {} }) do
        for _, record in ipairs(list) do if record.imagePath == path then return true end end
    end
    return false
end

function CustomizationStore.DeleteImageIfUnused(path, data)
    local imageDirectory = CustomizationStore.GetImageDirectory()
    local managed = path and (string.sub(path, 1, #imageDirectory + 1) == imageDirectory .. "/"
        or string.sub(path, 1, #CustomizationStore.IMAGE_DIRECTORY + 1)
            == CustomizationStore.IMAGE_DIRECTORY .. "/")
    if managed and not IsReferenced(path, data) then
        fileSystem:Delete(path)
    end
end

return CustomizationStore
