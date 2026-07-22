#!/usr/bin/env node

"use strict";

const fs = require("fs");
const path = require("path");

const SUPPORTED_USAGES = new Set(["inherit", "attach", "prefab", "point_light_marker"]);
const DEFAULT_MANIFESTS = [
  "assets/PCGDungeon/PCGDungeon.mesh_info.json",
];
const PIPELINE_FILES = [
  "scripts/Generation/PCGDungeonMarkerPipeline.lua",
];
const RENDERER_FILES = [
  "scripts/Rendering/PCGDungeonRenderer.lua",
];
const ENGINE_MODEL_RESOURCES = new Set([
  "Models/Box.mdl",
  "Models/Cone.mdl",
  "Models/Cylinder.mdl",
  "Models/Plane.mdl",
  "Models/Sphere.mdl",
]);

const args = process.argv.slice(2);
const checkRuntime = args.includes("--check-runtime");
const positional = args.filter((value) => value !== "--check-runtime");
const projectRoot = path.resolve(positional[0] || process.cwd());

function firstExisting(candidates) {
  for (const candidate of candidates) {
    const absolute = path.resolve(projectRoot, candidate);
    if (fs.existsSync(absolute)) return absolute;
  }
  return null;
}

const manifestPath = positional[1]
  ? path.resolve(projectRoot, positional[1])
  : firstExisting(DEFAULT_MANIFESTS);
const errors = [];
const warnings = [];

function error(message) {
  errors.push(message);
}

function warning(message) {
  warnings.push(message);
}

function isNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function validateVector(owner, key, value, length) {
  if (value === undefined) return;
  if (!Array.isArray(value) || value.length !== length || !value.every(isNumber)) {
    error(`${owner}.${key} must contain ${length} finite numbers`);
  }
}

function resourceCandidates(resourcePath) {
  if (typeof resourcePath !== "string" || resourcePath.length === 0) return [];
  const normalized = resourcePath.replaceAll("/", path.sep);
  return [path.resolve(projectRoot, normalized), path.resolve(projectRoot, "assets", normalized)];
}

function resourceExists(resourcePath) {
  if (ENGINE_MODEL_RESOURCES.has(String(resourcePath).replaceAll("\\", "/"))) return true;
  return resourceCandidates(resourcePath).some((candidate) => fs.existsSync(candidate));
}

function readMarkerTypes() {
  const sourcePath = firstExisting(PIPELINE_FILES);
  if (!sourcePath) {
    warning("Marker pipeline source was not found; marker names were not cross-checked");
    return null;
  }
  const source = fs.readFileSync(sourcePath, "utf8");
  const block = source.match(/\.MARKER_TYPES\s*=\s*\{([\s\S]*?)\}/);
  if (!block) {
    warning(`MARKER_TYPES was not found in ${path.relative(projectRoot, sourcePath)}`);
    return null;
  }
  return new Set([...block[1].matchAll(/["']([^"']+)["']/g)].map((match) => match[1]));
}

function validateMaterialOverrides(owner, rule) {
  for (const [index, override] of (rule.material_overrides || []).entries()) {
    const materialPath = typeof override === "string"
      ? override
      : override && typeof override === "object"
        ? override.material || override.path
        : null;
    if (!materialPath) {
      error(`${owner}.material_overrides[${index}] has no material path`);
    } else if (!resourceExists(materialPath)) {
      error(`${owner}.material_overrides[${index}] does not exist: ${materialPath}`);
    }
  }
}

function validateTransform(owner, rule) {
  validateVector(owner, "offset_cm", rule.offset_cm, 3);
  validateVector(owner, "rotation_deg", rule.rotation_deg, 3);
  validateVector(owner, "scale", rule.scale, 3);
  if (rule.density !== undefined && (!isNumber(rule.density) || rule.density < 0 || rule.density > 1)) {
    error(`${owner}.density must be between 0 and 1`);
  }
  if (rule.override_uniform_scale_range !== undefined) {
    validateVector(owner, "override_uniform_scale_range", rule.override_uniform_scale_range, 2);
  }
  for (const [index, copy] of (rule.marker_copies || []).entries()) {
    validateVector(`${owner}.marker_copies[${index}]`, "local_offset_m", copy.local_offset_m, 3);
  }
  validateMaterialOverrides(owner, rule);
}

function runtimeResourceCandidates(resourcePath) {
  const normalized = resourcePath.replaceAll("/", path.sep);
  const candidates = [path.resolve(projectRoot, normalized)];
  if (!resourcePath.startsWith("assets/")) {
    candidates.push(path.resolve(projectRoot, "assets", normalized));
  }
  return candidates;
}

function checkRuntimeManifest(activeManifest) {
  const rendererPath = firstExisting(RENDERER_FILES);
  if (!rendererPath) {
    error("Dungeon renderer source was not found; runtime manifest path cannot be verified");
    return;
  }
  const source = fs.readFileSync(rendererPath, "utf8");
  const configured = [...source.matchAll(/["']([^"']+\.mesh_info\.json)["']/g)]
    .map((match) => match[1]);
  if (configured.length === 0) {
    error(`No mesh_info candidate was found in ${path.relative(projectRoot, rendererPath)}`);
    return;
  }
  const existing = configured.flatMap(runtimeResourceCandidates)
    .filter((candidate) => fs.existsSync(candidate))
    .map((candidate) => path.resolve(candidate));
  if (existing.length === 0) {
    error(`Runtime loader cannot resolve any configured manifest: ${configured.join(", ")}`);
  } else if (!existing.includes(path.resolve(activeManifest))) {
    error(`Validated manifest is not loaded by runtime: ${path.relative(projectRoot, activeManifest)}`);
  }
}

if (!manifestPath || !fs.existsSync(manifestPath)) {
  console.error("[mesh-info] manifest not found");
  process.exit(1);
}

let data;
try {
  data = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
} catch (parseError) {
  console.error(`[mesh-info] invalid JSON: ${parseError.message}`);
  process.exit(1);
}

const markerTypes = readMarkerTypes();
const rules = Array.isArray(data.meshes) ? data.meshes : [];
const scatterRules = Array.isArray(data.scatter_rules) ? data.scatter_rules : [];
const bindings = data.asset_bindings && typeof data.asset_bindings === "object"
  ? data.asset_bindings
  : {};
if (!Array.isArray(data.meshes)) error("meshes must be an array");
if (!Array.isArray(data.scatter_rules)) error("scatter_rules must be an array");
if (!data.asset_bindings || typeof data.asset_bindings !== "object") {
  error("asset_bindings must be an object");
}

const ids = new Set();
const referencedAssets = new Set();
const producedSources = new Set();
for (const rule of rules) {
  if (rule.usage === "inherit" && rule.mesh) producedSources.add(rule.mesh);
  if (rule.usage === "prefab" && rule.source_mesh) producedSources.add(rule.source_mesh);
  if (rule.usage === "point_light_marker" && rule.mesh) producedSources.add(rule.mesh);
}

function validateId(owner, id) {
  if (typeof id !== "string" || id.length === 0) {
    error(`${owner} has no id`);
  } else if (ids.has(id)) {
    error(`duplicate rule id: ${id}`);
  } else {
    ids.add(id);
  }
}

function validateBinding(assetPath, owner) {
  referencedAssets.add(assetPath);
  const binding = bindings[assetPath];
  if (!binding || typeof binding !== "object") {
    error(`${owner} has no asset binding: ${assetPath}`);
    return;
  }
  if (!resourceExists(binding.model_resource)) {
    error(`${owner} model does not exist: ${binding.model_resource}`);
  }
  if (binding.material_resource && !resourceExists(binding.material_resource)) {
    error(`${owner} material does not exist: ${binding.material_resource}`);
  }
}

for (const [index, rule] of rules.entries()) {
  const owner = `meshes[${index}]${rule.id ? `(${rule.id})` : ""}`;
  validateId(owner, rule.id);
  if (typeof rule.marker !== "string" || rule.marker.length === 0) {
    error(`${owner}.marker is missing`);
  } else if (markerTypes && !markerTypes.has(rule.marker)) {
    error(`${owner} uses an unknown Marker: ${rule.marker}`);
  }
  if (!SUPPORTED_USAGES.has(rule.usage)) error(`${owner} has unsupported usage: ${rule.usage}`);
  if (rule.marker_group !== undefined && typeof rule.marker_group !== "string") {
    error(`${owner}.marker_group must be a string`);
  }
  validateTransform(owner, rule);

  if (rule.usage === "inherit") {
    if (rule.visible !== false) validateBinding(rule.mesh, owner);
    if (rule.density !== undefined) warning(`${owner}.density is ignored by inherit rules`);
  } else if (rule.usage === "attach") {
    if (!producedSources.has(rule.source_mesh)) {
      error(`${owner}.source_mesh is not produced by a base rule: ${rule.source_mesh}`);
    }
    if (rule.visible !== false) validateBinding(rule.mesh, owner);
  } else if (rule.usage === "prefab") {
    if (typeof rule.source_mesh !== "string" || rule.source_mesh.length === 0) {
      error(`${owner}.source_mesh is missing`);
    }
    if (!Array.isArray(rule.parts) || rule.parts.length === 0) {
      error(`${owner}.parts must be a non-empty array`);
    }
    for (const [partIndex, part] of (rule.parts || []).entries()) {
      const partOwner = `${owner}.parts[${partIndex}]`;
      validateTransform(partOwner, part);
      if (part.visible !== false) validateBinding(part.mesh, partOwner);
    }
    if (rule.density !== undefined) warning(`${owner}.density is ignored by prefab rules`);
  } else if (rule.usage === "point_light_marker") {
    if (rule.point_light_enabled !== true) error(`${owner} must enable point_light_enabled`);
  }

  if (rule.point_light_enabled === true) {
    if (!isNumber(rule.point_light_brightness) || rule.point_light_brightness < 0) {
      error(`${owner}.point_light_brightness must be a non-negative number`);
    }
    if (!isNumber(rule.point_light_range_m) || rule.point_light_range_m < 0) {
      error(`${owner}.point_light_range_m must be a non-negative number`);
    }
    validateVector(owner, "point_light_offset_cm", rule.point_light_offset_cm, 3);
    validateVector(owner, "point_light_rotation_deg", rule.point_light_rotation_deg, 3);
    validateVector(owner, "point_light_color_srgb", rule.point_light_color_srgb, 3);
  }
}

for (const [index, rule] of scatterRules.entries()) {
  const owner = `scatter_rules[${index}]${rule.id ? `(${rule.id})` : ""}`;
  validateId(owner, rule.id);
  if (rule.surface !== "GroundScatterSurface") {
    error(`${owner} uses an unsupported surface: ${rule.surface}`);
  }
  if (rule.enabled !== false && rule.visible !== false) validateBinding(rule.mesh, owner);
  if (!isNumber(rule.candidate_density_per_square_meter)
      || rule.candidate_density_per_square_meter < 0) {
    error(`${owner}.candidate_density_per_square_meter must be non-negative`);
  }
  validateVector(owner, "random_yaw_deg", rule.random_yaw_deg, 2);
  validateVector(owner, "uniform_scale_range", rule.uniform_scale_range, 2);
  validateVector(owner, "offset_cm", rule.offset_cm, 3);
  validateMaterialOverrides(owner, rule);
}

for (const [assetPath, binding] of Object.entries(bindings)) {
  if (!binding || typeof binding !== "object") {
    error(`asset_bindings[${assetPath}] must be an object`);
    continue;
  }
  if (!resourceExists(binding.model_resource)) {
    error(`asset binding model does not exist: ${binding.model_resource}`);
  }
  if (binding.material_resource && !resourceExists(binding.material_resource)) {
    error(`asset binding material does not exist: ${binding.material_resource}`);
  }
  if (!referencedAssets.has(assetPath)) warning(`unused asset binding: ${assetPath}`);
}

for (const [name, modelPath] of Object.entries(data.diagnostic_meshes || {})) {
  if (!resourceExists(modelPath)) error(`diagnostic model does not exist (${name}): ${modelPath}`);
}

if (checkRuntime) checkRuntimeManifest(manifestPath);

for (const message of warnings) console.warn(`[WARN] ${message}`);
for (const message of errors) console.error(`[ERROR] ${message}`);

const markerSummary = {};
for (const rule of rules) markerSummary[rule.marker] = (markerSummary[rule.marker] || 0) + 1;
console.log(`[mesh-info] ${path.relative(projectRoot, manifestPath)}`);
console.log(`[mesh-info] rules=${rules.length} scatter=${scatterRules.length} bindings=${Object.keys(bindings).length}`);
console.log(`[mesh-info] markers=${Object.entries(markerSummary).map(([name, count]) => `${name}:${count}`).join(",")}`);
console.log(`[mesh-info] warnings=${warnings.length} errors=${errors.length}`);
process.exit(errors.length === 0 ? 0 : 1);
