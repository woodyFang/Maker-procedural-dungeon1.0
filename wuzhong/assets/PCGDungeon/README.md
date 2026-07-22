# PCG Dungeon 资产与 Marker 对照

本文件对应 `PCGDungeon.mesh_info.json`。当前配置包含 20 条 Marker 规则、13 条地面散布规则和 25 个资源绑定。

## 配置边界

- Marker 位置、朝向和数量由 `scripts/Generation/PCGDungeonMarkerPipeline.lua` 生成。`mesh_info` 只能消费已有 Marker，不能创建新 Marker 或改变房间、走廊、楼梯和门的拓扑。
- 动态刷新会重建并覆盖 `scene.instances` 和 `scene.surfaces`。不要手工修改 `scene`；应修改 `asset_bindings`、`meshes` 或 `scatter_rules`。
- `offset_cm` 使用厘米，`rotation_deg` 顺序为 Pitch/Yaw/Roll，`scale` 为三轴倍率。`marker_copies[].local_offset_m` 是明确标注的例外，单位为米。
- `mesh` 和 `source_mesh` 是配置内部的逻辑资产键。真正加载的 UrhoX 资源来自 `asset_bindings`，资源路径不带 `assets/` 前缀。
- 运行时材质优先级为：当前规则 `material_overrides`、父级 prefab 规则 `material_overrides`、`asset_bindings.material_resource`。

## Marker 清单

| Marker | 可选 `marker_group` | 生成位置与用途 | 当前配置 |
| --- | --- | --- | --- |
| `Ground` | `marker_Ground_Room`、`marker_Ground_Corridor` | 每个房间或走廊可行走 Cell 的地面中心 | 房间地板、走廊地板，同时生成 `GroundScatterSurface` |
| `Wall` | `marker_Wall_Room`、`marker_Wall_Corridor`、`marker_Wall_Stair` | 房间、走廊和楼梯边界，朝向边界法线 | 双面墙 prefab、墙脚石、十字装饰 |
| `Door` | 无 | 每个拓扑门洞，带门朝向 | 双面墙拱、门框、可交互门扇 |
| `WallSeparator` | `marker_WallSeparator_Room`、`marker_WallSeparator_Corridor`、`marker_WallSeparator_Stair` | 墙段端点、拐角和 T 接点 | 石柱 |
| `Stair` | `marker_Stair_Stair` | 每组两格实体楼梯的起点和方向 | 楼梯模型，上下两份 `marker_copies` |
| `Ceil` | `marker_Ceil_Boundary`、`marker_Ceil_Interior`、`marker_Ceil_InnerCorner`、`marker_Ceil_NonInnerCorner`、`marker_Ceil_Room`、`marker_Ceil_Corridor`、`marker_Ceil_Stair` | 房间、走廊和楼梯净空顶部 | 屋顶块 |
| `Light` | 无 | 除实体楼梯 Cell 外的 Cell 中心 | 室内基础点光 |
| `Light_Ambient` | 无 | 避开门和楼梯的低密度环境补光候选点 | 冷色环境点光 |
| `Light_Door` | 无 | 门朝向前方相邻 Cell 中心 | 门口引导点光 |
| `Light_Stair` | 无 | 每组楼梯的上下端点 | 楼梯安全点光 |
| `Light_Hero` | 无 | 至少 6 个 Cell 的房间中心 | 大房间主点光 |
| `PillarPlacement` | 无 | 从墙柱分隔点向相邻房间或走廊内部偏移 1.2 米 | 隐藏传输规则、火盆和伴随点光 |
| `PillarWebPlacement` | 无 | 只有一个对角相邻地面的柱角内侧 | 当前没有资产规则，可直接新增规则使用 |
| `Curbstone01Placement` | 无 | 房间和走廊一侧的墙边 | 单侧墙脚石 |

`GroundScatterSurface` 不是 Marker。它由所有 `Ground` Marker 拼成，只供 `scatter_rules` 在地面上做噪声或簇状散布。

## 当前 Marker 资产

| 规则 ID | Marker / 分组 | 模式 | UrhoX 模型 | 材质 | 关键配置 |
| --- | --- | --- | --- | --- | --- |
| `ground_floor01` | `Ground` / Room | `inherit` | `Models/Floor01.mdl` | `Materials/pavement2.xml` | 房间地板 |
| `ground_floor01_corridor` | `Ground` / Corridor | `inherit` | `Models/Floor01.mdl` | `Materials/pavement2.xml` | 走廊地板 |
| `wall_bp_wall` | `Wall` | `prefab` | `Models/Wall01.mdl` x2 | `Materials/brick2.xml` | front/back 两个 part，背面旋转 180 度 |
| `wall_curbstone04` | `Wall` | `attach` | `Models/curbstone04.mdl` | `Materials/curbstone.xml` | 跟随墙体传输变换 |
| `wall_curbstone01_room_corridor_sides` | `Curbstone01Placement` | `inherit` | `Models/curbstone01.mdl` | `Materials/curbstone.xml` | 房间和走廊单侧墙脚 |
| `wall_cross` | `Wall` | `attach` | `Models/Cross.mdl` | `Materials/Jail.xml` | `density = 0.5`，确定性抽样 |
| `door_wall_arch` | `Door` | `inherit` | `Models/wall01Arch1.mdl` | `Materials/brick2.xml` | 门洞正面 |
| `door_wall_arch_backface` | `Door` | `attach` | `Models/wall01Arch1.mdl` | `Materials/brick2.xml` | 门洞背面 |
| `door_arch01` | `Door` | `inherit` | `Models/DoorArch01.mdl` | `Materials/DoorArch.xml` | 门框 |
| `door_leaf02` | `Door` | `attach` | `Models/Door02.mdl` | `Materials/Door1.xml` | `interactive_door = true` |
| `wall_separator_column03` | `WallSeparator` | `inherit` | `Models/Column03.mdl` | `Materials/column.xml` | 墙端点和拐角柱 |
| `pillar_placement_transport` | `PillarPlacement` | `inherit` | 不可见传输节点 | 无 | `visible = false`，给 attach 规则提供变换 |
| `wall_separator_roaster02` | `PillarPlacement` | `attach` | `Models/roaster02.mdl` | `Materials/Chandelier.xml` | `density = 0.35`，点光 brightness 0.3、range 4.8m、投射阴影 |
| `stair_stairs01` | `Stair` | `inherit` | `Models/Stairs01.mdl` | `Materials/Stairs.xml` | 两份 `marker_copies` 覆盖上下楼梯段 |
| `light_interior_cell` | `Light` | `point_light_marker` | 无可见模型 | 无 | `density = 0.75`，每房间至少 2 盏；brightness 0.3、range 7m、投射阴影 |
| `light_ambient_cool_fill` | `Light_Ambient` | `point_light_marker` | 无可见模型 | 无 | `density = 0.5`；brightness 0.3、range 20m、投射阴影 |
| `light_door_guide` | `Light_Door` | `point_light_marker` | 无可见模型 | 无 | 每个候选点；brightness 0.3、range 20m、投射阴影 |
| `light_stair_safety` | `Light_Stair` | `point_light_marker` | 无可见模型 | 无 | `density = 0.5`；brightness 0.3、range 20m、投射阴影 |
| `light_hero_room` | `Light_Hero` | `point_light_marker` | 无可见模型 | 无 | `density = 0.5`；brightness 0.3、range 20m、投射阴影 |
| `ceil_roof11` | `Ceil` | `inherit` | `Models/Roof11.mdl` | `Materials/Roof02.xml` | 房间、走廊和楼梯顶部 |

## 当前地面散布资产

所有规则都使用 `GroundScatterSurface`，并且 `align_to_normal = true`。

| 规则 ID | 模型 | 材质 | 分布 | 候选密度 / m2 | 缩放范围 |
| --- | --- | --- | --- | --- | --- |
| `ground_brickdamage_brick01` | `Models/Brick01.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.8-1.2 |
| `ground_brickdamage_brick02` | `Models/Brick02.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.8-1.2 |
| `ground_brickdamage_brick03` | `Models/Brick03.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.8-1.2 |
| `ground_brickdamage_brick04` | `Models/Brick04.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.8-1.2 |
| `ground_brickdamage_brick05` | `Models/Brick05.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.8-1.2 |
| `ground_brickdamage_brick06` | `Models/Brick06.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.8-1.2 |
| `ground_brickdamage_rock01` | `Models/rock01.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.65-1.2 |
| `ground_brickdamage_rock02` | `Models/rock02.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.7-1.25 |
| `ground_brickdamage_rock03` | `Models/rock03.mdl` | `Materials/BrickDamage.xml` | noise | 0.008 | 0.6-1.15 |
| `bone_cluster_bone01` | `Models/Bone01.mdl` | `Materials/Bones.xml` | cluster | 0.03 | 0.8-1.15 |
| `bone_cluster_bone02` | `Models/Bone02.mdl` | `Materials/Bones.xml` | cluster | 0.026 | 0.8-1.15 |
| `bone_cluster_bone03` | `Models/Bone03.mdl` | `Materials/Bones.xml` | cluster | 0.022 | 0.75-1.1 |
| `bone_cluster_scull01` | `Models/Scull01.mdl` | `Materials/Bones.xml` | cluster | 0.01 | 0.8-1.1 |

## 模式选择

| 需求 | 使用方式 | 注意事项 |
| --- | --- | --- |
| 每个已有 Marker 都生成一个模型 | `usage = "inherit"` | `density` 对 `inherit` 不生效；用 `marker_group` 缩小范围 |
| 在现有源资产变换上附加模型 | `usage = "attach"` | `source_mesh` 必须由 `inherit`、`prefab` 或 `point_light_marker` 规则产生；支持 `density` 和 `selection_seed` |
| 一个 Marker 生成多个模型部件 | `usage = "prefab"` + `parts` | 每个可见 part 都必须有 `asset_bindings`；part 可独立偏移、旋转、缩放和覆盖材质 |
| 使用已有光照 Marker | `usage = "point_light_marker"` | 必须填写 UrhoX 实际读取的 `point_light_brightness` 和 `point_light_range_m` |
| 在地面随机或成簇摆放 | `scatter_rules` | 只能使用现有 `GroundScatterSurface`；密度字段为 `candidate_density_per_square_meter` |

## 常用参数

| 参数 | 作用 |
| --- | --- |
| `id` | 全局唯一、稳定的规则 ID |
| `marker` / `marker_group` | 选择已有 Marker 类型及可选子集 |
| `mesh` | 逻辑资产键，必须与 `asset_bindings` 一致 |
| `source_mesh` | `attach` 的变换来源，或 `prefab` 的传输键 |
| `offset_cm` / `rotation_deg` / `scale` | 模型相对 Marker 的局部变换 |
| `marker_yaw_offset_deg` | 在打包 Marker 朝向时增加 Yaw 修正 |
| `marker_copies` | 从一个 Marker 生成多份传输变换；局部位移字段为 `local_offset_m` |
| `density` / `selection_seed` | `attach` 和点光规则的确定性抽样比例与种子 |
| `override_uniform_scale_range` | Marker 资产的确定性随机等比缩放 |
| `visible` / `cast_shadow` | 模型显隐与阴影开关 |
| `material_overrides` | 当前规则或 prefab part 的材质覆盖 |
| `point_light_brightness` / `point_light_range_m` | UrhoX 点光亮度与米制范围 |
| `point_light_color_srgb` / `point_light_color_palette` | 固定颜色或确定性调色板 |
| `point_light_intensity_variation` / `point_light_radius_variation` | 基于位置哈希的亮度与范围变化比例 |

## 修改后检查

1. 运行静态校验：

   ```powershell
   node skills/configure-pcg-dungeon-assets/scripts/validate_mesh_info.js . assets/PCGDungeon/PCGDungeon.mesh_info.json
   ```

2. 确认运行时加载器指向同一配置：

   ```powershell
   node skills/configure-pcg-dungeon-assets/scripts/validate_mesh_info.js . assets/PCGDungeon/PCGDungeon.mesh_info.json --check-runtime
   ```

3. 进入使用 PCG Dungeon 流程的主题并点击“刷新地牢”，至少检查两个不同种子。验证模型存在、材质正确、比例和朝向合理、没有悬空或严重穿插，并确认门、楼梯和第一人称通行没有回归。
