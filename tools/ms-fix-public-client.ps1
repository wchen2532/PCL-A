# ms-fix-public-client.ps1 —— 给应用注册开启「允许公共客户端流」（allowPublicClient / isFallbackPublicClient）
#
# 用途：解决设备码登录报 AADSTS70002: The client application must be marked as 'mobile'.
# 原理：用 Microsoft Graph PowerShell 的公共 client id 走设备码登录，
#       拿到 Graph 令牌后 PATCH 应用对象的 isFallbackPublicClient = true。
#
# 用法：
#   .\ms-fix-public-client.ps1 -AppId c30fbd50-5a79-4aa3-81cf-3bac0047059e
#   .\ms-fix-public-client.ps1 -AppId <GUID> -Tenant common        # 应用在某个工作/学校租户里时用 common 或具体租户 ID
#
# 需要：你的账号是该应用的所有者（或目录管理员），且允许同意 Application.ReadWrite.All。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [string]$Tenant = 'consumers',
    [string]$GraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',   # Microsoft Graph PowerShell（公共客户端）
    [string]$Scope = 'Application.ReadWrite.All offline_access'
)

$ErrorActionPreference = 'Stop'
$dcUrl = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode"
$tokenUrl = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
$graph = 'https://graph.microsoft.com/v1.0'

Write-Host "目标应用 appId = $AppId（租户视图：$Tenant）" -ForegroundColor Cyan

# 1. 设备码
$enc = [uri]::EscapeDataString($Scope)
$dc = (Invoke-WebRequest -Uri $dcUrl -Method Post -ContentType 'application/x-www-form-urlencoded' `
        -Body "client_id=$GraphClientId&scope=$enc" -UseBasicParsing -TimeoutSec 25).Content | ConvertFrom-Json

Write-Host "`n请打开下面地址并输入代码（650 秒内有效）：" -ForegroundColor Yellow
Write-Host "  地址 : $($dc.verification_uri)"
Write-Host "  代码 : $($dc.user_code)" -ForegroundColor Green
try { Start-Process $dc.verification_uri } catch { }
try { Set-Clipboard -Value $dc.user_code } catch { }

# 2. 轮询
$interval = [int]$dc.interval; if ($interval -lt 1) { $interval = 5 }
$deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
$tok = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $interval
    try {
        $tok = (Invoke-WebRequest -Uri $tokenUrl -Method Post -ContentType 'application/x-www-form-urlencoded' `
                -Body "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$GraphClientId&device_code=$($dc.device_code)&scope=$enc" `
                -UseBasicParsing -TimeoutSec 25).Content | ConvertFrom-Json
        break
    } catch {
        $msg = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        if ($msg -match 'authorization_pending') { Write-Host '  … 等待授权' -ForegroundColor DarkGray; continue }
        if ($msg -match 'slow_down') { $interval += 5; continue }
        Write-Host "`n✗ 令牌获取失败：$($msg -replace '\s+',' ')" -ForegroundColor Red
        Write-Host @"
可能原因：
  * 账号不是该应用的所有者 → 用创建应用的那个账号登录
  * 未同意 Application.ReadWrite.All → 登录时会弹同意页，需要勾选同意
  * 应用在一个工作/学校租户里 → 加 -Tenant <租户ID 或域名>
"@ -ForegroundColor Yellow
        exit 1
    }
}
if (-not $tok) { Write-Host '✗ 设备码过期' -ForegroundColor Red; exit 1 }
Write-Host '✓ 已拿到 Graph 令牌' -ForegroundColor Green
$headers = @{ Authorization = "Bearer $($tok.access_token)"; 'Content-Type' = 'application/json' }

# 3. 找应用
function Get-ErrBody($e) {
    try {
        $resp = $e.Exception.Response
        if ($resp) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $t = $sr.ReadToEnd(); $sr.Close(); if ($t) { return $t }
        }
    } catch { }
    if ($e.ErrorDetails) { return $e.ErrorDetails.Message }
    return $e.Exception.Message
}

$found = $null
$errText = ''
try {
    $r = Invoke-RestMethod -Uri "$graph/applications?`$filter=appId eq '$AppId'&`$select=id,appId,displayName,isFallbackPublicClient" -Headers $headers -Method Get -TimeoutSec 25
    $found = $r.value | Select-Object -First 1
} catch {
    $errText = Get-ErrBody $_
    Write-Host "  [诊断] 带 `$filter 查询失败：$(($errText -replace '\s+',' '))" -ForegroundColor DarkYellow
    # 兜底：不带 filter 全量取一页，本地匹配
    try {
        $r2 = Invoke-RestMethod -Uri "$graph/applications?`$select=id,appId,displayName,isFallbackPublicClient&`$top=999" -Headers $headers -Method Get -TimeoutSec 40
        $found = $r2.value | Where-Object { $_.appId -eq $AppId } | Select-Object -First 1
    } catch {
        $errText = Get-ErrBody $_
        Write-Host "  [诊断] 全量查询也失败：$(($errText -replace '\s+',' '))" -ForegroundColor DarkYellow
    }
}
if (-not $found) {
    Write-Host "✗ 当前租户里找不到 appId=$AppId 的应用（或 Graph 目录访问被个人账号限制）" -ForegroundColor Red
    Write-Host @"
改为门户手动操作（三次点击，效果相同）：
  1) https://entra.microsoft.com → 应用注册 → 点进该应用（别点“企业应用程序”）
  2) 左侧“身份验证” → 页面最底部“高级设置” → 允许公共客户端流 = 是
  3) 顶部“保存”
  或：左侧“清单” → "allowPublicClient": true → 保存
  或：身份验证 → 添加平台 → 移动和桌面应用程序 → 重定向 URI 填 http://localhost → 保存
"@ -ForegroundColor Yellow
    exit 1
}
Write-Host "  找到应用：$($found.displayName)  objectId=$($found.id)  isFallbackPublicClient=$($found.isFallbackPublicClient)"

# 4. 打补丁
$body = '{"isFallbackPublicClient":true}'
Invoke-RestMethod -Uri "$graph/applications/$($found.id)" -Headers $headers -Method Patch -Body $body -TimeoutSec 25 | Out-Null
$after = (Invoke-RestMethod -Uri "$graph/applications/$($found.id)?`$select=isFallbackPublicClient" -Headers $headers -Method Get -TimeoutSec 25)
Write-Host "✓ 已设置 isFallbackPublicClient = $($after.isFallbackPublicClient)" -ForegroundColor Green

# 5. 复验设备码端点
$body2 = "client_id=$AppId&tenant=/consumers&scope=XboxLive.signin%20offline_access"
try {
    $v = (Invoke-WebRequest -Uri 'https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode' -Method Post `
            -ContentType 'application/x-www-form-urlencoded' -Body $body2 -UseBasicParsing -TimeoutSec 25).Content | ConvertFrom-Json
    Write-Host "`n✓ 复验通过：user_code=$($v.user_code)  uri=$($v.verification_uri)" -ForegroundColor Green
    Write-Host '  现在 PCL 里点「登录」即可。' -ForegroundColor Green
} catch {
    $msg = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Host "`n✗ 复验仍失败：$($msg -replace '\s+',' ')" -ForegroundColor Red
    if ($msg -match '70002') { Write-Host '  补丁可能未传播（等 1~2 分钟再试），或应用还有 Web 平台的重定向 URI 需要清掉。' -ForegroundColor Yellow }
}
