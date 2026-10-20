#!/bin/bash

# ================= CONFIGURAÇÃO =================
SOURCE1="/mnt/hd1/01_gabinete"
DESTINATION1="/mnt/hd3/backups/"
LOGFILE="/.codes/bkp.log"
TMP_OUTPUT=$(mktemp)

# RETENÇÃO 
RETENCAO=7

# ================= FUNÇÕES (MANTIDAS) =================

add_to_log() {
    local message="$1"
    if [ ! -f "$LOGFILE" ]; then
        echo "$message" > "$LOGFILE"
    else
        sed -i "1s|^|${message}\n|" "$LOGFILE"
    fi
}

format_bytes() {
    local bytes=$1
    
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
        echo "0B"
        return
    fi
    
    local tb=$(echo "scale=2; $bytes / 1024 / 1024 / 1024 / 1024" | bc)
    local gb=$(echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc)
    local mb=$(echo "scale=2; $bytes / 1024 / 1024" | bc)
    local kb=$(echo "scale=2; $bytes / 1024" | bc)
    
    if (( $(echo "$tb >= 1" | bc -l) )); then
        echo "${tb}TB"
    elif (( $(echo "$gb >= 1" | bc -l) )); then
        echo "${gb}GB"
    elif (( $(echo "$mb >= 1" | bc -l) )); then
        echo "${mb}MB"
    elif (( $(echo "$kb >= 1" | bc -l) )); then
        echo "${kb}KB"
    else
        echo "${bytes}B"
    fi
}

# ================= FUNÇÕES NOVAS/MELHORADAS =================

criar_nome_backup() {
    echo "backup_$(date +%Y%m%d_%H%M%S)"
}

# ENCONTRAR ÚLTIMO BACKUP VÁLIDO (com verificação de integridade)
encontrar_ultimo_backup() {
    local destino_base="$1"
    
    # Lista backups ordenados por data (mais recente primeiro)
    find "$destino_base" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | \
        sort -r | while read -r backup; do
        
        # Verifica se é um backup válido (tem o arquivo de marcação)
        if [ -f "$backup/.backup-ok" ]; then
            echo "$backup"
            return 0
        else
            echo "AVISO: Backup incompleto/encontrado: $(basename "$backup")" >&2
        fi
    done
    
    # Se não encontrou nenhum válido
    echo ""
    return 1
}

# VERIFICAR INTEGRIDADE DO ÚLTIMO BACKUP
verificar_integridade_backup() {
    local backup="$1"
    
    if [ -z "$backup" ] || [ ! -d "$backup" ]; then
        echo "ERRO: Backup não existe ou é inválido: $backup" >&2
        return 1
    fi
    
    # Verifica se tem o marcador de backup OK
    if [ ! -f "$backup/.backup-ok" ]; then
        echo "ERRO: Backup não marcado como completo: $(basename "$backup")" >&2
        return 1
    fi
    
    # Verifica se o diretório não está vazio
    if [ -z "$(ls -A "$backup" 2>/dev/null)" ]; then
        echo "ERRO: Backup vazio: $(basename "$backup")" >&2
        return 1
    fi
    
    # Verifica tamanho mínimo (opcional - ajuste conforme necessário)
    local tamanho
    tamanho=$(du -s "$backup" 2>/dev/null | cut -f1)
    
    # Se for o primeiro backup, não temos referência, mas podemos ver se tem algo
    if [ "$tamanho" -lt 1024 ]; then  # Menos de 1MB
        echo "AVISO: Backup muito pequeno (<1MB): $(basename "$backup")" >&2
        # Não falha, apenas alerta - pode ser legítimo se for backup de poucos arquivos
    fi
    
    echo "OK: Backup $(basename "$backup") parece íntegro"
    return 0
}

# LIMPAR BACKUPS INCOMPLETOS (remove backups sem .backup-ok)
limpar_backups_incompletos() {
    local destino_base="$1"
    local removidos=0
    
    if [ ! -d "$destino_base" ]; then
        return
    fi
    
    echo "Verificando backups incompletos em $destino_base..."
    
    find "$destino_base" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | \
        while read -r backup; do
            # Se não tem o marcador .backup-ok, é incompleto
            if [ ! -f "$backup/.backup-ok" ]; then
                echo "Removendo backup incompleto: $(basename "$backup")"
                rm -rf "$backup"
                ((removidos++))
            fi
        done
    
    if [ "$removidos" -gt 0 ]; then
        echo "Removidos $removidos backups incompletos"
    fi
}

# Aplicar retenção - remove backups antigos
aplicar_retencao() {
    local destino_base="$1"
    local retencao="$2"
    local descricao="$3"
    
    if [ ! -d "$destino_base" ]; then
        return
    fi
    
    # Lista todos os backups VÁLIDOS (com .backup-ok), ordena do mais antigo para o mais novo
    local backups
    backups=$(find "$destino_base" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | \
              while read -r b; do [ -f "$b/.backup-ok" ] && echo "$b"; done | sort)
    
    local total_backups
    total_backups=$(echo "$backups" | wc -l)
    
    # Se tiver mais backups que a retenção permitida
    if [ "$total_backups" -gt "$retencao" ]; then
        local remover
        remover=$((total_backups - retencao))
        
        echo "Aplicando retenção para $descricao: mantendo $retencao, removendo $remover"
        
        # Remove os backups mais antigos
        echo "$backups" | head -n "$remover" | while read -r backup_antigo; do
            if [ -n "$backup_antigo" ]; then
                echo "Removendo backup antigo: $(basename "$backup_antigo")"
                rm -rf "$backup_antigo"
            fi
        done
    fi
}

# ================= FUNÇÃO PRINCIPAL ATUALIZADA =================
execute_rsync() {
    local source="$1"
    local destination_base="$2"
    local description="$3"
    local retencao="$4"
    local ssh_options="$5"
    
    echo "Iniciando $description"
    
    # 1. Limpar backups incompletos ANTES de começar
    limpar_backups_incompletos "$destination_base"
    
    # 2. Criar diretório base se não existir
    mkdir -p "$destination_base"
    
    # 3. Encontrar último backup VÁLIDO
    local ultimo_backup
    ultimo_backup=$(encontrar_ultimo_backup "$destination_base")
    
    # 4. Verificar integridade do último backup (se existir)
    if [ -n "$ultimo_backup" ]; then
        if ! verificar_integridade_backup "$ultimo_backup"; then
            echo "AVISO CRÍTICO: Último backup não parece íntegro!"
            echo "Continuando mesmo assim, mas o novo backup será completo (sem --link-dest)"
            ultimo_backup=""
        fi
    fi
    
    # 5. Nome do backup atual
    local nome_backup
    nome_backup=$(criar_nome_backup)
    local destino_completo="${destination_base}/${nome_backup}"
    
    # 6. Preparar opções de hardlink (se último backup for válido)
    local link_options=""
    if [ -n "$ultimo_backup" ]; then
        link_options="--link-dest=$ultimo_backup"
        echo "Usando hardlinks do backup anterior: $(basename "$ultimo_backup")"
    else
        echo "Backup completo (sem hardlinks)"
    fi
    
    # 7. Criar diretório do backup atual
    mkdir -p "$destino_completo"
    
    # 8. Executa o rsync
    if eval rsync -azvh --stats --progress $link_options $ssh_options "$source" "$destino_completo/" 2>&1 | tee "$TMP_OUTPUT"; then
        timestamp=$(date '+%d/%m/%Y_%H:%M:%S')
        msg="$timestamp => $description EFETUADO COM SUCESSO"
        
        transferred_size=""
        
        # Extrair tamanho transferido (método simplificado e robusto)
        if grep -q "Total transferred file size:" "$TMP_OUTPUT"; then
            # Extrai apenas o número (remove vírgulas e "bytes")
            bytes=$(grep "Total transferred file size:" "$TMP_OUTPUT" | awk '{print $5}' | tr -d ',')
            transferred_size=$(format_bytes "$bytes")
        fi
        
        # Se encontrou o tamanho transferido, adiciona à mensagem
        if [ -n "$transferred_size" ] && [ "$transferred_size" != "0B" ]; then
            msg="$msg  => $transferred_size"
        else
            msg="$msg  => 0B"
        fi
        
        # 9. MARCAR BACKUP COMO VÁLIDO (arquivo vazio .backup-ok)
        touch "$destino_completo/.backup-ok"
        echo "Backup marcado como válido: $destino_completo/.backup-ok"
        
        # 10. Aplicar política de retenção (remove backups antigos)
        aplicar_retencao "$destination_base" "$retencao" "$description"
        
    else
        # Se falhou, remove o backup incompleto
        if [ -d "$destino_completo" ]; then
            rm -rf "$destino_completo"
            echo "Removido backup incompleto: $destino_completo"
        fi
        
        timestamp=$(date '+%d/%m/%Y_%H:%M:%S')
        msg="$timestamp => FALHA AO EFETUAR $description"
    fi
    
    # Adicionando a mensagem no início do bkp.log
    add_to_log "$msg"
}

# ================= EXECUÇÃO PRINCIPAL =================
echo "=== $(date) - INICIANDO BACKUPS ===" >> "$LOGFILE"

# Executar backup
execute_rsync "$SOURCE1" "$DESTINATION1" "BACKUP TESTE GABINETE COM RETENCAO" "$RETENCAO" ""

# Limpeza
rm "$TMP_OUTPUT"

echo "=== BACKUP CONCLUÍDO ===" >> "$LOGFILE"