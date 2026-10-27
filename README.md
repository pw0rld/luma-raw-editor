# Luma RAW · Local-first RAW 照片编辑器

文档入口：[开发进度](DEVELOPMENT_STATUS.md) · [下一阶段计划](ROADMAP.md) · [同行调研](COMPETITOR_RESEARCH.md)。

本地开发进展（2026-10-27）：已加入原始分辨率细节查看。点击画布上方「100%」后，一个照片像素对应一个屏幕物理像素；菜单提供 50% / 100% / 200%，也可用按钮或捏合连续缩放。画布会先显示底图，再逐块补上当前视口的细节，底栏显示加载进度；完成后显示「原始细节」。适合窗口且底图已足够清晰时，不额外触发全分辨率解码。0.5 的直方图与溢出提示尚未实现，整版尚未发布。

浏览模式直接拖动平移，裁剪/蒙版模式按住空格拖动平移，也可滚动平移、⌘＋滚轮缩放。浏览模式双击或触控板双指轻点在 100% 与适合窗口间切换。照片、裁剪框和蒙版共用坐标变换，手柄保持固定大小。查看操作不修改配方或调色撤销记录；切图、切工具、旋转或切换原片比较时恢复适合窗口。

项目名：**Luma RAW**。建议 GitHub 仓库名：`luma-raw-editor`。图标源文件位于 `Art/AppIcon.png`，构建脚本会生成 `AppIcon.icns` 并写入应用包；`.github/workflows/macos.yml` 会在 GitHub Actions 上运行构建检查，`.github/workflows/release.yml` 会在推送 `v*` 标签时构建并创建 macOS Release。完整开发进度见 [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md)。

这是已实际编译、启动并验证的 SwiftUI 原生应用，不是界面设计稿。支持 macOS 13+；随附应用为本机编译的 Apple Silicon / arm64 版本，Intel Mac 可从源码重新构建。无第三方运行依赖。

## 启动与试用

双击本目录的 **Luma RAW.app**，或在终端运行：

```bash
open "Luma RAW.app"
```

1. 点击「添加文件夹」一次载入文件夹中的照片，默认包含子文件夹，可通过「包含子文件夹」开关更改。也可继续用「导入」添加单张图片。左侧列表按文件名自然排序（如 image2 在 image10 前），重复添加不会重复列出同一路径；隐藏文件、应用包和非图片文件会被忽略。
   点击左侧照片切换编辑，按需读取当前原片，不会一次解码整个文件夹。切换时保留各张照片的调整及撤销/重做记录；橙点表示尚未保存为独立配方。编辑停止约 700 ms 后自动写入本地草稿，启动时恢复列表、调整和历史；仍可分别保存 JSON 配方用于备份或迁移。
2. 可选：点击工具栏「参考图」导入希望接近其颜色的照片（RAW 或普通图片），窗口会并排显示参考图和当前照片。在右侧「参考图追色」点击「一键追色」，再调整「颜色强度」「明暗匹配」「颜色占比权重」。默认只应用 75% 的颜色匹配，不改变明暗；明暗可单独加到需要的程度。「颜色分组」支持 1–5，默认 3；更换分组后重新点击一键追色。更换参考图只改变左侧参考预览，点击一键追色后才替换当前编辑。
3. 调整色温、色调、曝光、饱和度、三点色调曲线。在底栏切换到「裁剪」后拖动裁剪框和四角；切回「浏览」检查最终成片，右侧「重置裁剪框」恢复整张照片。下面还有 90° 旋转和导出选项。追色分析使用当前基础调整；重新追色会先排除旧匹配，避免多次点击叠加偏色。
4. 在右侧「蒙版」点击「新建」，选择「径向蒙版」或「线性蒙版」。蒙版框可以在画布上拖动，四角可调整范围；线性蒙版还可以调整渐变方向，作用框保持固定；覆盖色来自实际渲染权重。选中蒙版后调整局部曝光、色温、色调、饱和度、强度和羽化，也可以反向或停用。蒙版随配方保存，并参与预览、撤销/重做和导出。
5. 「查看原片」显示原始显影；再次切换回调整后。原片比较包含未裁剪、未旋转的完整构图，也不包含追色。「移除」可去掉追色，同时保留其他调整；操作支持撤销/重做。
6. 「保存配方」写入独立 `.luma.json` 文件。恢复时先导入同一原片，再点击工具栏下载文档图标或菜单「恢复配方」。原片可移动或改名，SHA-256 相同即可匹配。追色和蒙版结果完整嵌入配方，恢复与导出无需再次找到参考图。文件夹中每张照片分别保存匹配、蒙版和历史；已载入的参考图可继续用于其他照片。
7. 选择 JPEG（8 bit）或 TIFF（16 bit），点击「导出」。输出嵌入 sRGB 配置；GPS 默认不保留，可单独开启。

快捷键：⌥⌘O 添加文件夹，⌘O 导入，⌥⌘R 导入参考图，⇧⌘M 一键追色，⌘S 保存配方，⇧⌘O 恢复配方，⇧⌘E 导出，⌘Z 撤销，⇧⌘Z 重做，反斜杠 `\` 切换前后对比。滑块拖动合并为一次撤销操作；最多保留 100 步。切换照片保留调整；正常退出会等待草稿原子写入。草稿保存在 `~/Library/Application Support/Luma RAW/Drafts/workspace.json`；写入失败时状态栏会提示，退出时询问未保存的编辑。崩溃恢复仅能恢复最近已写入的草稿。导出不等同于保存独立配方。

本地应用为 ad-hoc 签名、未公证的开发原型；没有自动更新或网络请求。复制给其他机器后可能需要通过系统安全设置确认打开。

## 测试素材

- `Samples/orientation-test.jpg`：80×40 像素、EXIF 方向 6 的人造测试图，正确显示为 40×80。
- `Samples/orientation-test.luma.json`：该 JPEG 的测试配方。
- `Samples/expected-edited.tiff`：恢复上述配方后对应的 64×32、16 位 TIFF 输出。
- `Samples/synthetic-bayer.dng`：1024×768 的合成 Bayer DNG，用于验证 CIRAWFilter 路径；其颜色梯度不是实际摄影作品，也不代表相机色彩准确度。
- `Samples/match-source.png`、`Samples/match-reference.png`：180×120 的人造颜色分布，用于追色闭环；`match-result.tiff` 与 `match-source.luma.json` 是其导出及配方示例。构建检查会生成这些文件。
- `folder-ui-smoke.png`：加入文件夹后的原生窗口截图。
- `ui-smoke.png`：应用真实窗口导入 DNG 后的程序内截图。
- `match-ui-smoke.png`、`match-raw-ui-smoke.png`：普通图片和 DNG 的参考图追色真实窗口截图。

## 构建

需要 macOS SDK 和 Swift 6 工具链；不需要安装大型第三方库。正常环境下：

```bash
bash scripts/build.sh --check
```

脚本用 `xcrun swiftc` 构建核心动态库和 SwiftUI 应用、打包 `.app` 并执行测试。同一组测试可在完整 Xcode 环境下用 `swift test` 运行；也提供标准 `Package.swift`，可用 Xcode 打开或运行 `swift build`。

测试时指定 RAW 样片可增加 RAW 检查，否则会明确跳过该组：

```bash
LUMA_RAW_FIXTURE="$PWD/Samples/synthetic-bayer.dng" bash scripts/build.sh --check
```

`LUMA_BUILD_DIR` 可把中间产物放到单独目录。脚本默认只编译本机架构；源码最低部署版本是 macOS 13。

### 本机 Command Line Tools 的兼容处理

本次机器没有完整 Xcode。现有 CLT 存在两个独立问题：旧 `PackageDescription.private.swiftinterface` 与动态库版本不一致，且 SwiftBridging 被两份 modulemap 重复定义。因此本机标准 `swift build` 失败，不能将它报告为通过。

本机构建使用直接编译脚本和项目内 VFS overlay，仅对当前编译隐藏重复模块；没有修改或安装系统工具链。复现方法：

```bash
python3 scripts/local-toolchain-overlay.py .build-direct
LUMA_TOOLCHAIN_OVERLAY="$PWD/.build-direct/toolchain-overlay.json" \
LUMA_RAW_FIXTURE="$PWD/Samples/synthetic-bayer.dng" \
bash scripts/build.sh --check
```

正常工具链无需 overlay。若另一个系统出现不同的 SDK/编译器损坏，应修复或选择匹配的 Xcode/CLT；这里的覆盖不是通用修复工具。

## 图像与颜色管线

- `ImageEngine` 是串行 actor，CIRAWFilter 的可变状态和 Core Image 渲染不在主线程操作。
- CIContext 优先使用 Metal；无 GPU 时退回软件渲染并在状态栏说明。工作空间为 **extended linear Display P3**，工作格式 **RGBAh（16 位半浮点）**。
- RAW：CIRAWFilter 读取相机白平衡，曝光直接作用于 RAW 解码器；记录 decoderVersion、baselineExposure、shadowBias、boostAmount、boostShadowAmount、支持的局部影调/降噪/锐化等默认值以及镜头校正状态。
- 明确保留解码器默认 SDR 影调（`extendedDynamicRangeAmount = 0`）。本版不把 boostAmount 强行清零，也不再叠加第二套自动 HDR→SDR 映射。曝光调整发生在解码器 SDR 成像之前；RAW 输出本身不是未经处理的场景线性数据。
- 普通图片：Core Image 读取嵌入 ICC，按 EXIF 方向转正。无配置的 RGB 采用 CI 默认 sRGB；白平衡是相对 6500 K 的温度/色调变化，不宣称恢复传感器白平衡。
- 共同后处理：可选 CIToneCurve → 饱和度 → 90° 旋转 → 径向/线性局部蒙版 → 自定义裁剪框 → 参考图追色。蒙版和裁剪框都以转正后图像左上角为坐标原点，保存归一化的 x/y/宽/高，预览和导出使用同一像素边界。
- 预览与导出共用 `processed`。交互底图长边最多 1800，RAW 通过 scaleFactor 减少解码工作，RGB 使用 Lanczos 缩小；原生细节另用全分辨率管线按视口分块渲染。滑块 90 ms 去抖，并取消尚未开始的旧任务、丢弃过期结果。ImageIO 缩略图在初次完整预览之前临时显示。
- 最后才转换到 sRGB 和整数输出。JPEG 为 8 bit、质量 0.94；TIFF 为 16 bit 整数。透明像素统一合成黑底。导出总是使用全分辨率解码，且包含实际裁剪。

浮点工作缓冲避免过早的 8 位量化；它不意味着本版保留 HDR 输出。RAW 解码器的默认 SDR 成像以及用户曲线仍会改变高光，最终 sRGB 输出也会限制色域/范围。

## 参考图追色的实现与使用边界

实现借鉴 [darktable Color mapping](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/color-mapping/) 的公开算法思路：在 Lab 颜色空间分析颜色分簇，再把颜色与明暗分开控制。项目独立使用 Swift 和 Core Image 实现，没有复制或链接 darktable/G’MIC 源码，也不使用外部 AI 服务；与 darktable 的数值输出不完全相同。

- 对当前基础调整和参考图初始显影做小尺寸浮点采样，使用确定性的颜色分簇统计。新版在最多 5 个簇之间寻找全局对应，尽可能避免多个源簇都落入一个参考簇；旧配方保留原算法。参考 RAW 使用相机白平衡及系统默认 SDR 显影；如果参考图本身是导出的成品，匹配的是它已呈现的颜色。
- 为颜色簇寻找对应关系，综合颜色距离和颜色占比；使用均值和标准差映射，平滑混合各簇结果。「颜色占比权重」越高，颜色在画面中的占比对对应关系影响越大。
- 明暗从两张图片的亮度分布构建 257 点单调映射，使用分位点插值而非阶梯直方图，保持黑白端点；源图亮度近乎单一时关闭明暗转移，避免放大噪声。颜色标准差设置下限，缩放限制在 0.5–2 倍。颜色强度为 0 时关闭颜色映射，仍可单独使用明暗匹配；两种强度都为 0 时不改变图像。
- 映射通过 Core Image 浮点管线执行，预览与导出使用同一逻辑。配方嵌入统计、对应结果和明暗映射；参考文件名及 SHA-256 只作为来源标记，输出不依赖参考文件路径。
- 重新追色不会累计使用旧映射。已有匹配冻结为可保存的参数；此后调整曝光、白平衡或曲线时不会自动重新分析，必要时再点击一键追色。

这是整体颜色分布匹配，适合先建立相近的整体色调，再人工微调。它不识别人脸、肤色、天空或具体物体，不保证不同场景中的每个物体与参考图一一对应。背景面积、光线、剪裁和照片内容差异很大时，建议降低强度、减少颜色分组，或选一张构图/光线更接近的参考图。参考图追色本身没有选区和肤色保护；需要局部修正时可使用第一版径向/线性蒙版。不宣称复刻成熟软件的全部追色功能。

## 文件、配方与元数据

- 原片只读。导出和保存配方均拒绝与列表中原片或本次会话载入过的参考原片相同的路径、符号链接目标或文件标识。输出采用原子写入；不会在原片内写 XMP/调整信息。
- 新 JSON 使用 schema `version: 3`、pipeline `luma-sdr-p3-v3`，包含源文件名、SHA-256、RAW 配置、基础调整、蒙版及可选追色参数。v1/v2 可读取并迁移到 v3，旧版程序将明确拒绝 v3，避免静默删除蒙版。旧追色保持 v1 算法；旧线性蒙版保留原渐变跨度，可在面板点击「转换为新版渐变宽度」并撤销。新版修正蒙版透明度和几何处理；有旧配方时建议保留原文件并核对成像。拒绝未知版本、无效数值、重复蒙版 ID 和不匹配原片。
- 本版严格要求恢复配方的 RAW 默认配置与本机导入结果相同；系统升级导致解码器/默认值变化时明确拒绝，避免静默改变成像。尚无跨系统版本迁移功能。
- 像素已经转正，导出方向统一为 1，同时更新像素尺寸和 EXIF 色彩空间；ICC 来自最终 CGImage。
- 保留可用 EXIF 拍摄信息、TIFF 相机/作者/版权/日期信息、IPTC。去掉旧尺寸、旧配置、MakerNote、UserComment、CFA/旧主体坐标及旧预览相关项目。GPS 仅在用户开启时保留。
- 不承诺保留厂商私有元数据、完整 XMP、深度图、增益图或辅助图；不复制可能过期的 RAW 缩略图到成品。

## 验证结果与边界

本机：Apple M1 Max，macOS 26.5.2，Apple Swift 6.1。直接编译、打包、ad-hoc 签名检查成功；程序实际启动，RGB 和合成 DNG 都完成了窗口预览。

文件夹版本另外验证了：子文件夹开关、非图片/隐藏文件过滤、自然排序、重复添加去重、逐张调整和未保存标记、跨照片撤销/重做、失败导入和空文件夹不破坏当前编辑。`scripts/FolderCheck.swift` 由 `build.sh --check` 一并执行。

追色版自动检查包含：参考图导入、追色可撤销/重做、移除及恢复、强度滑块合并历史、重复匹配不叠加、逐张照片保留匹配、参考图导入失败保持已有匹配。模型集成检查位于 `scripts/MatchModelCheck.swift`；核心算法检查另覆盖恒等、极端输入、参数验证、配方自包含、旧配方兼容和导出一致性。真实窗口冒烟路径可通过 `LUMA_SMOKE_REFERENCE` 加载参考图并追色后截图。

**原有 49 项断言通过**：配方往返/非法版本与数值拒绝、撤销重做及历史分支、EXIF 方向的像素级比对、裁剪旋转尺寸、配方恢复像素一致性、JPEG/TIFF 导出与预览像素误差、16 位 TIFF、ICC、EXIF/IPTC、GPS 默认去除/主动保留、原片及符号链接防覆盖、失败导入保持现有文档，以及 DNG 的白平衡/曝光、RAW 配方重现、全分辨率 TIFF 与缩略图读取。日志见 `VALIDATION.txt`。

**追色和自定义裁剪版共 118 项核心断言通过**，另通过文件夹和追色模型集成检查，以及普通图片、DNG 两次原生窗口追色冒烟验证。合成测试图对参考图的平均 RGB 差异从 38.68 降至 23.71（8 位通道尺度）；颜色＋明暗、仅明暗的 GPU 与独立 CPU 输出对比误差均为 0。该数值只验证此测试素材，不代表真实照片画质评分。

限制：

- 未获得真实相机 RAW 样片，未验证各相机型号、ProRAW、厂商私有压缩、实际高光恢复和噪声/色彩质量。兼容性取决于系统 RAW 支持。
- 追色使用合成色彩素材验证算法和管线闭环；尚未用大量真实人像、风景及跨相机 RAW 做主观画质评估，颜色分布匹配不能替代人工调色。
- 当前蒙版包含径向/有范围的线性渐变；没有画笔、颜色/亮度范围或主体识别。修复版增加选区外保持不变、透明度、反向、方向、导出及旋转组合的回归检查。实际验证状态见 DEVELOPMENT_STATUS.md。
- 未做大像素 RAW 的交互帧率或峰值内存基准。已完成的 GPU 渲染不能中途取消；新参数需等待当前工作结束，但不会用过时结果覆盖新预览。
- 交互底图的缩小解码与滤镜插值可能使它与全分辨率结果有小差异；100% 细节加载完成后使用全分辨率管线，已核对对应 TIFF 区域。视口仍是 SDR sRGB / 8 bit 显示，不代表 HDR 或 16 bit 屏幕输出。
- 裁剪框支持自由比例和移动，旋转仅 90°；没有拉直。已支持缩放平移和原始分辨率 100% 查看；没有直方图、持久化图库、批量处理、HDR、Vision 标签或 Photoshop 图层。
- 原生 GUI 冒烟验证覆盖启动/导入/预览及截图；没有自动化点击所有文件面板和滑块，也未在 macOS 13 或 Intel 真机运行。

## 源码结构

- `Sources/LumaCore/PhotoFolder.swift`：文件夹扫描、格式筛选和自然排序。
- `Sources/LumaCore/Recipe.swift`：可版本化配方、参数验证和编辑历史。
- `Sources/LumaCore/MaskGeometry.swift`：画布与渲染共用的蒙版几何。
- `Sources/LumaCore/ViewportTransform.swift`：物理像素倍率、实际显示比例、画布变换、坐标转换与边界限制。
- `Sources/LumaCore/DetailPreview.swift`：视口分块规划、采样层级与全分辨率输出尺寸。
- `Sources/LumaCore/DraftStore.swift`：原子草稿保存、校验和恢复。
- `Sources/LumaCore/ColorMatch.swift`：追色统计、颜色分簇、对应关系及可保存的颜色/明暗映射。
- `Sources/LumaCore/ImageEngine.swift`：导入、RAW/普通图片管线、颜色管理、局部蒙版、元数据和导出。
- `Sources/LumaRAW/EditorModel.swift`：文档状态、异步预览、文件面板和配方操作。
- `Sources/LumaRAW/LumaRAWApp.swift`：SwiftUI 窗口、检查器、曲线示意和菜单。
- `Sources/LumaRAW/CanvasNavigation.swift`：限定于当前画布的原生输入路由，协调平移、缩放与编辑手势。
- `Tests/LumaCoreTests`：测试；`scripts/CheckMain.swift` 使其能在仅有 CLT 的环境独立运行。

参考：[Apple CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter)、[RAW EDR 设置](https://developer.apple.com/documentation/coreimage/cirawfilter/extendeddynamicrangeamount)、[ImageIO DNG 元数据](https://developer.apple.com/documentation/imageio/dng-image-properties)。实现同时核对了本机 SDK 的 CIRAWFilter.h。

## 0.4 修复版验证

`bash scripts/build.sh --check` 执行完整检查，包括像素渲染、自动草稿重新打开、文件夹和追色模型集成。仅需检查几何、配方、算法和文档状态时，可运行 `bash scripts/build.sh --check-model`；该模式明确排除像素测试，不能代替完整检查。

2026-10-27 已核实 0.4 提交 `df60bb7` 的 [GitHub CI](https://github.com/pw0rld/luma-raw-editor/actions/runs/40184283821) 通过完整检查，含 182 项核心断言。当前本地原生细节改动在系统图形环境下也通过完整 `--check`：276 项核心断言、草稿恢复、文件夹/追色集成及原生输入检查。受限执行环境无法连接窗口服务或创建 Core Image 预览时，须在允许访问系统图形服务的环境验证；这类环境失败不能用 `--check-model` 的结果替代。已补充 24MP 合成 RGB 的单次查看基准；真实相机 RAW、大规模相机兼容及交互性能仍需进一步评估。

Release 构建会校验标签、Info.plist、发布说明、arm64 二进制及签名。若本机 iconutil 无法打包有效的 iconset，脚本会使用已校验 PNG 尺寸的 ICNS 封装备用实现。


## 原始分辨率细节查看

- 100% / 200% 分别为每个处理后照片像素占 1 / 2 个屏幕物理像素。读取实际窗口 backing scale，窗口变化或移动显示器后维持该倍率；适合窗口则随窗口调整。
- 底图满足当前显示像素需求时复用底图；需要更多细节时，在完整显影、旋转、局部调整、裁剪和追色之后切出当前视口，保持邻域滤镜和蒙版羽化。RAW 细节使用独立的全分辨率解码器实例，避免预览缩小参数影响细节。
- 1024×1024 分块带 2 像素重叠边缘；低倍率使用二次幂采样层级，100% 及以上直接渲染原始像素，放大显示采用最近邻插值。分块按视口中心优先加载，平移复用已有分块。
- 渲染器的分块 LRU 上限 48 MiB；画布仅保留当前计划中的分块，单次计划最多 64 块。这个上限只约束分块图像，不涵盖 RAW 解码缓冲、Core Image/Metal 缓存或窗口资源。RAW 解码器仍可能完整解码原片，不能视为严格的区域 RAW 解码。
- 曝光、裁剪、蒙版、追色、照片或显示比例变化后丢弃过期结果；加载不修改配方和撤销历史。已开始的 GPU 工作不能中途抢占，更新的请求会等待它结束。
- 复杂蒙版叠加追色时，在浮点工作空间插入中间渲染节点，避免本机 Metal 编译器将过大的滤镜图融合而崩溃。预览、细节与导出仍复用同一调整管线。

验证包含 Retina 1×/2× 比例数学检查、真实 2× Retina 窗口、单像素纹理、分块重叠接缝、非对称裁剪＋旋转＋两种蒙版＋追色、RAW、缓存复用/淘汰、取消及旧照片/参数结果拒绝。RGB 细节与 16 位 TIFF 对应区域平均字节误差约 0.00118（8 位通道尺度），属于本次合成素材的一致性检查，不是摄影画质评分。

`scripts/DetailBench.swift` 可分别运行 `create` 和 `run`，避免素材生成影响查看进程测量。本机 M1 Max 单次 6000×4000 合成 RGB 基准：打开约 58 ms、1800 像素底图约 79 ms、首批 100% 视口 4 块约 29 ms、5 次平移共约 20 ms，分块缓存约 40.8 MiB；最大驻留集约 204 MiB，系统报告峰值内存 footprint 约 505 MiB。测量未包含完整 UI，不能据此推算真实相机 RAW 的延迟、帧率或内存。
