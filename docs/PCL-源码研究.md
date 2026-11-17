# PCL（Plain Craft Launcher 2）源码研究

研究对象：`src\Meloong-Git-PCL-93ede5d`（GitHub `Meloong-Git/PCL`，main @ `93ede5d`）
子模块：`src\Meloong-Git-PCL-93ede5d\MeloongCore`（`Meloong-Git/MeloongCore`，C# 基础库）
本文所有结论均带 `文件:行号`，行号来自本机源码实读；末尾「附录 A」是本次**实际跑通**的构建过程与日志。

---

## 1. 结论速览

| 项 | 结论 |
| --- | --- |
| 是什么 | Minecraft Java 版启动器（Windows 桌面），VB.NET + WPF，.NET Framework 4.8，`Option Strict Off` |
| 规模 | 113 个 `.vb`（其中 1 个不参与编译）、63 个 `.xaml`；VB 约 3.8 万行，最大单文件 `ModLaunch.vb` 1978 行 |
| 版本 | `2.99.0.1`，VersionCode 415（Release）/416（Snapshot），`ModBase.vb:9-15`；编译产物 exe 的 FileVersion 已实测为 `2.99.0.1` |
| 骨架 | `Loader` 任务框架统管"步骤 + 进度 + 取消 + 失败级联"，启动/下载/安装/搜索全部复用 |
| 能编译吗 | **能**。本次用 dotnet SDK 8 + NuGet 参考程序集、零 Visual Studio，Debug/Release 均编译通过并成功启动到主窗口（见附录 A） |
| 最大问题 | 全局可变状态 + 单例窗体 + 巨型文件；若干"静默失效"的真实缺陷（见 §13） |
| 许可 | 自定义《PCL 分发有限许可》，非 MIT/GPL，二次开发有署名与颜色约束（`LICENCE`） |

---

## 2. 结构与规模

```
Plain Craft Launcher 2.sln
├─ Plain Craft Launcher 2.vbproj    VB/WPF 主程序，RootNamespace=PCL，net48，AnyCPU
├─ PCLCS.csproj                    C# net48 类库：Java 探测、版本元数据、配置模型、启动辅助
├─ MeloongCore\Shared              C# netstandard2.0 基础库（git 子模块）
├─ MeloongCore\Wpf                 C# net48 WPF 辅助（git 子模块）
└─ MeloongCore\Tests               TUnit 测试（net48）
```

主程序目录：`Modules\`（Base/Minecraft/Resource/ThirdParty）、`Pages\`、`Controls\`、`Resources\`、`Images\`，
入口 `Application.xaml` + `FormMain.xaml`。

VB 行数 Top 10（`Get-Content | Measure-Object -Line`）：

| 行数 | 文件 |
| --- | --- |
| 1978 | `Modules\Minecraft\ModLaunch.vb` |
| 1976 | `Pages\PageDownload\ModDownloadLib.vb` |
| 1874 | `Modules\Minecraft\ModMinecraft.vb` |
| 1662 | `Modules\Base\ModNet.vb` |
| 1588 | `FormMain.xaml.vb` |
| 1183 | `Modules\Minecraft\ModDownload.vb` |
| 1050 | `Pages\PageDownload\PageDownloadInstall.xaml.vb` |
| 1029 | `Modules\Base\ModBase.vb` |
| 990 | `Modules\Minecraft\ModCrash.vb` |
| 914 | `Modules\Base\ModAnimation.vb` |

项目文件里各类 Item 数量（解析 vbproj 得到）：`Compile` 112、`Page` 60、`Resource` 52、`None` 24、`Reference` 27、
`ApplicationDefinition` 1、`EmbeddedResource` 1、`ProjectReference` 3。

---

## 3. 构建：实测可复现路径

### 3.1 原 vbproj 为什么在无 VS 机器上编不动

原工程是**旧式（非 SDK 风格）VB/WPF 工程**：`<Project ToolsVersion="15.0">`，末尾
`<Import Project="$(MSBuildToolsPath)\Microsoft.VisualBasic.targets" />`（`Plain Craft Launcher 2.vbproj:953`），
靠 `ProjectTypeGuids` 里的 WPF GUID 隐式引入 `Microsoft.WinFX.targets` 做 XAML 标记编译。

本机装的是 dotnet SDK 8.0.428（MSBuild 17.11，**Core** 版），没有 VS、也没有 .NET Framework 4.8 开发包。
直接把 WPF 目标文件塞给它（`/p:CustomAfterMicrosoftCommonTargets=...\Microsoft.WinFX.targets`）能进入标记编译，
但立刻死在：

```
error MC1000: 未知的生成错误"Could not find assembly 'mscorlib, Version=0.0.0.0, ..."
```

即 Core 版 MSBuild 里的 `PresentationBuildTasks`（net8.0 分支）解析不了 .NET Framework 参考程序集的 mscorlib 引用闭包。
**结论：旧式 vbproj 这条路需要 VS 2022（或 Framework 版 MSBuild 17）+ net48 开发包，本次不采用。**

顺带一个坑：三个 C# 工程写死 `<LangVersion>13.0</LangVersion>`（`MeloongCore.csproj:12`、`MeloongCore.Wpf.csproj:11`、`PCLCS.csproj:12`），
SDK 8 最高 C# 12，直接编会报 `CS1617: /langversion 的选项"13.0"无效`。要么装 .NET 9 SDK，要么把 `LangVersion` 降到 12（本次采用后者，实测三工程全过）。

### 3.2 实际做法：SDK 风格影子工程

新增 `Plain Craft Launcher 2\PCL.Shadow.vbproj`，用 `Microsoft.NET.Sdk` + `UseWPF` + `net48` **编译同一批源码**，
与原 vbproj 并存、互不覆盖。核心设置：

| 设置 | 值 | 原因 |
| --- | --- | --- |
| `TargetFramework` / `UseWPF` | `net48` / `true` | 与上游一致；SDK 的 WinFX 目标在 Core MSBuild 下走 net8 任务，能正常做标记编译 |
| `PackageReference` | `Microsoft.NETFramework.ReferenceAssemblies 1.0.3` | 免装 4.8 Developer Pack，参考程序集从 NuGet 取 |
| `RootNamespace` / `AssemblyName` / `MyType` | `PCL` / `Plain Craft Launcher 2` / `Custom` | `My.Computer`、`My.Resources` 必须靠 `_MyType=Custom` |
| `OptionStrict` / `OptionInfer` / `OptionCompare` | `Off` / `On` / `Binary` | 与 vbproj 的 75/78 行一致，否则上千处隐式转换报错 |
| `NoWarn` | `41999,42016,...,42314` | 照抄 vbproj:44 |
| `GenerateAssemblyInfo` | `false` | 保留 `My Project\AssemblyInfo.vb` |
| `ApplicationDefinition` | `Application.xaml` | 生成 VB 的 `Sub Main` 与 App 部分类 |
| `Page` | `**\*.xaml` 排除 `Application.xaml`、`Resources\Custom.xaml` | 与 vbproj 的 60 个 Page 一致 |
| `Resource` | `Images\**\*`、`Resources\Font.ttf` | 对应 vbproj 的 52 个 Resource；`Images\icon.ico` 是 `SplashScreen` 的启动图 |
| `EmbeddedResource` | `My Project\Resources.resx`，`LogicalName=PCL.Resources.resources` | `Resources.Designer.vb` 用 `ResourceManager("PCL.Resources")` 取资源 |
| `ProjectReference` | 三个 C# 工程 + `AdditionalProperties="LangVersion=12.0"` | 一行命令连带编三个依赖，不必改上游 csproj |
| `Import` 项 | 30 条，等价 vbproj:677-706 | VB 的"项目级 Imports"在 SDK 风格里是 `<Import>` Item |

两处必须照抄上游的"不正常"：

1. **`Controls\MySliderDot.xaml.vb` 必须排除**。它引用了全仓不存在的 `MathRange`、`SetTop`、`SliderDrag_Finish` 与
   `Logger.Warning`/`LogLevel.Hint`，上游 vbproj 的 112 个 Compile 项里也没有它（113 个 `.vb` 减 1）。照抄即可编过。
2. **两个 jar 不在 `Resources\`**。vbproj 引用 `Resources\java-wrapper.jar`、`Resources\lwjgl-unsafe-agent.jar`，但仓库里实际文件是
   `PCLCS\Launch\JavaWrapper.jar`、`PCLCS\Launch\LwjglUnsafeAgent.jar`（`PCLCS.csproj:59-60` 把它们嵌进 PCLCS）。
   影子工程用 `<None Include="..\PCLCS\Launch\JavaWrapper.jar" Link="Resources\java-wrapper.jar" />` 映射。

还有两个纯工程性坑：

- **影子工程必须放在源码目录里**。放在外部用绝对路径 `Include` 时，WPF 的 `Resource` 资源名会丢掉首层目录，
  编译产物里只有 `icon.ico` 而没有 `images/icon.ico`，运行时报
  `找不到资源"images\icon.ico"`（`Application.xaml.vb:112` 的 `SplashScreen`）。放进 `Plain Craft Launcher 2\` 用相对路径即恢复。
- `DocumentationFile` 不能用绝对路径，否则 `Microsoft.Common.CurrentVersion.targets` 会拼出 `obj\...\D:\...` 并告 `MSB3191`。

### 3.3 编译与运行命令（实测）

```powershell
$dotnet = 'D:\PCLSE Demo\dotnet\dotnet.exe'
cd 'D:\PCLSE Demo\src\Meloong-Git-PCL-93ede5d\Plain Craft Launcher 2'
& $dotnet build PCL.Shadow.vbproj -c Debug     # 或 -c Release / -c Snapshot
& $dotnet build PCL.Shadow.vbproj -c Release
```

| 配置 | 产物 | 大小 |
| --- | --- | --- |
| Debug（定义 `SNAPSHOT`） | `bin\Debug\net48\Plain Craft Launcher 2.exe` | 6,151,680 B |
| Release（定义 `RELEASE`） | `bin\Release\net48\Plain Craft Launcher 2.exe` | 5,917,696 B |

启动验证（Debug 版，窗口枚举 + 日志）：

```
窗口标题：Plain Craft Launcher　        <- 注意是全角空格
[FormMain] 已从老版本迁移微软登录结果
[FormMain] 全新的 PCL，使用新的版本隔离默认值
[ModLoader] 加载器 LoaderTask`2 Minecraft Folder List 状态改变：Loading
[ModMinecraft] 已创建 launcher_profiles.json：...\net48\.minecraft\
[ModAnimation] 动画线程开始
[PageLaunchLeft] 当前选择的 Minecraft 版本无效：null
[ModMain] 弹出提示：【开发者模式】PCL 正以开发者模式运行...
[MyMsgText] 普通弹窗：协议授权
```

即：主窗口、页面导航、动画线程、实例扫描、协议弹窗全部正常工作。

### 3.4 与官方 CI 的差异（`\.github\workflows\build.yml`）

官方在 windows-latest 上：`Setup MSBuild` → 克隆 `PCL2Help` 打成 `Resources\Help.zip` →
**用 secrets 覆写** `ModSecret.vb` 的 `OAuthClientId`/`CurseForgeAPIKey`、用 commit sha 覆写 `ModBase.CommitHash` →
`dotnet restore PCLCS` → `msbuild 主 vbproj` → 只上传 `obj\<cfg>\Plain Craft Launcher 2.exe`（单文件发布，依赖靠 ILMerge 式的资源内嵌 + Costura？实际是 exe 内嵌资源，见 `Resources.resx:148-152`）。

本地影子构建**不做密钥注入**，所以：微软登录走环境变量 `PCL_MS_CLIENT_ID`（`ModSecret.vb:10`）、
CurseForge 搜索走 `PCL_CURSEFORGE_API_KEY`（`ModSecret.vb:12`），不设也能启动，只是相关功能受限。
`Help.zip` 用的是仓库自带的那份，不是最新的 PCL2Help。

---

## 4. 运行时骨架：Loader 任务框架

`Modules\Base\ModLoader.vb`（690 行）是整个工程的调度中枢。

### 4.1 状态机与双通道

`LoadState` 为 `Waiting=0 / Loading=1 / Finished=2 / Failed=3 / Canceled=4`（`ModBase.vb:426-432`）。
**枚举顺序被当作语义用**：`State >= LoadState.Finished` 到处用来判"终态"（`ModLoader.vb:384`、`:455`、`:551`、`:585`），重排即静默改行为。

```vb
' ModLoader.vb:88-107（State setter 节选）
If _State = value Then Return
Dim OldState = _State
If value = LoadState.Finished AndAlso Settings.Get(Of Boolean)("SystemDebugDelay") Then Thread.Sleep(RandomInteger(100, 2000))
_State = value
If value = LoadState.Canceled Then CancellationTokenSource?.Cancel()
Logger.Log($"加载器 {[GetType].Name} {Name} 状态改变：{value}", If(value = LoadState.Failed, LogLevel.Error, LogLevel.Info))
RunInUi(Sub()
            Select Case value
                Case LoadState.Loading : LoadingState = MyLoading.MyLoadingState.Run
                Case LoadState.Failed : LoadingState = MyLoading.MyLoadingState.Error
                Case Else : LoadingState = MyLoading.MyLoadingState.Stop
            End Select
            RaiseEvent OnStateChangedUi(Me, value, OldState)
        End Sub)
If HasOnStateChangedThread Then RunInThread(Sub() RaiseEvent OnStateChangedThread(Me, value, OldState))
```

两条通道不对称，这是最容易踩的地方：

- **UI 通道**默认开：`RunInUi` → 非 UI 线程时 `Dispatcher.InvokeAsync`（`ModBase.vb:939-947`，不阻塞），并顺手把 `LoadingState` 映射成 `MyLoading` 的三种态。
- **工作线程通道**默认关：必须先 `AddHandler OnStateChangedThread` 再把 `HasOnStateChangedThread = True`（`ModLoader.vb:53-56` 的注释就是这个约定），
  否则 `:107` 直接跳过，事件静默不触发。`LoaderCombo` 构造时替子加载器做了这一步（`:499-500`）。
- 因此**从工作线程改 State 时，`_State` 立刻变，而 UI 回调排队执行**，两者之间有明显时间窗。

### 4.2 四类加载器

| 类型 | 职责 | 关键点 |
| --- | --- | --- |
| `LoaderTask(Of TIn,TOut)` | 单步异步任务 | `ShouldStart` 去重、`ReloadTimeout`、`IsCanceled` 靠**线程身份**比较、`Thread.Interrupt` 取消 |
| `LoaderCombo(Of InputType)` | 串行组合器 | 按子加载器 `State` 推进，`Block` 控制是否允许后续并行，失败级联 |
| `LoaderWorker` | 包装 `IWorker` | 进度映射 `actual+skiped`，`Cancel` 只允许 `Loading→Canceled` |
| `LoaderDownload` | 包装下载集合 | 见 §7.8 |

`IsCanceled` 不是布尔标记而是身份比较（`ModLoader.vb:283-285`）：`LastRunningThread Is Nothing OrElse 引用不等于当前线程 OrElse State=Canceled`。
取消链路 `Cancel` → 置 `Canceled` → `TriggerThreadInterrupt` → `Thread.Interrupt()` 并把 `LastRunningThread` 置空，
抛出的 `ThreadInterruptedException` 由 `ExceptionExtensions.cs:17-22` 的 `IsCanceled` 识别。

`LoaderCombo.Update` 的推进语义（`ModLoader.vb:589-643`）：
前一个 `LoaderTask` 的 `Output` 成为后一个的 `Input`，但**只有泛型实参类型匹配时才真正传入**（`:622`、`:631`），类型不符就传 `Nothing` 并断链；
`Block=True`（默认，`:131`）且自己还没完成时不置 `Blocked`，从而允许后续 `Block=False` 的任务并行跑。

### 4.3 进度

`Progress` 是虚拟属性，按状态分派：`Waiting→0`，`Loading→_Progress`，**`Failed`/`Canceled` 一律返回 1**（`ModLoader.vb:146-163`）——
所以"失败也 100%"是设计取舍，不是 bug，但调用方不能靠 `Progress>=1` 判成功。

`ProgressWeight` 的注释写着"预计时间（秒）"（`:179-182`）；`LoaderCombo` 按权重加权平均（`:470-490`），
而任务栏聚合用**不加权**平均 `Select(Progress).Average()`（`:719-727`），两处口径不同。
另有 `CreateSyncProgressProvider`（`:170`）把新式 `ProgressProvider` 单向映射回旧 `Loader.Progress`——这是 MeloongCore 渐进替换旧框架的痕迹。

---

## 5. 设置系统

`Pages\PageSetup\Settings.vb`：一张**强类型注册表**。

- `Setting` 字段：`Key / Encrypted / DefaultValue / Source / OnChanged / Type`（`:205-217`），`Type` 由默认值的运行时类型推断（`:224`）。
- `Sources` 只有三个：`Normal`（`Setup.ini`，`:262`）、`Registry`（`HKCU\Software\PCLDebug`，`:265`，`RegFolder` 见 `ModSecret.vb:8`）、
  `Instance`（`versions\<名>\PCL\Setup.ini`，`:271`）。**没有 "Global" 枚举值**——"全局"由 Normal + Registry 承载。
- 取值：`Settings.Get(Of T)(Key, Instance)`；缓存键对实例设置用 `PathVersion`，其余用空串（`:235-244`）。
- 加密项：DES，IV 固定 `"95168702"`（`:439`），key 由 `key.GetStableHashCode().ToString()` 取 8 字符（`:445`、`:463`）。
  开源版 `Identify` 恒为 `"0000-0000-0000-0000"`（`ModSecret.vb:197-199`），**密钥完全可由源码推导**，只能算混淆。
- `OnChanged` 只在 `Set`（保存之后，`:291-292`）与 `Reset`（`:403`）触发；`Get` 从不触发。
- **实例级不自动级联**：`Sources.Instance` 且 `Instance Is Nothing` 直接抛异常（`:336-340`）。"用全局值"靠哨兵字符串，
  例如 `VersionArgumentJavaSelect` 的默认值是 `"使用全局设置"`（`:189`）。

---

## 6. 启动链

### 6.1 应用启动（`Application.xaml.vb:7-146`）

`MeloongCore.Main.Init("PCL")` + `Wpf.Main.Init()` → 单例互斥体 `PCL_SingletonMutex`（`--update/--gpu/--memory` 跳过，`:151-176`）→
主线程提到 `Highest` → 查注册表 `NDP\v4\Full\Release < 528040` 强制 4.8 → 命令行分支
（`--update` 替换自身、`--gpu` 写 GPU 偏好、`--memory` 清理内存并把释放量作退出码）→ 目录与权限检查（失败回退缓存目录）→
`ServicePointManager` 调优（含 Win7 TLS 回退）→ 启动图 → 打印版本/识别码/路径/编码/管理员 → 压缩包内运行检测、
32 位系统直接拒绝 → 建主窗口。

### 6.2 游戏启动链（`ModLaunch.vb:106-133`）

10 段 `LoaderCombo`，权重与 Block 如下（顺序即执行顺序）：

| # | 名称 | 权重 | Block |
| --- | --- | --- | --- |
| 1 | 获取 Java | 4 | False |
| 2 | 登录 | 15 | False |
| 3 | 补全文件（`DlClientFix`，`Show=False`） | 15 | True |
| 4 | 获取启动参数 | 2 | True |
| 5 | 解压文件（Natives） | 2 | True |
| 6 | 预启动处理 | 1 | True |
| 7 | 执行自定义命令 | 1 | True |
| 8 | 启动进程 | 2 | True |
| 9 | 等待游戏窗口出现 | 1 | True |
| 10 | 结束处理 | 1 | True |

前三段并行（`Block=False`）。内存优化是**条件插入**在第 4 位、权重 30，插入时把"补全文件"改成 `Block=False`（`:135-145`）。

### 6.3 启动参数装配（`McLaunchArgumentsJVM`，`:1221-1401`）

顺序：版本 JSON 的 `arguments.jvm` → 自定义 JVM 参数 → 首次去重 → Nide javaagent → Authlib javaagent → JLW →
LUA → 内存/GC → 清 `MaxDirectMemorySize` → log4j → 编码 → `-jar JavaWrapper.jar` → 二次去重。
`McLaunchArgumentMain` 再拼 `JVM + mainClass + Game`，逐 token 套 `${}` 替换并处理引号（`:1191-1217`）。

里面全是实战踩坑记录：

- 新版 JSON 的 `arguments.jvm` 按 `rules` 过滤（`McJsonRuleCheck`，`ModMinecraft.vb:1554-1595`：只认 `windows`，`arch` 为 `x86`/含 `arm` 否决，
  `features.quick_play`/`is_demo_user` 一律反选），并沿 `inheritsFrom` 逐级向上合并（`:1249-1252`）。
- **GC 分支**：`SetupType` 与 Java 版本、系统版本双条件（`:1329-1340`）——ZGC 要 Java 15+/分代 ZGC 要 21+、Windows 10 1809+，否则退 G1；
  G1 参数 `G1NewSizePercent=20 / G1ReservePercent=20 / G1HeapRegionSize=32M / MaxGCPauseMillis=50`，Java ≤7 补 `MaxPermSize=512m`（`:1341-1352`）。
- **编码**：Java ≥18 用 `native.encoding`，否则 `file.encoding`；GBK 统一映射 GB18030；`stdout/stderr.encoding` 前缀按 <19 判断是否加 `sun.`（`:1376-1393`）。
- **JLW**（`JavaWrapper.jar`）用于捕获 `javaw` 拿不到的 stdout；启用时 `-jar JavaWrapper.jar` 必须在最后（`:1396-1398`），
  Java ≥9 还要 `--add-exports cpw.mods.bootstraplauncher/...`。
- **参数去重** `DeduplicateJavaArguments`（`:1617-1655`）：单参数精确去重；键值对在**游戏参数且非 `--tweakClass`** 时用新值覆盖旧值
  （注释解释重复 `--width/--uuid` 会让两者同时失效）；`Val("...") = 0` 用来避免 `-xPos -50` 的负数被当成参数名。

### 6.4 登录

`McLoginType` = Legacy 0 / Nide 2 / Auth 3 / Ms 5（`:296-301`），`McLoginLoader` 权重 15、`Block=False`、`ReloadTimeout=1`（`:475-476`）。

注入方式全部集中在 JVM 段，靠 `Output.Type` 字面量分支（`:1271-1288`）：

```vb
If McLoginLoader.Output.Type = "Nide" Then
    Args.Add("-javaagent:""${pure_directory}\nide8auth.jar""=""" & Settings.Get(Of String)("VersionServerNide", Instance:=McInstanceSelected) & """")
End If
If McLoginLoader.Output.Type = "Auth" Then
    If McLaunchJavaSelected.Version.Major >= 6 Then Args.Add("-Djavax.net.ssl.trustStoreType=WINDOWS-ROOT")
    Dim Server As String = Settings.Get(Of String)("VersionServerAuthServer", Instance:=McInstanceSelected)
    Dim Response As String = NetRequestByClientRetry(Server, Encoding:=Encoding.UTF8)
    Args.Add("-javaagent:""${pure_directory}\authlib-injector.jar""=""" & Server & """")
    Args.Add("-Dauthlibinjector.side=client")
    Args.Add("-Dauthlibinjector.yggdrasil.prefetched=" & Convert.ToBase64String(Encoding.UTF8.GetBytes(Response)))
End If
```

两个 jar 由"补全文件"下到 `PathPure`（`ModMinecraft.vb:1784-1824`）。微软登录唯一写文件的地方是 `launcher_profiles.json` 假数据注入（`:1768-1797`）。

### 6.5 进程守护（`ModWatcher.vb`）

- 启动：`javaw.exe` 不可用（注释点名 #6263，必须 `java.exe`），`UseShellExecute=False`、双流重定向、
  `StandardOutputEncoding=McLaunchEncoding`、工作目录 `PathIndie`、`Path` 追加 Java 目录（`ModLaunch.vb:2096-2114`）。
- 日志：`BeginOutputReadLine` + 事件回调把行塞进 `WaitingLog`，主循环每 64ms 批量消费（`ModWatcher.vb:86-89`、`:99`、`:141-183`）；
  内存保留 501 行。**PCL 自己不写 `latest.log`**，那是 MC 写的，崩溃分析时才去读。
- 游戏就绪分五级（`:195-211`）：任意日志→1、`Setting user:`→2、`lwjgl version`→3、`OpenAL initialized`→4、`Created...textures...-atlas`→5。
- 窗口探测：`EnumWindows` + **类名白名单** `GLFW30/SDL_app/LWJGL/SunAwtFrame`（`:312-345`），再按标题排除，
  最后要求窗口进程 `StartTime >= GameProcess.StartTime`。
- 崩溃判定：退出码 + 日志关键字双判据（`:160-179`、`:215-235`），`Crash report saved to` / `Unable to launch` 等直接判崩；
  2012 年前的版本非 0 退出码当正常结束（`:171`）。

### 6.6 崩溃分析（`ModCrash.vb`）

`Collect` 只收 **3 分钟内修改且非空**的 `latest.log`/`debug.log`/`crash-reports\*`（`:21-85`），
然后四级瀑布：`Crit1` 精确匹配（约百条，命中即停，`:474-584`）→ `Crit2` Mixin 专用（`:589-645`）→
堆栈关键词抽取（`System Details` 前、`/FATAL]` 块、hs_err 的 `T H R E A D`…`Registers:`，`:402-431`）→ `Crit3` 兜底（`:649-670`）。
结论汇总到 `CrashReasons`，再由 `GetAnalyzeResult` 套文案；导出 zip 时把 `RawOutput.log` 改名成"游戏崩溃前的输出.txt"（`:894-903`）。

### 6.7 Java 探测（`PCLCS\Java.cs` + `ModJava.vb`）

- 候选目录一长串（`Java.cs:136-168`）：PCL 自下载的 `.minecraft\runtime\`、HMCL、ATLauncher、Modrinth App、Prism、CurseForge、
  `.jdks`、`.sdkman`、Microsoft Store 版 MC、`ProgramFiles\Java|Eclipse Adoptium|Amazon Corretto|Zulu|Microsoft\jdk-*`，最后拼 `JDK_HOME;JAVA_HOME`。
- **版本识别不读 release 文件，直接跑进程**：`-XshowSettings:properties -version`，从合并的 stdout+stderr 里正则取 `version "..."`，
  去 `1.` 前缀、补足 4 段、`<=4 或 >=100` 判失败（`Java.cs:41-53`）；再强制 64 位（不含 `64-bit` 即拒绝）。
- 选 Java：`GetJavaRequirement`（`ModJava.vb:128-273`）先按原版号定区间（1.20.5+→≥21、1.18pre2+→≥17、1.17+→≥16、2017 年后→≥8、≤1.5.2→<9），
  再叠 `javaVersion.majorVersion`、OptiFine/Forge/NeoForge/Fabric/LiteLoader/Nide 的细分约束；没有则按 Mojang `java-runtime/all.json` 现下。
- 默认排序：先"是否在候选目录内"，再 `|Major-21|` 升序（`Java.cs:116-129`）。

---

## 7. 下载引擎（`ModNet.vb`，最值得抄的部分）

### 7.1 状态机

`WaitingToCheck(-1) → WaitingToDownload(0) → Connecting(1) → Reading(2) → Downloading(3) → Merging(4) → Finished(5) / Canceled(6)`（`:373-406`）。
`Progress` 按状态给固定映射，`Downloading` 用 `1-(1-p)^0.9` 做曲线压缩再映射到 5%~98%（`:728-752`）。

### 7.2 分块（Range）

- 不切块：`IsNoSplit => IsUnknownSize OrElse FileSize < 1MB`（`:674-678`）。未知长度走单线程 + 内存缓冲，`DownloadEnd` 置 1e12 当哨兵（`:487-491`）。
- 切块：取剩余量最大的线程，剩余 ≥ 256KB（`FilePieceLimit`）才切，新起点 = `DownloadEnd - DownloadUndone*0.4`（`:862`）——
  即从大块尾部截走 60%，原线程留前 40%。
- 线程上限 `NetTaskThreadLimit = ToolDownloadThread + 1`（`:311-315`），全局用 `Interlocked` 计数。
- **强制单线程的域名白名单**：URL 含 `pcl2-server`、`meloong.com`、`bmclapi`、`github.com`、`optifine.net`、`momot.rs` 就不再开新线程（`:852-854`）。

### 7.3 多源与降级

- `NetSource{Id, Url, FailCount, SingleThread, IsFailed}`；`GetSource(from)` 从起点环形查找第一个未失败源（`:607-627`）。
- 成功收到有效数据即把该源与所有任务 `FailCount` 清零（`:1014-1017`）。
- 剔除触发条件（`:1079-1084`）：Range 不支持/416、合并失败、`502/404/未能解析/无返回数据/空间不足`、
  非 bmclapi 源的 `403/429`、`FailCount >= clamp(5,30)` 且尚无数据、`FailCount > limit+2`。
- **合并失败 → 整文件降级单线程**：`SourceFail(IsMergeFailure=True)` 跳过"还有可用源"分支，把所有源清空后塞进 `SourcesOnce`，
  重新 `Reset()` 回到 `WaitingToDownload`，此后 `GetSource` 只返回 `SourcesOnce.First`，且首线程**不带 Range 头**（`:917`、`:1105-1120`、`:826-831`、`:889`）。

### 7.4 限速与统计

单线程速度 200ms 窗口（`:522-532`）；全局速度保留 30 个采样做加权平均（`:1683-1696`）；
`NetTaskSpeedLimitLow` 自适应提升为近 10 次均值 ×0.85（`:1698-1703`）；
上限档位：`ToolDownloadSpeed ≤14 →(v+1)*0.1MB`、`15..31 →(v-11)*0.5MB`、`32..41 →(v-21)*1MB`、`≥42 → 不限`（`:323-339`）；
令牌桶每 100ms 补 `high/10`，线程侧 `Left<=0` 就 `Sleep(16)`（`:996-1000`、`:1779`）。

### 7.5 校验

连接阶段（仅首线程）比对 `ContentLength` 与 `Check.MinSize/ActualSize`（`:940-947`），`>50MB` 再算磁盘空间；
非首线程要求 `FileSize - DownloadStart = ContentLength` 否则抛 `RangeNotSupportedException`（`:964-971`）；
合并后再 `Check?.Check(LocalPath)`（`:1205`），失败重试 3 次后删文件重下（`:1228-1243`）。

### 7.6 镜像映射（`ModDownload.vb`）

总开关 `DlSourceOrder`（`:1226-1228`）按 `ToolDownloadSource`/`DlPreferMojang` 决定官方与镜像的先后；
版本列表另有毫秒级抢跑参数（`:198-214`）。被替换的 host（全部指向 `bmclapi2.bangbang93.com`）：

| 函数 | 规则 |
| --- | --- |
| `DlSourceAssetsGet`（`:1249-1255`） | `resources.download.minecraft.net` 强制 https；`piston-data`/`piston-meta`/`resources...` → `.../assets` |
| `DlSourceLibraryGet`（`:1265-1283`） | `piston-data`/`piston-meta`/`libraries.minecraft.net` → `.../maven` 与 `.../libraries` |
| `DlSourceLauncherOrMetaGet`（`:1295-1299`） | `piston-data`/`piston-meta`/`launcher.mojang.com`/`launchermeta.mojang.com` → 根域 |
| `DlSourceModGet`（`:1305-1312`） | Modrinth/CurseForge → `mod.mcimirror.top/modrinth`、`/curseforge`、根域 |

两处绕过设置：库 URL 含 `minecraftforge`/`fabricmc`/`neoforged` 时固定只用镜像（`:1262-1272`）；
OptiFine 额外追加 `bmclapi2.bangbang93.com/maven/com/optifine/...`（`ModMinecraft.vb:1884-1889`）。

### 7.7 库与 assets 分析（`DlClientFix`）

`McLibListGet` → `McLibListGetWithJson`（`ModMinecraft.vb:1601-1605`）：清 null 属性 → `McJsonRuleCheck` →
优先 `downloads.artifact` 的 `url/path/size/sha1`，否则根 `url` + `McLibGet` 推路径 →
有 `natives.windows` 时取 `downloads.classifiers[NativeName]` 并把 `.jar` 改写成 `-{NativeName}.jar`、`${arch}` 按 64 位替换（`:1695-1727`）→
按 `Name + IsNatives` 去重、同区间取高版本。路径规则 `libraries\{group点转}\{name}\{version}\{name-version.jar}`（`:1909-1912`）。

assets：索引缺失回退到硬编码 legacy JSON（`:1930-1963`）；安装时先下到 `PathTemp\Cache\` 再 `Move` 回正式位置（`ModDownload.vb:96-112`），
后台每天更新一次（`:137-142`）。对象路径三态：`map_to_resources → {indie}resources\{name}`、`virtual → assets\virtual\legacy\{name}`、
其余 `assets\objects\{hash前2}\{hash}`（`ModMinecraft.vb:2023-2032`）。

### 7.8 进度映射

`LoaderDownload.Progress` 的 setter 直接抛异常（`ModNet.vb:1335-1337`），进度由 `NetManager` 每 100ms 刷新计算：
`IsCopy` 的文件按 0.2 权重、其余 1，再归一化（`:1379-1389`）；空列表强制 0（`:1332`）。

---

## 8. 版本与实例模型

### 8.1 一个版本目录里有什么

`McInstance` 由"版本名或绝对路径"构造，非绝对路径拼 `McFolderSelected & "versions\"`（`ModMinecraft.vb:573`），名字取末段（`:286`）。

| 文件 | 语义 | 读写点 |
| --- | --- | --- |
| `versions\<名>\<名>.json` | 版本 JSON | `GetJsonPath`（`:358`），不存在则扫描目录内 `*.json` 并校验含 `mainClass`/`type`/`id`（`:362-367`） |
| `versions\<名>\<名>.jar` | 客户端 jar | `JsonVersion` 读内部 `version.json`（`:520-522`）；`McLibListGet` 当主 jar 入列 |
| `versions\<名>\PCL\config.json` | 安装清单缓存 | `JsonConfigProvider`（`:574`），键 `MinecraftInstallManifest`（`PCLCS\Configs.cs:4`） |
| `versions\<名>\PCL\Setup.ini` | 实例元数据（Logo/Star/DisplayType/ReleaseTime/隔离开关等） | `Load()` 末尾写（`:700-712`），整合包安装写 Logo 与隔离开关（`ModModpack.vb:140-147`、`:327-328`） |
| `versions\<名>\PCL\Logo.png` | 卡片 Logo | `:798-799` |
| `versions\<名>\.pclignore` | 一次性忽略标记 | 首次加载直接删除（`:1043-1050`） |
| `<MC根>\PCL.ini` | 选中版本、缓存指纹、卡片布局 | `:976`、`:999`、`:1033-1040` |
| `launcher_profiles.json` | 启动器档案 | 不存在则用 GB18030 写一份（`:146-168`） |

### 8.2 inheritsFrom 合并（`:457-481`）

```vb
'合并 Libraries 项：子版本放在前面，父版本放在后面（5978#：如果多个 jar 包中含有相同的类，Java 8 和之前的版本按照 -cp 指定的顺序选择第一个）
Dim CurrentLib As JArray = _JsonObject("libraries").DeepClone()
For Each LibToken In InheritInstance.JsonObject("libraries")
    CurrentLib.Add(LibToken)
Next
'合并其他项：子版本优先于父版本
InheritInstance.JsonObject.Merge(_JsonObject)
_JsonObject = InheritInstance.JsonObject
_JsonObject("libraries") = CurrentLib
```

- 自引用（`inheritsFrom == Name`）清空并跳过，不报错（`:461-465`）；父版本继承名等于自身则抛"版本依赖项出现嵌套"（`:470`）。
- **libraries 是"子在前父在后"拼接**，其余字段父对象 `Merge(子)`（子覆盖父），数组语义交给 Newtonsoft 默认。
- 两处特判：LiteLoader（含 `liteloader`、名字不等于原版、无 `logging` 且 `jar` 等于原版名 → 继承名强制改为原版名，`:547-549`）；
  HMCL 格式（有 `patches` 无 `time`，按 `priority` 升序 Merge，再置 `id=Name`、删 `inheritsFrom`，`:427-455`）。

### 8.3 版本号识别与 Check

`JsonVersion`（`:514-534`）只在 `<名>.jar` 存在时读 zip 里的 `version.json`，失败只 Warn。
原版号识别在 `PCLCS\Minecraft\McVersion.cs:154-207`，是一串回退：发布时间<2013→`Old` → `pending` → `clientVersion` →
HMCL `patches[game]` → `--fml.mcVersion` → `inheritsFrom`/`jar` → downloads URL 段 → libraries 里 forge/fmlloader/OptiFine/intermediary 正则 →
`jar` 字段 → jar 内 `version.json` 的 `name`（长度<32 才用）→ JSON `id` → 文件夹名（此时 `Reliable=false`）。

`Check()` 四道（`:583-624`）：目录存在 → `mainClass` 可取（失败会清空 `JsonText`/`JsonObject`）→ `VanillaName` 非空 → 前置版本 `<InheritName>.json` 存在。
失败一律 `State=Error` + `Info` 文本，不抛异常。

### 8.4 本地扫描

`versions` 子目录遍历，跳过空目录、跳过名为 `cache`/`BLClient`/`PCL` 且无同名 json 的伪目录、处理 `.pclignore`（`:1141-1163`）。
缓存指纹是**文件夹名列表拼串的哈希**（`:975-976`），命中走 `InitMcInstanceListWithCache`，任一项读失败即全量重扫。
排序依次比发布时间、加载器有无（Fabric→NeoForge→Forge→OptiFine→LiteLoader）、组件版本码、名称（`:1288-1303`）。

---

## 9. 整合包（`ModModpack.vb`）

判定只看根目录与一级子目录的**特征文件**，优先级写死在 `:44-56`：

| 特征 | 类型 |
| --- | --- |
| `mcbbs.packmeta` | MCBBS（3） |
| `mmc-pack.json` | MMC（2） |
| `modrinth.index.json` | Modrinth（4） |
| `manifest.json`（无 `addons`） | CurseForge（0） |
| `manifest.json`（有 `addons`） | MCBBS（3） |
| `modpack.json` | HMCL（1） |
| `modpack.zip`/`modpack.mrpack` | 带启动器（9） |
| 都不匹配 | 普通压缩包，用正则反查 `.minecraft` 根（`:829-838`） |

统一流程两段式：`InstallLoaders`（解压 + overrides 复制 + 附加文件下载）先完成，再跑 `McInstallLoadersGet` 组装的
`MergeLoaders`（`ModDownloadLib.vb:1781-1864`：写 `.pclignore` → Fabric API → OptiFabric → 下载原版(39) → OptiFine → Forge → NeoForge →
LiteLoader → Fabric → 安装游戏/合并 JSON/按隔离信息投递 `mods`）。overrides 落地在解压任务的同一个 Task 内同步执行（`:411-412`）。

---

## 10. 资源搜索（`Modules\Resource\`）

- CurseForge：固定 `gameId=432&sortField=2&sortOrder=desc&pageSize=40`，按类型加 `classId`（6/4471/6945/6552/12），
  再叠 `categoryId`、`modLoaderType`（只取第一个）、`gameVersion`、`searchFilter`、`index`（`ResourceSearcher.vb:73-91`）。
- Modrinth：`limit=40&index=relevance` + `query` + `offset`，其余塞 `facets`（`project_type`、`categories:'tag'`、多选加载器、`versions:'x'`，`:99-110`）。
- 分页：CurseForge `offset += data.Count`、`total = pagination.totalCount`；Modrinth 用 `hits.Count`/`total_hits`，不足目标数继续翻（`:325-354`、`:470-478`）。
- 归一化成 `ResourceProject`（`ResourceProject.vb:150-378`）：Id/Slug/名称/简介/官网/更新时间/下载量/图标/Drops/加载器/Tags 逐字段映射，
  两家字段名完全不同（如 `dateReleased` vs `date_modified`，`latestFilesIndexes[].gameVersion` vs `game_versions`）。
- 过滤分层：请求层做 facet；特例 `Forge 且 Drop<140` 时不发加载器过滤（`ResourceSearcher.vb:301`），返回后在客户端只留 `None`/`Forge`（`:417`）。

---

## 11. UI 层

### 11.1 动画引擎（`ModAnimation.vb`，914 行）

- `AniData` 用**枚举对**（`TypeMain` 7 种 × `TypeSub` 13 种）编码"改哪个属性"，不靠属性名字符串（`:60-178`）；
  `TimeFinished` 用**负值编码延迟**（`:199`）。
- `Aa*` 家族的 `Obj` 有三态：控件引用 / `{控件, 依赖属性, 资源名}` / 委托（`:197`、`:348`、`:393`、`:449`）。
  **颜色动画的 `Value` 是差值**（`New MyColor(FindResource(Res)) - New MyColor(Obj.GetValue(Prop))`，`:394`），
  所以它天然支持"从当前色渐变到资源色"，结束时 `SetResourceReference` 把值挂回资源以便换肤跟随（`:885`）。
- `AniStart` 摊平嵌套集合后入 `AniGroups`；`Name=""` 用 `Uuid` 作键，否则**先 `AniStop(Name)` 再 Add**，天然实现同名覆盖（`:753-771`）。
- 主时钟：`AboveNormal` 后台线程死循环，`DeltaTime=(now-last).Clamp(0,100000)`，<3ms 跳过，其余 `RunInUiWait(AniTimer(DeltaTime*AniSpeed))`（`:805-851`）。
  所有属性写入都在 UI 线程。
- 缓动 11 个类都实现 `GetValue(t)`，`AniRun` 用**增量** `Lerp(0, Value, Ease.GetDelta(...))`（`:936`），
  各级增量望远镜求和仍然精确等于目标值——这是"某帧越过终点也不跑偏"的原因。
- `AniSpeed` 在 `SystemDebugAnim>=30` 时返回 200（`:13-18`），调试加速会把动画全部快进。

### 11.2 页面骨架与导航

- `MyPageRight` 的加载环由 `PageState`（10 态，`MyPageRight.vb:18-29`）与 `PageLoader.State` 共同驱动，
  6 个转移方法在 `Case Else` 上抛异常（`:204`、`:292`…），属强约束状态机。加载器 `Loading` 时用 `AaCode(...,400)` 延迟 400ms 再出加载环（防闪烁）。
- 入场动画：白名单控件（`MyCard/MyHint/MyExtraTextButton/TextBlock/MyTextButton`，`:478`）每个叠 Opacity/TranslateY 三条，`Delay += 25` 错峰（`:392-428`）。
- 导航：`PageStack` 是 `List(Of PageStackData)`（`FormMain.xaml.vb:1327`），`PageStackData` 重写 `Equals` 做"同类型且 Additional 相等"（`:1333-1349`）；
  `PageType` 0-9 区分主/副页面（`:1195-1232`）；`PageSubType` 注释明确"数值必须与 StackPanel 下标一致"（`:1234-1235`），
  `PageChange` 直接 `Children(SubType)` 索引（`:1375`、`:1383`）。

### 11.3 主题（`ModSecret.vb:65-134`）

`ColorHue=210 / ColorSat=85 / ColorLightAdjust=0` 经 HSL 生成 8 级主色 + 2 个背景色，写进 `Application.Current.Resources`
的 `ColorBrush1..8`/`ColorObject1..8`，`ThemeRefreshMain` 再画顶栏三段渐变。**开源版这组变量没有任何赋值点**，
设置里的 `UiLauncherHue/Sat/...` 也没有 `OnChanged`（`Settings.vb:131-134`），所以主题滑块实际是死的。

### 11.4 自绘控件套路

统一三件套：纯代码建可视树 → 颜色一律 `SetResourceReference` 到资源名 → 状态变化全走 `Aa*` 动画。
代表：`MyButton`（`ContentProperty("Inlines")` + 依赖属性穿透到内部 `LabText`，`:3-61`）、
`MyCard`（构造函数里手动 Insert 阴影/边框/网格三层，`:65-74`；高度动画区分短程/长程，`:185-224`）、
`MyLoading`（`State` 接受任意 `ILoadingTrigger`，无绑定时用 `MyLoadingStateSimulator`，`:251-276`）、
`MyMsgBox`（不是控件而是**队列 + 嵌套消息泵**：`ComponentDispatcher.PushModal` + `Dispatcher.PushFrame`，`ModMain.vb:230-274`）。

---

## 12. MeloongCore

| 模块 | 能力 | 主程序使用点 |
| --- | --- | --- |
| `Shared/Main.cs` | `AppName` + 正则默认超时 5s | `Application.xaml.vb:10` |
| `General/Config.cs` | 强类型 JSON 配置，500ms 尾随防抖 + `WriteAtomic`（先 `.tmp` 再 `File.Replace`） | `ModMinecraft.vb:574`、`FormMain.xaml.vb:641` |
| `General/Logger.cs` | 四级 + 六档行为 + `Log1..Log4` 轮转 + 独立 Lowest 线程 + `InterpolatedStringHandler` 惰性格式化 | `PclLogger.vb`（重写 `HandleBehavior` 做 Toast/弹窗） |
| `General/Progress.cs` | 三元和进度 `(actual, skiped, splited)` + `GetIncreasing()` 单调映射 | `ModLoader.vb:170-178` |
| `General/Worker/` | `RateLimitedWorker`（节流/防抖）、`RedoableWorker`（运行中再调只重跑一次） | `ModJava.vb:52`、`ModDownloadLib.vb:2042` |
| `General/ValueRange.cs` | 开闭区间与交集，用来表达 Java 版本需求 | `ModJava.vb:133/142/156` |
| `Utils/`（File/Path/String/Math/Directory/Registry/Task…） | 272+ 个静态方法 | 全仓 `FileUtils` 273 处、`PathUtils` 168 处 |
| `Wpf/` | `Dialogs`（原生对话框 + 补扩展名）、`ValueConverters`（算术/取反绑定）、`ModernTooltipService`（自绘 Popup 提示） | `Application.xaml:15-18`、`Wpf/Main.cs:4-6` |

工程洁癖程度：Shared 26 个源文件里 `System.Windows*` 引用为 0，Wpf 只引用 Shared，无反向依赖。
三处不干净：`LogBehavior` 把 UI 策略写进基础库枚举却空实现（`Logger.cs:236-237`）；`FileLogger` 默认目录与 `ConfigProviders.Default` 绑定
`Paths`，而 `AppName` 初值是 `"Meloong"`（`Main.cs:4`），求值时机错了路径就定错；`MsDelta`/`RegistryUtils` 是 Windows 专属却在 netstandard2.0 里。

测试：TUnit 1.43.38、`OutputType=Exe`、net48，37 个方法覆盖 Config/Progress/Worker/Cryptography/Directory/File/Path/TaskUtils；
`ValueRange`、`OneOf`、`ConcurrentList`、`Logger`、Wpf 层**无测试**。
值得注意的是主程序**没有采用** `Config` 的抽象层（`ConfigEntry` 在 `Plain Craft Launcher 2\` 下 grep 为 0），
只借用了 `JsonConfigProvider` 做版本级配置——新旧两套模型并存。

---

## 13. 缺陷与风险清单（按严重度）

### 13.1 会静默出错的

| # | 现象 | 依据 |
| --- | --- | --- |
| 1 | `JsonVersion` 用 `Static JsonVersionInited` 做方法级一次性标志，而 `_JsonVersion` 是实例字段：**第一个实例读过 jar 后，同进程内所有其他实例永远返回 `Nothing`** | `ModMinecraft.vb:516`、`:535` |
| 2 | `Check()` 的第三道（版本号非空）实际失效：`VanillaName` setter 把 null 强制成 `"Unknown"`，`IsNullOrEmpty` 永不成立 | `ModMinecraft.vb:600-607`、`McVersion.cs:14-15` |
| 3 | 实例列表缓存指纹只看目录名，往已有版本目录增删 jar 不会失效 | `ModMinecraft.vb:975` |
| 4 | 缓存回读把 `DisplayType` 读成 `<MC根>\PCL\Setup.ini` 而不是版本目录（其余 8 处都读版本目录） | `ModMinecraft.vb:1062` vs `:697` |
| 5 | 继承合并把子 JSON `Merge` 进父实例的缓存 `JObject` 后又当子用，"父 JSON"已不是文件内容 | `ModMinecraft.vb:478-479` |
| 6 | `LoaderTask.ShouldStart` 取输入异常时已置 `Failed`，`Start` 随后无条件写 `State = Loading`，失败被洗掉 | `ModLoader.vb:319-321`、`:341-343` |
| 7 | 忘记置 `HasOnStateChangedThread` 就永远收不到线程通道事件（无提示） | `ModLoader.vb:53-56`、`:107` |
| 8 | `LoaderCombo.Update` 无锁，可被 `Start` 与多个子加载器回调并发进入 | `ModLoader.vb:584-643` |
| 9 | 设置项的 `Type` 由默认值推断，默认值类型写错只在运行时炸，且被 `Get` 的 Catch 吞成默认值 | `Settings.vb:224`、`:357-360` |
| 10 | 解密失败静默回写默认值，等于静默丢数据；DES 固定 IV + `Identify` 常量，密钥可推导 | `Settings.vb:346-353`、`:439-463`、`ModSecret.vb:197` |
| 11 | `AniStop` 只删组不回滚属性，被迫在 `PageOnForceExit` 里手动 `Visibility=Collapsed` | `ModAnimation.vb:782-784`、`MyPageRight.vb:241-248` |
| 12 | `PageSubType` 与 XAML 下标强耦合，往中间插一项就错位 | `FormMain.xaml.vb:1234-1235`、`:1375` |
| 13 | 跨模块靠字符串动画组名协议（`AniStop("FrmMain LeftChange")` 等）避免重复触发，改名即断 | `FormMain.xaml.vb:1523`、`PageSetupLeft.xaml.vb:124` |

### 13.2 会导致数据/功能异常

| # | 现象 | 依据 |
| --- | --- | --- |
| 14 | 整合包把 mod 投进隔离目录，若 `Setup.ini` 的隔离开关没写成功 → "装好了但没有 mod" | `ModModpack.vb:141/146`、`:301` |
| 15 | `.pclignore` 只在本次启动首次加载时生效（首次直接删文件） | `ModMinecraft.vb:1044-1049` |
| 16 | 断点续传只在进程内有效：`NetManager.Start` 首次调用即删 `PathTemp\Download`，`Reset()` 清空分片 | `ModNet.vb:1806-1815`、`:1147-1156` |
| 17 | 跨任务并发写同一文件只靠原始大小写路径登记，`C:\a\B` 与 `c:\a\b` 可绕过 | `ModNet.vb:1829` vs `:1399` |
| 18 | Natives 只解压 `.dll`；路径非 ASCII 且非 GBK 时回退到**共享** natives 目录，多版本并行会互删文件 | `ModLaunch.vb:1682`、`:1729-1733` |
| 19 | 两份 `-Xmx` 会共存（用户自定义与 PCL 追加字符串不同，精确去重拦不住） | `ModLaunch.vb:1318`、`:1626` |
| 20 | JLW 冲突检测只看用户自定义参数，Nide/Auth 的 `-javaagent` 更早加入，导致"第三方登录 + JLW"共存 | `ModLaunch.vb:1295` vs `:1272-1288` |
| 21 | Authlib 每次启动都同步联网 prefetch，失败即整体启动失败，且 base64 塞进命令行 | `ModLaunch.vb:1281-1286` |
| 22 | 窗口探测用 ANSI API + `hWnd As Integer`，Unicode 标题失真、句柄签名不匹配 | `ModWatcher.vb:315`、`:348-350` |
| 23 | 读日志的挂接顺序反了（先 `BeginOutputReadLine` 再 `AddHandler`），启动最初几行可能丢 | `ModWatcher.vb:86-89` |

### 13.3 性能/可维护性

| # | 现象 | 依据 |
| --- | --- | --- |
| 24 | 动画每帧 `AniGroups.Values(i)` 按下标取值（每次重建枚举器），组多时单帧成本随组数平方增长 | `ModAnimation.vb:861-864`、`:912-917` |
| 25 | `Progress` 在 `Failed`/`Canceled` 返回 1；Combo 加权、任务栏不加权，两套口径 | `ModLoader.vb:146-163`、`:470-490`、`:722` |
| 26 | 巨型文件（`ModLaunch.vb` 1978 行、`ModNet.vb` 1662 行、`ModMinecraft.vb` 1874 行）+ `Module` 全局状态 + 单例 `FrmMain` | — |
| 27 | 主流程里有 `Do While ... Thread.Sleep(10)` 轮询等待动画/状态 | `ModLoader.vb:217`、`MyPageRight.vb:78-80` |
| 28 | 无自动化测试（`ModDevelop.Start()` 空壳）；子模块与密钥依赖让"clone 即编译"不成立 | `ModDevelop` 相关 |
| 29 | `MsDelta` 在主程序 0 引用（死代码） | `MeloongCore/Shared/General/MsDelta.cs` |

---

## 14. 如果要基于它做 PCLSE（改造建议）

不做泛泛的"重构"，只列**有代码依据的可替换点**：

1. **启动链插桩**：`McLaunchStart(Loader)` 里那 10 个 `LoaderTask` 就是全部业务步骤（`ModLaunch.vb:122-133`）。
   加自定义步骤只需往 `Loaders` 列表插一个 `LoaderTask`（例如"启动前校验版本完整性""注入自定义 agent"），权重按预计秒数给。
2. **参数后处理**：`McLaunchArgumentsJVM` 返回 `List(Of String)` 后才拼串（`:1401-1217`），
   fork 想加 `-D`/`-javaagent` 就在这里 `Args.Add`，不必碰 GC/编码那段高危代码。
3. **下载源策略**：`DlSourceOrder` + 三个 `DlSource*Get` 函数是唯一的源策略出口（`ModDownload.vb:1226-1312`），
   换成自建镜像只改这四处；但注意 `ModDownload.vb:1262-1272` 与 `ModMinecraft.vb:1884-1889` 对 Forge/Fabric/OptiFine 有硬编码例外。
4. **UI 换肤**：颜色全部走资源名（`ColorBrush1..8`/`ColorObject*`），改基色只需在 `ThemeRefresh` 前给出 `ColorHue/Sat/LightAdjust`
   三个变量的赋值——注意开源版这四个设置项没有 `OnChanged`（`Settings.vb:131-134`），要自己接。
5. **安装/整合包**：`McInstallLoadersGet` 返回的 `MergeLoaders` 是安装步骤的声明式列表（`ModDownloadLib.vb:1781-1864`），
   加新加载器（Quilt/自定义）就在那里插一段。
6. **必踩的许可约束**：`LICENCE` 要求重度修改版自称「PCL XXX 修改版」、关于页首位署名、继续开源、保留正版购买劝导、
   **Windows 下主色相必须为蓝色**。做分支前先读这份文件；`ModSecret.vb` 里 `VersionBranchMain = "OpenSource"`（`:6`）可作为分支标识位。
7. **优先修的 bug**：§13.1 的 #1（`JsonVersion` 静态标志）、#2（版本号校验失效）、#4（缓存读错路径）、
   §13.2 的 #14（整合包隔离开关）、#18（natives 共享目录互删）。这五个都是"用户能感知但日志不报"的类型。

---

## 15. 阅读与调试索引

| 顺序 | 文件 | 看什么 |
| --- | --- | --- |
| 1 | `Modules\Base\ModLoader.vb` | 先懂 Loader，否则后面全是"为什么这里在等状态" |
| 2 | `Modules\Base\ModBase.vb:426-457`、`:899-957` | `LoadState` 枚举顺序、`RunInUi/RunInThread` 语义 |
| 3 | `Modules\Minecraft\ModLaunch.vb:106-145`、`:1191-1401` | 启动链与参数装配 |
| 4 | `Modules\Base\ModNet.vb:373-406`、`:674-678`、`:1079-1120` | 下载状态机、切块条件、降级路径 |
| 5 | `Modules\Minecraft\ModDownload.vb:1226-1312` | 镜像策略 |
| 6 | `Modules\Minecraft\ModMinecraft.vb:457-481`、`:514-534`、`:583-624` | 继承合并、`JsonVersion`、`Check` |
| 7 | `Modules\Minecraft\ModModpack.vb:44-77` | 七种整合包的判定 |
| 8 | `Pages\PageSetup\Settings.vb:200-273` | 存储源与加密 |
| 9 | `Modules\Base\ModAnimation.vb:60-200`、`:805-940` | 动画数据模型与主时钟 |
| 10 | `Controls\MyPageRight.vb`、`FormMain.xaml.vb:1370-1520` | 页面状态机与导航 |

调试建议：`Settings` 里有 `SystemDebugAnim`（动画加速）与 `SystemDebugDelay`（每个加载器完成随机 sleep 100~2000ms，`ModLoader.vb:90`），
Debug 配置会把 `BuildType` 标成 `Debug` 并弹"【开发者模式】"提示。

---

## 附录 A：本次构建与运行实录

环境：Windows 10.0.22631、dotnet SDK 8.0.428（自带 MSBuild 17.11.71）、.NET Framework 运行时 Release 533320（4.8.1）、
NuGet 缓存已有 `microsoft.netframework.referenceassemblies.net48 1.0.3`。**无 Visual Studio、无 4.8 开发包**。

失败的两次尝试（留作参考，别再重复踩）：

1. 直接 `dotnet msbuild "Plain Craft Launcher 2.vbproj" /p:TargetFrameworkRootPath=<refasm包>\build\`
   → 缺 `Microsoft.WinFX.targets`，XAML 不编译，`InitializeComponent` 全部未声明。
2. 再叠加 `/p:CustomAfterMicrosoftCommonTargets=<sdk>\Sdks\Microsoft.NET.Sdk.WindowsDesktop\targets\Microsoft.WinFX.targets`
   → `error MC1000: Could not find assembly 'mscorlib, Version=0.0.0.0'`（Core MSBuild 的标记编译任务与 net48 参考程序集不兼容）。

成功路径（一条命令）：

```powershell
$dotnet = 'D:\PCLSE Demo\dotnet\dotnet.exe'
cd 'D:\PCLSE Demo\src\Meloong-Git-PCL-93ede5d\Plain Craft Launcher 2'
& $dotnet build PCL.Shadow.vbproj -c Debug
# 输出：PCL.Shadow -> ...\bin\Debug\net48\Plain Craft Launcher 2.exe
#       0 个警告 0 个错误（MeloongCore / MeloongCore.Wpf / PCLCS 一并编译）
& $dotnet build PCL.Shadow.vbproj -c Release
```

首次运行产物里会创建 `PCL\Log1.txt`、`.minecraft\launcher_profiles.json`，并弹出"协议授权"，属预期行为。

## 附录 B：构建时可复用的检查清单

- [ ] `dotnet build` 报 `CS1617 langversion 13.0` → 说明用的是 SDK 8；给 C# 工程传 `LangVersion=12.0` 或换 SDK 9。
- [ ] `InitializeComponent 未声明` → WPF 标记编译没跑（缺 `ApplicationDefinition`/`Page` 项，或引错了 vbproj）。
- [ ] 运行报 `找不到资源 "images\icon.ico"` → `Resource` 项用了绝对路径，资源名丢层级；把工程放源码目录用相对路径。
- [ ] 编译报 `未声明 MathRange / SetTop / SliderDrag_Finish` → 忘了排除 `Controls\MySliderDot.xaml.vb`。
- [ ] `MSB3030 找不到 Resources\java-wrapper.jar` → 该文件在 `PCLCS\Launch\`，用 `Link` 映射。
- [ ] `MSB3191 无法创建目录 obj\...\D:\...` → `DocumentationFile` 用了绝对路径。
