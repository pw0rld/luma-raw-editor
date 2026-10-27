# Luma RAW 同类产品调研

调研日期：2026-10-25。对照版本：Luma RAW 0.4.0，提交 `df60bb7`。

## 结论

有直接同行，而且既有成熟的跨平台编辑器，也有技术栈与我们接近的原生 Mac 开源项目。本次样本中，MorrowRAW 与我们的技术路线和功能组合最接近；RapidRAW 是跨平台与完整照片工作流的重要参考；Photomator、Nitro 是原生 Mac 产品体验的参考；Capture One Match Look 是参考图追色工作流的重要参考。

“开源、离线、原生 Mac、无损 RAW 编辑、参考图追色”这些属性分别已有同行具备。我们可以继续围绕“简单、可控的参考图追色”形成产品特色，但目前还不能证明匹配质量或使用效率优于同行。

## 调研方法与证据边界

- 核对本地 README、DEVELOPMENT_STATUS 和当前实现说明；外部信息来自官方仓库、官网和官方手册。
- 竞品的功能描述代表其公开文档所述能力。本轮没有下载、编译或运行竞品，没有做画质、速度、内存或稳定性排名。
- 新项目的 README 功能列表不能直接证明成熟度；计划中的平台也不能当作已发布平台。
- 本文为代表性样本调研，不是完整市场清单。未核实的功能标为“未确认”，不能由此推断产品没有该功能。
- 本轮不比较价格、装机量或市场份额，也不用 GitHub star 数判断画质。

## 最接近我们的开源项目

| 项目 | 官方资料所述能力 | 与 Luma RAW 的关系 | 值得研究的部分 |
| --- | --- | --- | --- |
| [MorrowRAW](https://github.com/liminghuang/MorrowRAW) | 原生 macOS，SwiftUI / Core Image / Metal；无损编辑、参考图匹配、渐变及语义蒙版、批量编辑导出 | 本次样本中技术栈与功能组合重合度很高；依赖 Apple RAW 解码器 | 追色交互、直方图及示波器、预览调度、批处理；需进一步实测 |
| [Chiaro](https://github.com/arjunphull123/chiaro) | SwiftUI、CIRAWFilter、Metal；局部蒙版、sidecar、内置 MCP 接口 | 与我们共享系统 RAW 路线，另以外部 agent 控制编辑为特色 | 统一参数模型、可撤销的自动操作、蒙版亮度范围；不要将 agent 调色等同于独立追色算法 |
| [OpenStill](https://github.com/haon-v2/OpenStill) | 原生 Mac 浏览与无损编辑、图库、批处理、Core Image GPU 渲染和缓存 | 面向更完整的照片管理工作流，功能范围明显更大 | 缓存、滑动时低开销预览、100% 查看、缩放平移、复制调整；参考视图本身不等于自动追色 |
| [Redlamp](https://github.com/pdcgomes/redlamp) | Mac 优先；Swift / Metal，自建 RAW 处理管线，LibRaw 解包；配方与局部编辑 | 属于相邻的原生开源路线，底层显影自主程度更高；iPad/iPhone 在其文档中仍属后续阶段 | 参数规范、相机测试、配方版本、引擎与 UI 边界；不能将它视为我们当前系统解码方案的直接替换 |
| [RapidRAW](https://github.com/CyberTimon/RapidRAW) | Rust / Tauri / WGPU，Windows/macOS/Linux 等平台；无损 sidecar、蒙版、LUT、图库与批量工作流 | 对“轻量、现代、跨平台 RAW 编辑器”定位有直接重合 | Windows 技术路线、导出队列、选片、批量套用；本轮未确认与我们完全等价的参考图自动追色入口 |

上述项目都值得跟进，但本次没有验证其各项功能的完成质量。尤其不能仅凭新项目的功能列表断言其渲染质量、兼容性或可靠性超过 Luma RAW。

## 成熟开源产品

| 项目 | 官方资料依据 | 与我们相关的能力 | 对我们的启示 |
| --- | --- | --- | --- |
| darktable | [项目介绍](https://www.darktable.org/about/)、[color mapping 手册](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/color-mapping/) | 完整 RAW 工作流；已有按颜色分簇与统计进行图像间颜色映射的模块 | 我们目前追色的算法思路已有先例。更易理解的交互和真实照片上的效果仍可改进 |
| RawTherapee | [官方功能文档](https://rawpedia.pixls.us/features/) | 浮点处理、DCP/ICC、PP3 配方、导出队列、镜头校正、CLI | 显影质量、颜色管理、输出与兼容性是基本功；应用预设或复制参数不能直接等同于参考图追色 |
| ART | [官网](https://artraweditor.github.io/) | 源自 RawTherapee，强调简化界面；绘制与参数蒙版、XMP、LibRaw、LUT/HDR 工具 | “功能适度收敛、界面简单”本身已有同行尝试；我们需要更具体的目标用户与任务 |
| vkdt | [官方文档](https://jo.dreggn.org/vkdt/readme.html) | Vulkan / GLSL GPU 管线、节点图、RAW 静态及视频工作流 | 可以研究 GPU 图像处理架构；其工作流范围与我们差异较大，优先级低于直接竞品 |

darktable 的 color mapping 与 color calibration 中的 area color mapping 也应区分：前者是图像间颜色分布迁移；后者可用指定区域的目标颜色帮助统一系列照片的色度。[官方 area color mapping 说明](https://darktable-org.github.io/dtdocs/en/module-reference/processing-modules/color-calibration/)

## 商业软件的直接参考

| 产品 | 已核实的相关能力 | 适合参考的方向 |
| --- | --- | --- |
| [Photomator](https://www.pixelmator.com/photomator/) | 原生 Apple 平台、RAW、画笔/径向/线性与自动选区、批量操作；[官方文档明确有 ML Match Colors](https://support.pixelmator.com/v/photomator-user-guide/get-started/document-settings) | 原生交互、快速追色入口、局部调整和导出衔接 |
| [Nitro](https://www.gentlemencoders.com/nitro/user-manual/index.html) | Apple RAW 引擎及额外相机支持；文件夹/Photos 浏览、无损调整、画笔/渐变与颜色/亮度范围 | 相机兼容、照片工作流、范围蒙版；本轮未确认等价自动追色功能 |
| [Capture One Match Look](https://support.captureone.com/hc/en-us/articles/22188770298269-Match-Look-Tool) | 从参考图生成可继续调整的结果；明暗、色彩等分组可选；强度、批量应用、保存预设及新图层应用 | 追色之后如何继续编辑，以及如何让一组照片保持一致 |
| [Lightroom Classic Reference View](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/develop-module-tools.html) | 并排显示参考图与当前照片，供调整与视觉匹配 | 对比、放大、读色及照片切换；不能把 Reference View 本身描述成一键追色 |

Capture One 的实现尤其值得借鉴：它将匹配结果落实到已有调色工具中，用户能够继续调整。我们当前保存的是统计颜色映射，尚没有将其转换为普通曲线、HSL 或色轮参数的能力。两种方法都能保留编辑结果，但后续微调方式不同，不能只比较是否有“一键追色”按钮。

## Luma RAW 0.4.0 的实际位置

当前项目已形成从导入、基础调整、参考图追色、裁剪、几何蒙版到配方和导出的闭环。颜色与明暗匹配分别控制、配方携带追色统计、离线执行，这些是可继续打磨的基础。

与上述产品相比，影响日常使用的主要缺口是：

1. **查看能力。** 缺少 100% 查看、缩放平移、直方图与高光/暗部溢出提示，用户难以核对细节和颜色是否受损。
2. **照片工作流。** 文件夹导入尚未形成批量套用、批量导出、选片与缓存的完整流程。能导入多张不代表已有批量处理。
3. **追色可控性。** 当前是全图颜色分布匹配，缺少独立的分析选区、追色作用蒙版、肤色保护与颜色对应关系编辑。
4. **局部调整。** 当前只有径向与有范围的线性蒙版，尚无画笔/橡皮擦、颜色/亮度范围和蒙版组合。
5. **真实照片验证。** 尚缺跨相机真实 RAW 的画质评估与大像素性能基准。0.4.0 完整像素回归在本机受 Core Image 渲染环境阻断；本次调研未核实最新 CI 结果。

当前局部蒙版调整发生在追色之前。它能修正某区域的基础颜色和曝光，不能直接实现“只给背景追色，人物保持原来颜色”。要实现后者，需要明确区分：

- **分析选区**：从源图/参考图的哪些区域统计颜色。
- **作用蒙版**：追色映射最终作用在哪些像素上。
- **保护范围**：哪些肤色、亮度或颜色应降低追色强度。

## 建议的产品定位与优先级

建议定位：**面向希望快速接近参考照片色调的 Mac 用户，提供离线、简单、可控的 RAW 调色流程。**

这是待验证的产品方向，尚不是已证明的市场优势。可以先围绕一个明确任务验收：打开一组照片，选一张参考图，得到自然的初稿，保护人物肤色，逐张微调并统一导出。

| 优先级 | 建议工作 | 验收目标 |
| --- | --- | --- |
| P0 | 补齐真实 RAW、像素回归和预览/导出一致性验证 | 旋转/裁剪/蒙版组合无错位；导出结果可重现；列出已测相机与系统 |
| P1 | 缩放平移、100% 查看、直方图与溢出提示 | 用户能检查人脸、纹理、噪声与高光，而非只看缩略预览 |
| P1 | 批量套用与导出队列 | 可选择复制哪些调整；保留每张照片独立曝光/裁剪；可取消并列出失败项 |
| P2 | 追色分析选区、作用蒙版、肤色保护 | 可以明确表达“匹配背景、保留人物”，并检查实际覆盖范围 |
| P2 | 色簇可视化与可调对应、更多后续调色工具 | 用户知道哪些颜色被映射，遇到不自然结果可以修正 |
| P3 | 主体/天空自动蒙版、预设分享、Windows 后端 | 在基础体验与目标用户验证后，再按实际需求投入 |

这些阶段不代表新功能已获实现或发布时间承诺。分析选区与作用蒙版可以先使用手动工具，不必等复杂语义模型。

## Windows 的含义

RapidRAW 已提供跨平台实现，说明这类产品可以在 Windows 上完成。我们当前的 SwiftUI 界面、CIRAWFilter 解码和 Core Image 渲染依赖 Apple 平台，现有工程不能直接编译成 Windows 应用。

如果 Windows 成为明确目标，需要单独选择跨平台 UI、RAW 解码、GPU 渲染和颜色管理方案。可以保留配方设计与算法思路，并为两个后端建立共同的测试素材；同时要处理不同 RAW 解码器导致的成像差异。RapidRAW 的 Rust/Tauri/WGPU 路线值得评估，但本次调研不足以认定必须迁移。

## 下一次实测建议

先选 MorrowRAW、RapidRAW、darktable、Photomator、Capture One 五个对象，用同一组经授权的真实照片和参考图比较：

- 同场景不同曝光、人像不同背景、风景绿植、室内混合光、夜景。
- 默认匹配与人工微调后的肤色自然度、高光/阴影、饱和色、灰阶和局部边界。
- 达到可接受结果所需操作与时间；记录算法不适用的样例。
- 首次打开、再次打开、滑块响应、批量导出耗时与峰值内存。
- 保存配方、重启恢复、丢失参考图、跨版本打开和导出一致性。

对不同场景的创意追色，不能直接把整图平均像素误差当作美观分数。色卡或同场景一致性可补充客观测量，跨内容风格迁移仍需人工评价。

最值得优先深入的三个方向：MorrowRAW 的相近实现、RapidRAW 的跨平台与工作流、Capture One 的可继续编辑的追色结果。它们分别回答“与我们有多像”“如何扩展到日常照片处理”“追色怎样更可控”。
