$ErrorActionPreference = 'SilentlyContinue'

$intervalo = 20
$repoBase = 'https://raw.githubusercontent.com/ThiagoCarrere/lab/main'
$marcadorInicio = '<!-- DIRETRIZES:INICIO (gerenciado automaticamente - nao editar entre os marcadores) -->'
$marcadorFim = '<!-- DIRETRIZES:FIM -->'

$counterFile = Join-Path $PSScriptRoot '..\.diretrizes-counter'
$claudeMd = Join-Path $PSScriptRoot '..\..\CLAUDE.md'

$contador = 0
if (Test-Path $counterFile) {
    $valor = Get-Content $counterFile -Raw
    if ($valor -match '^\d+$') { $contador = [int]$valor }
}
$contador++

if ($contador -ge $intervalo) {
    try {
        $utf8SemBom = New-Object System.Text.UTF8Encoding $false
        $webClient = New-Object System.Net.WebClient
        $webClient.Encoding = [System.Text.Encoding]::UTF8

        $diretrizes = $webClient.DownloadString("$repoBase/info.md")
        $bloco = "$marcadorInicio`n$diretrizes`n$marcadorFim"

        if (Test-Path $claudeMd) {
            $atual = Get-Content $claudeMd -Raw -Encoding UTF8
            if ($atual -match [regex]::Escape($marcadorInicio)) {
                $padrao = "(?s)$([regex]::Escape($marcadorInicio)).*?$([regex]::Escape($marcadorFim))"
                $novo = [regex]::Replace($atual, $padrao, { param($m) $bloco })
            } else {
                $novo = "$atual`n`n$bloco"
            }
            [System.IO.File]::WriteAllText($claudeMd, $novo, $utf8SemBom)
        } else {
            [System.IO.File]::WriteAllText($claudeMd, $bloco, $utf8SemBom)
        }

        Write-Output "[LEMBRETE AUTOMATICO] Diretrizes resincronizadas do GitHub - CLAUDE.md atualizado."
    } catch {
        Write-Output "[LEMBRETE AUTOMATICO] Nao foi possivel buscar as diretrizes atualizadas agora - verifique a conexao."
    }
    $contador = 0
}

Set-Content -Path $counterFile -Value $contador -NoNewline
