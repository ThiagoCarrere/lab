#!/bin/bash

# Configurações
GITHUB_BASE="https://raw.githubusercontent.com/ThiagoCarrere/linux/refs/heads/main/scripts"
CODES_DIR="/.codes1"

# Criar diretório
echo "📁 Criando diretório $CODES_DIR..."
mkdir -p "$CODES_DIR"

# Baixar arquivos
echo "⬇️ Baixando arquivos..."
curl -s -o "$CODES_DIR/imp.sh" "$GITHUB_BASE/imp.sh"
curl -s -o "$CODES_DIR/exp.sh" "$GITHUB_BASE/exp.sh"
curl -s -o "$CODES_DIR/conf.exp" "$GITHUB_BASE/conf.exp"

# Dar permissões
echo "🔒 Configurando permissões..."
chmod +x "$CODES_DIR/imp.sh"
chmod +x "$CODES_DIR/exp.sh"

# Executar script principal
echo "🚀 Executando script principal..."
cd "$CODES_DIR"
./imp.sh

echo "✅ Configuração concluída!"