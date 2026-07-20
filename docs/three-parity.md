# Three.js → UrhoX 程序化地牢复刻说明

基线：`D:/Maker/PCG/threejs-procedural-dungeon/src/main.js`

本轮最终核对版本 SHA-256：`D9FF2B6640720CF0807A500E04ED167BFB8ADAC54C7F07F7F2235B62F50FE718`。
该文件在本轮工作期间被外部更新过，因此此哈希用于明确本次复刻针对的版本。

## API 对照

| Three.js | UrhoX Lua | 迁移规则 |
|---|---|---|
| `BoxGeometry` / `CylinderGeometry` / `TorusGeometry` 等 | `procedural-geometry.md` 全局同名 API | 参数顺序和默认值与 Three.js 一致；参数化形体由引擎处理坐标系 |
| `BufferGeometry` 合并 | `FillCustomGeometry` + `GeometryBridge.Merge` | 只通过文档公开接口取得原生几何，不读取 `geometry.attributes` |
| `InstancedMesh` + `setColorAt` | `CustomGeometry` 顶点色批次 | 保留每格/每实例颜色，同时按顶点上限自动分块 |
| `MeshStandardMaterial` | UrhoX 原生 `Material` + `PBRDiffVCol` | `roughness`、`metalness` 和顶点色映射到原生材质参数 |
| `MeshBasicMaterial` | UrhoX 原生无光照顶点色材质 | 用于火焰、徽记、标线等不受光照颜色 |
| `CanvasTexture` | 当前为程序化 PBR/顶点色 | 颜色和几何一致；Three 的石材/医院 Canvas 细纹未生成独立贴图 |
| `ShaderMaterial` 液体/粒子 | UrhoX PBR/透明无光材质 | 静态形状与色板已迁移；Three 的 FBM 动态液体和 GPU 粒子需要单独 Shader Technique 才能逐像素一致 |
| JS 数组 0 起始 | Lua table 1 起始 | 房间 id、边索引和网格索引统一在边界处转换 |
| `Math.imul` Mulberry32 | Lua 5.4 位运算 | 保持 32 位截断，随机序列一致 |

## 已对齐的生成契约

- Mulberry32 随机数、房间尺度/散布、6 米房间间距。
- Delaunay 输出顺序、Prim MST、回环长度限制、至少 3 个叶房的回环裁剪。
- Boss/入口选择、BFS 深度、关键路径、宝藏/神龛/精英语义分配。
- 锁定房间分离、5 格回基边距、格子中心 `+0.5` 世界坐标。
- A* 走廊、关键路径宽度、每条走廊两个权威门框、多层楼梯空间保留。
- 熔岩/水/瘴气池、冰湖、墓园、冰柱、树根/苔藓、骨骸、裂纹与医院道具规则。

## 已对齐的模型与渲染契约

- Three 当前运行时使用的 77 个 `GEO.*`：Lua 几何库覆盖 77/77。
- 地板、医院地板、墙体高度扰动、墙帽和逐格颜色规则。
- 全套地牢与医院组合道具，包括床、推车、MRI、手术灯、门框、入口环、Boss 晶体、火盆、出生标记等。
- 所有基础/复杂形体由 `procedural-geometry.md` 列出的 `ConvexGeometry`、`LoftGeometry`、`ShapeGeometry`、`TubeGeometry` 等生成；平面倒角使用点云凸包避免圆角平滑法线，`CustomGeometry` 仅承担实例合批，不再手写形体顶点。
- 视觉地砖继续保留 Three 的 0.96/0.98 米尺寸、倒角和高度扰动；下方增加恒高 1.006 米封缝层，以 3mm 边界重叠消除透底，同时不改变表层砖缝风格。
- Three 顶点色实例改为 UrhoX `CustomGeometry` 顶点色批次，避免旧实现把所有实例压成单一颜色。
- 主题雾色、环境渐变、太阳颜色/强度、HDR 和点光源参数按 Three 色板驱动。

## 验收

- Lua LSP：本轮修改文件 0 errors。
- 纯数据测试：8/8 套件通过，含 20 组多层种子、六层楼梯回归、医院覆盖和 Three 主题契约。
- 自动几何审计：Three active GEO 77，Lua defined GEO 78（唯一额外项是 UrhoX 液体单元面），缺失 0。
- 本机 UrhoXEditor/UrhoXRuntime：`main.lua` 重启后保持运行；按用户要求不进行 Maker 远程提交或预览。

## 像素级差异边界

UrhoX 的 Three 兼容层明确不支持 `toneMappingExposure`，而原版还使用 CanvasTexture、FBM 液体 Shader、GPU 粒子和分阶段实例显现动画。这些不是模型 API 的参数差异，不能只靠 Geometry 替换得到逐像素一致。当前版本已对齐最终静态布局、几何、实例色与灯光语义；若验收目标包含动态液体、粒子和构建动画，需要继续把三类 GLSL/动画移植成 UrhoX Technique 与运行时更新逻辑。
