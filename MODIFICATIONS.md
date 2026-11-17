# 本仓库相对上游的改动

上游：<https://github.com/Meloong-Git/PCL>（main @ `93ede5d`）
本仓库：**PCL-A 修改版**，仅供学习与自用构建，遵循上游《PCL 分发有限许可》。

## 1. 下载功能恢复

`Plain Craft Launcher 2\Modules\ModSecret.vb:18`

```vb
Public Const RestrictMcDownload As Boolean = False   ' 上游开源版为 True
```

上游从 2.99.0.0 起下线了 MC 下载入口（只摘入口 + 一个编译期常量，引擎代码仍完整）。
把它改回 `False` 后，下载页「原版游戏」、版本安装页、整合包安装、导入整合包等入口全部恢复。

## 2. 微软登录 client id

`Plain Craft Launcher 2\Modules\ModSecret.vb:10`

```vb
Public OAuthClientId As String = If(Environment.GetEnvironmentVariable("PCL_MS_CLIENT_ID"), "c30fbd50-5a79-4aa3-81cf-3bac0047059e")
```

环境变量 `PCL_MS_CLIENT_ID` 优先，便于替换而不重编。

> 该应用需在 Azure/Entra 门户开启「允许公共客户端流」(`allowPublicClient: true`)，
> 否则设备码请求会报 `AADSTS70002`。

## 3. 微软登录 403 文案修正

`Plain Craft Launcher 2\Modules\Minecraft\ModLaunch.vb`（`MsLoginStep4`）

上游把所有 403 都映射成「当前 IP 的登录尝试异常，请更换 VPN 节点」，会把
`Invalid app registration`（应用未获准入）误报成网络问题。现按响应体细分：

| 响应体特征 | 提示 |
| --- | --- |
| `Invalid app registration` | 应用未获 Minecraft API 准入，与网络无关 |
| `Account security interrupt` | 账号被安全拦截，去微软账户安全页 |
| 其它 403 | 保持原「IP / VPN」提示 |

## 4. 改用官方启动器端点获取 MC 令牌

同一函数里，第 4 步优先请求：

```
POST https://api.minecraftservices.com/launcher/login
{"xtoken":"XBL3.0 x=<uhs>;<xsts>","platform":"PC_LAUNCHER"}
```

失败（401/403/404）再回落到上游的 `authentication/login_with_xbox`。
原因：`launcher/login` 是官方启动器使用的端点，不校验调用方应用是否在 Minecraft API 准入名单里，
而 `login_with_xbox` 会对未登记的应用返回 `403 Invalid app registration`。
Prism Launcher 等第三方启动器同样走 `launcher/login`。

## 5. 构建方式（无需 Visual Studio）

新增 `Plain Craft Launcher 2\PCL.Shadow.vbproj`：SDK 风格 VB/WPF 工程，用 `Microsoft.NET.Sdk` + `UseWPF` + `net48`
编译同一批源码，参考程序集来自 NuGet 包 `Microsoft.NETFramework.ReferenceAssemblies`。

```powershell
# 需要 dotnet SDK 8+（C# 工程 LangVersion=13，SDK 8 下由 AdditionalProperties 降为 12）
dotnet build "Plain Craft Launcher 2\PCL.Shadow.vbproj" -c Release
```

产物：`Plain Craft Launcher 2\bin\Release\net48\Plain Craft Launcher 2.exe`（单文件，依赖以资源内嵌）。

原 `Plain Craft Launcher 2.vbproj` 保持不变，仍可用 VS 2022 + .NET Framework 4.8 开发包构建。

## 6. 已知状态（2026-11-17 实测）

- 下载：Mojang 版本清单与 BMCLAPI 镜像正常，安装页可用
- 微软登录：设备码 → OAuth → XBL → XSTS 全通过；`/launcher/login` 端点尚待完整回归
- 离线登录：正常

## 许可提醒

上游 `LICENCE` 要求：重度修改版须自称「PCL XXX 修改版」、在关于页首位署名、继续开源、
保留正版购买劝导，且 Windows 下主色相必须为蓝色。分发前请自行核对条款。

## 7. 品牌调整为 PCL-A

| 位置 | 改动 |
| --- | --- |
| `Plain Craft Launcher 2\FormMain.xaml` | 窗口标题 `Plain Craft Launcher　` → `PCL-A　` |
| `Plain Craft Launcher 2\Application.xaml.vb` | 单实例查找窗口改为 `PCL-A　`（旧名保留为回退） |
| `Plain Craft Launcher 2\PCL.Shadow.vbproj`、`Plain Craft Launcher 2.vbproj` | `AssemblyName` → `PCL-A`，产物为 `PCL-A.exe` |
| 全部 `*.xaml` / `ModBase.vb`（共 15 处） | pack URI `/Plain Craft Launcher 2;component/…` → `/PCL-A;component/…` |
| `My Project\AssemblyInfo.vb` | `AssemblyTitle` → `PCL-A 启动器（Plain Craft Launcher 修改版）`；`AssemblyProduct` 保持 `Plain Craft Launcher`，以免破坏 `ModModpack.vb:782` 的整合包启动器识别 |
| `Pages\PageOther\PageOtherAbout.xaml` | 关于页首行改为「PCL-A（本仓库修改版）」+ 维护者与上游说明，头像换成 PCL 图标；龙腾猫跃 / HerobrineXia 两行保留 |

许可要求的三项已满足：自称「PCL-A 修改版」、关于页首位署名（修改者在前，原作者在后）、继续开源（本仓库）、保留正版购买劝导与蓝色主色相（未改动主题）。