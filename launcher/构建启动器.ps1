# ===============================================================
#  重新编译 DSH管家.exe（无窗口启动器）
#  用法：右键本文件 → 使用 PowerShell 运行；或者在本目录执行  .\构建启动器.ps1
#  依赖：.NET Framework 4.x 自带的 csc.exe（Windows 都有，不用装东西）
# ===============================================================
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$src  = Join-Path $here 'Launcher.cs'
$out  = Join-Path (Split-Path $here -Parent) 'DSH管家.exe'

if (-not (Test-Path -LiteralPath $src)) { throw ('找不到源码: ' + $src) }

$icon = Join-Path $here 'launcher.ico'
if (-not (Test-Path -LiteralPath $icon)) { $icon = Join-Path (Split-Path $here -Parent) 'DSH管家.ico' }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
  $icon = Join-Path $here 'launcher.ico'
if (-not (Test-Path -LiteralPath $icon)) { $icon = Join-Path (Split-Path $here -Parent) 'DSH管家.ico' }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) { throw '找不到 csc.exe，需要 .NET Framework 4.x' }

Write-Output ('编译器: ' + $csc)
& $csc /nologo /target:winexe /codepage:65001 /out:"$out" /reference:System.dll /reference:System.Windows.Forms.dll /win32icon:"$icon" "$src"
if ($LASTEXITCODE -ne 0) { throw ('编译失败，退出码 ' + $LASTEXITCODE) }

Write-Output ('已生成: ' + $out + '  (' + [Math]::Round((Get-Item -LiteralPath $out).Length / 1KB, 1) + ' KB)')
