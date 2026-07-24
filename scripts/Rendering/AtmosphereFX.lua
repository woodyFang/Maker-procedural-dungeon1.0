-- Dynamic atmosphere layer for the ruins ("遗迹") setting.
--
-- Everything the static batcher cannot express lives here: the ambient
-- particle field, real volumetric light columns, the spinning entrance gate,
-- floating shrine crystals, boss rune sigils, grave wisps and the global emissive
-- breathing pulse. The pass structure is GENERIC — which rooms receive which
-- effect comes from EnvironmentProfiles.<setting>.atmosphere, and every color,
-- count and envelope comes from the palette (theme.particles / theme.fx), so
-- custom palettes cloned from a ruins base adapt automatically. A setting
-- without an `atmosphere` profile builds nothing and pays nothing.
--
-- Particle kinds (theme.particles.kind):
--   0 dust motes  (slow drift)        1 embers   (rise, shrink)
--   2 snowfall    (fall, sway)        3 soul motes (spiral rise)
--   4 fireflies   (wander + blink)
--
-- Runtime shape: every animated element is one small StaticModel node (the
-- engine auto-groups equal model+material into instanced batches), updated in
-- place each frame through shared scratch vectors — no per-frame allocation
-- beyond the engine property setters.

local MultiFloor = require("Generation.MultiFloor")
local Random = require("Generation.Random")
local EnvironmentProfiles = require("Config.EnvironmentProfiles")
local VolumetricFog = require("Rendering.VolumetricFog")
local MaterialRules = require("Rendering.ProceduralMaterialRules")

local AtmosphereFX = {}

local TILE_FLOOR = 1
local TAU = math.pi * 2

local scratch = Vector3(0, 0, 0)
local scratchScale = Vector3(1, 1, 1)

-- Atmosphere elements are accents, not a second lighting system. Keep their
-- emissive contribution restrained; the important silhouettes remain readable
-- through shape, point lights and the scene's regular lighting.
local ATMOSPHERE_EMISSIVE_SCALE = 0.58

local function ChannelColor(value, factor)
    local gain = factor or 1.0
    return Color(
        math.min(1, ((value >> 16) & 0xff) / 255 * gain),
        math.min(1, ((value >> 8) & 0xff) / 255 * gain),
        math.min(1, (value & 0xff) / 255 * gain), 1)
end

local function GlowMaterial(color, strength, alpha)
    local material = Material:new()
    -- Keep the diffuse dark so scene lighting cannot wash the element toward
    -- white — the emissive term owns the hue (neon rule).
    if alpha then
        material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        local diffuse = ChannelColor(color, 0.26)
        diffuse.a = alpha
        material:SetShaderParameter("MatDiffColor", Variant(diffuse))
    else
        material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        material:SetShaderParameter("MatDiffColor", Variant(ChannelColor(color, 0.22)))
    end
    material:SetShaderParameter("MatSpecColor", Variant(Color(0.04, 0.04, 0.04, 1)))
    material:SetShaderParameter("Metallic", Variant(0.0))
    material:SetShaderParameter("Roughness", Variant(0.4))
    material:SetShaderParameter("MatEmissiveColor", Variant(ChannelColor(
        color, (strength or 1.5) * ATMOSPHERE_EMISSIVE_SCALE)))
    return material
end

local function FxColor(theme, field, fallback)
    local fx = theme.fx
    local value = fx and fx[field]
    if type(value) == "number" then return value end
    return fallback or theme.accentObject
end

local function AddNode(fx, parent, name, model, material, x, y, z, sx, sy, sz, rotation)
    local node = parent:CreateChild(name)
    node.position = Vector3(x, y, z)
    node.scale = Vector3(sx or 1, sy or sx or 1, sz or sx or 1)
    if rotation then node.rotation = rotation end
    local staticModel = node:CreateComponent("StaticModel")
    staticModel:SetModel(model)
    staticModel:SetMaterial(material)
    staticModel.castShadows = false
    fx.nodeCount = fx.nodeCount + 1
    return node
end

-- Flat holder: three.js ring/circle geometry faces +Z; a -90° pitch child lays
-- it on the floor plane so the parent only ever spins around +Y. The start
-- angle derives from the position so rebuilds of the same seed line up.
local function AddFlatSpinner(fx, parent, name, model, material, x, y, z, scale, rate)
    local spinner = parent:CreateChild(name)
    spinner.position = Vector3(x, y, z)
    AddNode(fx, spinner, name .. "-face", model, material,
        0, 0, 0, scale, scale, scale, Quaternion(-90, 0, 0))
    fx.spinners[#fx.spinners + 1] = {
        node = spinner, angle = (x * 53.7 + z * 91.3) % 360, rate = rate,
    }
    return spinner
end

local function CollectFloorCells(layer)
    local cells = {}
    for cell, tile in ipairs(layer.grid) do
        if tile == TILE_FLOOR and not layer.stairMask[cell]
            and not (layer.lakeMask and layer.lakeMask[cell]) then
            cells[#cells + 1] = cell
        end
    end
    return cells
end

local function BuildParticles(fx, args, spec, rng)
    local particleSpec = args.theme.particles
    if type(particleSpec) ~= "table" or (particleSpec.n or 0) <= 0 then return end
    local budget = spec.particles or {}
    local visibleLayers = {}
    for _, layer in ipairs(args.dungeon.layers) do
        if args.floorVisible(layer.floor) then visibleLayers[#visibleLayers + 1] = layer end
    end
    if #visibleLayers == 0 then return end
    local perFloor = math.min(particleSpec.n, budget.perFloorCap or 240)
    local totalCap = budget.totalCap or 420
    perFloor = math.min(perFloor, math.floor(totalCap / #visibleLayers))
    if perFloor <= 0 then return end

    local kind = particleSpec.kind or 0
    local strength = (budget.emissive or 1.9) * (kind == 2 and 0.55 or 1.0)
    local material = GlowMaterial(particleSpec.color or 0xffffff, strength)
    local model = args.modelCache:Get("octahedron")
    if not model then return end
    local baseSize = budget.size or 0.052
    local group = fx.root:CreateChild("Particles")

    for _, layer in ipairs(visibleLayers) do
        local cells = CollectFloorCells(layer)
        local available = #cells
        local count = math.min(perFloor, available)
        for index = 1, count do
            -- Partial Fisher-Yates keeps the sample unique and deterministic.
            local pick = rng:Int(index, available)
            cells[index], cells[pick] = cells[pick], cells[index]
            local x, y = MultiFloor.Coordinates(cells[index], args.dungeon.width)
            local wx, wy, wz = args.worldPosition(x, y, layer.floor, 0)
            local size = baseSize * rng:Float(0.72, 1.34)
            local particle = {
                bx = wx + rng:Float(-0.45, 0.45),
                by = wy,
                bz = wz + rng:Float(-0.45, 0.45),
                ph = rng:Float(0, TAU),
                sp = rng:Float(0.75, 1.35),
                sw = rng:Float(0, TAU),
                size = size,
            }
            particle.node = AddNode(fx, group, "P" .. layer.floor .. "-" .. index,
                model, material, particle.bx, particle.by + 1.0, particle.bz, size)
            fx.particles[#fx.particles + 1] = particle
        end
    end
    fx.particleKind = kind
end

local function BuildGodRays(fx, args, spec, rng)
    local raySpec = args.theme.fx and args.theme.fx.godRays
    local policy = spec.godRays
    local config = args.volumetricFogConfig or {}
    if type(raySpec) ~= "table" or not policy or not args.volumetricFogEnabled then return end

    local candidates = {}
    local RANK = { boss = 1, shrine = 2, entrance = 3, treasure = 4 }
    for _, room in ipairs(args.dungeon.rooms) do
        if args.floorVisible(room.floor) and policy.roomTypes[room.type]
            and math.min(room.w, room.h) >= (policy.minDim or 6) then
            candidates[#candidates + 1] = room
        end
    end
    table.sort(candidates, function(a, b)
        if a.floor ~= b.floor then return a.floor < b.floor end
        local rankA, rankB = RANK[a.type] or 9, RANK[b.type] or 9
        if rankA ~= rankB then return rankA < rankB end
        return a.id < b.id
    end)

    local total, perFloorCount = 0, {}
    local vs = fx.verticalScale
    for _, room in ipairs(candidates) do
        if total >= (raySpec.count or 6) then break end
        local floorCount = perFloorCount[room.floor] or 0
        if floorCount < (policy.maxPerFloor or 5) then
            perFloorCount[room.floor] = floorCount + 1
            total = total + 1
            local wx, wy, wz = args.worldPosition(room.cx, room.cy, room.floor, 0)
            local span = (config.localVolumeHeight or 4.6) * vs
            local radius = math.min(1.0, math.min(room.w, room.h) * 0.09)
            local x = wx + rng:Float(-0.8, 0.8)
            local z = wz + rng:Float(-0.8, 0.8)

            -- A LocalFogVolume supplies the actual medium. The spotlight above
            -- it is a real participating light, so walls and shadows shape the
            -- beam instead of a translucent cone mesh.
            local volumeNode = fx.root:CreateChild("GodRayFog-" .. room.id)
            volumeNode.position = Vector3(x, wy + span * 0.5, z)
            volumeNode.scale = Vector3(radius, span * 0.5, radius)
            local volume = volumeNode:CreateComponent("LocalFogVolume")
            volume.albedo = Color(1, 1, 1, 1)
            volume.emissive = Color(0, 0, 0, 1)
            volume.radialExtinction = config.localVolumeExtinction or 0.12
            volume.heightExtinction = config.localVolumeHeightExtinction or 0
            volume.heightFalloff = config.localVolumeHeightFalloff or 0
            volume.radialFalloff = config.localVolumeFalloff or 1.35
            volume.phaseG = config.localVolumePhaseG or config.phaseG or 0.58
            volume.maxDrawDistance = config.viewDistance or 90.0

            local lightNode = fx.root:CreateChild("GodRayLight-" .. room.id)
            lightNode.position = Vector3(x, wy + span * 0.96, z)
            lightNode.direction = Vector3(0, -1, 0)
            local light = lightNode:CreateComponent("Light")
            light.lightType = LIGHT_SPOT
            light.color = ChannelColor(raySpec.color or 0xffffff, 1.0)
            light.brightness = 0
            light.range = span * 1.30
            light.fov = config.localLightFov or 34.0
            light.castShadows = false
            VolumetricFog.ConfigureLight(light, true,
                raySpec.intensity or config.localLightIntensity or 2.4, false)
            fx.lights[#fx.lights + 1] = {
                light = light, base = raySpec.intensity or config.localLightIntensity or 2.4,
                ph = rng:Float(0, TAU),
            }
            fx.volumetricVolumeCount = fx.volumetricVolumeCount + 1
        end
    end
end

local function BuildRuneCircle(fx, parent, args, x, y, z, color, scale, rateOuter)
    local outer = args.modelCache:Get("runeRing")
    local inner = args.modelCache:Get("runeRingInner")
    if not outer or not inner then return end
    local material = GlowMaterial(color, 1.35, 0.62)
    material.cullMode = CULL_NONE
    AddFlatSpinner(fx, parent, "Sigil-Outer", outer, material, x, y + 0.045, z, scale, rateOuter)
    AddFlatSpinner(fx, parent, "Sigil-Inner", inner, material, x, y + 0.058, z, scale, -rateOuter * 1.7)
end

local function BuildOrbiters(fx, args, x, y, z, color, count, radius, rate, size, vertAmp)
    local model = args.modelCache:Get("octahedron")
    if not model then return end
    local material = GlowMaterial(color, 2.0)
    for index = 0, count - 1 do
        local node = AddNode(fx, fx.root, "Orbit-" .. index, model, material, x, y, z, size)
        fx.orbiters[#fx.orbiters + 1] = {
            node = node, cx = x, cy = y, cz = z,
            radius = radius, rate = rate, ph = index * TAU / count,
            vertAmp = vertAmp or 0.18,
        }
    end
end

local function BuildPortal(fx, args, prop, layer, rng)
    local wx, wy, wz = args.worldPosition(prop.x, prop.y, layer.floor, 0)
    local vs = fx.verticalScale
    local color = FxColor(args.theme, "orbitColor", 0x3fd0bb)
    local discModel = args.modelCache:Get("portalDisc")
    local ringModel = args.modelCache:Get("runeRing")
    local gateModel = args.modelCache:Get("gateRing")
    if not (discModel and ringModel and gateModel) then return end

    local discMaterial = GlowMaterial(color, 1.5, 0.68)
    discMaterial.cullMode = CULL_NONE
    local disc = AddNode(fx, fx.root, "PortalDisc", discModel, discMaterial,
        wx, wy + 0.14, wz, 1, 1, 1, Quaternion(-90, 0, 0))
    fx.pulseNodes[#fx.pulseNodes + 1] = { node = disc, base = 1.0, amp = 0.07, speed = 2.1, ph = rng:Float(0, TAU) }

    local runeMaterial = GlowMaterial(color, 1.35, 0.55)
    runeMaterial.cullMode = CULL_NONE
    AddFlatSpinner(fx, fx.root, "PortalRunes", ringModel, runeMaterial,
        wx, wy + 0.10, wz, 0.62, 24)

    -- Two upright rings crossed at 90° spin together around +Y: the gate.
    local gateMaterial = GlowMaterial(color, 1.5)
    local spinner = fx.root:CreateChild("PortalGate")
    spinner.position = Vector3(wx, wy + 1.15 * vs, wz)
    AddNode(fx, spinner, "GateA", gateModel, gateMaterial, 0, 0, 0, 1, vs, 1)
    AddNode(fx, spinner, "GateB", gateModel, gateMaterial, 0, 0, 0, 1, vs, 1, Quaternion(0, 90, 0))
    fx.spinners[#fx.spinners + 1] = { node = spinner, angle = rng:Float(0, 360), rate = 26 }

    BuildOrbiters(fx, args, wx, wy + 1.05 * vs, wz, color, 4, 1.18, 1.0, 0.075, 0.22)

    local lightNode = fx.root:CreateChild("PortalLight")
    lightNode.position = Vector3(wx, wy + 1.4 * vs, wz)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.color = ChannelColor(color, 1.0)
    light.brightness = 0
    light.range = 6.5
    light.castShadows = false
    VolumetricFog.ConfigureLight(light, args.volumetricFogEnabled,
        args.volumetricFogConfig and args.volumetricFogConfig.portalLightIntensity or 1.0, false)
    fx.lights[#fx.lights + 1] = { light = light, base = 2.3, ph = rng:Float(0, TAU) }
end

local function BuildShrine(fx, args, prop, layer, rng)
    local wx, wy, wz = args.worldPosition(prop.x, prop.y, layer.floor, 0)
    local vs = fx.verticalScale
    local color = FxColor(args.theme, "orbitColor", 0x8fbcff)
    local model = args.modelCache:Get("octahedron")
    if not model then return end
    local material = GlowMaterial(color, 2.1)

    -- Floating twin crystal: parent bobs and spins, children keep the authored
    -- silhouette of the old static GEO.crystal (0.3 + 0.16 radius octahedra).
    local bob = fx.root:CreateChild("ShrineCrystal")
    bob.position = Vector3(wx, wy + 1.4 * vs, wz)
    AddNode(fx, bob, "CrystalMain", model, material, 0, 0, 0, 0.63, 0.92, 0.63)
    AddNode(fx, bob, "CrystalTip", model, material, 0, 0.36, 0, 0.34, 0.47, 0.34,
        Quaternion(0, 34, 0))
    fx.bobbers[#fx.bobbers + 1] = {
        node = bob, bx = wx, bz = wz, baseY = wy + 1.4 * vs, amp = 0.13 * vs,
        speed = 1.15, ph = rng:Float(0, TAU), spin = 46, angle = rng:Float(0, 360),
    }
    BuildOrbiters(fx, args, wx, wy + 1.35 * vs, wz, color, 3, 0.58, 1.5, 0.058, 0.12)
end

local function BuildRoomSigils(fx, args, spec)
    local policy = spec.runeCircles
    if not policy then return end
    local runeColor = FxColor(args.theme, "runeColor", args.theme.flame)
    for _, layer in ipairs(args.dungeon.layers) do
        if args.floorVisible(layer.floor) then
            for _, prop in ipairs(layer.props) do
                local room = prop.roomId and args.dungeon.rooms[prop.roomId] or nil
                if prop.kind == "bossCrystal" and policy.roomTypes.boss then
                    local wx, wy, wz = args.worldPosition(prop.x, prop.y, layer.floor, 0)
                    BuildRuneCircle(fx, fx.root, args, wx, wy, wz, runeColor, 1.0, 14)
                    BuildOrbiters(fx, args, wx, wy + 0.7 * fx.verticalScale, wz,
                        FxColor(args.theme, "orbitColor"), 5, 1.65, 0.85, 0.066, 0.28)
                elseif prop.kind == "shrineCrystal" and policy.roomTypes.shrine and room then
                    local wx, wy, wz = args.worldPosition(prop.x, prop.y, layer.floor, 0)
                    BuildRuneCircle(fx, fx.root, args, wx, wy, wz, runeColor, 0.56, 20)
                end
            end
        end
    end
end

local function BuildAnimatedProps(fx, args, spec, rng)
    local animated = spec.animatedProps or {}
    for _, layer in ipairs(args.dungeon.layers) do
        if args.floorVisible(layer.floor) then
            for _, prop in ipairs(layer.props) do
                local kind = prop.kind
                if kind == "entrance" then kind = "ring" end
                if kind == "shrine" then kind = "shrineCrystal" end
                if kind == "ring" and animated.ring then
                    BuildPortal(fx, args, prop, layer, rng)
                elseif kind == "shrineCrystal" and animated.shrineCrystal then
                    BuildShrine(fx, args, prop, layer, rng)
                end
            end
        end
    end
end

local function BuildWisps(fx, args, rng)
    local wispSpec = args.theme.fx and args.theme.fx.wisps
    if type(wispSpec) ~= "table" then return end
    local model = args.modelCache:Get("octahedron")
    if not model then return end
    local material = GlowMaterial(wispSpec.color or 0xb6ff8a, 2.3)
    local group = fx.root:CreateChild("Wisps")
    local perRoom = wispSpec.perRoom or 3
    local total = 0
    for _, layer in ipairs(args.dungeon.layers) do
        if args.floorVisible(layer.floor) then
            local perRoomCount = {}
            for _, prop in ipairs(layer.props) do
                if total >= 24 then return end
                if prop.kind == "grave" and prop.roomId then
                    local used = perRoomCount[prop.roomId] or 0
                    if used < perRoom and rng:Chance(0.6) then
                        perRoomCount[prop.roomId] = used + 1
                        total = total + 1
                        local wx, wy, wz = args.worldPosition(prop.x, prop.y, layer.floor, 0)
                        local wisp = {
                            bx = wx + rng:Float(-0.3, 0.3), by = wy, bz = wz + rng:Float(-0.3, 0.3),
                            ph = rng:Float(0, TAU), sp = rng:Float(0.10, 0.18),
                            size = rng:Float(0.07, 0.11),
                            height = (wispSpec.height or 2.3) * fx.verticalScale,
                        }
                        wisp.node = AddNode(fx, group, "Wisp-" .. total, model, material,
                            wisp.bx, wisp.by + 0.4, wisp.bz, wisp.size)
                        fx.wisps[#fx.wisps + 1] = wisp
                    end
                end
            end
        end
    end
end

function AtmosphereFX.Build(args)
    local profile = EnvironmentProfiles.Resolve(args.settingKey)
    local spec = profile["atmosphere"]
    if not spec then return nil end

    local fx = {
        root = args.parent:CreateChild("AtmosphereFX"),
        time = 0,
        revealTime = args.revealTime or 0,
        revealed = (args.revealTime or 0) <= 0,
        verticalScale = args.dungeon.floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT,
        nodeCount = 0, volumetricVolumeCount = 0,
        particles = {}, particleKind = 0,
        spinners = {}, bobbers = {}, orbiters = {},
        wisps = {}, lights = {}, pulseNodes = {},
        pulse = nil,
    }

    local rng = Random.new((args.dungeon.seed or 0) ~ 0x51ed270b)
    BuildParticles(fx, args, spec, rng)
    BuildGodRays(fx, args, spec, rng)
    BuildAnimatedProps(fx, args, spec, rng)
    BuildRoomSigils(fx, args, spec)
    BuildWisps(fx, args, rng)

    -- Global emissive breathing over the batcher's shared glow materials.
    local envelope = (args.theme.fx and args.theme.fx.pulse) or spec.pulse
    if envelope and args.emissiveEntries and #args.emissiveEntries > 0 then
        local entries = {}
        for _, entry in ipairs(args.emissiveEntries) do
            entries[#entries + 1] = {
                material = entry.material,
                r = ((entry.color >> 16) & 0xff) / 255,
                g = ((entry.color >> 8) & 0xff) / 255,
                b = (entry.color & 0xff) / 255,
            }
        end
        fx.pulse = {
            entries = entries,
            min = envelope.min or 0.9, max = envelope.max or 1.15,
            speed = envelope.speed or 1.1,
            strength = MaterialRules.DEFAULT_EMISSIVE_STRENGTH * ATMOSPHERE_EMISSIVE_SCALE,
        }
    end

    if not fx.revealed then fx.root:SetDeepEnabled(false) end
    return fx
end

local function UpdateParticles(fx, time)
    local kind = fx.particleKind
    local vs = fx.verticalScale
    for _, particle in ipairs(fx.particles) do
        local ph, sp = particle.ph, particle.sp
        local x, y, z = particle.bx, particle.by, particle.bz
        local setScale = nil
        if kind == 1 then -- embers: rise and shrink
            local frac = (time * sp * 0.24 + ph) % 1
            y = y + (0.12 + frac * 3.0) * vs
            x = x + math.sin(time * 0.9 + particle.sw) * 0.22
            z = z + math.cos(time * 0.8 + particle.sw) * 0.22
            setScale = particle.size * (1.05 - frac * 0.62)
        elseif kind == 2 then -- snow: fall with sway
            local frac = (time * sp * 0.16 + ph) % 1
            y = y + (0.06 + (1 - frac) * 2.8) * vs
            x = x + math.sin(time * 0.7 + particle.sw) * 0.34
            z = z + math.cos(time * 0.5 + particle.sw * 1.3) * 0.34
        elseif kind == 3 then -- soul motes: slow spiral rise
            local frac = (time * sp * 0.12 + ph) % 1
            y = y + (0.15 + frac * 2.4) * vs
            local swirl = time * 0.45 + ph
            x = x + math.cos(swirl) * 0.32
            z = z + math.sin(swirl) * 0.32
            setScale = particle.size * (1.1 - frac * 0.55)
        elseif kind == 4 then -- fireflies: wander and blink
            x = x + math.sin(time * 0.53 + particle.sw) * 0.55
                + math.sin(time * 0.21 + ph) * 0.3
            z = z + math.cos(time * 0.47 + particle.sw * 0.7) * 0.55
            y = y + (0.55 + math.sin(time * 0.66 + ph) * 0.42) * vs
            local blink = math.sin(time * 2.6 + ph)
            blink = blink > 0 and blink * blink * blink or 0
            setScale = particle.size * (0.35 + blink * 1.05)
        else -- dust: slow drift
            y = y + (1.05 + math.sin(time * 0.24 + ph) * 0.55) * vs
            x = x + math.sin(time * 0.16 + particle.sw) * 0.4
            z = z + math.cos(time * 0.13 + particle.sw * 1.7) * 0.4
        end
        scratch.x, scratch.y, scratch.z = x, y, z
        particle.node.position = scratch
        if setScale then
            scratchScale.x, scratchScale.y, scratchScale.z = setScale, setScale, setScale
            particle.node.scale = scratchScale
        end
    end
end

function AtmosphereFX.Update(fx, timeStep)
    if not fx then return end
    fx.time = fx.time + timeStep
    local time = fx.time

    if not fx.revealed then
        if time < fx.revealTime then return end
        fx.root:SetDeepEnabled(true)
        fx.revealed = true
    end
    local reveal = fx.revealTime > 0
        and math.min(1, (time - fx.revealTime) / 0.6) or 1

    UpdateParticles(fx, time)

    for _, spinner in ipairs(fx.spinners) do
        spinner.angle = (spinner.angle + spinner.rate * timeStep) % 360
        spinner.node.rotation = Quaternion(spinner.angle, Vector3.UP)
    end

    for _, bobber in ipairs(fx.bobbers) do
        bobber.angle = (bobber.angle + bobber.spin * timeStep) % 360
        scratch.x = bobber.bx
        scratch.y = bobber.baseY + math.sin(time * bobber.speed + bobber.ph) * bobber.amp
        scratch.z = bobber.bz
        bobber.node.position = scratch
        bobber.node.rotation = Quaternion(bobber.angle, Vector3.UP)
    end

    for _, orbiter in ipairs(fx.orbiters) do
        local angle = orbiter.ph + time * orbiter.rate
        scratch.x = orbiter.cx + math.cos(angle) * orbiter.radius
        scratch.y = orbiter.cy + math.sin(time * 0.9 + orbiter.ph * 2.3) * orbiter.vertAmp
        scratch.z = orbiter.cz + math.sin(angle) * orbiter.radius
        orbiter.node.position = scratch
    end

    for _, wisp in ipairs(fx.wisps) do
        local frac = (time * wisp.sp + wisp.ph) % 1
        scratch.x = wisp.bx + math.sin(time * 0.8 + wisp.ph) * 0.16
        scratch.y = wisp.by + 0.25 + frac * wisp.height
        scratch.z = wisp.bz + math.cos(time * 0.7 + wisp.ph * 1.4) * 0.16
        wisp.node.position = scratch
        local fade = frac < 0.75 and 1 or (1 - (frac - 0.75) * 4)
        local blink = 0.7 + 0.3 * math.sin(time * 5.2 + wisp.ph)
        local size = wisp.size * fade * blink
        scratchScale.x, scratchScale.y, scratchScale.z = size, size * 1.4, size
        wisp.node.scale = scratchScale
    end

    for _, pulsed in ipairs(fx.pulseNodes) do
        local factor = pulsed.base + math.sin(time * pulsed.speed + pulsed.ph) * pulsed.amp
        scratchScale.x, scratchScale.y, scratchScale.z = factor, factor, factor
        pulsed.node.scale = scratchScale
    end

    for _, entry in ipairs(fx.lights) do
        entry.light.brightness = entry.base * reveal
            * (0.84 + 0.16 * math.sin(time * 5.1 + entry.ph))
    end

    local pulse = fx.pulse
    if pulse then
        local wave = 0.5 + 0.5 * math.sin(time * pulse.speed)
        local strength = pulse.strength * (pulse.min + (pulse.max - pulse.min) * wave)
        for _, entry in ipairs(pulse.entries) do
            entry.material:SetShaderParameter("MatEmissiveColor", Variant(Color(
                math.min(2.5, entry.r * strength),
                math.min(2.5, entry.g * strength),
                math.min(2.5, entry.b * strength), 1)))
        end
    end
end

return AtmosphereFX
