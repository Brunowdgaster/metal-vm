<#
    run_tests.ps1 — roda todos os casos de tests/cases e compara com o .expected.
    Saida: uma linha por caso, e exit code 1 se qualquer um falhar (serve pro CI).
#>
param([string] $Exe = (Join-Path $PSScriptRoot '..\build\fvm.exe'))

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Exe)) { Write-Error "fvm.exe nao encontrado em $Exe. Rode .\build.ps1 antes."; exit 2 }

$cases = Get-ChildItem (Join-Path $PSScriptRoot 'cases\*.fasm') | Sort-Object Name
$pass = 0; $fail = 0

foreach ($c in $cases) {
    $expectedFile = [IO.Path]::ChangeExtension($c.FullName, '.expected')
    if (-not (Test-Path $expectedFile)) { Write-Host "SKIP $($c.BaseName) (sem .expected)"; continue }

    $expected = (Get-Content $expectedFile -Raw) -replace "`r`n", "`n"
    $actual   = (& $Exe run $c.FullName 2>$null | Out-String) -replace "`r`n", "`n"
    $code     = $LASTEXITCODE

    if ($code -ne 0) {
        Write-Host ("FAIL {0,-10} exit code {1}" -f $c.BaseName, $code) -ForegroundColor Red
        $fail++
    } elseif ($actual.TrimEnd("`n") -ne $expected.TrimEnd("`n")) {
        Write-Host ("FAIL {0,-10}" -f $c.BaseName) -ForegroundColor Red
        Write-Host "  esperado: $($expected.TrimEnd("`n") -replace "`n", ' | ')"
        Write-Host "  obtido  : $($actual.TrimEnd("`n")   -replace "`n", ' | ')"
        $fail++
    } else {
        Write-Host ("ok   {0,-10}" -f $c.BaseName) -ForegroundColor Green
        $pass++
    }
}

Write-Host ""
Write-Host "$pass passaram, $fail falharam"
if ($fail -gt 0) { exit 1 }
