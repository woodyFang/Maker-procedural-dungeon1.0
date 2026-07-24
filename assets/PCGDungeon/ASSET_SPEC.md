# 地牢资产包筛选、Blender 规范化与统一导出规范（通用）

> **文档状态：待审阅**
> 本规范用于从任意来源的美术资产包中筛选适合目标地牢的静态模型，在 Blender 中统一尺寸、Pivot 和局部轴向，并按 Marker 分类输出。规范不依赖资产包名称、文件夹结构、文件名、商城来源或某次导出的绝对路径。

## 1. 目标与边界

本规范解决以下问题：

1. 如何盘点一个未知资产包，而不直接修改源文件。
2. 如何把候选模型映射到目标地牢的 Marker/用途。
3. 如何依据尺寸、几何、安装方式和运行时约束筛选模型。
4. 如何在 Blender 中统一 Pivot、局部轴向和等比缩放。
5. 如何以固定目录、固定命名和固定坐标约定输出。
6. 如何区分机械校验通过与最终美术签收。

本规范不保证任何未知模型仅凭文件名即可自动分类，也不允许脚本在无法判断模型语义时静默批准。门铰链、灯具发光点、墙面正面、角落挂点等语义位置无法可靠自动识别时，必须进入人工复核。

## 2. 核心强制规则

以下规则适用于每个被批准输出的资产，缺一项不得标记为 `approved`：

- **必须指定目标用途**：每个条目必须有一个 `target_marker` 和一个明确的 `usage`；不能只写“地牢装饰”。
- **必须标注 Pivot**：必须记录 Pivot 规则、语义说明和最终位置。最终导出对象的 Pivot 默认为局部原点 `(0, 0, 0)`。
- **必须标注局部轴**：必须分别说明最终局部 `+X`、`+Y`、`+Z` 的语义；其中 `+X` 和 `+Y` 为最低必填项。
- **只允许等比缩放**：任何尺寸调整只能使用 `[s, s, s]`。禁止用 `[sx, sy, sz]` 拉伸模型适配地牢模块。
- **必须应用变换**：最终 Blender 对象 Rotation 为零，Scale 为 `[1, 1, 1]`；规范化旋转和等比缩放必须烘焙到模型。
- **不得覆盖源资产**：源资产包永远只读；中间文件、Blender 文件和最终输出必须在独立目录。
- **不得只靠目录名分类**：目录和文件名只能作为候选提示。最终 Marker 归属必须写入资产清单并经过规则校验。
- **同一源模型可拆成多个规范条目**：若同一模型用于不同 Marker 时需要不同 Pivot、轴向或安装语义，必须生成不同 `asset_id`，不能共用一个含糊版本。
- **Scatter Pivot 必须在底部支撑区域中心**：不得使用几何中心、任意最低顶点或偏心接触点。

## 3. 流水线输入

通用流程在开始前必须具备三个输入。任一输入缺失时，只能盘点，不能批量批准。

### 3.1 源资产包

源资产可以来自 Unreal Content、FBX、glTF、OBJ、Blend 或其他可转换格式。必须记录：

- 资产包稳定 ID 和版本。
- 只读源根目录或内容浏览器根路径。
- 授权、来源和允许的使用范围。
- 原始格式、单位、Up 轴、Forward 轴和坐标系手性。
- 原始材质、贴图、碰撞和 LOD 的存放方式。
- 是否包含骨骼、动画、蓝图、粒子或非模型依赖。

只有可独立输出为静态模型的几何体进入本流程。依赖蓝图逻辑、骨骼动画或运行时组件才能成立的对象，应进入独立流程或被拒绝。

### 3.2 资产包导入 Profile

每套资产包必须提供独立的 `asset_set_profile`。它描述“如何读取这套资产”，不能把这些假设写死在通用脚本中。

最低字段：

| 字段 | 说明 |
| --- | --- |
| `asset_set_id` | 资产包稳定 ID |
| `asset_set_version` | 资产包版本或来源版本 |
| `source_root` | 只读源根目录/逻辑路径 |
| `source_format` | Unreal StaticMesh、FBX、glTF 等 |
| `source_unit` | cm、m 等 |
| `source_up_axis` | 原始 Up 轴 |
| `source_forward_axis` | 原始 Forward 轴 |
| `source_handedness` | 左手或右手 |
| `import_preset` | Blender 导入预设 ID |
| `classification_rules` | 目录、标签、元数据到候选用途的映射，仅用于候选提示 |
| `material_policy` | 材质/贴图复制、引用或重建策略 |
| `collision_policy` | 是否保留源碰撞及命名约定 |
| `lod_policy` | LOD 保留、重建或拒绝规则 |
| `output_root` | 本资产包独立输出根目录 |

### 3.3 目标地牢 Profile

目标地牢必须提供 `dungeon_target_profile`。它描述“什么样的模型算符合当前地牢”，与源资产包无关。

最低字段：

| 字段 | 说明 |
| --- | --- |
| `profile_id` / `version` | 目标规范版本，写入每个输出条目 |
| `length_unit` | 目标长度单位，默认米 |
| `cell_size_m` | 单格边长 |
| `storey_height_m` | 楼层高度/净高 |
| `walkable_clearance_m` | 最低通行净空 |
| `corridor_clear_width_m` | 走廊最低净宽 |
| `door_opening_range_m` | 门洞允许宽、高、深范围 |
| `wall_envelope_m` | 墙段长度、厚度、高度范围 |
| `stair_envelope_m` | 单段或整组楼梯包络和上行方向 |
| `scatter_class_limits` | 每类 scatter 的最大尺寸、间距和缩放范围 |
| `marker_profiles` | 每种 Marker 的尺寸、Pivot、轴向和碰撞规则 |
| `output_coordinate_system` | 最终坐标系和轴映射 |
| `export_preset` | 最终模型格式及固定导出参数 |

具体尺寸必须来自 `dungeon_target_profile`。通用文档不应把某个项目的 `5 m` Cell、某套楼梯 copies 或某种门洞大小写成所有项目都必须遵守的常量。

## 4. 固定执行流程

任何资产包都必须按以下顺序执行，不得跳过门禁：

```text
只读盘点
  -> 候选用途分类
  -> Marker 尺寸/几何筛选
  -> 中间格式转换
  -> Blender 规范化
  -> 机械回读校验
  -> Marker 校准场景复核
  -> 人工签收
  -> 按 Marker 分类交付
```

### 阶段 A：只读盘点

1. 递归枚举所有可用静态模型。
2. 记录原始路径、类型、包围盒、对象数量、材质槽、三角面数、UV、碰撞、LOD 和原始 Pivot。
3. 生成预览图或可定位到源资产的检查入口。
4. 不修改源对象，不在源目录生成加工文件。

输出状态：`discovered`。

### 阶段 B：候选分类

1. 根据模型外形、资产标签和 `classification_rules` 生成候选 Marker。
2. 人工或可靠规则确认唯一的 `target_marker`、`subtype` 和 `usage`。
3. 无法判断用途的资产标记为 `unclassified`，不得自动进入 Blender 批处理。
4. 同一源模型需要不同 Pivot/轴向时拆成多个加工条目。

输出状态：`candidate`、`unclassified` 或 `rejected`。

### 阶段 C：筛选

按目标 Marker Profile 检查：

- 原始尺寸和允许的等比缩放后尺寸。
- 是否能在目标 Cell、墙段、门洞、楼梯或装饰包络内使用。
- 是否会侵入通行区、门洞、楼梯净空或相邻 Cell。
- 模型语义是否与 Marker 一致。
- 是否需要不可接受的非等比拉伸、大幅运行时偏移或特殊逻辑。
- 材质、UV、法线、拓扑和依赖是否具备交付条件。

不符合硬限制的资产直接 `rejected`；可通过有限修复解决的资产标记 `needs_fix`；可进入 Blender 的资产标记 `screened`。

### 阶段 D：中间格式转换

1. 对 Unreal、专有格式或批量资产使用对应工具导出中间模型。
2. 中间格式必须保留顶点、法线、UV、材质槽名称和必要的顶点色。
3. 中间文件只作为 Blender 输入，不是最终交付文件。
4. 每个条目必须能从中间文件反查源资产路径和资产包版本。

### 阶段 E：Blender 规范化

严格按照第 10 章的顺序执行单位、轴向、缩放、Pivot、清理和元数据处理。

输出状态：`normalized` 或 `needs_fix`。

### 阶段 F：机械回读校验

将最终导出文件重新导入空白 Blender 场景，检查第 12 章的机械验收项。机械校验失败时不得进入人工签收。

输出状态：`mechanical_pass` 或 `validation_failed`。

### 阶段 G：场景复核与签收

将模型放入对应 Marker 校准场景，检查拼接、方向、安装、碰撞和通行。语义无法自动验证的资产保持 `manual_review`。完成美术和关卡签收后才能标记 `approved`。

## 5. 资产清单最低字段

每个加工条目必须包含：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `asset_id` | 是 | 输出条目稳定唯一 ID |
| `asset_set_id` / `asset_set_version` | 是 | 来源资产包和版本 |
| `source_path` | 是 | 可反查的源资产路径 |
| `source_format` | 是 | 源格式 |
| `target_profile_id` / `version` | 是 | 使用的目标地牢规范 |
| `target_marker` | 是 | 主 Marker |
| `marker_group` | 否 | Marker 子分组 |
| `subtype` | 是 | DoorLeaf、DoorFrame、StairBody 等 |
| `usage` | 是 | `inherit`、`attach`、`prefab`、`scatter` 等 |
| `source_bbox_m` | 是 | 源包围盒，按源工作轴记录 |
| `normalized_bbox_m` | 是 | 最终目标坐标包围盒 |
| `pivot_rule` | 是 | 固定 Pivot 规则 ID |
| `pivot_note` | 是 | Pivot 语义位置说明 |
| `pivot_position_m` | 是 | 最终局部坐标，通常 `[0,0,0]` |
| `source_axis_mapping` | 是 | 源坐标到 Blender 工作坐标映射 |
| `axis_normalization_rotation` | 是 | Blender 中实际应用的规范化旋转 |
| `x_axis_direction` | 是 | 最终局部 `+X` 语义 |
| `y_axis_direction` | 是 | 最终局部 `+Y` 语义 |
| `z_axis_direction` | 是 | 最终局部 `+Z` 语义 |
| `uniform_scale` | 是 | 必须为 `true` |
| `normalization_uniform_scale` | 是 | 规范化倍率 `s` |
| `material_slots` | 是 | 材质槽名称/映射 |
| `collision_policy` | 是 | 碰撞要求 |
| `blender_file` | 是 | 加工文件路径 |
| `export_path` | 是 | 最终模型路径 |
| `validation_status` | 是 | 机械校验状态 |
| `manual_review_required` | 是 | 是否需要人工复核 |
| `status` | 是 | 生命周期状态 |
| `notes` | 否 | 限制和问题 |

## 6. 通用筛选条件

### 6.1 必须拒绝

出现以下任一情况，默认拒绝：

- 只有通过非等比拉伸才能适配目标包络。
- 必须依赖骨骼、动画、蓝图、粒子或脚本才能表达基本外形，但目标只接受静态模型。
- 关键几何、材质或贴图缺失，且无法合法补齐。
- 面数、材质槽或纹理规格超过目标 Profile 的硬限制。
- 无法消除负缩放、破损法线、严重非流形、重复几何或退化面。
- 需要跨越多个未声明 Cell/Marker，导致重复生成或拓扑冲突。
- Pivot 和轴向语义无法确定，也无法安排人工修复。
- 授权或来源不明确。

### 6.2 可以进入修复

以下情况可以标记 `needs_fix`：

- Pivot 错误但安装语义明确。
- 源轴向错误但能通过明确旋转修正。
- 尺寸略超限但允许使用统一倍率 `s` 缩小。
- 含多余 Empty、隐藏网格、碰撞壳或辅助几何，可安全清理。
- 材质槽名称、对象名或层级不符合输出命名规则。

### 6.3 禁止用运行时配置掩盖资产错误

- 大幅 `offset` 不能代替 Blender Pivot 修复。
- `rotation` 补偿不能代替资产轴向规范化，除非旋转属于 Marker 的运行时语义。
- 随机缩放不能用于修正模型尺寸错误。
- scatter 密度和间距不能用于掩盖模型本体过大。

## 7. Marker 选择与规范

具体尺寸来自 `marker_profiles`；下表定义通用语义、Pivot 和轴向。坐标描述均指最终目标坐标。

| Marker / subtype | 适合的模型 | Pivot | `+X` | `+Y` | `+Z` |
| --- | --- | --- | --- | --- | --- |
| `Ground` | 单格/模块化地板、地面表层 | 模块水平中心的地面接触面；厚度向下 | 网格右 | 向上 | 网格前 |
| `Wall` / WallSegment | 单段墙、栅栏、牢墙 | 墙段中心的墙脚接触面 | 墙外法线 | 向上 | 沿墙段 |
| `Wall` / WallAttachment | 墙面挂饰、管线、机关 | 明确的墙面安装点 | 安装面外法线 | 向上 | 装饰展开方向 |
| `Door` / DoorFrame | 门框、门拱、门洞墙块 | 门洞底部中心 | 门洞法线 | 向上 | 沿门宽 |
| `Door` / DoorLeaf | 可开合门扇 | 真实铰链轴底部 | 门面法线 | 向上 | 从铰链指向自由边或 Profile 规定方向 |
| `WallSeparator` | 柱、墙端头、转角连接件 | 柱脚/连接点底部中心 | canonical 方向或连接法线 | 向上 | Profile 规定方向 |
| `Stair` / StairBody | 单段或整组楼梯 | 下层起步边中心 | 楼梯宽度 | 向上 | 楼梯上行方向 |
| `Stair` / StairAttachment | 扶手、栏杆、基座 | 对应楼梯的安装锚点 | 楼梯宽度或安装面法线 | 向上 | 楼梯上行方向 |
| `Ceil` | 单格天花、顶部模块 | 室内可见底面中心 | 网格右 | 向上 | 网格前 |
| `PillarPlacement` | 火盆、柱旁落地装饰 | 底座支撑中心 | 面向空间的 canonical 方向 | 向上 | 装饰前向 |
| `PillarWebPlacement` | 蛛网、角落挂饰 | 实际角落挂点/安装点 | 安装面外法线 | 向上 | 装饰展开方向 |
| `CurbstonePlacement` | 墙脚石、踢脚线 | 墙段中心的底面接触面 | 墙外法线 | 向上 | 沿墙段 |
| `Light` / Fixture | 吊灯、壁灯、火把、蜡烛 | 安装点或发光中心，必须由 subtype 指定 | 灯具正面/安装面外法线 | 向上或 Profile 指定吊装方向 | 灯具展开方向 |
| `GroundScatterSurface` | 砖块、石块、骨骼、小型杂物 | 底部稳定支撑区域中心 | 随机 Yaw 的基准方向 | 向上 | 资产参考前向 |

一个模型的外形可能同时适合多个 Marker，但只有 Pivot、轴向、碰撞和生成方式均相同时才能复用同一输出条目。

## 8. 尺寸筛选

### 8.1 尺寸计算

- 所有尺寸统一换算为米。
- 筛选使用应用源单位和源轴映射后的真实世界包围盒。
- 允许的规范化尺寸为 `source_bbox * s`，其中 `s` 是单一标量。
- 旋转导致的轴交换必须在尺寸判定前明确应用。
- `normalized_bbox_m` 按最终目标坐标的 `[X, Y, Z]` 记录。

### 8.2 Marker 包络

每个 `marker_profile` 至少定义：

- `preferred_bbox_m`：推荐范围。
- `hard_bbox_m`：硬包络。
- `allowed_uniform_scale_range`：允许的 `s` 范围。
- `clearance_m`：与通行、墙体、天花和相邻 Cell 的安全距离。
- `can_cross_cells`：是否允许跨 Cell，以及跨越数量。
- `collision_policy`：是否阻挡导航/角色。

结构模型超过硬包络时不得自动缩小到失真比例；由目标 Profile 明确允许的装饰和 scatter 才能使用自动等比归一化。

## 9. Pivot 规范

### 9.1 总原则

Pivot 必须表示运行时 Marker 的实际锚点，而不是建模软件默认原点或几何中心。最终导出时将 Pivot 放在局部 `(0,0,0)`，并记录它在源/Blender 工作空间中的修正位置。

Pivot 判定优先级：

1. 人工提供的明确安装点、铰链、插槽或 Socket。
2. 源资产中经过验证的语义原点。
3. Marker Profile 规定的几何特征点。
4. 可证明适用的包围盒/支撑区域算法。
5. 无法可靠判定时进入 `manual_review`，不得猜测后批准。

### 9.2 Scatter 支撑中心

适合 scatter 的物件必须使用底部稳定支撑区域中心：

1. 确定模型在规范 Up 轴上的最低高度 `h_min`。
2. 从 `h_min` 向上取 Profile 指定的支撑带厚度，收集支撑顶点或接触面。
3. 将支撑区域投影到水平面。
4. 计算投影轮廓/凸包的面积中心。
5. Pivot 水平位置使用该面积中心，竖直位置使用 `h_min`。
6. 回读后必须验证底部高度为零，且重新计算的支撑中心仍位于原点。

禁止只选择某个最低顶点。对于弯曲骨骼、头骨、碎石等不规则模型，必须以稳定放置时的实际支撑区域为准；自动算法与视觉稳定姿态不一致时转人工复核。

### 9.3 常用 Pivot Rule ID

| `pivot_rule` | 语义 |
| --- | --- |
| `cell_center_floor` | 单格中心地面接触面 |
| `wall_segment_center_floor` | 墙段中心墙脚 |
| `wall_attachment_mount` | 墙面附属件安装点 |
| `door_frame_base_center` | 门洞底部中心 |
| `door_hinge_base` | 门扇铰链轴底部 |
| `wall_endpoint_base` | 墙端/柱脚中心 |
| `stair_lower_start_floor` | 楼梯下层起步边中心 |
| `stair_attachment_mount` | 楼梯附属件安装点 |
| `ceil_underside_center` | 天花可见底面中心 |
| `pillar_base_floor` | 落地装饰底座中心 |
| `corner_mount` | 角落安装点 |
| `curbstone_segment_center_floor` | 墙脚石段中心底面 |
| `scatter_bottom_support_center` | scatter 底部支撑区域中心 |
| `light_fixture_mount` | 灯具安装点 |
| `light_emission_center` | 实际发光中心 |

## 10. Blender 规范化步骤

Blender 工作场景默认使用 Metric、`Unit Scale = 1.0`、`+Z` 向上。源坐标如何转换到 Blender 必须由 `import_preset` 指定；Blender 到最终目标坐标的转换必须由 `export_preset` 指定。

每个资产按以下顺序处理：

1. **隔离源对象**：每次只处理一个 `asset_id`，保留可反查的源路径。
2. **检查层级**：识别 Mesh、Empty、碰撞、LOD、隐藏对象和辅助几何。
3. **清理对象**：删除不允许交付的辅助对象；多部件资产按 `prefab`/part 规则拆分或合并。
4. **应用源导入变换**：将单位、父层级和导入旋转转换为 Blender 米制工作空间。
5. **规范局部轴向**：按 `axis_rule` 旋转几何，使局部轴符合 Marker 语义；记录并应用旋转。
6. **执行等比缩放**：只允许 `[s,s,s]`；记录 `s` 并应用 Scale。
7. **设置 Pivot**：按 `pivot_rule` 找到安装点，将对象原点设到该位置，再把最终 Pivot 放在 `(0,0,0)`。
8. **应用 Rotation/Scale**：最终 Rotation 为零、Scale 为 `[1,1,1]`；禁止负缩放。
9. **复核几何**：检查法线、退化面、UV、材质槽、顶点色、碰撞和 LOD。
10. **写入元数据**：至少写入 `asset_id`、Marker、Pivot、`+X/+Y/+Z`、等比缩放、Profile 版本和源路径。
11. **保存加工文件**：每个条目保存独立 `.blend`，或使用能独立导出且不会串资产的批次场景。
12. **按固定 Preset 导出**：不得临时更换轴向、单位或格式参数。

轴向规范化必须改变实际对象/几何变换，而不是只在清单中写一段方向文字。轴向无法从几何或源元数据确认时，保持 `manual_review`。

## 11. 输出结构和命名

每套资产包必须写入独立根目录：

```text
<output_root>/<asset_set_id>/
  catalog/
    source_inventory.json
    screened_candidates.json
    asset_catalog.json
    asset_catalog.csv
    validation_report.json
  intermediate/
  ByMarker/
    <Marker>/
      Models/
      Blender/
      Previews/          # 可选但推荐
  rejected/              # 拒绝清单/报告，不复制源模型
```

命名规则：

- 最终文件名使用稳定 `asset_id`，不能只使用可能重名的源文件名。
- 推荐格式：`<asset_set_id>__<marker>__<semantic_name>__<variant>`。
- 左右手、不同铰链、不同 Pivot、不同轴向或不同拆分方式必须是不同 variant。
- 模型文件、Blender 文件、预览图和清单必须能通过 `asset_id` 一一对应。
- 最终目录必须在导出前固定；批处理不能把文件散落在源资产包或临时目录。

## 12. 自动机械校验

最终模型导出后必须重新导入空白场景，并至少检查：

- 文件存在且可重新导入。
- Mesh 对象数量与条目定义一致。
- 单位和最终包围盒与目录记录一致。
- 对象原点为 `(0,0,0)` 或 Profile 明确允许的值。
- Rotation 为零、Scale 三轴相等且最终为 `[1,1,1]`。
- 没有负缩放和未应用父变换。
- `pivot_rule`、`pivot_note`、`x_axis_direction`、`y_axis_direction`、`z_axis_direction` 元数据存在。
- `uniform_scale = true`。
- Marker 语义几何成立，例如 Ground 顶面、Wall 底面、Ceil 底面、Door 铰链边、Stair 起步边。
- Scatter 的最低支撑面和支撑区域中心均位于 Pivot。
- 轴向修正后尺寸轴与 Marker 语义相符，例如门厚沿法线轴、门宽沿门宽轴。
- 材质槽、UV、法线、碰撞和 LOD 满足 Profile。
- 输出文件不包含其他资产的对象或依赖。

自动校验通过只得到 `mechanical_pass`，不能替代人工视觉验收。

## 13. Marker 校准场景

目标地牢 Profile 必须提供或定义以下校准场景：

- 单格 Ground 四方向拼接。
- Wall 直线、内角、外角、T 接和十字连接。
- Door 门框、门扇关闭/开启和角色通行。
- Stair 单段、组合段、上下层连接和最低净空。
- Ceil 与墙、楼梯、灯具组合。
- Wall/Pillar/Stair 附属件的安装面和朝向。
- Scatter 多随机种子、不同坡度、不同缩放和最小间距。
- 灯具安装面、实际发光中心和周围净空。

人工复核必须回答：

- 外形和尺度是否符合地牢风格及人类尺度。
- Pivot 是否真的是安装/铰链/支撑语义点。
- `+X` 正面/法线与 `+Z` 展开方向是否正确。
- 是否悬空、插地、穿墙、越过相邻 Cell 或遮挡通行。
- 材质、贴图密度、透明、双面和法线表现是否正常。
- 碰撞和导航策略是否符合用途。

## 14. 状态与批准门禁

| 状态 | 含义 | 是否可进入最终资产绑定 |
| --- | --- | --- |
| `discovered` | 已盘点，未分类 | 否 |
| `unclassified` | 无法确认用途 | 否 |
| `candidate` | 已分配候选 Marker | 否 |
| `rejected` | 不符合硬条件 | 否 |
| `needs_fix` | 可修复但尚未完成 | 否 |
| `screened` | 允许进入 Blender | 否 |
| `normalized` | Blender 处理完成 | 否 |
| `validation_failed` | 机械回读失败 | 否 |
| `mechanical_pass` | 机械检查通过 | 否 |
| `manual_review` | 等待语义/视觉确认 | 否 |
| `approved` | 机械与人工验收均通过 | 是 |

只有 `approved` 条目可以进入运行时 `asset_bindings` 或正式模型库。输出文件已经生成不代表已经批准。

## 15. 材质、碰撞与 LOD

### 材质

- 保留稳定材质槽名称和槽顺序。
- 记录每个槽的源材质和目标材质映射。
- 禁止依赖无法交付的绝对贴图路径。
- 透明、双面、顶点色或特殊 Shader 必须单独标注并在目标引擎复核。

### 碰撞

- 结构模型按 Profile 提供阻挡碰撞或由目标引擎生成碰撞。
- scatter 和纯装饰默认不影响导航，除非 Profile 明确允许。
- 源碰撞体只有符合命名、轴向和包络规则时才能保留。
- 门扇、楼梯和复杂结构必须在运行时交互场景复核。

### LOD

- 记录源 LOD 数量、切换策略和三角面数。
- LOD 必须保持相同 Pivot、轴向、材质槽语义和包络基准。
- 缺少 LOD 是否允许由目标 Profile 决定，不能由批处理脚本自行假设。

## 16. Profile 示例模板

### 16.1 资产包导入 Profile

```json
{
  "asset_set_id": "<stable_asset_set_id>",
  "asset_set_version": "<version>",
  "source_root": "<read_only_source_root>",
  "source_format": "<UnrealStaticMesh|FBX|GLTF|OBJ|BLEND>",
  "source_unit": "<cm|m>",
  "source_up_axis": "<X|Y|Z>",
  "source_forward_axis": "<+X|-X|+Y|-Y|+Z|-Z>",
  "source_handedness": "<left|right>",
  "import_preset": "<preset_id>",
  "classification_rules": [],
  "material_policy": "<copy|reference|rebuild>",
  "collision_policy": "<preserve|rebuild|strip>",
  "lod_policy": "<preserve|rebuild|optional>",
  "output_root": "<fixed_output_root>"
}
```

### 16.2 目标地牢 Profile

```json
{
  "profile_id": "<dungeon_profile_id>",
  "version": "<version>",
  "length_unit": "m",
  "cell_size_m": "<number>",
  "storey_height_m": "<number>",
  "walkable_clearance_m": "<number>",
  "corridor_clear_width_m": "<number>",
  "output_coordinate_system": {
    "right": "+X",
    "up": "+Y",
    "forward": "+Z",
    "handedness": "left"
  },
  "export_preset": "<fixed_export_preset_id>",
  "marker_profiles": {}
}
```

### 16.3 单资产记录

```json
{
  "asset_id": "<asset_set>__<marker>__<name>__<variant>",
  "source_path": "<source_path>",
  "target_marker": "<marker>",
  "subtype": "<subtype>",
  "usage": "<inherit|attach|prefab|scatter>",
  "pivot_rule": "<pivot_rule>",
  "pivot_note": "<semantic pivot description>",
  "pivot_position_m": [0, 0, 0],
  "x_axis_direction": "<explicit direction>",
  "y_axis_direction": "up",
  "z_axis_direction": "<explicit direction>",
  "normalization_uniform_scale": 1.0,
  "uniform_scale": true,
  "manual_review_required": true,
  "status": "screened"
}
```

## 17. 交付检查清单

- [ ] 已创建资产包导入 Profile，且没有把资产包路径/命名假设写死到通用规则。
- [ ] 已绑定明确版本的目标地牢 Profile。
- [ ] 源资产包保持只读。
- [ ] 每个候选条目都有 Marker、subtype 和 usage。
- [ ] 每个输出条目都有 Pivot、`+X`、`+Y`、`+Z` 标注。
- [ ] 所有尺寸调整都是 `[s,s,s]`，没有非等比拉伸。
- [ ] Blender Rotation/Scale 已应用，最终 Scale 为 `[1,1,1]`。
- [ ] Scatter Pivot 位于底部稳定支撑区域中心。
- [ ] 门扇铰链、楼梯起步端、墙面安装点和灯具发光点已按语义确认。
- [ ] 包围盒、通行净空、碰撞、材质、UV、法线和 LOD 满足 Marker Profile。
- [ ] 最终模型已回读并通过机械校验。
- [ ] 需要人工复核的资产没有被误标为 `approved`。
- [ ] 输出按 `<asset_set_id>/ByMarker/<Marker>` 分类。
- [ ] 模型、`.blend`、预览和目录表能通过 `asset_id` 一一反查。
- [ ] 只有 `approved` 资产进入运行时绑定或正式资产库。

## 18. 规范保证范围

当资产包 Profile、目标地牢 Profile、候选分类和人工语义复核都完整执行时，本规范可以保证输出资产满足统一的单位、尺寸记录、Pivot、轴向、等比缩放、命名、目录和机械回读要求。

本规范不能仅凭未知资产包的文件名保证视觉适配，也不能自动保证艺术风格、门铰链真实性、灯具发光点、墙面正面或复杂安装关系。此类结论必须通过 Marker 校准场景和人工签收获得。
