# FantasyDungeon 资产包导出执行报告

> 本文件是一次具体资产包的执行记录，不属于通用资产规范。通用规范见 `ASSET_SPEC.md`。

## 执行范围

| 项目 | 值 |
| --- | --- |
| 资产包 ID | `FantasyDungeon` |
| 源资产（只读） | `D:\SUMIT\ProjectCity\Content\FantasyDungeon` |
| Unreal 逻辑根目录 | `/Game/FantasyDungeon/meshes` |
| 输出根目录 | `D:\SUMIT\ProjectCity\Exports\FantasyDungeonByMarker` |
| Unreal | `5.8` |
| Blender | `5.1.2` |
| 最终格式 | FBX 二进制 |
| Blender 工作 Up | `+Z` |
| 目标 Up | `+Y` |
| FBX 预设 | `axis_forward = Z`、`axis_up = Y` |

## 执行结果

- 扫描 `StaticMesh`：280 个。
- Marker/用途筛选通过：203 个。
- 筛选拒绝：77 个。
- 最终输出：203 个 FBX、203 个 `.blend`。
- Blender 空场景回读：203/203 通过。
- 非等比缩放：0。
- Scatter 底部支撑中心异常：0。
- 导出失败或回读失败：0。

| Marker | 数量 |
| --- | ---: |
| `Ground` | 15 |
| `Wall` | 34 |
| `Door` | 20 |
| `WallSeparator` | 13 |
| `Stair` | 51 |
| `Ceil` | 23 |
| `PillarPlacement` | 2 |
| `PillarWebPlacement` | 10 |
| `Curbstone01Placement` | 6 |
| `Light` | 16 |
| `GroundScatterSurface` | 13 |
| **合计** | **203** |

## 特殊处理

- 13 个 `Door` 文件夹或 `JailDoor` 资产绕 Blender `Z` 轴旋转 `-90°` 并应用旋转，使最终局部 `+X` 为门洞法线、局部 `+Z` 为门宽。
- 16 个资产执行了等比尺寸归一化：`rock02-03`、4 个超限柱体和 `SpiderWeb01-10`。
- 13 个 scatter 资产使用最低支撑带投影凸包的面积中心作为 Pivot。
- 101 个资产保留人工签收：16 个灯具发光点、10 个蛛网挂点、42 个楼梯附属件、33 个墙面附属件。

## 产物

```text
D:\SUMIT\ProjectCity\Exports\FantasyDungeonByMarker\
  catalog\
    unreal_inventory.json
    asset_catalog.json
    asset_catalog.csv
    blender_validation_report.json
  intermediate_fbx\
  ByMarker\<Marker>\
    Models\
    Blender\
```

执行脚本：

- `scripts/Tools/PCGDungeonAssetPipeline/unreal_export_fbx.py`
- `scripts/Tools/PCGDungeonAssetPipeline/blender_normalize_export.py`

最终清单 `asset_catalog.json` 是本次资产 Pivot、轴向、尺寸、缩放、输出路径和复核状态的权威记录。
