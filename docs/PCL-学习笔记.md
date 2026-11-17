# PCL（Plain Craft Launcher 2）源码学习笔记

仓库：https://github.com/Meloong-Git/PCL
本地样本：`D:\PCLSE Demo\src\Meloong-Git-PCL-93ede5d`（main @ 93ede5d，2026-10-24 推送）

> 本文是第一轮速览；带行号依据的深度研究与**可复现构建流程**见 `PCL-源码研究.md`。

## 1. 基本盘

| 项 | 值 |
| --- | --- |
| 定位 | Minecraft Java 版启动器（Windows 桌面） |
| 语言/框架 | VB.NET + WPF，.NET Framework 4.8，`Option Strict Off` |
| 版本常量 | `2.99.0.1`，VersionCode 415（正式）/ 416（快照）（`Modules\Base\ModBase.vb`） |
| 规模 | 113 个 .vb / 63 个 .xaml，约 4.7 万行（不含子模块） |
| 社区 | 约 9.7k stars / 1.6k forks |
| 许可 | 自定义《PCL 分发有限许可》+《存储库合理使用指南》，不是 MIT/GPL |

许可里对二次开发约束很具体：重度使用必须自称「PCL XXX 修改版」、关于页首位署名、继续开源、保留正版购买劝导、Windows 下主色相必须为蓝色。做 PCLSE 这类分支前要先对齐这些条款。

## 2. 解决方案结构

```
Plain Craft Launcher 2.sln
├─ Plain Craft Launcher 2.vbproj   VB/WPF 主程序（RootNamespace=PCL，AnyCPU）
├─ PCLCS.csproj                    C# net48 类库（Java 探测、版本元数据、启动辅助）
├─ MeloongCore\Shared              git 子模块（基础工具库）
└─ MeloongCore\Wpf                 git 子模块（WPF 工具库）
```

注意：zipball 不含子模块，`MeloongCore\` 目录为空，直接打开 sln 会缺引用。

主程序目录：

```
Modules\            业务模块（Base / Minecraft / Resource / ThirdParty）
Pages\              页面（Launch / Download / Instance / Setup / Other / Link）
Controls\           自绘 WPF 控件 + 行为 + 消息框
Resources\          第三方 dll、Custom.xaml、Help.zip、字体
Images\             图标与主题图
Application.xaml    应用级资源与启动入口
FormMain.xaml       主窗口（标题栏、页面容器、导航）
```

代码量分布（行）：

| 区域 | 文件 | 行数 |
| --- | --- | --- |
| Pages | 90 | 19,498 |
| Modules/Minecraft | 7 | 8,269 |
| Controls | 51 | 6,272 |
| Modules/Base | 7 | 5,367 |
| Shell（App/FormMain） | 5 | 2,681 |
| Modules/Resource | 5 | 2,170 |
| Modules 根 | 5 | 1,925 |
| PCLCS（C#） | 9 | 854 |

## 3. 核心抽象：Loader 任务/进度框架

文件：`Modules\Base\ModLoader.vb`

- `LoaderBase`：统一状态机（Waiting → Loading → Finished / Failed / Canceled）、`Progress`、`ProgressWeight`、父子关系、UI 线程与工作线程双通道事件（`OnStateChangedThread` / `OnStateChangedUi`）。
- `LoaderTask(Of TIn, TOut)`：单步异步任务，带输入/输出、`ShouldStart` 去重、超时重启（`ReloadTimeout`）、取消令牌、进度提供器。
- `LoaderCombo(Of InputType)`：串行组合器，按子加载器 `State` 推进；子任务失败/Cancel 会级联；总进度按 `ProgressWeight` 加权平均。
- `LoaderWorker`：固定线程执行器。
- `LoaderDownload`（在 `ModNet.vb`）：把 `NetFile` 列表包成加载器，直接驱动下载页进度。

这套抽象是整份代码的骨架：业务方只写 `Sub(Loader)`，UI 只订阅 `LoadingState`/`Progress`，页面（`MyPageRight`）可直接把加载器塞进内容区。启动、下载、安装、资源搜索、Java 扫描全走同一套。

## 4. 启动流程

### 4.1 应用启动

`Application.xaml.vb` → `Application_Startup`：

1. `MeloongCore.Main.Init` / `Wpf.Main.Init`
2. 单例互斥体 `PCL_SingletonMutex`（`--update/--gpu/--memory` 时跳过）
3. 日志轮转 + 主线程最高优先级
4. .NET Framework Release ≥ 528040 检查（4.8）
5. 命令行分支：自动更新替换、GPU 偏好、内存优化
6. 目录/权限检查、缓存目录回退、`ServicePointManager` 调优
7. 环境校验（压缩包内运行、32 位系统直接拒绝）
8. 建主窗口

### 4.2 游戏启动链

`Modules\Minecraft\ModLaunch.vb` → `McLaunchStart(Loader)`，构造 9 段 `LoaderCombo`：

```
获取 Java → 登录 → 补全文件(DlClientFix) → [内存优化] → 获取启动参数
→ 解压 Natives → 预启动处理 → 自定义命令 → 启动进程 → 等待窗口 → 结束处理
```

权重 4 / 15 / 15 / 30 / 2 / 2 / 1 / 1 / 2 / 1 / 1，总进度加权。

启动参数（`McLaunchArgumentsJVM`）里能看到大量真实踩坑经验：

- 新版 JSON 的 `arguments.jvm` 按 `rules` 过滤，并沿 `inheritsFrom` 逐级向上合并
- JLW（`JavaWrapper.jar`）+ `-Dstdout.encoding`/`file.encoding=COMPAT` 解决中文路径/编码
- LUA（`LwjglUnsafeAgent.jar`）针对 lwjgl 3.4.1
- 按 Java 版本选 ZGC / 分代 ZGC / G1GC（Java 21/15/24 分支）
- `-Dlog4j2.formatMsgNoLookups=true`、`-XX:MaxPermSize`（Java ≤7）等兼容参数
- 第三方登录：`authlib-injector` 预取 + `-javaagent`，统一通行证 `nide8auth.jar`
- 参数去重 `DeduplicateJavaArguments`，避免用户自定义参数重复

### 4.3 进程守护与崩溃

- `ModWatcher.vb`：挂接 stdout/stderr、窗口探测、日志节流、退出/崩溃回调。
- `ModCrash.vb`：`CrashAnalyzer` 采集 `latest.log`/`crash-report`/启动日志，`AnalyzeCrit1~3` 分三级判据 + 模组名启发式，最终生成可读报告。

## 5. 下载引擎（最值得抄的部分）

文件：`Modules\Base\ModNet.vb`（约 1.9k 行）

- `NetSource`：一个下载源，带失败计数、单线程标记。
- `NetFile`：一个文件任务，含 `Sources`（可多线程）与 `SourcesOnce`（仅单线程源）。
- `NetThread`：按 Range 分块的工作线程；文件 < 1MB 或大小未知时不切块。
- 关键策略：
  - 多源轮询 + 失败源剔除
  - 断点续传；合并失败后整体降级为单线程逐源重试（兼容会返回错误内容/多线程抽风的源）
  - 速度统计窗口 200ms、全局限速、连接数上限
  - `FileChecker` 统一做大小/哈希校验
- `LoaderDownload` 把 `NetFile` 集合映射成加载器进度，UI 无感。

镜像层（`Modules\Minecraft\ModDownload.vb`）：

- `DlSourceOrder`：按设置决定官方源/镜像源顺序
- `DlSourceAssetsGet` / `DlSourceLibraryGet` / `DlSourceLauncherOrMetaGet`：把 Mojang 域名替换为 BMCLAPI
- `DlSourceModGet`：Modrinth / CurseForge → `mod.mcimirror.top`

## 6. 版本模型与文件补全

`Modules\Minecraft\ModMinecraft.vb`：

- `McInstance`：一个版本目录 = `versions\<name>\`，含 `json`、`jar`、`PCL\config.json`、`PCL\Setup.ini`
- `JsonObject` 惰性加载；`InheritName` 处理 `inheritsFrom`，并特判老 LiteLoader 与 HMCL 格式
- `JsonVersion`：从版本 jar 内读 `version.json`（用于识别原版号）
- `Check()`：目录、`mainClass`、版本号、前置版本四道校验
- `DlClientFix`：库文件分析 → 下载库 → assets 索引 → assets 文件；索引支持后台每日更新（缓存 `_background` 文件原子替换）

## 7. 安装与整合包

`ModModpack.vb` 支持 7 种：

```
CurseForge / Modrinth / HMCL / MMC / MCBBS / LauncherPack / 纯压缩包
```

统一流程：解压到临时目录 → 识别 `manifest.json` / `modrinth.index.json` / `mmc-pack.json` → 建实例 → 装加载器 → 复制 `overrides` → 清理。

## 8. 资源搜索

`Modules\Resource\`：

- `ResourceProject`：CurseForge 与 Modrinth 的统一项目模型（标题、图标、下载量、支持的 MC 版本/加载器）
- `ResourceSearcher`：分别拼两家的搜索 URL，结果归一化后合并，配合 `MyVirtualizingElement` 做虚拟化列表
- `PageDownloadMod/PageDownloadPack/...` 共用一套资源页骨架

## 9. 设置系统

`Pages\PageSetup\Settings.vb`：

- 全局强类型注册表 `Settings.Entries`：默认值 + 存储源（Registry / Instance / Global）+ 是否加密 + `OnChanged` 回调
- `Settings.Get(Of T)("Key", Instance:=...)`：实例级覆盖优先
- 加密项（登录 token、计数、识别码）走 DPAPI 一类机制
- 实例级配置落在 `versions\<name>\PCL\config.json`

这种「注册表 + 泛型读写 + 作用域」的做法比散落的 ini 读取好维护得多。

## 10. UI 层

- 全部自绘控件：`MyButton`、`MyCard`、`MyListItem`、`MyLoading`、`MyMsg*`、`MyScrollBar` 等，基于 `Border` + 模板 + 依赖属性。
- `ModAnimation.vb`：自研动画引擎，`AaX/AaY/AaWidth/AaOpacity/AaColor/AaScale/AaRotate/AaTextAppear` 生成 `AniData`，`AniStart` 批量入队，配 `AniEaseInout/OutBack/OutFluent` 等缓动；统一由主时钟驱动，可整组取消。
- 页面骨架：`MyPageLeft`（左侧导航，逐个入场动画）+ `MyPageRight`（右侧内容，内置加载环状态机 `PageStates`）。
- 导航：`FormMain.PageStack` + `PageChange`，支持主页面/子页面两级与返回栈。
- 主题：`ModSecret.ThemeRefresh` 用 HSL 生成 8 级色板写入 `Application.Resources`，顶部栏做渐变；开源版把主题解锁相关函数留成 stub。

## 11. 开源版的“留白”

`Modules\ModSecret.vb` 顶部明确写了部分代码被删除：

- `OAuthClientId`、`CurseForgeAPIKey` 改为读环境变量
- `ClsBaseUrl = ""` → 遥测函数直接 return
- `SecretCdnSign` 简化为去标记
- `ThemeCheckOne/ThemeUnlock` 恒 True/False

所以开源版能编译出可用启动器，但官方版的 CDN 鉴权、赞助主题、匿名统计、部分下载限制不在其中。

## 12. 工程实践点评

值得借鉴：

1. Loader 抽象把「业务步骤 + 进度 + 取消 + 失败级联」一次性解决。
2. 下载器的多源/断点/降级策略非常实战。
3. 启动参数构造按 Java 版本、系统版本、编码逐条分支，注释带 issue 号，可追溯。
4. 设置注册表 + 实例作用域，避免配置散落。
5. 动画/控件自研，视觉一致性和性能可控。
6. CI 里自动拉帮助文档、注入密钥、只产出一个 exe，发布链路简单。

明显短板：

1. `Option Strict Off` + 大量 `Module` 全局状态 + 单例 `FrmMain`，耦合重、难测试。
2. 巨型文件：`ModLaunch.vb` 2.2k 行、`ModNet.vb` 1.9k 行、`ModMinecraft.vb` 113KB。
3. 启动主流程里 `Do While ... Thread.Sleep(100)` 轮询 UI 刷新。
4. 无自动化测试，`ModDevelop.Start()` 是空壳。
5. 子模块与密钥依赖让「clone 即编译」不成立。

## 13. 本地构建步骤

1. 安装 VS 2022（.NET 桌面开发 + .NET Framework 4.8 targeting pack）。
2. 补子模块：`git submodule update --init --recursive`（或单独拉 MeloongCore）。
3. 还原：`dotnet restore PCLCS\PCLCS.csproj`。
4. 编译：`msbuild "Plain Craft Launcher 2.sln" /p:Configuration=Debug`。
5. 可选环境变量：`PCL_MS_CLIENT_ID`、`PCL_CURSEFORGE_API_KEY`（不设也能跑，微软登录/CF 搜索会受限）。

**2026-11-17 更新（已实测）**：本机无 VS、无 4.8 开发包，上面的 VS 路线走不通；改走 SDK 风格影子工程
`Plain Craft Launcher 2\PCL.Shadow.vbproj`（`Microsoft.NET.Sdk` + `UseWPF` + `net48` + NuGet 参考程序集），
一条命令即可编出可运行的 exe，并已实机启动到主窗口。完整步骤与踩坑见 `PCL-源码研究.md` 第 3 节与附录 A。命令：

```powershell
& 'D:\PCLSE Demo\dotnet\dotnet.exe' build 'D:\PCLSE Demo\src\Meloong-Git-PCL-93ede5d\Plain Craft Launcher 2\PCL.Shadow.vbproj' -c Debug
```

## 14. 建议阅读顺序

1. `ModLoader.vb`（先懂 Loader）
2. `ModLaunch.vb` 的 `McLaunchStart` + `McLaunchArgumentsJVM`
3. `ModNet.vb` 的 `NetFile` / `NetThread` / `LoaderDownload`
4. `ModDownload.vb` 的 `DlClientFix` 与镜像映射
5. `ModMinecraft.vb` 的 `McInstance` / `JsonVersion` / `InheritName`
6. `ModModpack.vb`
7. `Settings.vb` + `ModSecret.vb`
8. `MyPageRight.vb` + `ModAnimation.vb` + `FormMain.xaml.vb`

