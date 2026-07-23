$ErrorActionPreference = 'Stop'

$repoBase = 'https://raw.githubusercontent.com/ThiagoCarrere/lab/main'
$marcadorInicio = '<!-- DIRETRIZES:INICIO (gerenciado automaticamente - nao editar entre os marcadores) -->'
$marcadorFim = '<!-- DIRETRIZES:FIM -->'

New-Item -ItemType Directory -Force -Path '.claude\commands' | Out-Null
New-Item -ItemType Directory -Force -Path '.claude\hooks' | Out-Null

# 1. Diretrizes -> CLAUDE.md (Claude Code le esse arquivo automaticamente ao abrir o projeto)
$diretrizes = (Invoke-WebRequest -Uri "$repoBase/info.md" -UseBasicParsing).Content
$bloco = "$marcadorInicio`n$diretrizes`n$marcadorFim"

if (Test-Path 'CLAUDE.md') {
    $atual = Get-Content 'CLAUDE.md' -Raw
    if ($atual -match [regex]::Escape($marcadorInicio)) {
        $padrao = "(?s)$([regex]::Escape($marcadorInicio)).*?$([regex]::Escape($marcadorFim))"
        $novo = [regex]::Replace($atual, $padrao, { param($m) $bloco })
    } else {
        $novo = "$atual`n`n$bloco"
    }
    Set-Content 'CLAUDE.md' -Value $novo -NoNewline
} else {
    Set-Content 'CLAUDE.md' -Value $bloco -NoNewline
}

# 2. Permissoes genericas
$permissoes = Invoke-WebRequest -Uri "$repoBase/permissions.json" -UseBasicParsing
Set-Content '.claude\settings.local.json' -Value $permissoes.Content -NoNewline

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
Set-Content '.claude\settings.json' -Value $settingsJson -NoNewline

Write-Output 'Ambiente preparado: CLAUDE.md atualizado, permissoes aplicadas, hook de resincronizacao instalado.'
