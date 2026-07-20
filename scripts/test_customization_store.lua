local CustomizationStore = require("Config.CustomizationStore")

local function Check(condition, message)
    if not condition then error(message or "check failed", 2) end
end

local function Run()
    local jsonPath = CustomizationStore.GetLocalPath("customization-store-regression.json")
    local sourcePath = CustomizationStore.GetLocalPath("customization-source-test.png")
    fileSystem:Delete(jsonPath)
    fileSystem:Delete(jsonPath .. ".bak")
    fileSystem:Delete(jsonPath .. ".tmp")

    fileSystem:Delete(sourcePath)
    local source = Image()
    source:SetSize(128, 128, 4)
    for y = 0, 127 do
        for x = 0, 127 do
            source:SetPixel(x, y, Color(x / 127, y / 127, 0.72, 1))
        end
    end
    Check(source:SavePNG(sourcePath), "could not create source image")
    source:Dispose()

    local record, reason = CustomizationStore.PrepareImage({
        id = "custom-image-test",
        label = "Image Test",
        baseSettingKey = "dungeon",
        prompt = "test",
        imagePath = sourcePath,
        imageName = "customization-source-test.png",
    }, nil, "theme", 1)
    Check(record ~= nil, "image preparation failed: " .. tostring(reason))
    Check(record.imageData and #record.imageData > 0, "image was not embedded")
    Check(record.imageBytes > 0 and record.imageBytes <= CustomizationStore.MAX_IMAGE_BYTES,
        "processed image size is invalid")

    local saved, saveReason = CustomizationStore.SaveAtomic(jsonPath, {
        customSettings = { record },
        activeCustomSettingId = record.id,
    })
    Check(saved, "atomic save failed: " .. tostring(saveReason))
    Check(fileSystem:FileExists(jsonPath), "atomic save did not create primary file")

    local loaded = CustomizationStore.Load(jsonPath)
    Check(loaded and loaded.customSettings[1], "saved customization did not load")
    local restoredPath = loaded.customSettings[1].imagePath
    fileSystem:Delete(restoredPath)
    fileSystem:Delete(sourcePath)
    Check(not fileSystem:FileExists(restoredPath), "managed image cleanup failed")
    Check(CustomizationStore.RestoreImages(loaded) == 1, "embedded image did not restore")
    restoredPath = loaded.customSettings[1].imagePath
    Check(fileSystem:FileExists(restoredPath), "restored image file is missing")

    fileSystem:Delete(restoredPath)
    fileSystem:Delete(jsonPath)
    fileSystem:Delete(jsonPath .. ".bak")
    fileSystem:Delete(jsonPath .. ".tmp")
    print("[test] PASS customization image + atomic save")
end

function Start()
    local ok, err = xpcall(Run, debug.traceback)
    if not ok then ErrorExit("[test] FAIL\n" .. tostring(err), 1); return end
    engine:Exit()
end
