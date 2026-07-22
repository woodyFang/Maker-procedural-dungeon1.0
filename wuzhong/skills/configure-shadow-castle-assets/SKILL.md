---
name: configure-shadow-castle-assets
description: Configure, add, replace, or tune Shadow Castle dungeon assets through the existing PCGDungeon mesh_info and Marker data without changing Lua generation logic. Use when a user asks to place a model on an existing Marker, change dungeon models or materials, build Marker-based prefabs or attachments, add ground scatter, configure Marker point lights, refresh the Shadow Castle, and validate the resulting scene.
---

# Configure Shadow Castle Assets

Only change data consumed by the existing dungeon pipeline. Never implement a missing placement algorithm or Marker in Lua as part of this skill.

## Establish the active configuration

1. Work only in the `wuzhong` project root containing `scripts/`, `assets/`, `Models/`, and `Materials/`.
2. Inspect `git status --short` and preserve every unrelated or pre-existing change.
3. Locate the renderer currently used by `DungeonApp` and read its manifest candidate list. Locate the one active `*.mesh_info.json`; prefer `assets/PCGDungeon/PCGDungeon.mesh_info.json` after the PCG rename, but do not assume a moved file is already wired into the runtime.
4. Read `assets/PCGDungeon/README.md` and the active manifest completely enough to understand the target Marker, existing rules, resource bindings, and nearby transforms.
5. Run the bundled validator with runtime path checking before editing:

   ```powershell
   node skills/configure-shadow-castle-assets/scripts/validate_mesh_info.js . <active-mesh-info> --check-runtime
   ```

If the loader cannot see the active manifest, stop and report the path mismatch. Do not repair renderer, generator, adapter, or application code under this skill.

## Translate the request to existing data

Confirm these inputs from the request or local resources:

- Target existing Marker and optional `marker_group`.
- Model resource and material resource already present in `Models/`, `Materials/`, or another configured resource root.
- Desired local offset, Pitch/Yaw/Roll rotation, scale, visibility, shadow behavior, and collision intent.
- Whether placement is every Marker, a deterministic subset, a multi-part prefab, ground scatter, or a point light.

Do not invent a Marker name. If the desired placement is not representable by the README's Marker list and modes, return that boundary explicitly without changing files.

Choose the rule type deliberately:

| Intent | Configuration |
| --- | --- |
| One asset on every selected Marker | Add an `inherit` rule and an `asset_bindings` entry |
| Extra asset on all or some transforms of an existing source | Add an `attach` rule with valid `source_mesh`; use `density` and `selection_seed` for a subset |
| Several models forming one object | Add one `prefab` rule with `parts`; bind every visible part |
| Light on an existing light Marker | Add `point_light_marker` with `point_light_brightness` and `point_light_range_m` |
| Random or clustered ground decoration | Add `scatter_rules` targeting `GroundScatterSurface` |

`density` is used by `attach` and point-light rules, not by `inherit` or `prefab`. To sample ordinary Marker assets, use a valid attach source or a supported ground scatter rule; do not add dead parameters.

## Edit the manifest

1. Use a unique stable snake-case rule `id`.
2. Reuse a real logical asset key when one exists. Otherwise create one stable key such as `/Game/Configured/ShadowCastle/<Asset>.<Asset>`; this is a lookup key, not a filesystem path.
3. Add or reuse the matching `asset_bindings` entry with an existing `model_resource` and optional existing `material_resource`.
4. Add the smallest suitable rule to `meshes` or `scatter_rules`. Copy only relevant fields from a nearby rule using the same Marker and usage.
5. Keep coordinates consistent with the manifest: `offset_cm` is centimeters, `rotation_deg` is Pitch/Yaw/Roll, and `marker_copies[].local_offset_m` is meters.
6. For point lights, set the UrhoX fields `point_light_brightness` and `point_light_range_m`; do not rely only on legacy `point_light_intensity` or `point_light_attenuation_radius`.
7. Do not modify `scene`, because runtime Marker adaptation overwrites it on every refresh.
8. Do not modify anything under `scripts/`, `LegacyReference/`, generation fixtures, or BGEO files.
9. Update the corresponding current-asset or scatter table in `assets/PCGDungeon/README.md` so the inventory remains accurate.

Patch the JSON narrowly. Do not parse and serialize the entire large manifest when a small textual patch is sufficient, because that creates unrelated formatting churn.

## Validate data and resources

Run:

```powershell
node skills/configure-shadow-castle-assets/scripts/validate_mesh_info.js . <active-mesh-info> --check-runtime
git diff --check -- <active-mesh-info> assets/PCGDungeon/README.md
```

Inspect the focused diff. Verify that it contains only the intended binding, rule, parameter, and README changes. Treat missing resources, duplicate IDs, unknown Markers, unsupported usage, invalid attach sources, and ignored density fields as failures.

## Refresh and test the dungeon

Static validation is necessary but not sufficient.

1. Discover the current PCG test filenames with `rg --files scripts | rg 'pcg_dungeon|shadow_castle|first_person_door'` instead of relying on legacy Houdini/Bgeo names.
2. Reuse the runtime executable and package arguments from `start-offline.cmd`. Run the current Marker-flow and Shadow Castle integration tests and wait for each process to exit. Run lighting tests for light changes and first-person door tests for doorway or collision-adjacent changes.
3. Confirm the engine log says `Executed Lua script <test-name>` and contains that test's PASS result. A GUI process launch or exit code alone is not proof: an active editor may route the request back to `main.lua`. If the project requires temporarily selecting the test in `dev.json`, preserve its exact original content and restore it immediately after the test; never leave test configuration behind.
4. Inspect stdout/stderr, result files, and engine logs. Fail on invalid manifest, missing model/material, zero generated instances for the new rule, Lua errors, or stale manifest paths.
5. Open or reuse the running application, select Shadow Castle, and click the visible `刷新地牢` control. A process restart alone does not satisfy this step.
6. Refresh at least two different seeds. Record generation statistics and verify the new asset appears at the intended Marker frequency.
7. Inspect the scene from both overview and first-person views. Check scale, orientation, materials, shadows, floating geometry, severe intersections, z-fighting, and visual repetition.
8. Walk through doors, corridors, and stairs near the new asset. Verify mouse-look, first-person entry/exit, door interaction, and Shadow Castle parameter adjustment still work.
9. Capture screenshots or other concrete visual evidence. If visual control or capture is unavailable, report validation as incomplete rather than claiming the scene is reasonable.

If placement is wrong, adjust only supported manifest fields and repeat static validation, refresh, and visual checks. Never compensate by changing generation code.

## Return results

Report:

- User intent and chosen Marker, group, and usage.
- Exact binding and rule IDs added or changed.
- Static validation and resource-load results.
- Test scripts executed and their pass/fail results.
- Refresh seeds, generated instance/light counts, and visual findings.
- Screenshot paths or equivalent evidence.
- Any remaining limitation or blocker.

Do not report success unless the active manifest was loaded, the dungeon was refreshed, and visual scene validation completed.
