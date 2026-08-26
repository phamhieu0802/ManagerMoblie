<#
.SYNOPSIS
    Tu dong tang version, build tat ca platform, tao GitHub Release.
.DESCRIPTION
    - Doc version hien tai tu lib/core/version.dart
    - Tang patch: 2.1.0 -> 2.1.1
    - Cap nhat version moi vao TAT CA file: version.dart, app_info_screen.dart, setup.iss, pubspec.yaml, HUONGDAN.md, README.md
    - Build: Flutter Windows, Flutter APK, Inno Setup installer
    - Tao GitHub Release voi TAT CA file (setup.exe + APK)
    - Tag v{version}
.PARAMETER Changelog
    Mo ta ban cap nhat (de trong thi tu lay tu git log 5 commit gan nhat).
.EXAMPLE
    .\scripts\create_release.ps1 -Changelog "Sua bug cong no, them auto-update"
#>
param(
    [string]$Changelog = ""
)

$ErrorActionPreference = "Stop"
$ghPath = "C:\Program Files\GitHub CLI\gh.exe"
$isccPath = "C:\Users\Admin\AppData\Local\Programs\Inno Setup 6\ISCC.exe"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# ============================================================
# 1. Doc version hien tai
# ============================================================
$versionFile = Join-Path $repoRoot "lib\core\version.dart"
$versionContent = Get-Content $versionFile -Raw
$match = [regex]::Match($versionContent, "currentAppVersion\s*=\s*'([\d.]+)'")
if (-not $match.Success) {
    Write-Host "LOI: Khong the doc version tu $versionFile" -ForegroundColor Red
    exit 1
}
$currentVersion = $match.Groups[1].Value
$parts = $currentVersion.Split('.')
$major = [int]$parts[0]
$minor = [int]$parts[1]
$patch = [int]$parts[2] + 1
$newVersion = "$major.$minor.$patch"
$tagName = "v$newVersion"

Write-Host "Version hien tai: $currentVersion" -ForegroundColor Cyan
Write-Host "Version moi:      $newVersion" -ForegroundColor Green
Write-Host "Tag:              $tagName" -ForegroundColor Green

# ============================================================
# 2. Cap nhat version o TAT CA cac file
# ============================================================
# version.dart
$versionContent = $versionContent -replace "currentAppVersion = '$currentVersion'", "currentAppVersion = '$newVersion'"
Set-Content $versionFile $versionContent -NoNewline
Write-Host "Da cap nhat version.dart" -ForegroundColor Gray

# app_info_screen.dart
$appInfoFile = Join-Path $repoRoot "lib\features\settings\screens\app_info_screen.dart"
if (Test-Path $appInfoFile) {
    $appInfoContent = Get-Content $appInfoFile -Raw
    $appInfoContent = $appInfoContent -replace "kAppVersion = 'v$currentVersion'", "kAppVersion = 'v$newVersion'"
    Set-Content $appInfoFile $appInfoContent -NoNewline
    Write-Host "Da cap nhat app_info_screen.dart" -ForegroundColor Gray
}

# setup.iss
$issFile = Join-Path $repoRoot "windows\installer\setup.iss"
$issContent = Get-Content $issFile -Raw
$issContent = $issContent -replace "AppVersion=$currentVersion", "AppVersion=$newVersion"
Set-Content $issFile $issContent -NoNewline
Write-Host "Da cap nhat setup.iss" -ForegroundColor Gray

# pubspec.yaml
$pubspecFile = Join-Path $repoRoot "pubspec.yaml"
$pubspecContent = Get-Content $pubspecFile -Raw
$buildNumber = $major * 10000 + $minor * 100 + $patch
$pubspecContent = $pubspecContent -replace "version: \d+\.\d+\.\d+\+\d+", "version: $newVersion+$buildNumber"
Set-Content $pubspecFile $pubspecContent -NoNewline
Write-Host "Da cap nhat pubspec.yaml" -ForegroundColor Gray

# HUONGDAN.md
$hqdFile = Join-Path $repoRoot "HUONGDAN.md"
if (Test-Path $hqdFile) {
    $hqdContent = Get-Content $hqdFile -Raw
    $hqdContent = $hqdContent -replace "Manager MSR \|v$currentVersion", "Manager MSR | v$newVersion"
    Set-Content $hqdFile $hqdContent -NoNewline
    Write-Host "Da cap nhat HUONGDAN.md" -ForegroundColor Gray
}

# README.md
$readmeFile = Join-Path $repoRoot "README.md"
if (Test-Path $readmeFile) {
    $readmeContent = Get-Content $readmeFile -Raw
    $readmeContent = $readmeContent -replace "Manager MSR \|v$currentVersion", "Manager MSR | v$newVersion"
    Set-Content $readmeFile $readmeContent -NoNewline
    Write-Host "Da cap nhat README.md" -ForegroundColor Gray
}

# ============================================================
# 3. Build Flutter Windows
# ============================================================
Write-Host "`nDang build Flutter Windows..." -ForegroundColor Yellow
flutter build windows --release 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "LOI: Flutter build Windows that bai!" -ForegroundColor Red
    exit 1
}
Write-Host "Da build Flutter Windows" -ForegroundColor Gray

# ============================================================
# 4. Build Inno Setup Installer
# ============================================================
Write-Host "`nDang build Inno Setup installer..." -ForegroundColor Yellow
if (-not (Test-Path $isccPath)) {
    Write-Host "LOI: Inno Setup khong tim thay tai $isccPath" -ForegroundColor Red
    exit 1
}
& $isccPath (Join-Path $repoRoot "windows\installer\setup.iss") 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "LOI: Inno Setup build that bai!" -ForegroundColor Red
    exit 1
}
$installerPath = Join-Path $repoRoot "dist\Manager_MSR_Setup.exe"
if (-not (Test-Path $installerPath)) {
    Write-Host "LOI: Khong tim thay $installerPath" -ForegroundColor Red
    exit 1
}
$fileSize = [math]::Round((Get-Item $installerPath).Length / 1MB, 1)
Write-Host "Installer: $installerPath ($fileSize MB)" -ForegroundColor Gray

# ============================================================
# 5. Build Flutter Android APK
# ============================================================
Write-Host "`nDang build Flutter Android APK..." -ForegroundColor Yellow
flutter build apk --release 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "LOI: Flutter build APK that bai!" -ForegroundColor Red
    exit 1
}
$apkPath = Join-Path $repoRoot "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apkPath)) {
    Write-Host "LOI: Khong tim thay $apkPath" -ForegroundColor Red
    exit 1
}
$apkSize = [math]::Round((Get-Item $apkPath).Length / 1MB, 1)
Write-Host "APK: $apkPath ($apkSize MB)" -ForegroundColor Gray

# ============================================================
# 6. Tao changelog
# ============================================================
if ([string]::IsNullOrWhiteSpace($Changelog)) {
    $gitLog = git -C $repoRoot log --oneline -10 --no-merges 2>&1
    if ($gitLog -is [array]) {
        $Changelog = ($gitLog | Select-Object -First 10) -join "`n"
    } else {
        $Changelog = "$gitLog"
    }
}
Write-Host "`nChangelog:" -ForegroundColor Cyan
Write-Host $Changelog -ForegroundColor Gray

# ============================================================
# 7. Git commit + push
# ============================================================
Write-Host "`nDang commit va push..." -ForegroundColor Yellow
git -C $repoRoot add -A
git -C $repoRoot commit -m "v$newVersion: release"
$token = & $ghPath auth token 2>$null
$token = $token.Trim()
git -C $repoRoot remote set-url origin "https://x-access-token:${token}@github.com/phamhieu0802/ManagerMoblie.git"
git -C $repoRoot tag $tagName
git -C $repoRoot push origin master --tags 2>&1 | Out-Null
Write-Host "Da push code + tag $tagName" -ForegroundColor Gray

# ============================================================
# 8. Tao GitHub Release + upload TAT CA file
# ============================================================
Write-Host "`nDang tao GitHub Release..." -ForegroundColor Yellow

# Xoa release cu neu tag da ton tai
& $ghPath release delete $tagName --repo "phamhieu0802/ManagerMoblie" --yes 2>&1 | Out-Null
git -C $repoRoot tag -d $tagName 2>&1 | Out-Null
git -C $repoRoot push origin ":refs/tags/$tagName" 2>&1 | Out-Null

# Tao release moi + upload installer + APK
& $ghPath release create $tagName `
    --repo "phamhieu0802/ManagerMoblie" `
    --title "Manager MSR $newVersion" `
    --notes "$Changelog" `
    --latest `
    $installerPath `
    $apkPath

if ($LASTEXITCODE -ne 0) {
    Write-Host "LOI: Tao GitHub Release that bai!" -ForegroundColor Red
    exit 1
}

Write-Host "`n ===== THANH CONG =====" -ForegroundColor Green
Write-Host "Release: https://github.com/phamhieu0802/ManagerMoblie/releases/tag/$tagName" -ForegroundColor Cyan
Write-Host "Files uploaded:" -ForegroundColor Cyan
Write-Host "  - Manager_MSR_Setup.exe ($fileSize MB) - Windows installer" -ForegroundColor Gray
Write-Host "  - app-release.apk ($apkSize MB) - Android APK" -ForegroundColor Gray
Write-Host "App se tu check va hien dialog cap nhat khi mo lai." -ForegroundColor Gray
