# 氛围系统设计（Atmosphere System）

> 状态：v1 已落地。首个氛围预设「幽邃地牢」随遗迹（dungeon）题材默认启用。

## 1. 目标

给场景一个可命名、可复用、可切换的**情绪层**：同一套布局、同一套配色，可以是"幽暗压迫的地牢"，也可以是"中性的展示厅"。氛围回答的问题是**画面感觉如何**（多暗、雾多浓、火光怎么跳、四角压不压），而不是**画面是什么颜色**、**哪里摆什么东西**。

## 2. 三轴拆分

项目里"氛围"一词此前散落在三处。本系统不推翻它们，而是补齐缺失的第三轴，并给三轴明确分工：

| 轴 | 回答的问题 | 归属模块 | 分类 |
|---|---|---|---|
| 色相 hue | 雾/天空/火光/粒子是什么颜色 | `Themes` / `PaletteData`（配色） | 已有 |
| 摆放策略 placement | 哪些房间跑哪些动态效果 | `EnvironmentProfiles.<setting>.atmosphere`（含体积雾配置） | 已有 |
| **情绪包络 mood** | 多暗、雾多浓、火光怎么动、暗角多重 | **`Config/AtmosphereProfiles`（本系统新增）** | 新增 |

关键约束：**氛围预设完全不携带色相**。所有缩放都是对配色提供的基础值做乘法调制，因此：

- 不与配色系统打架——换配色，氛围自动跟随新色相；
- 不违反"结构中性灰 + 顶点贴色"规则——氛围永远不会成为第二个颜色来源；
- 自定义/AI 配色克隆基础色调时（`PaletteData.CreateRuntimeTheme` 深拷贝），氛围行为自动继承。

## 3. 预设 Schema

```lua
dungeonDepths = {
    key = "dungeonDepths", label = "幽邃地牢",
    lighting = {
        ambientScale = 0.90,     -- 环境光强度 ×（zone.ambientIntensity）
        sunScale = 0.82,         -- 直射光亮度 ×（sun.brightness）
        fogDensityScale = 1.30,  -- 深度雾密度 ×；题材开启体积雾时同样喂给 froxel 密度
    },
    post = { vignette = 1.6 },   -- 暗角强度；0 = 关闭
    torch = {
        scale = 1.12,            -- 火把/楼梯火光亮度 ×
        flicker = {              -- 闪烁包络：base + sinA*ampA + sinB*ampB
            base = 0.86, ampA = 0.10, speedA = 6.9,
            ampB = 0.04, speedB = 12.7, phaseScale = 0.37,
        },
    },
}
```

约定：闪烁包络峰值（base + ampA + ampB）≈ 1.0，使"配色声明的火光亮度"始终等于最亮瞬间；谷值 ≥ 0.6 防频闪。

## 4. 解析顺序

```text
配色 theme.atmosphereKey（配色级覆盖，可选）
  > AtmosphereProfiles.DEFAULTS[settingKey]（题材默认）
    > neutral（中性兜底）
```

- **中性预设是严格恒等**：缩放全为 1、暗角为 0、闪烁包络等于渲染器历史硬编码常数（0.90 / 0.07·7.3 / 0.03·13.1）。未创作氛围的题材（当前：神殿、医院、学校）画面逐帧不变。
- 神殿的情绪目前由其配色（bloom、fx、emissiveScale）与体积雾承担，保持中性；未来可以为它创作专属预设，把这些散点收进来。

## 5. 首个氛围：幽邃地牢（dungeonDepths）

设计意图：经典地牢的四件套——**黑暗压迫、薄雾封闭、火光摇曳、尘埃浮动**。

| 手段 | 数值 | 理由 |
|---|---|---|
| 压暗基础光 | ambient ×0.90、sun ×0.82 | 让未被火光覆盖的角落沉下去，直射"月光"退居次要 |
| 增稠深度雾 | fogDensity ×1.30 | 远端更快融入雾色，制造封闭感；雾色仍来自配色 |
| 轻暗角 | vignette 1.6 | 四角压暗一档（引擎默认量级为 1.0），镜头感而不抢画面 |
| 火光回补 | torch ×1.12 + 更深闪烁（0.72~1.0） | 暖光池对比冷暗底，平均亮度大致回到验收带内 |
| 尘埃层 | `EnvironmentProfiles.dungeon.atmosphere`：粒子 200/层、360 总量 + 呼吸 0.94~1.06 | 首次为遗迹开启动态氛围层；五套遗迹配色自带的粒子数据（尘/烬/雪/魂/萤）由此生效 |

明确不做的：神迹光柱、符文法阵、传送门、悬浮水晶、体积雾——这些是神殿的招牌（题材数据），普通遗迹保持克制；测试断言防止回流。

有效值抽查（ambient / sun / fogDensity）：

| 配色 | 基础 | 幽邃地牢生效值 |
|---|---|---|
| ancient | 0.55 / 0.85 / 0.0021 | 0.495 / 0.697 / 0.00273 |
| grim（最暗） | 0.52 / 0.45 / 0.0030 | 0.468 / 0.369 / 0.00390 |
| verdant | 0.60 / 0.80 / 0.0023 | 0.540 / 0.656 / 0.00299 |

## 6. 校验与验收

- `AtmosphereProfiles.Validate()`：环境光/直射光缩放 0.6~1.4、雾密度缩放 0.5~2.0、暗角 0~4、火光缩放 0.7~1.4、闪烁峰值 0.95~1.05 且谷值 ≥ 0.6、中性恒等不漂移、默认映射引用存在的预设。
- `GenerationTests` 新套件 `atmosphere mood presets`：解析链、恒等性、五套遗迹配色的有效值下限（ambient ≥ 0.40、sun ≥ 0.30）、闪烁深度关系。
- 最终裁决仍是 §2.10 的**最终渲染画面**验收（平均亮度 0.12~0.82、压黑 ≤8%、过曝 ≤3%）；配置校验只是把明显越界挡在数据层。

## 7. 接入点（v1 全部落地）

| 位置 | 消费内容 |
|---|---|
| `DungeonApp:ApplyTheme` | `ComputeLighting` → zone.fogDensity / ambientIntensity / vignette、sun.brightness；体积雾密度同样乘 `fogDensityScale` |
| `NativeDungeonRenderer:Build` | `Resolve` 缓存 mood；火把灯与楼梯灯亮度 × `TorchScale` |
| `NativeDungeonRenderer:Update` | `FlickerEnvelope` 驱动所有闪烁点光（中性 = 历史常数） |
| `EnvironmentProfiles.dungeon.atmosphere` | 尘埃粒子 + 呼吸兜底，AtmosphereFX 据此为遗迹构建粒子场 |

与体积雾的关系：体积雾是**摆放/介质轴**上的题材数据（`atmosphere.volumetricFog`，当前神殿专属），氛围预设是**强度轴**；二者正交。题材开启体积雾时，氛围的 `fogDensityScale` 作用于 froxel 密度而非深度雾。

## 8. 后续路线（未实现，按需排期）

1. **更多预设**：神殿"神辉圣所"（收编 bloom/emissive 散点）、医院"无影冷寂"、学校"午后课堂"；以及跨题材可复用的默认氛围（对齐配色的"默认/题材"两分法）。
2. **面板选择**：氛围下拉与配色面板同级，实时预览 + 保存/丢弃语义与配色一致。
3. **自定义/AI 氛围**：schema 已可序列化，走 `CustomizationStore` 与 `PaletteAIProvider` 同款管线。
4. **氛围过渡**：切换时对缩放值做 0.5~1s 插值，避免硬切。
5. **配色级覆盖的数据入口**：`theme.atmosphereKey` 解析已支持，缺 UI 与持久化字段。
