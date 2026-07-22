# Maker Procedural Dungeon 2.0

基于 UrhoX Lua 的程序化多层地牢生成与编辑项目。当前稳定版本位于
`stable-2.0` 分支，主运行项目位于 `wuzhong/`。

## 主要功能

- 多层房间、走廊、楼梯和回环路径生成
- 2D 平面编辑、3D 编辑与第一人称预览
- AI 题材和固定规则 PCG 题材
- 暗影古堡固定题材
  - 运行时生成房间拓扑和 A* 楼梯路径
  - 将拓扑转换为 Marker 点与面
  - 通过 `mesh_info` 映射模型、材质、散布规则和点光源
  - 支持门交互、第一人称检查和动态刷新
- 本地自定义题材、房间组与配色管理

## 运行环境

- UrhoX Runtime
- Lua 5.4
- Windows PowerShell 或 CMD
- 项目长度单位为米；`mesh_info` 中继承自 Houdini/UE 的偏移使用厘米

## 启动

1. 检查 [wuzhong/start-offline.cmd](wuzhong/start-offline.cmd) 中的
   `URHOX_RUNTIME` 和资源包路径。
2. 在仓库根目录运行：

```powershell
.\wuzhong\start-offline.cmd
```

默认入口为 `wuzhong/scripts/main.lua`，使用 deferred rendering pipeline。

## 暗影古堡流程

在题材面板中展开“固定规则”，选择“暗影古堡”。应用层执行：

```text
ShadowCastleGenerator
  -> HoudiniMarkerPipeline
  -> HoudiniMeshInfoAdapter
  -> BgeoDungeonRenderer
```

调整颜色或点击“刷新地牢”会基于最新拓扑重新构建模型、门和 Marker 点光源。
内部的 Houdini 验证、方块调试、灯光调试和生成参数不在正式 UI 中显示，
底层接口及测试仍然保留。

## 关键配置

### 固定题材

文件：`wuzhong/scripts/Config/FixedThemes.lua`

暗影古堡可配置种子、层数、每层房间数量、房间尺寸、回环率、装饰密度和环境光。

### 模型与灯光

文件：`wuzhong/assets/BgeoDungeon/DungeonInstances.mesh_info.json`

该清单控制：

- Unreal/Houdini 资源到 UrhoX Model/Material 的映射
- prefab 组合、附加模型和确定性散布
- Marker 点光源的颜色、亮度、范围、偏移和阴影参数
- 诊断几何资源

当前 Marker 点光源基准：

- 所有 Marker 灯亮度为 `0.3 Unitless`
- 所有 Marker 灯开启投射阴影
- 火盆灯垂直偏移 `155cm`
- 其他 Marker 灯垂直偏移 `50cm`
- 超薄墙体场景使用低 Shadow Bias，减少穿墙漏光

## 目录结构

```text
wuzhong/
  assets/BgeoDungeon/   BGEO、Marker fixture、mesh_info 和灯光清单
  Materials/            UrhoX 材质
  Models/               古堡模型
  Textures/             纹理资源
  scripts/App/          应用流程
  scripts/Generation/   地牢、A*、Marker 和坐标转换
  scripts/Rendering/    原生与 BGEO 渲染器
  scripts/UI/           控制面板和编辑器 UI
  scripts/test_*.lua    运行时回归测试
```

## 验证

测试脚本通过 UrhoXRuntime 启动，参数与 `start-offline.cmd` 一致，只需将
`main.lua` 替换为对应测试脚本：

- `test_houdini_shadow_castle.lua`：拓扑、Marker、模型、灯光、刷新和调试状态
- `test_shadow_castle_lighting.lua`：环境光、Marker 点光和题材切换
- `test_shadow_castle_light_parity.lua`：灯光清单与 UrhoX Light 映射
- `test_theme_pack_ui_flow.lua`：题材、颜色、古堡切换和正式 UI

成功时运行时会输出对应的 `PASS` 信息。

## Stable 2.0 变更

- 引入暗影古堡运行时生成与 BGEO/Marker 渲染流程
- 修复固定题材、颜色切换和第一人称预览之间的场景重建问题
- 修复刷新后 Marker 点光源未同步的问题
- 按 UrhoX Light 参数映射 `mesh_info`，统一亮度、阴影和体积雾配置
- 针对 2mm 超薄墙体降低点光 Shadow Bias，减少漏光
- 预加载古堡模型与材质，避免首次显示白模
- 压缩主要古堡纹理，降低仓库和运行资源体积
- 隐藏内部 Houdini/调试 UI，保留正式的地牢刷新入口
