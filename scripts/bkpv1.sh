#!/bin/bash

# ============================================================================
# Script de Backup com Rsync - Versão Profissional Robusta
# ============================================================================

set -euo pipefail

# -----------------------------
# CONFIGURAÇÕES
# -----------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE1="backup@192.168.42.250:/mnt/"
readonly DESTINATION1="/mnt/hd1/"
readonly SOURCE2="/mnt/hd1/"
readonly DESTINATION2="backup@154.16.196.186:/pmclp/"
readonly SSH_PORT="55498"
readonly LOGDIR="/var/log/rsync-backup"
readonly LOGFILE="${LOGDIR}/bkp.log"
readonly MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB
readonly SSH_TIMEOUT=30
readonly MIN_FREE_SPACE_GB=10
readonly LOCK_FILE="/var/run/rsync-backup.lock"  # /var/run é melhor que /var/lock

declare -a TEMP_FILES=()

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# -----------------------------
# TRAP PARA LIMPEZA
# -----------------------------
cleanup() {
    local exit_code=$?
    
    rm -f "$LOCK_FILE"
    
    for temp_file in "${TEMP_FILES[@]}"; do
        [ -f "$temp_file" ] && rm -f "$temp_file"
    done
    
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Script encerrado com erro (código: $exit_code)"
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM

# -----------------------------
# FUNÇÕES AUXILIARES
# -----------------------------

# Detecta tamanho de arquivo (compatível Linux/macOS/BSD)
get_file_size() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]] || [[ "$OSTYPE" == "freebsd"* ]]; then
        stat -f%z "$file" 2>/dev/null || echo "0"
    else
        stat -c%s "$file" 2>/dev/null || echo "0"
    fi
}

# Função de log com rotação automática
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$LOGDIR"
    
    # Rotação de logs (CORRIGIDO: multiplataforma)
    if [ -f "$LOGFILE" ] && [ "$(get_file_size "$LOGFILE")" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOGFILE" "${LOGFILE}.old"
        gzip -f "${LOGFILE}.old" 2>/dev/null || true
    fi
    
    echo "[${timestamp}] [${level}] ${message}" >> "$LOGFILE"
    
    if [ -t 1 ]; then
        case "$level" in
            ERROR) echo -e "${RED}[${level}]${NC} ${message}" ;;
            SUCCESS) echo -e "${GREEN}[${level}]${NC} ${message}" ;;
            WARNING) echo -e "${YELLOW}[${level}]${NC} ${message}" ;;
            *) echo "[${level}] ${message}" ;;
        esac
    fi
}

# Verifica conectividade SSH
check_ssh_connection() {
    local host="$1"
    local port="${2:-22}"
    local server="${host#*@}"
    server="${server%%:*}"
    
    log "INFO" "Verificando conectividade SSH para ${server}:${port}..."
    
    if timeout "$SSH_TIMEOUT" ssh -p "$port" -o ConnectTimeout=10 -o BatchMode=yes \
        -o StrictHostKeyChecking=no "${host%%:*}" "exit" 2>/dev/null; then
        log "SUCCESS" "Conexão SSH OK: ${server}"
        return 0
    else
        log "ERROR" "Falha na conexão SSH: ${server}:${port}"
        return 1
    fi
}

# Verifica espaço em disco (CORRIGIDO: aceita arquivos também)
check_disk_space() {
    local path="$1"
    
    [[ -d "$path" ]] || path="$(dirname "$path")"
    
    local available_gb
    available_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
    available_gb=${available_gb:-0}
    
    if [ "$available_gb" -lt "$MIN_FREE_SPACE_GB" ]; then
        log "ERROR" "Espaço insuficiente em $path: ${available_gb}GB (mínimo: ${MIN_FREE_SPACE_GB}GB)"
        return 1
    fi
    
    log "INFO" "Espaço disponível em $path: ${available_gb}GB"
    return 0
}

# Verifica ponto de montagem
check_mount() {
    local mount_point="$1"
    
    if ! mountpoint -q "$mount_point"; then
        log "ERROR" "O destino $mount_point não está montado!"
        return 1
    fi
    
    log "INFO" "Ponto de montagem OK: $mount_point"
    return 0
}

# Extrai estatísticas do rsync (CORRIGIDO: multiplataforma sem grep -P)
extract_rsync_stats() {
    local output_file="$1"
    local pattern="$2"
    
    if grep -q "$pattern" "$output_file" 2>/dev/null; then
        # Usa sed básico (compatível com todas as plataformas)
        grep "$pattern" "$output_file" | sed -E 's/.*: ([0-9.,]+[KMGT]?i?B?).*/\1/' | head -n1
    else
        echo "N/A"
    fi
}

# Executa rsync com tratamento robusto
execute_rsync() {
    local source="$1"
    local destination="$2"
    local description="$3"
    local ssh_port="${4:-22}"
    
    log "INFO" "Iniciando: $description"
    log "INFO" "Origem: $source"
    log "INFO" "Destino: $destination"
    
    local tmp_output
    tmp_output=$(mktemp)
    TEMP_FILES+=("$tmp_output")
    
    local rsync_cmd=(
        rsync
        -avzh
        --stats
        --delete
        --timeout=300
        --partial
        --partial-dir=.rsync-partial
    )
    
    # Adiciona SSH se origem ou destino for remoto
    if [[ "$destination" =~ @ ]] || [[ "$source" =~ @ ]]; then
        rsync_cmd+=(-e "ssh -p ${ssh_port} -o ConnectTimeout=30 -o StrictHostKeyChecking=no")
    fi
    
    rsync_cmd+=("$source" "$destination")
    
    if "${rsync_cmd[@]}" > "$tmp_output" 2>&1; then
        local total_size transferred
        
        # CORRIGIDO: extração multiplataforma
        total_size=$(extract_rsync_stats "$tmp_output" "Total file size")
        transferred=$(extract_rsync_stats "$tmp_output" "Total transferred file size")
        
        log "SUCCESS" "$description CONCLUÍDO"
        log "INFO" "Tamanho total: $total_size"
        log "INFO" "Transferido: $transferred"
        
        return 0
    else
        local exit_code=$?
        log "ERROR" "$description FALHOU (código: $exit_code)"
        log "ERROR" "Últimas 10 linhas da saída de erro:"
        
        while IFS= read -r line; do
            log "ERROR" "  $line"
        done < <(tail -n 10 "$tmp_output")
        
        return $exit_code
    fi
}

# -----------------------------
# VALIDAÇÕES PRÉ-EXECUÇÃO
# -----------------------------
pre_flight_checks() {
    log "INFO" "=== Iniciando verificações pré-execução ==="
    
    if [ "$EUID" -ne 0 ]; then 
        log "WARNING" "Script não está rodando como root. Verifique permissões."
    fi
    
    # CORRIGIDO: Lock file baseado em PID
    if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
        log "ERROR" "Já existe uma instância do script rodando (PID: $(cat "$LOCK_FILE"))."
        exit 1
    elif [ -f "$LOCK_FILE" ]; then
        log "WARNING" "Lock file antigo encontrado. Removendo."
        rm -f "$LOCK_FILE"
    fi
    
    echo $$ > "$LOCK_FILE"
    
    check_mount "$DESTINATION1" || exit 1
    check_disk_space "$DESTINATION1" || exit 1
    check_ssh_connection "$DESTINATION2" "$SSH_PORT" || exit 1
    
    log "INFO" "=== Todas as verificações passaram ==="
}

# -----------------------------
# MAIN
# -----------------------------
main() {
    log "INFO" "=========================================="
    log "INFO" "Iniciando rotina de backup"
    log "INFO" "=========================================="
    
    pre_flight_checks
    
    if execute_rsync "$SOURCE1" "$DESTINATION1" \
        "SINCRONIZAÇÃO DO SERVIDOR ESPELHO" "22"; then
        log "SUCCESS" "Backup 1 finalizado com sucesso"
    else
        log "ERROR" "Backup 1 falhou - Abortando backup 2"
        exit 1
    fi
    
    if execute_rsync "$SOURCE2" "$DESTINATION2" \
        "BACKUP DE CONTINGÊNCIA" "$SSH_PORT"; then
        log "SUCCESS" "Backup 2 finalizado com sucesso"
    else
        log "ERROR" "Backup 2 falhou"
        exit 1
    fi
    
    log "INFO" "=========================================="
    log "INFO" "Rotina de backup concluída com sucesso"
    log "INFO" "=========================================="
}

main "$@"