# DungeonAssetsV1 mesh_info

`DungeonAssetsV1.mesh_info.json` 是基于固定 PCG Dungeon Marker 结构创建的独立首版资产清单。它不会替换或修改运行时当前加载的 `PCGDungeon.mesh_info.json`。

## 资产源

- 只读根目录：`E:/DungeonAssets/FBX`
- 权威目录：`E:/DungeonAssets/FBX/_Catalog/asset_catalog.json`
- 人工审核：2026-07-23 已批准
- 机械校验：4/4 FBX 通过，UrhoX 原生 `.mdl` 转换 4/4 通过

## Marker 规则

| 规则 ID | Marker / 分组 | 源 FBX | UrhoX 模型 | 用途 |
| --- | --- | --- | --- | --- |
| `dungeon_assets_v1_ground_room` | `Ground` / Room | `Wall/Env_Tiles_03.fbx` | `Models/DungeonAssetsV1/Env_Tiles_03.mdl` | 房间地板 |
| `dungeon_assets_v1_ground_corridor` | `Ground` / Corridor | `Wall/Env_Tiles_03.fbx` | `Models/DungeonAssetsV1/Env_Tiles_03.mdl` | 走廊地板 |
| `dungeon_assets_v1_wall` | `Wall` | `Wall/Env_Wall_01.fbx` | `Models/DungeonAssetsV1/Env_Wall_01.mdl` | 完整墙段 |
| `dungeon_assets_v1_door_opening` | `Door` | `Door/Env_Wall_DoorFrame_Round_01.fbx` | `Models/DungeonAssetsV1/Env_Wall_DoorFrame_Round_01.mdl` | 无门扇拱形门洞 |
| `dungeon_assets_v1_ceiling` | `Ceil` | `Ceil/Env_Ceiling_Stone_Flat_01.fbx` | `Models/DungeonAssetsV1/Env_Ceiling_Stone_Flat_01.mdl` | 单格天花板 |

所有规则使用规范化资产 Pivot 和轴向，因此运行时变换均为零偏移、零旋转、等比缩放 1。地板源文件虽位于 `Wall/`，其几何和审核用途为水平 5 米地面模块。

## 共用材质

- 材质：`Materials/DungeonAssetsV1.xml`
- 纹理：`Textures/DungeonAssetsV1/Dungeons_Texture_01_D.png`
- 材质槽：`Dungeon_Material_01`

当前首版不包含门扇、灯光、装饰、散布、墙柱或楼梯。
