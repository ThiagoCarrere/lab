# 🐧 Laboratório

![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![Debian](https://img.shields.io/badge/Debian-A81D33?style=for-the-badge&logo=debian&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![Terminal](https://img.shields.io/badge/Terminal-%23054020?style=for-the-badge&logo=gnome-terminal&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Git](https://img.shields.io/badge/Git-F05032?style=for-the-badge&logo=git&logoColor=white)
![CLI](https://img.shields.io/badge/CLI-FFD43B?style=for-the-badge&logo=terminal&logoColor=black)
[![Typing SVG](https://readme-typing-svg.demolab.com?font=Fira+Code&size=16&pause=1000&color=FCC624&width=500&lines=Experimentos+em+andamento...+%F0%9F%94%A5;Scripts%2C+testes+e+caos+controlado+%E2%9A%A1;Bem-vindo+ao+laborat%C3%B3rio!+%F0%9F%90%A7)](https://git.io/typing-svg)

## Preparar um projeto novo (1 comando)

Numa pasta de projeto nova, antes de abrir o Claude Code, rode no terminal:

**PowerShell (ou cmd):**
```
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ThiagoCarrere/lab/main/bootstrap.ps1 | iex"
```

**Git Bash:**
```
curl --ssl-no-revoke -fsSL https://raw.githubusercontent.com/ThiagoCarrere/lab/main/bootstrap.sh | bash
```

Ou simplesmente diga ao Claude Code, numa sessão nova, para rodar o bootstrap a partir da URL — ele executa sozinho, sem depender do seu terminal.

Isso prepara o projeto por completo:
- Grava as diretrizes de operação (`info.md`) no `CLAUDE.md` do projeto, dentro de um bloco marcado — Claude Code carrega isso automaticamente ao abrir a sessão, sem precisar de comando nenhum
- Aplica as permissões padrão em `.claude/settings.local.json`
- Instala o hook de resincronização automática (`.claude/hooks/lembrete-diretrizes.ps1`), que a cada 20 interações rebusca o `info.md` atualizado do GitHub e atualiza o `CLAUDE.md` sozinho
- Copia os comandos `/diretrizes` e `/setup` para uso manual, se precisar forçar uma resincronização na hora
- Verifica se o projeto já tem repositório git; se não tiver, inicializa
- Cria o `task.md` (lista de tarefas) se ainda não existir
- Faz o commit inicial de tudo isso, já deixando o projeto rastreável desde o primeiro momento

Rodar o comando de novo no mesmo projeto é seguro — ele atualiza o bloco de diretrizes sem duplicar nem apagar o resto do `CLAUDE.md`.

### Arquivos deste repositório

- `info.md` — diretrizes de operação (papel, princípios inegociáveis, formato de resposta, etc.)
- `permissions.json` — conjunto padrão de permissões
- `bootstrap.ps1` / `bootstrap.sh` — scripts de preparação de projeto novo (PowerShell e Git Bash)
- `hooks/lembrete-diretrizes.ps1` — hook de resincronização automática
- `.claude/commands/` — comandos `/diretrizes` e `/setup` para uso manual dentro de uma sessão já em andamento

