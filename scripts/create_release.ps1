<#
.SYNOPSIS
    Tự động tăng version, build installer, tạo GitHub Release và upload file .exe.
.DESCRIPTION
    - Đọc version hiện tại từ lib/core/version.dart
    - Tăng patch: 2.1.0 -> 2.1.1
    - Ghi lại version mới vào: version.dart, setup.iss, pubspec.yaml
    - Build installer bằng Inno Setup
    - Tạo GitHub Release trên phamhieu0802/ManagerMoblie với tag v{version}
    - Upload Manager_MSR_Setup.exe làm asset
.PARAMETER Changelog
    Mô tả bản cập nhật (để trống thì tự lấy từ git log 5 commit gần nhất).
.EXAMPLE
    .\scripts\create_release.ps1 -Changelog "Sửa bug công nợ, thêm auto-update"
#>
param(
    [string]$Changelog = ""
)

$ErrorActionPreference = "Stop"
$ghPath = "C:\Program Files\GitHub CLI\gh.exe"
$isccPath = "C:\Users\Admin\AppData\Local\Programs\Inno Setup 6\ISCC.exe"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# ============================================================
# 1. Đọc version hiện tại
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
# 2. Cập nhật version ở tất cả các file
# ============================================================
# version.dart
$versionContent = $versionContent -replace "currentAppVersion = '$currentVersion'", "currentAppVersion = '$newVersion'"
Set-Content $versionFile $versionContent -NoNewline
Write-Host "Da cap nhat version.dart" -ForegroundColor Gray

# setup.iss
$issFile = Join-Path $repoRoot "windows\installer\setup.iss"
$issContent = Get-Content $issFile -Raw
$issContent = $issContent -replace "AppVersion=$currentVersion", "AppVersion=$newVersion"
Set-Content $issFile $issContent -NoNewline
Write-Host "Da cap nhat setup.iss" -ForegroundColor Gray

# pubspec.yaml
$pubspecFile = Join-Path $repoRoot "pubspec.yaml"
$pubspecContent = Get-Content $pubspecFile -Raw
# pubspec version format: X.Y.Z+BUILD (tăng build number cùng patch)
$buildNumber = $major * 10000 + $minor * 100 + $patch
$pubspecContent = $pubspecContent -replace "version: \d+\.\d+\.\d+\+\d+", "version: $newVersion+$buildNumber"
Set-Content $pubspecFile $pubspecContent -NoNewline
Write-Host "Da cap nhat pubspec.yaml" -ForegroundColor Gray

# ============================================================
# 3. Build installer
# ============================================================
Write-Host "`nDang build installer..." -ForegroundColor Yellow

# Build Flutter Windows release
flutter build windows --release 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "LOI: Flutter build that bai!" -ForegroundColor Red
    exit 1
}
Write-Host "Da build Flutter Windows" -ForegroundColor Gray

# Build Inno Setup
if (-not (Test-Path $isccPath)) {
    Write-Host "LOI: Inno Setup khong tim thay tai $isccPath" -ForegroundColor Red
    exit 1
}
& $isccPath (Join-Path $repoRoot "windows\installer\setup.iss") 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "LOI: Inno Setup build that bai!" -ForegroundColor Red
    exit 1
}
Write-Host "Da build installer" -ForegroundColor Gray

# Kiểm tra file installer
$installerPath = Join-Path $repoRoot "dist\Manager_MSR_Setup.exe"
if (-not (Test-Path $installerPath)) {
    Write-Host "LOI: Khong tim thay $installerPath" -ForegroundColor Red
    exit 1
}
$fileSize = [math]::Round((Get-Item $installerPath).Length / 1MB, 1)
Write-Host "Installer: $installerPath ($fileSize MB)" -ForegroundColor Gray

# ============================================================
# 4. Tạo changelog
# ============================================================
if ([string]::IsNullOrWhiteSpace($Changelog)) {
    # Lấy 10 commit gần nhất làm changelog
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
# 5. Tạo GitHub Release
# ============================================================
Write-Host "`nDang tao GitHub Release..." -ForegroundColor Yellow

# Xóa release cũ nếu tag đã tồn tại
& $ghPath release delete $tagName --repo "phamhieu0802/ManagerMoblie" --yes 2>&1 | Out-Null
# Xóa tag cũ nếu tồn tại
git -C $repoRoot tag -d $tagName 2>&1 | Out-Null
git -C $repoRoot push origin ":refs/tags/$tagName" 2>&1 | Out-Null

# Tạo release mới + upload asset
& $ghPath release create $tagName `
    --repo "phamhieu0802/ManagerMoblie" `
    --title "Manager MSR $newVersion" `
    --notes "$Changelog" `
    $installerPath

if ($LASTEXITCODE -ne 0) {
    Write-Host "LOI: Tao GitHub Release that bai!" -ForegroundColor Red
    exit 1
}

Write-Host "`n THANH CONG!" -ForegroundColor Green
Write-Host "Release: https://github.com/phamhieu0802/ManagerMoblie/releases/tag/$tagName" -ForegroundColor Cyan
Write-Host "App se tu check va hien dialog cap nhat khi mo lai." -ForegroundColor Gray
