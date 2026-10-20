#!/bin/bash
set -euo pipefail

# ============================
# BACKUP INCREMENTAL COM HARDLINKS - VERSÃO PRODUÇÃO OTIMIZADA
# ============================

# ---------------------------
# CONFIGURAÇÕES
# ---------------------------
readonly SOURCE="root@192.168.42.203:/mnt/hd1/"
readonly DEST_BASE="/mnt/hd3/backups/diario"
readonly LOGFILE="/.codes/backup_incremental.log"
readonly RSYNC_LOGDIR="/var/log/backup_rsync"
readonly LOCKFILE="/var/run/backup_incremental.lock"
readonly RETENTION=7
readonly MIN_DISK_SPACE_GB=10
readonly MAX_LOG_SIZE_MB=100

# Opções rsync (SEM --checksum para performance)
readonly RSYNC_OPTS="-azvh --numeric-ids --partial --stats --timeout=300 --delete-excluded"
readonly SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=60 -o StrictHostKeyChecking=yes -o Compression=yes"

# Notificações (deixar vazio para desabilitar)
readonly EMAIL_ADMIN=""

# Alertas de integridade (% variação aceitável)
readonly INTEGRITY_MIN_PERCENT=50   # Alerta se <50% dos arquivos anteriores
readonly INTEGRITY_MAX_PERCENT=200  # Alerta se >200% dos arquivos anteriores

# ---------------------------
# FUNÇÃO DE LOG SEGURA
# ---------------------------
log_message() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" | tee -a "$LOGFILE"
}

# ---------------------------
# FUNÇÃO DE NOTIFICAÇÃO
# ---------------------------
notify_admin() {
    local subject="$1"
    local message="$2"
    local priority="${3:-INFO}"
    
    log_message "NOTIFICAÇÃO [$priority]: $message"
    
    # Enviar email apenas para ERRO e ALERTA
    if [[ -n "$EMAIL_ADMIN" ]] && [[ "$priority" == "ERRO" || "$priority" == "ALERTA" ]]; then
        if command -v mail &> /dev/null; then
            if echo "$message" | mail -s "[BACKUP-$priority] $subject" "$EMAIL_ADMIN" 2>&1; then
                log_message "Email enviado para $EMAIL_ADMIN"
            else
                log_message "Falha ao enviar email para $EMAIL_ADMIN"
            fi
        else
            log_message "AVISO: 'mail' não instalado, notificação email desabilitada"
        fi
    fi
}

# ---------------------------
# FUNÇÃO SEGURA DE REMOÇÃO
# ---------------------------
safe_remove() {
    local target="$1"
    
    if [[ -z "$target" ]] || [[ ! -d "$target" ]]; then
        log_message "AVISO: Tentativa de remover diretório inválido: $target"
        return 1
    fi
    
    # Validação extra de segurança
    local real_target
    real_target=$(realpath "$target" 2>/dev/null || echo "$target")
    local real_base
    real_base=$(realpath "$DEST_BASE" 2>/dev/null || echo "$DEST_BASE")
    
    # Garantir que está dentro do base e não é o próprio base ou raiz
    if [[ "$real_target" != "$real_base" ]] && 
       [[ "$real_target" != "/" ]] && 
       [[ "$real_target" == "$real_base"/* ]]; then
        log_message "Removendo: $(basename "$target")"
        rm -rf "$target"
        return 0
    else
        log_message "ERRO SEGURANÇA: Bloqueada remoção suspeita: $target"
        return 1
    fi
}

# ---------------------------
# ROTACIONAR LOG SE NECESSÁRIO
# ---------------------------
rotate_log_if_needed() {
    if [[ -f "$LOGFILE" ]]; then
        local log_size_bytes
        if log_size_bytes=$(stat -c%s "$LOGFILE" 2>/dev/null); then
            : # GNU Linux
        else
            log_size_bytes=$(stat -f %z "$LOGFILE" 2>/dev/null || echo 0)
        fi
        
        if [[ $log_size_bytes -gt $((MAX_LOG_SIZE_MB * 1024 * 1024)) ]]; then
            local rotated="${LOGFILE}.$(date +%Y%m%d_%H%M%S)"
            mv "$LOGFILE" "$rotated"
            gzip "$rotated" &  # Comprimir em background
            touch "$LOGFILE"
            chmod 640 "$LOGFILE"
            log_message "Log rotacionado (tamanho > ${MAX_LOG_SIZE_MB}MB)"
        fi
    fi
}

# ---------------------------
# VALIDAR CONFIGURAÇÃO
# ---------------------------
validate_config() {
    local errors=0
    
    if [[ ! "$SOURCE" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+:.+$ ]]; then
        echo "ERRO: SOURCE inválido: $SOURCE" >&2
        ((errors++))
    fi
    
    if [[ ! "$DEST_BASE" =~ ^/ ]]; then
        echo "ERRO: DEST_BASE deve ser caminho absoluto: $DEST_BASE" >&2
        ((errors++))
    fi
    
    if [[ -n "$EMAIL_ADMIN" ]] && ! command -v mail &> /dev/null; then
        echo "AVISO: EMAIL configurado mas comando 'mail' não encontrado" >&2
    fi
    
    if [[ $errors -gt 0 ]]; then
        echo "Configuração inválida. Abortando." >&2
        exit 1
    fi
}

# ---------------------------
# VALIDAÇÕES INICIAIS
# ---------------------------
validate_config
rotate_log_if_needed
log_message "=== INICIANDO BACKUP ==="

# Verificar root
if [[ $EUID -ne 0 ]]; then
    notify_admin "Backup falhou" "Script precisa ser executado como root" "ERRO"
    exit 1
fi

# Validar RETENTION
if ! [[ "$RETENTION" =~ ^[0-9]+$ ]] || [[ "$RETENTION" -lt 1 ]]; then
    notify_admin "Backup falhou" "RETENTION inválido: $RETENTION" "ERRO"
    exit 1
fi

# Criar diretórios necessários
mkdir -p "$(dirname "$LOGFILE")" "$RSYNC_LOGDIR" "$DEST_BASE"
chmod 750 "$(dirname "$LOGFILE")" "$RSYNC_LOGDIR"

# Verificar espaço em disco
AVAILABLE_KB=$(df -k "$DEST_BASE" | awk 'NR==2 {print $4}')
AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
if [[ $AVAILABLE_GB -lt $MIN_DISK_SPACE_GB ]]; then
    notify_admin "Backup falhou" \
        "Espaço insuficiente: ${AVAILABLE_GB}GB < ${MIN_DISK_SPACE_GB}GB" "ERRO"
    exit 1
fi
log_message "Espaço disponível: ${AVAILABLE_GB}GB"

# ---------------------------
# LOCK
# ---------------------------
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    notify_admin "Backup já em execução" "Lock file existe" "ALERTA"
    exit 1
fi
trap 'rm -rf "$LOCKFILE"' EXIT

# ---------------------------
# TESTAR SSH
# ---------------------------
log_message "Testando conectividade SSH..."
SSH_HOST="${SOURCE%%:*}"
if ! timeout 15 ssh $SSH_OPTS -o BatchMode=yes "$SSH_HOST" "exit" 2>/dev/null; then
    notify_admin "Backup falhou" "Falha SSH: $SSH_HOST" "ERRO"
    exit 1
fi
log_message "Conexão SSH OK"

# ---------------------------
# PREPARAR DESTINO
# ---------------------------
readonly HOJE=$(date +%F_%H%M)
readonly DEST="$DEST_BASE/$HOJE"

if ! mkdir -p "$DEST"; then
    notify_admin "Backup falhou" "Falha ao criar $DEST" "ERRO"
    exit 1
fi

# ---------------------------
# ENCONTRAR SNAPSHOT ANTERIOR
# ---------------------------
PREV=""
PREV_COUNT=0
SNAPSHOT_LIST=()

while IFS= read -r -d '' dir; do
    if [[ -f "$dir/BACKUP_OK" ]] && [[ "$dir" != "$DEST" ]]; then
        SNAPSHOT_LIST+=("$dir")
    fi
done < <(find "$DEST_BASE" -maxdepth 1 -type d -name "20*" -print0 2>/dev/null | sort -zr)

if [[ ${#SNAPSHOT_LIST[@]} -gt 0 ]]; then
    PREV="${SNAPSHOT_LIST[0]}"
    LINKDEST="--link-dest=$PREV"
    PREV_COUNT=$(find "$PREV" -type f 2>/dev/null | wc -l)
    PREV_SIZE=$(du -sh "$PREV" 2>/dev/null | cut -f1 || echo "N/A")
    log_message "Snapshot anterior: $(basename "$PREV") - $PREV_COUNT arquivos, $PREV_SIZE"
else
    LINKDEST=""
    log_message "Backup COMPLETO (nenhum snapshot anterior)"
fi

# ---------------------------
# EXECUTAR BACKUP
# ---------------------------
START_TIME=$(date +%s)
RSYNC_LOG="$RSYNC_LOGDIR/rsync_${HOJE}.log"

log_message "Iniciando rsync..."
log_message "Origem: $SOURCE | Destino: $DEST"

set +e
rsync $RSYNC_OPTS $LINKDEST \
    -e "ssh $SSH_OPTS" \
    "$SOURCE" "$DEST/" \
    > "$RSYNC_LOG" 2>&1
RSYNC_EXIT=$?
set -e

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Extrair estatísticas do log
if [[ -f "$RSYNC_LOG" ]]; then
    {
        echo "=== Estatísticas rsync ==="
        grep -E "(Total file size|Number of files|Total transferred|sent |received )" "$RSYNC_LOG" || true
        echo "=== Fim estatísticas ==="
    } >> "$LOGFILE"
    
    # Limpar logs antigos (>30 dias)
    find "$RSYNC_LOGDIR" -name "rsync_*.log" -mtime +30 -delete 2>/dev/null || true
fi

log_message "Duração rsync: ${DURATION}s"

# ---------------------------
# PROCESSAR RESULTADO
# ---------------------------
if [[ $RSYNC_EXIT -eq 0 || $RSYNC_EXIT -eq 24 ]]; then
    # Verificação de integridade
    NEW_COUNT=$(find "$DEST" -type f 2>/dev/null | wc -l)
    
    if [[ $PREV_COUNT -gt 0 ]]; then
        DIFF_PERCENT=$(( (NEW_COUNT * 100) / PREV_COUNT ))
        
        if [[ $DIFF_PERCENT -lt $INTEGRITY_MIN_PERCENT ]] || \
           [[ $DIFF_PERCENT -gt $INTEGRITY_MAX_PERCENT ]]; then
            notify_admin "Variação anormal no backup" \
                "Anterior: $PREV_COUNT arquivos | Novo: $NEW_COUNT ($DIFF_PERCENT%)" \
                "ALERTA"
        fi
    fi
    
    # Marcar sucesso
    touch "$DEST/BACKUP_OK"
    NEW_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1 || echo "N/A")
    
    if [[ $RSYNC_EXIT -eq 24 ]]; then
        log_message "⚠ CONCLUÍDO COM AVISOS (código 24) - $NEW_SIZE"
        notify_admin "Backup com avisos" "Código 24: arquivos alterados durante cópia" "ALERTA"
    else
        log_message "✓ BACKUP CONCLUÍDO - $NEW_SIZE ($NEW_COUNT arquivos)"
    fi
    
    # Calcular taxa de transferência
    if [[ $DURATION -gt 0 ]]; then
        TOTAL_KB=$(du -sk "$DEST" 2>/dev/null | cut -f1 || echo 0)
        RATE_MB_S=$(( (TOTAL_KB / DURATION) / 1024 ))
        log_message "Taxa média: ${RATE_MB_S} MB/s"
    fi
else
    log_message "✗ FALHA (código rsync: $RSYNC_EXIT)"
    notify_admin "Backup falhou" "Código rsync $RSYNC_EXIT - ver $RSYNC_LOG" "ERRO"
    [[ -d "$DEST" ]] && rm -rf "$DEST"
    exit 1
fi

# ---------------------------
# RETENÇÃO
# ---------------------------
log_message "Aplicando retenção ($RETENTION snapshots)"

# Listar snapshots válidos (já ordenados por data)
VALID_SNAPSHOTS=()
while IFS= read -r -d '' snap; do
    [[ -f "$snap/BACKUP_OK" ]] && VALID_SNAPSHOTS+=("$snap")
done < <(find "$DEST_BASE" -maxdepth 1 -type d -name "20*" -print0 | sort -z)

TOTAL=${#VALID_SNAPSHOTS[@]}
log_message "Snapshots válidos: $TOTAL"

if [[ $TOTAL -gt $RETENTION ]]; then
    REMOVE_COUNT=$((TOTAL - RETENTION))
    log_message "Removendo $REMOVE_COUNT snapshots antigos"
    
    REMOVED=0
    # Remover apenas os primeiros (mais antigos)
    for (( i=0; i<REMOVE_COUNT && i<${#VALID_SNAPSHOTS[@]}; i++ )); do
        if safe_remove "${VALID_SNAPSHOTS[$i]}"; then
            ((REMOVED++))
        fi
    done
    
    log_message "Snapshots removidos: $REMOVED"
else
    log_message "Retenção OK ($TOTAL/$RETENTION)"
fi

# ---------------------------
# RELATÓRIO FINAL
# ---------------------------
FINAL_TIME=$(date +%s)
TOTAL_DURATION=$((FINAL_TIME - START_TIME))
FINAL_SPACE_KB=$(df -k "$DEST_BASE" | awk 'NR==2 {print $4}')
FINAL_SPACE_GB=$((FINAL_SPACE_KB / 1024 / 1024))

log_message "=== RELATÓRIO ==="
log_message "Tempo total: ${TOTAL_DURATION}s"
log_message "Espaço livre: ${FINAL_SPACE_GB}GB"
log_message "Snapshots mantidos: $((TOTAL - REMOVED))"

# Listar snapshots atuais
log_message "Snapshots disponíveis:"
while IFS= read -r -d '' snap; do
    if [[ -d "$snap" ]]; then
        snap_name=$(basename "$snap")
        snap_size=$(du -sh "$snap" 2>/dev/null | cut -f1 || echo "N/A")
        
        # Idade do snapshot
        if snap_mtime=$(stat -c %Y "$snap" 2>/dev/null); then
            : # GNU
        else
            snap_mtime=$(stat -f %m "$snap" 2>/dev/null || echo 0)
        fi
        snap_age_days=$(( ($(date +%s) - snap_mtime) / 86400 ))
        
        log_message "  $snap_name: $snap_size (${snap_age_days}d)"
    fi
done < <(find "$DEST_BASE" -maxdepth 1 -type d -name "20*" -print0 | sort -zr)

log_message "=== FINALIZADO COM SUCESSO ==="