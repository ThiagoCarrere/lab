#!/bin/bash
# criar-usuario-com-troca-senha.sh

USUARIO="$1"
GRUPO="$2"
SENHA_TEMP="Mudar@123"

echo "Criando usuário: $USUARIO"

# 1. Criar usuário Linux
useradd -M -s /usr/sbin/nologin -G $GRUPO $USUARIO

# 2. Senha temporária (usuário DEVE trocar)
echo "$USUARIO:$SENHA_TEMP" | chpasswd

# 3. ⭐⭐ FORÇAR TROCA NO PRÓXIMO LOGIN ⭐⭐
chage -d 0 $USUARIO  # MÁGICO!

# 4. Senha Samba (igual à Linux)
echo -e "$SENHA_TEMP\n$SENHA_TEMP" | smbpasswd -a -s $USUARIO
smbpasswd -e $USUARIO

echo "✅ Usuário criado!"
echo "Senha temporária: $SENHA_TEMP"
echo "DEVE ser trocada no primeiro acesso!"