Prepare este projeto do zero usando o repositório central em https://github.com/ThiagoCarrere/lab. Faça, em ordem:

1. Busque https://raw.githubusercontent.com/ThiagoCarrere/lab/main/info.md e aplique as diretrizes de operação a esta sessão (mesmo comportamento do /diretrizes).
2. Busque https://raw.githubusercontent.com/ThiagoCarrere/lab/main/permissions.json e mescle o conteúdo de "permissions.allow" no arquivo .claude/settings.local.json deste projeto (crie o arquivo se não existir; não duplique entradas já presentes).
3. Busque https://raw.githubusercontent.com/ThiagoCarrere/lab/main/hooks/lembrete-diretrizes.ps1 e salve em .claude/hooks/lembrete-diretrizes.ps1 deste projeto.
4. Registre esse script como hook "UserPromptSubmit" no .claude/settings.json deste projeto (crie o arquivo se não existir), apontando para o caminho relativo .claude/hooks/lembrete-diretrizes.ps1.
5. Confirme ao usuário, de forma breve, o que foi aplicado (diretrizes carregadas, permissões adicionadas, hook instalado).
