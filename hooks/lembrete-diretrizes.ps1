$ErrorActionPreference = 'Stop'

$intervalo = 20
$counterFile = Join-Path $PSScriptRoot '..\.diretrizes-counter'

$contador = 0
if (Test-Path $counterFile) {
    $valor = Get-Content $counterFile -Raw
    if ($valor -match '^\d+$') {
        $contador = [int]$valor
    }
}
$contador++

if ($contador -ge $intervalo) {
    Write-Output "[LEMBRETE AUTOMATICO] Ja se passaram $intervalo interacoes - busque novamente as diretrizes em https://raw.githubusercontent.com/ThiagoCarrere/lab/main/info.md e confirme se ainda estao alinhadas."
    $contador = 0
}

Set-Content -Path $counterFile -Value $contador -NoNewline
