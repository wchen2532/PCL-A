# ms-client-id.ps1 —— 用 PCL 的原始请求验证 / 写入 / 重编 Microsoft OAuth client id
#
# 用法：
#   .\ms-client-id.ps1 -ClientId <GUID>              # 只验证（拿一个设备码，登录网页会打印出来）
#   .\ms-client-id.ps1 -ClientId <GUID> -Poll        # 验证并真正走完一次设备码登录，确认能拿到令牌
#   .\ms-client-id.ps1 -ClientId <GUID> -Apply       # 写入 Modules\ModSecret.vb 的 OAuthClientId 默认值
#   .\ms-client-id.ps1 -ClientId <GUID> -Apply -Build  # 写入并重编 Release
#
# 它复刻的是 ModLaunch.vb:888-890 与 MyMsgLogin.xaml.vb:108-117 的请求，
# 所以这里通过 = PCL 里也能通过。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ClientId,
    [switch]$Poll,
    [switch]$Apply,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
$Scope = 'XboxLive.signin%20offline_access'
$DeviceCodeUrl = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode'
$TokenUrl = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/token'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $RepoRoot 'src\Meloong-Git-PCL-93ede5d'))) { $RepoRoot = 'D:\PCLSE Demo' }
$SecretFile = Join-Path $RepoRoot 'src\Meloong-Git-PCL-93ede5d\Plain Craft Launcher 2\Modules\ModSecret.vb'
$ShadowProj = Join-Path $RepoRoot 'src\Meloong-Git-PCL-93ede5d\Plain Craft Launcher 2\PCL.Shadow.vbproj'
$Dotnet = Join-Path $RepoRoot 'dotnet\dotnet.exe'

Write-Host "client_id = $ClientId" -ForegroundColor Cyan
if ($Force) { Write-Host "（-Force：跳过设备码验证，直接改源码/编译）" -ForegroundColor Yellow }

# ---------- 1. 设备码 ----------
if (-not $Force) {
try {
    $resp = Invoke-WebRequest -Uri $DeviceCodeUrl -Method Post `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body "client_id=$ClientId&tenant=/consumers&scope=$Scope" `
        -UseBasicParsing -TimeoutSec 25
} catch {
    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { '?' }
    $body = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Host "✗ 设备码申请失败（HTTP $code）" -ForegroundColor Red
    Write-Host ($body -replace '\s+', ' ')
    Write-Host @"

常见错误码对照：
  AADSTS700016  application not found  -> client id 不是当前 consumers 目录里的应用（拼错，或是旧的 MSA app id）
  AADSTS9002332  configured for AAD users only -> 注册时没勾选“个人 Microsoft 账户”
  AADSTS7000218  request body must contain client_secret -> 没开“允许公共客户端流”
  AADSTS70002   client must be marked as mobile -> 没开“允许公共客户端流”（或没有“移动和桌面应用程序”平台）
  AADSTS900144  request body must contain client_id -> client id 传空（PCL 里就是没注入 OAuthClientId）
"@ -ForegroundColor Yellow
    exit 1
}
}

if (-not $Force) {
$dc = $resp.Content | ConvertFrom-Json
Write-Host "✓ 设备码申请成功" -ForegroundColor Green
Write-Host "  登录地址 : $($dc.verification_uri)"
Write-Host "  输入代码 : $($dc.user_code)"
Write-Host "  有效期   : $($dc.expires_in) 秒（轮询间隔 $($dc.interval) 秒）"
Write-Host "  提示     : 打开上面的地址，输入该代码并同意，PCL 就能拿到令牌。"
}

# ---------- 2. 可选：轮询拿令牌 ----------
if ($Poll) {
    $interval = [int]$dc.interval; if ($interval -lt 1) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    Write-Host "`n等待浏览器里完成登录……（Ctrl+C 可中断）" -ForegroundColor Cyan
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $t = Invoke-WebRequest -Uri $TokenUrl -Method Post `
                -ContentType 'application/x-www-form-urlencoded' `
                -Body "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$ClientId&device_code=$($dc.device_code)&scope=$Scope" `
                -UseBasicParsing -TimeoutSec 25
            $tok = $t.Content | ConvertFrom-Json
            Write-Host "✓ 登录成功" -ForegroundColor Green
            Write-Host "  access_token  : $($tok.access_token.Length) 字符"
            Write-Host "  refresh_token : $($tok.refresh_token.Length) 字符（将写入 PCL 的 LoginMsJson）"
            Write-Host "  expires_in    : $($tok.expires_in) 秒"
            $Poll = $false
            break
        } catch {
            $body = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            if ($body -match 'authorization_pending') { Write-Host '  … 尚未完成授权' -ForegroundColor DarkGray; continue }
            if ($body -match 'slow_down') { $interval += 5; continue }
            if ($body -match 'expired_token') { Write-Host '✗ 设备码过期，重跑一次' -ForegroundColor Red; exit 1 }
            Write-Host "✗ 令牌请求失败：$($body -replace '\s+',' ')" -ForegroundColor Red
            exit 1
        }
    }
}

# ---------- 3. 可选：写入源码 ----------
if ($Apply) {
    if (-not (Test-Path $SecretFile)) { Write-Host "✗ 找不到 $SecretFile" -ForegroundColor Red; exit 1 }
    $text = Get-Content $SecretFile -Raw -Encoding utf8
    $new = "    Public OAuthClientId As String = If(Environment.GetEnvironmentVariable(""PCL_MS_CLIENT_ID""), ""$ClientId"")"
    $pattern = '(?m)^\s*Public OAuthClientId As String = .*$'
    if ($text -notmatch $pattern) { Write-Host '✗ ModSecret.vb 里没找到 OAuthClientId 定义' -ForegroundColor Red; exit 1 }
    $text = [regex]::Replace($text, $pattern, $new)
    Set-Content $SecretFile -Value $text -Encoding utf8 -NoNewline
    Write-Host "✓ 已写入 ModSecret.vb（环境变量 PCL_MS_CLIENT_ID 仍然优先）" -ForegroundColor Green
    Select-String -Path $SecretFile -Pattern 'OAuthClientId'
}

# ---------- 4. 可选：重编 ----------
if ($Build) {
    if (-not (Test-Path $Dotnet)) { Write-Host "✗ 找不到 $Dotnet" -ForegroundColor Red; exit 1 }
    Write-Host "`n开始编译 Release ……" -ForegroundColor Cyan
    & $Dotnet build $ShadowProj -c Release
    if ($LASTEXITCODE -ne 0) { Write-Host '✗ 编译失败' -ForegroundColor Red; exit 1 }
    $exe = Join-Path $RepoRoot 'src\Meloong-Git-PCL-93ede5d\Plain Craft Launcher 2\bin\Release\net48\Plain Craft Launcher 2.exe'
    Write-Host "✓ 编译完成：$exe" -ForegroundColor Green
}
