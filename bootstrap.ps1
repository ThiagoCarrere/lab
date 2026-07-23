$ErrorActionPreference = 'Stop'

$repoBase = 'https://raw.githubusercontent.com/ThiagoCarrere/lab/main'
$marcadorInicio = '<!-- DIRETRIZES:INICIO (gerenciado automaticamente - nao editar entre os marcadores) -->'
$marcadorFim = '<!-- DIRETRIZES:FIM -->'

New-Item -ItemType Directory -Force -Path '.claude\commands' | Out-Null
New-Item -ItemType Directory -Force -Path '.claude\hooks' | Out-Null

$utf8SemBom = New-Object System.Text.UTF8Encoding $false
$webClient = New-Object System.Net.WebClient
$webClient.Encoding = [System.Text.Encoding]::UTF8

function Escrever-Utf8($caminhoRelativo, $conteudo) {
    $caminhoAbsoluto = Join-Path (Get-Location).Path $caminhoRelativo
    [System.IO.File]::WriteAllText($caminhoAbsoluto, $conteudo, $utf8SemBom)
}

# 1. Diretrizes -> CLAUDE.md (Claude Code le esse arquivo automaticamente ao abrir o projeto)
$diretrizes = $webClient.DownloadString("$repoBase/info.md")
$bloco = "$marcadorInicio`n$diretrizes`n$marcadorFim"

if (Test-Path 'CLAUDE.md') {
    $atual = Get-Content 'CLAUDE.md' -Raw -Encoding UTF8
    if ($atual -match [regex]::Escape($marcadorInicio)) {
        $padrao = "(?s)$([regex]::Escape($marcadorInicio)).*?$([regex]::Escape($marcadorFim))"
        $novo = [regex]::Replace($atual, $padrao, { param($m) $bloco })
    } else {
        $novo = "$atual`n`n$bloco"
    }
    Escrever-Utf8 'CLAUDE.md' $novo
} else {
    Escrever-Utf8 'CLAUDE.md' $bloco
}

# 2. Permissoes genericas
$permissoes = $webClient.DownloadString("$repoBase/permissions.json")
Escrever-Utf8 '.claude\settings.local.json' $permissoes

# 3. Hook de resincronizacao automatica
Invoke-WebRequest -Uri "$repoBase/hooks/lembrete-diretrizes.ps1" -OutFile '.claude\hooks\lembrete-diretrizes.ps1'

# 4. Comandos manuais (fallback para reload sob demanda)
Invoke-WebRequest -Uri "$repoBase/.claude/commands/diretrizes.md" -OutFile '.claude\commands\diretrizes.md'
Invoke-WebRequest -Uri "$repoBase/.claude/commands/setup.md" -OutFile '.claude\commands\setup.md'

# 5. Registro do hook
$settingsJson = @'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \".claude\\hooks\\lembrete-diretrizes.ps1\""
          }
        ]
      }
    ]
  }
}
'@
Escrever-Utf8 '.claude\settings.json' $settingsJson

Write-Output 'Ambiente preparado: CLAUDE.md atualizado, permissoes aplicadas, hook de resincronizacao instalado.'
