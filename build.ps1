<#
    build.ps1 — compila a fvm no Windows com o MSVC do Build Tools.

    Por que este script existe: o `cl.exe` só funciona depois de `vcvars64.bat`
    popular o ambiente (INCLUDE, LIB, PATH). Em vez de exigir que quem clona o
    repositório abra o "x64 Native Tools Prompt", o script localiza o toolset
    com o vswhere e injeta o ambiente sozinho.

    uso:
      .\build.ps1                 # Release
      .\build.ps1 -Config Debug
      .\build.ps1 -Clean
#>
param(
    [ValidateSet('Release', 'Debug')] [string] $Config = 'Release',
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $root 'build'

if ($Clean -and (Test-Path $buildDir)) {
    Remove-Item -Recurse -Force $buildDir
    Write-Host "build/ removido."
}

# --- localizar o MSVC -------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vcvars = $null

if (Test-Path $vswhere) {
    $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($install) { $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvars64.bat' }
}

if (-not $vcvars -or -not (Test-Path $vcvars)) {
    # fallback: varre as instalações conhecidas
    $cands = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio' -Directory -ErrorAction SilentlyContinue |
             ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } |
             ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } |
             ForEach-Object { Join-Path $_.FullName 'VC\Auxiliary\Build\vcvars64.bat' } |
             Where-Object { Test-Path $_ }
    if ($cands) { $vcvars = $cands[0] }
}

if (-not $vcvars) {
    throw "vcvars64.bat nao encontrado. Instale o 'Desktop development with C++' do Visual Studio Build Tools."
}

Write-Host "MSVC: $vcvars"

# --- configurar e compilar --------------------------------------------------
# 2>NUL silencia um aviso inofensivo do próprio vcvars64.bat (ele chama
# vswhere.exe sem caminho absoluto quando só o Build Tools está instalado).
$cmd = "call `"$vcvars`" > NUL 2>NUL & cmake -S `"$root`" -B `"$buildDir`" -G `"NMake Makefiles`" -DCMAKE_BUILD_TYPE=$Config & cmake --build `"$buildDir`""
& cmd.exe /c $cmd
if ($LASTEXITCODE -ne 0) { throw "falha na compilacao (exit $LASTEXITCODE)" }

$exe = Join-Path $buildDir 'fvm.exe'
Write-Host ""
Write-Host "ok: $exe"
& $exe version
