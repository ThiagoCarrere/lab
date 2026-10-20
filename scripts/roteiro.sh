# 1. Criar pastas privada
mkdir nome_pasta_privada

# 2. Criar grupo
groupadd nome_grupo

# 3. Criar usuario sem criar pasta e sem permissao de login
adduser --no-create-home --disabled-login nome_usuario

# 4. Vincular pastas aos grupos
chgrp nome_grupo nome_pasta_privada

# 5. Inserir usuario em grupo
usermod -aG nome_grupo nome_usuario

# 6. Criar o usuário no samba
smbpasswd -a nome_usuario

# 7. Criando permissao de acesso a pasta
chmod 2770 nome_pasta_privada

# 8. Corrigir arquivos existentes
find nome_pasta_privada -type f -exec chmod 660 {} \;

# 9. Verificar se o usuario tem acesso ao grupo
groups nome_usuario

# 10. Configurar o samba 
[nome_grupo]
path = /dados/nome_pasta_privada
writable = yes
create mask = 0660
directory mask = 2770
force create mode = 0660
force directory mode = 2770
force group = nome_grupo
guest ok = no
valid users = @nome_grupo