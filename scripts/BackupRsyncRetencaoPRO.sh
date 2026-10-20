#!/bin/bash
set -euo pipefail

# ================================================================================
# BACKUP INCREMENTAL COM HARDLINKS - ENTERPRISE GRADE
# ================================================================================
# Versão: 2.0.0
# Autor: Thiago Carrere
# Descrição: Sistema de backup incremental com hardlinks, detecção automática
#            de modo local/remoto, verificação de integridade e recuperação
# ================================================================================

# ================================================================================
# CONFIGURAÇÕES PRINCIPAIS
# ================================================================================
readonly VERSION="2.0.0"
readonly SOURCE="root@192.168.42.250:/mnt/hd1/"
readonly DEST_BASE="/mnt/hd3/backups/diario"
readonly LOGFILE="/.codes/backup_incremental.log"
readonly RSYNC_LOGDIR="/var/log/backup_rsync"
readonly LOCKFILE="/var/run/backup_incremental.lock"
readonly RETENTION_DAYS=7
readonly MIN_DISK_SPACE_GB=10
readonly MAX_LOG_SIZE_MB=100

# Opções rsync base (otimizadas para performance)
readonly RSYNC_BASE_OPTS="-azh --numeric-ids --partial --stats --timeout=300"

# Opções SSH (segurança e performance balanceadas)
readonly SSH_OPTS="-o ConnectTimeout=10 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes -o Compression=no"

# Lista de exclusões (adicione paths que não quer no backup)
readonly EXCLUDE_LIST=(
    "*.tmp"
    "*.temp"
    "*~"
    ".cache/"
    ".Trash/"
    "lost+found/"
    ".snapshots/"
)

# Notificações por email (deixar vazio para desabilitar)
readonly EMAIL_ADMIN=""
readonly EMAIL_FROM="backup@$(hostname -f 2>/dev/null || echo 'localhost')"

# Alertas de integridade (% variação aceitável entre backups)
readonly INTEGRITY_MIN_PERCENT=30    # Alerta se <30% dos arquivos anteriores
readonly INTEGRITY_MAX_PERCENT=250   # Alerta se >250% dos arquivos anteriores

# Timeouts e limites
readonly SSH_TEST_TIMEOUT=15
readonly LOCK_MAX_AGE_HOURS=24       # Considera lock órfão após 24h
readonly FIND_TIMEOUT=300            # Timeout para operações find (5min)

# Hooks externos (deixar vazio para desabilitar)
readonly PRE_BACKUP_HOOK=""          # Ex: "/scripts/pre-backup.sh"
readonly POST_BACKUP_HOOK=""         # Ex: "/scripts/post-backup.sh"

# ================================================================================
# VARIÁVEIS GLOBAIS (NÃO EDITAR)
# ================================================================================
declare SCRIPT_START_TIME
declare IS_LOCAL_BACKUP=false
declare LOCAL_SOURCE=""
declare RSYNC_OPTS=""
declare -i BACKUP_SUCCESS=0
declare -i ERRORS_COUNT=0

# ================================================================================
# FUNÇÕES DE UTILIDADE
# ================================================================================

# --------------------------------------------------------------------------------
# Log com timestamp e níveis
# --------------------------------------------------------------------------------
log_message() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Garantir que diretório do log existe
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    
    # Formato: [TIMESTAMP] [LEVEL] message
    echo "[$timestamp] [$level] $message" | tee -a "$LOGFILE"
}

log_info() {
    log_message "INFO" "$@"
}

log_warn() {
    log_message "WARN" "$@"
    ((ERRORS_COUNT++))
}

log_error() {
    log_message "ERROR" "$@"
    ((ERRORS_COUNT++))
}

log_success() {
    log_message "SUCCESS" "$@"
}

log_debug() {
    # Só loga se DEBUG=1
    [[ "${DEBUG:-0}" == "1" ]] && log_message "DEBUG" "$@"
}

# --------------------------------------------------------------------------------
# Notificação por email com fallback
# --------------------------------------------------------------------------------
notify_admin() {
    local subject="$1"
    local message="$2"
    local priority="${3:-INFO}"
    
    log_message "$priority" "NOTIFICAÇÃO: $message"
    
    # Enviar email apenas para WARN, ERROR e ALERT
    if [[ -n "$EMAIL_ADMIN" ]] && [[ "$priority" =~ ^(WARN|ERROR|ALERT)$ ]]; then
        if command -v mail &> /dev/null; then
            {
                echo "Servidor: $(hostname -f 2>/dev/null || hostname)"
                echo "Data/Hora: $(date)"
                echo "Script: $0 v$VERSION"
                echo ""
                echo "$message"
                echo ""
                echo "---"
                echo "Log completo: $LOGFILE"
            } | mail -s "[BACKUP-$priority] $subject" -r "$EMAIL_FROM" "$EMAIL_ADMIN" 2>&1 | tee -a "$LOGFILE" || {
                log_warn "Falha ao enviar email para $EMAIL_ADMIN"
            }
        else
            log_warn "Comando 'mail' não encontrado - notificação email desabilitada"
        fi
    fi
}

# --------------------------------------------------------------------------------
# Remoção segura de diretórios com múltiplas camadas de validação
# --------------------------------------------------------------------------------
safe_remove() {
    local target="$1"
    
    # Validação 1: Target não pode ser vazio
    if [[ -z "$target" ]]; then
        log_error "safe_remove: target vazio"
        return 1
    fi
    
    # Validação 2: Deve existir e ser diretório
    if [[ ! -d "$target" ]]; then
        log_warn "safe_remove: não é diretório ou não existe: $target"
        return 1
    fi
    
    # Validação 3: Resolver paths reais (seguir symlinks)
    local real_target
    if ! real_target=$(realpath "$target" 2>/dev/null); then
        log_error "safe_remove: falha ao resolver path real: $target"
        return 1
    fi
    
    local real_base
    if ! real_base=$(realpath "$DEST_BASE" 2>/dev/null); then
        log_error "safe_remove: falha ao resolver DEST_BASE: $DEST_BASE"
        return 1
    fi
    
    # Validação 4: Proteção contra paths perigosos
    local dangerous_paths=("/" "/bin" "/boot" "/dev" "/etc" "/home" "/lib" "/lib64" "/opt" "/root" "/sbin" "/sys" "/usr" "/var")
    for dangerous in "${dangerous_paths[@]}"; do
        if [[ "$real_target" == "$dangerous" ]] || [[ "$real_target" == "$dangerous/"* ]]; then
            log_error "SEGURANÇA: Bloqueada remoção de path perigoso: $real_target"
            notify_admin "Tentativa de remoção perigosa bloqueada" "Path: $real_target" "ALERT"
            return 1
        fi
    done
    
    # Validação 5: Deve estar dentro de DEST_BASE
    if [[ "$real_target" != "$real_base"/* ]]; then
        log_error "SEGURANÇA: Path fora de DEST_BASE: $real_target"
        return 1
    fi
    
    # Validação 6: Não pode ser o próprio DEST_BASE
    if [[ "$real_target" == "$real_base" ]]; then
        log_error "SEGURANÇA: Tentativa de remover DEST_BASE"
        return 1
    fi
    
    # Validação 7: Verificar profundidade mínima (segurança extra)
    local depth
    depth=$(echo "$real_target" | tr -cd '/' | wc -c)
    local base_depth
    base_depth=$(echo "$real_base" | tr -cd '/' | wc -c)
    
    if [[ $depth -le $base_depth ]]; then
        log_error "SEGURANÇA: Profundidade insuficiente: $real_target"
        return 1
    fi
    
    # Tudo OK - remover
    log_info "Removendo snapshot: $(basename "$target")"
    if rm -rf "$real_target" 2>&1 | tee -a "$LOGFILE"; then
        return 0
    else
        log_error "Falha ao remover: $real_target"
        return 1
    fi
}

# --------------------------------------------------------------------------------
# Rotação de log com proteção contra race condition
# --------------------------------------------------------------------------------
rotate_log_if_needed() {
    [[ ! -f "$LOGFILE" ]] && return 0
    
    local log_size_bytes
    # Compatibilidade GNU/BSD
    if log_size_bytes=$(stat -c%s "$LOGFILE" 2>/dev/null); then
        : # GNU Linux
    elif log_size_bytes=$(stat -f %z "$LOGFILE" 2>/dev/null); then
        : # BSD/macOS
    else
        log_warn "Não foi possível obter tamanho do log"
        return 1
    fi
    
    local max_size=$((MAX_LOG_SIZE_MB * 1024 * 1024))
    
    if [[ $log_size_bytes -gt $max_size ]]; then
        local rotated="${LOGFILE}.$(date +%Y%m%d_%H%M%S)"
        local temp_log="${LOGFILE}.new"
        
        # Criar novo log ANTES de mover o antigo (evita race condition)
        touch "$temp_log" && chmod 640 "$temp_log" || {
            log_error "Falha ao criar novo log"
            return 1
        }
        
        # Mover log antigo
        mv "$LOGFILE" "$rotated" || {
            log_error "Falha ao rotacionar log"
            rm -f "$temp_log"
            return 1
        }
        
        # Ativar novo log
        mv "$temp_log" "$LOGFILE"
        
        # Comprimir em background com tratamento de erro
        {
            if gzip "$rotated" 2>&1; then
                log_info "Log rotacionado e comprimido: $(basename "$rotated").gz"
            else
                log_warn "Falha ao comprimir log rotacionado: $rotated"
            fi
        } &
    fi
}

# --------------------------------------------------------------------------------
# Validação de configuração no início
# --------------------------------------------------------------------------------
validate_config() {
    local errors=0
    
    log_info "Validando configuração..."
    
    # Validar formato SOURCE
    if [[ ! "$SOURCE" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+:.+$ ]] && [[ ! "$SOURCE" =~ ^/ ]]; then
        echo "ERRO: SOURCE inválido: $SOURCE" >&2
        echo "  Formato esperado: user@host:/path ou /path/local" >&2
        ((errors++))
    fi
    
    # Validar DEST_BASE é path absoluto
    if [[ ! "$DEST_BASE" =~ ^/ ]]; then
        echo "ERRO: DEST_BASE deve ser caminho absoluto: $DEST_BASE" >&2
        ((errors++))
    fi
    
    # Validar RETENTION_DAYS
    if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$RETENTION_DAYS" -lt 1 ]]; then
        echo "ERRO: RETENTION_DAYS inválido: $RETENTION_DAYS" >&2
        ((errors++))
    fi
    
    # Avisos (não bloqueiam)
    if [[ -n "$EMAIL_ADMIN" ]] && ! command -v mail &> /dev/null; then
        echo "AVISO: EMAIL_ADMIN configurado mas comando 'mail' não encontrado" >&2
    fi
    
    # Verificar comandos necessários
    local required_commands=("rsync" "ssh" "find" "date" "df" "du" "awk")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "ERRO: Comando necessário não encontrado: $cmd" >&2
            ((errors++))
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        echo "Configuração inválida ($errors erros). Abortando." >&2
        exit 1
    fi
    
    log_success "Configuração validada"
}

# --------------------------------------------------------------------------------
# Detectar se backup é local ou remoto
# --------------------------------------------------------------------------------
is_local_backup() {
    local ssh_host="$1"
    
    # localhost explícito
    if [[ "$ssh_host" =~ ^(localhost|127\.0\.0\.1|::1)$ ]]; then
        return 0
    fi
    
    # Obter hostname local
    local local_hostname
    local_hostname=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
    
    # Comparar hostname (sem domínio)
    local remote_hostname="${ssh_host%%.*}"
    if [[ "$remote_hostname" == "$local_hostname" ]]; then
        return 0
    fi
    
    # Resolver IP e comparar com IPs locais
    local remote_ip
    if remote_ip=$(getent hosts "$ssh_host" 2>/dev/null | awk '{print $1}' | head -n1); then
        # Obter IPs locais
        local local_ips
        if local_ips=$(hostname -I 2>/dev/null); then
            if echo "$local_ips" | grep -qw "$remote_ip"; then
                return 0
            fi
        fi
        
        # Fallback: usar ip command
        if local_ips=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}'); then
            if echo "$local_ips" | grep -qw "$remote_ip"; then
                return 0
            fi
        fi
    fi
    
    return 1
}

# --------------------------------------------------------------------------------
# Verificar e limpar lock órfão
# --------------------------------------------------------------------------------
check_stale_lock() {
    [[ ! -d "$LOCKFILE" ]] && return 0
    
    log_warn "Lock file existe: $LOCKFILE"
    
    # Verificar idade do lock
    local lock_age_seconds
    if lock_mtime=$(stat -c %Y "$LOCKFILE" 2>/dev/null); then
        : # GNU
    elif lock_mtime=$(stat -f %m "$LOCKFILE" 2>/dev/null); then
        : # BSD
    else
        log_error "Não foi possível verificar idade do lock"
        return 1
    fi
    
    lock_age_seconds=$(( $(date +%s) - lock_mtime ))
    local lock_max_age_seconds=$((LOCK_MAX_AGE_HOURS * 3600))
    
    if [[ $lock_age_seconds -gt $lock_max_age_seconds ]]; then
        log_warn "Lock órfão detectado (idade: $((lock_age_seconds / 3600))h) - removendo"
        rm -rf "$LOCKFILE"
        return 0
    else
        log_error "Backup já em execução (lock age: $((lock_age_seconds / 60))min)"
        return 1
    fi
}

# --------------------------------------------------------------------------------
# Construir opções de exclusão do rsync
# --------------------------------------------------------------------------------
build_exclude_opts() {
    local exclude_opts=""
    
    for pattern in "${EXCLUDE_LIST[@]}"; do
        exclude_opts+="--exclude=$pattern "
    done
    
    echo "$exclude_opts"
}

# --------------------------------------------------------------------------------
# Executar hook se configurado
# --------------------------------------------------------------------------------
run_hook() {
    local hook_type="$1"
    local hook_script=""
    
    case "$hook_type" in
        pre)
            hook_script="$PRE_BACKUP_HOOK"
            ;;
        post)
            hook_script="$POST_BACKUP_HOOK"
            ;;
        *)
            log_error "Tipo de hook inválido: $hook_type"
            return 1
            ;;
    esac
    
    if [[ -z "$hook_script" ]]; then
        return 0
    fi
    
    if [[ ! -x "$hook_script" ]]; then
        log_warn "Hook $hook_type não executável ou não encontrado: $hook_script"
        return 0
    fi
    
    log_info "Executando hook $hook_type: $hook_script"
    
    if timeout 60 "$hook_script" 2>&1 | tee -a "$LOGFILE"; then
        log_success "Hook $hook_type concluído"
        return 0
    else
        log_error "Hook $hook_type falhou"
        return 1
    fi
}

# --------------------------------------------------------------------------------
# Calcular tamanho real transferido (parsing do log do rsync)
# --------------------------------------------------------------------------------
get_transferred_size() {
    local rsync_log="$1"
    
    if [[ ! -f "$rsync_log" ]]; then
        echo "0"
        return
    fi
    
    # Extrair "Total transferred file size" em bytes
    local transferred
    transferred=$(grep -i "Total transferred file size:" "$rsync_log" | \
                  grep -oP '\d+' | head -n1)
    
    echo "${transferred:-0}"
}

# --------------------------------------------------------------------------------
# Formatar bytes para humano
# --------------------------------------------------------------------------------
human_size() {
    local bytes="$1"
    
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt $((1024 * 1024)) ]]; then
        echo "$((bytes / 1024))KB"
    elif [[ $bytes -lt $((1024 * 1024 * 1024)) ]]; then
        echo "$((bytes / 1024 / 1024))MB"
    else
        echo "$((bytes / 1024 / 1024 / 1024))GB"
    fi
}

# ================================================================================
# INICIALIZAÇÃO
# ================================================================================

SCRIPT_START_TIME=$(date +%s)

# Rotacionar log se necessário
rotate_log_if_needed

# Banner
log_info "========================================================================"
log_info "  BACKUP INCREMENTAL ENTERPRISE v$VERSION"
log_info "========================================================================"
log_info "Iniciado em: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname -f 2>/dev/null || hostname)"
log_info "Usuário: $(whoami)"
log_info "PID: $$"

# Validar configuração
validate_config

# Verificar root
if [[ $EUID -ne 0 ]]; then
    log_error "Este script precisa ser executado como root"
    notify_admin "Backup falhou" "Script não executado como root" "ERROR"
    exit 1
fi

# Criar diretórios necessários
mkdir -p "$(dirname "$LOGFILE")" "$RSYNC_LOGDIR" "$DEST_BASE" 2>/dev/null || {
    log_error "Falha ao criar diretórios necessários"
    exit 1
}

chmod 750 "$(dirname "$LOGFILE")" "$RSYNC_LOGDIR" 2>/dev/null || true

# Verificar espaço em disco
log_info "Verificando espaço em disco..."
AVAILABLE_KB=$(df -k "$DEST_BASE" | awk 'NR==2 {print $4}')
AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))

if [[ $AVAILABLE_GB -lt $MIN_DISK_SPACE_GB ]]; then
    log_error "Espaço insuficiente: ${AVAILABLE_GB}GB disponível < ${MIN_DISK_SPACE_GB}GB mínimo"
    notify_admin "Backup falhou" \
        "Espaço insuficiente em $DEST_BASE: ${AVAILABLE_GB}GB < ${MIN_DISK_SPACE_GB}GB" "ERROR"
    exit 1
fi

log_success "Espaço disponível: ${AVAILABLE_GB}GB ✓"

# ================================================================================
# LOCK FILE (com detecção de lock órfão)
# ================================================================================

if ! check_stale_lock; then
    notify_admin "Backup já em execução" "Lock file existe e é recente" "ALERT"
    exit 1
fi

if ! mkdir "$LOCKFILE" 2>/dev/null; then
    log_error "Falha ao criar lock file"
    exit 1
fi

# Garantir limpeza do lock
trap 'rm -rf "$LOCKFILE"; log_info "Lock removido"' EXIT

# Escrever PID no lock (para debug)
echo "$$" > "$LOCKFILE/pid" 2>/dev/null || true
echo "$(date +%s)" > "$LOCKFILE/timestamp" 2>/dev/null || true

# ================================================================================
# DETECTAR MODO: LOCAL vs REMOTO
# ================================================================================

log_info "Analisando origem do backup..."

# Verificar se SOURCE é path local
if [[ "$SOURCE" =~ ^/ ]]; then
    # Path absoluto local
    IS_LOCAL_BACKUP=true
    LOCAL_SOURCE="$SOURCE"
    log_info "Modo: BACKUP LOCAL"
    log_info "Origem: $LOCAL_SOURCE"
    
    # Verificar se diretório existe
    if [[ ! -d "$LOCAL_SOURCE" ]]; then
        log_error "Diretório local não existe: $LOCAL_SOURCE"
        notify_admin "Backup falhou" "Diretório origem não existe: $LOCAL_SOURCE" "ERROR"
        exit 1
    fi
    
    # Verificar permissões de leitura
    if [[ ! -r "$LOCAL_SOURCE" ]]; then
        log_error "Sem permissão de leitura em: $LOCAL_SOURCE"
        notify_admin "Backup falhou" "Sem permissão de leitura: $LOCAL_SOURCE" "ERROR"
        exit 1
    fi
    
else
    # Formato user@host:path
    SSH_HOST="${SOURCE%%:*}"
    REMOTE_PATH="${SOURCE#*:}"
    
    log_info "Verificando se é backup local ou remoto..."
    
    if is_local_backup "$SSH_HOST"; then
        IS_LOCAL_BACKUP=true
        LOCAL_SOURCE="$REMOTE_PATH"
        
        log_info "Modo: BACKUP LOCAL (detectado automaticamente)"
        log_info "Host remoto '$SSH_HOST' é o host local"
        log_info "Origem: $LOCAL_SOURCE"
        
        # Verificar se diretório existe
        if [[ ! -d "$LOCAL_SOURCE" ]]; then
            log_error "Diretório local não existe: $LOCAL_SOURCE"
            notify_admin "Backup falhou" "Diretório origem não existe: $LOCAL_SOURCE" "ERROR"
            exit 1
        fi
        
    else
        IS_LOCAL_BACKUP=false
        
        log_info "Modo: BACKUP REMOTO via SSH"
        log_info "Host: $SSH_HOST"
        log_info "Path remoto: $REMOTE_PATH"
        
        # Testar conectividade SSH
        log_info "Testando conexão SSH..."
        
        if ! timeout "$SSH_TEST_TIMEOUT" ssh $SSH_OPTS -o BatchMode=yes "$SSH_HOST" "exit" 2>/dev/null; then
            log_error "Falha na conexão SSH com $SSH_HOST"
            notify_admin "Backup falhou" \
                "Não foi possível conectar via SSH: $SSH_HOST" "ERROR"
            exit 1
        fi
        
        log_success "Conexão SSH estabelecida ✓"
        
        # Verificar se path remoto existe
        log_info "Verificando existência do path remoto..."
        
        if ! timeout "$SSH_TEST_TIMEOUT" ssh $SSH_OPTS -o BatchMode=yes "$SSH_HOST" "test -d '$REMOTE_PATH'" 2>/dev/null; then
            log_error "Path remoto não existe ou não é acessível: $REMOTE_PATH"
            notify_admin "Backup falhou" \
                "Path remoto não existe: $SSH_HOST:$REMOTE_PATH" "ERROR"
            exit 1
        fi
        
        log_success "Path remoto verificado ✓"
    fi
fi

# ================================================================================
# CONSTRUIR OPÇÕES DO RSYNC
# ================================================================================

# Detectar se está em terminal interativo
if [[ -t 1 ]]; then
    # Terminal interativo - mostrar progresso
    PROGRESS_OPT="--info=progress2"
    log_info "Modo interativo - progresso habilitado"
else
    # Cron/background - sem progresso
    PROGRESS_OPT=""
    log_info "Modo não-interativo - progresso desabilitado"
fi

# Construir exclusões
EXCLUDE_OPTS=$(build_exclude_opts)

# Opções finais do rsync
RSYNC_OPTS="$RSYNC_BASE_OPTS $PROGRESS_OPT --delete $EXCLUDE_OPTS"

log_debug "Opções rsync: $RSYNC_OPTS"

# ================================================================================
# PREPARAR DESTINO
# ================================================================================

readonly HOJE=$(date +%F_%H%M)
readonly DEST="$DEST_BASE/$HOJE"

log_info "Criando diretório de destino..."

if ! mkdir -p "$DEST"; then
    log_error "Falha ao criar diretório de destino: $DEST"
    notify_admin "Backup falhou" "Não foi possível criar $DEST" "ERROR"
    exit 1
fi

log_success "Destino criado: $DEST"

# ================================================================================
# ENCONTRAR SNAPSHOT ANTERIOR (para --link-dest)
# ================================================================================

log_info "Procurando snapshot anterior válido..."

PREV=""
PREV_COUNT=0
PREV_SIZE_BYTES=0
SNAPSHOT_LIST=()

# Buscar todos os snapshots válidos (ordenados do mais recente para o mais antigo)
while IFS= read -r -d '' dir; do
    if [[ -f "$dir/BACKUP_OK" ]] && [[ "$dir" != "$DEST" ]]; then
        SNAPSHOT_LIST+=("$dir")
    fi
done < <(find "$DEST_BASE" -maxdepth 1 -type d -name "20*" -print0 2>/dev/null | sort -zr)

if [[ ${#SNAPSHOT_LIST[@]} -gt 0 ]]; then
    PREV="${SNAPSHOT_LIST[0]}"
    LINKDEST="--link-dest=$PREV"
    
    log_info "Snapshot anterior encontrado: $(basename "$PREV")"
    
    # Contar arquivos (com timeout para evitar travamento)
    log_info "Contando arquivos do snapshot anterior..."
    if PREV_COUNT=$(timeout "$FIND_TIMEOUT" find "$PREV" -type f 2>/dev/null | wc -l); then
        log_info "Arquivos no snapshot anterior: $PREV_COUNT"
    else
        log_warn "Timeout ao contar arquivos do snapshot anterior"
        PREV_COUNT=0
    fi
    
    # Tamanho do snapshot anterior
    if PREV_SIZE=$(du -sh "$PREV" 2>/dev/null | cut -f1); then
        log_info "Tamanho do snapshot anterior: $PREV_SIZE"
    else
        PREV_SIZE="N/A"
    fi
    
else
    LINKDEST=""
    log_info "Nenhum snapshot anterior - será feito backup COMPLETO"
fi

# ================================================================================
# EXECUTAR HOOK PRÉ-BACKUP
# ================================================================================

if ! run_hook "pre"; then
    log_warn "Hook pré-backup falhou (continuando backup)"
fi

# ================================================================================
# EXECUTAR BACKUP
# ================================================================================

START_TIME=$(date +%s)
RSYNC_LOG="$RSYNC_LOGDIR/rsync_${HOJE}.log"

log_info "========================================================================"
log_info "  INICIANDO RSYNC"
log_info "========================================================================"

if [[ "$IS_LOCAL_BACKUP" == true ]]; then
    log_info "Origem: $LOCAL_SOURCE (local)"
else
    log_info "Origem: $SOURCE (remoto via SSH)"
fi

log_info "Destino: $DEST"
log_info "Link-dest: ${LINKDEST:-nenhum (backup completo)}"
log_info "Log rsync: $RSYNC_LOG"
log_info ""

set +e

if [[ "$IS_LOCAL_BACKUP" == true ]]; then
    # Backup LOCAL - sem SSH
    rsync $RSYNC_OPTS $LINKDEST \
        "$LOCAL_SOURCE" "$DEST/" \
        > "$RSYNC_LOG" 2>&1
else
    # Backup REMOTO - com SSH
    rsync $RSYNC_OPTS $LINKDEST \
        -e "ssh $SSH_OPTS" \
        "$SOURCE" "$DEST/" \
        > "$RSYNC_LOG" 2>&1
fi

RSYNC_EXIT=$?
set -e

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_info ""
log_info "========================================================================"
log_info "Rsync finalizado em ${DURATION}s (código: $RSYNC_EXIT)"
log_info "========================================================================"

# ================================================================================
# PROCESSAR ESTATÍSTICAS DO RSYNC
# ================================================================================

if [[ -f "$RSYNC_LOG" ]]; then
    log_info "Extraindo estatísticas..."
    
    {
        echo ""
        echo "=== ESTATÍSTICAS DO RSYNC ==="
        grep -E "(Number of files|Number of created files|Number of deleted files|Total file size|Total transferred file size|Literal data|Matched data|File list size|Total bytes sent|Total bytes received)" "$RSYNC_LOG" 2>/dev/null || echo "Estatísticas não disponíveis"
        echo "=== FIM ESTATÍSTICAS ==="
        echo ""
    } | tee -a "$LOGFILE"
    
    # Limpar logs antigos do rsync (>30 dias)
    find "$RSYNC_LOGDIR" -name "rsync_*.log" -mtime +30 -delete 2>/dev/null || true
fi

# ================================================================================
# PROCESSAR RESULTADO DO RSYNC
# ================================================================================

# Códigos de saída do rsync:
# 0  = Sucesso
# 24 = Arquivos parcialmente transferidos (arquivos mudaram durante cópia - aceitável)
# 23 = Erro parcial de transferência (alguns arquivos falharam)
# outros = erro

if [[ $RSYNC_EXIT -eq 0 || $RSYNC_EXIT -eq 24 ]]; then
    
    log_info "Rsync concluído - verificando integridade..."
    
    # Contar arquivos no novo backup
    NEW_COUNT=0
    if NEW_COUNT=$(timeout "$FIND_TIMEOUT" find "$DEST" -type f 2>/dev/null | wc -l); then
        log_info "Arquivos no novo backup: $NEW_COUNT"
    else
        log_warn "Timeout ao contar arquivos do novo backup"
    fi
    
    # Verificação de integridade (alertar sobre variações anormais)
    if [[ $PREV_COUNT -gt 0 ]] && [[ $NEW_COUNT -gt 0 ]]; then
        DIFF_PERCENT=$(( (NEW_COUNT * 100) / PREV_COUNT ))
        
        log_info "Variação de arquivos: ${DIFF_PERCENT}% (anterior: $PREV_COUNT → novo: $NEW_COUNT)"
        
        if [[ $DIFF_PERCENT -lt $INTEGRITY_MIN_PERCENT ]]; then
            log_warn "ALERTA: Redução significativa de arquivos (${DIFF_PERCENT}% < ${INTEGRITY_MIN_PERCENT}%)"
            notify_admin "Variação anormal no backup" \
                "Apenas $DIFF_PERCENT% dos arquivos anteriores ($PREV_COUNT → $NEW_COUNT)" \
                "ALERT"
        elif [[ $DIFF_PERCENT -gt $INTEGRITY_MAX_PERCENT ]]; then
            log_warn "ALERTA: Aumento significativo de arquivos (${DIFF_PERCENT}% > ${INTEGRITY_MAX_PERCENT}%)"
            notify_admin "Variação anormal no backup" \
                "$DIFF_PERCENT% dos arquivos anteriores ($PREV_COUNT → $NEW_COUNT)" \
                "ALERT"
        else
            log_success "Verificação de integridade OK (variação: ${DIFF_PERCENT}%)"
        fi
    fi
    
    # Marcar backup como bem-sucedido
    {
        echo "BACKUP_OK"
        echo "timestamp=$(date +%s)"
        echo "date=$(date)"
        echo "source=$SOURCE"
        echo "files=$NEW_COUNT"
        echo "duration=$DURATION"
        echo "rsync_exit=$RSYNC_EXIT"
    } > "$DEST/BACKUP_OK"
    
    # Calcular tamanho
    NEW_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1 || echo "N/A")
    
    # Calcular dados realmente transferidos (não confundir com tamanho total por causa dos hardlinks)
    TRANSFERRED_BYTES=$(get_transferred_size "$RSYNC_LOG")
    TRANSFERRED_HUMAN=$(human_size "$TRANSFERRED_BYTES")
    
    # Calcular taxa de transferência REAL
    if [[ $DURATION -gt 0 ]] && [[ $TRANSFERRED_BYTES -gt 0 ]]; then
        RATE_MBS=$(( TRANSFERRED_BYTES / DURATION / 1024 / 1024 ))
        log_info "Taxa de transferência: ${RATE_MBS} MB/s"
    fi
    
    # Mensagem final
    if [[ $RSYNC_EXIT -eq 24 ]]; then
        log_warn "BACKUP CONCLUÍDO COM AVISOS (código 24)"
        log_warn "Alguns arquivos foram modificados durante a cópia"
        notify_admin "Backup com avisos" \
            "Código rsync 24: arquivos modificados durante backup" "WARN"
    else
        log_success "✓ BACKUP CONCLUÍDO COM SUCESSO"
    fi
    
    log_info "Tamanho total: $NEW_SIZE"
    log_info "Dados transferidos: $TRANSFERRED_HUMAN"
    log_info "Arquivos: $NEW_COUNT"
    
    BACKUP_SUCCESS=1
    
elif [[ $RSYNC_EXIT -eq 23 ]]; then
    log_warn "Rsync concluído com erros parciais (código 23)"
    log_warn "Alguns arquivos não foram transferidos"
    notify_admin "Backup com erros parciais" \
        "Código rsync 23 - verificar $RSYNC_LOG" "WARN"
    
    # Marcar como parcialmente bem-sucedido
    touch "$DEST/BACKUP_PARTIAL"
    BACKUP_SUCCESS=1
    
else
    log_error "BACKUP FALHOU (código rsync: $RSYNC_EXIT)"
    log_error "Consulte o log para detalhes: $RSYNC_LOG"
    
    notify_admin "Backup falhou" \
        "Código rsync $RSYNC_EXIT - ver $RSYNC_LOG" "ERROR"
    
    # Remover backup incompleto
    if [[ -d "$DEST" ]]; then
        log_info "Removendo backup incompleto..."
        rm -rf "$DEST"
    fi
    
    BACKUP_SUCCESS=0
    exit 1
fi

# ================================================================================
# POLÍTICA DE RETENÇÃO
# ================================================================================

log_info "========================================================================"
log_info "  APLICANDO POLÍTICA DE RETENÇÃO"
log_info "========================================================================"
log_info "Política: manter últimos $RETENTION_DAYS snapshots"

# Listar todos os snapshots válidos (ordenados do mais antigo para o mais recente)
VALID_SNAPSHOTS=()
while IFS= read -r -d '' snap; do
    if [[ -f "$snap/BACKUP_OK" ]] || [[ -f "$snap/BACKUP_PARTIAL" ]]; then
        VALID_SNAPSHOTS+=("$snap")
    fi
done < <(find "$DEST_BASE" -maxdepth 1 -type d -name "20*" -print0 2>/dev/null | sort -z)

TOTAL=${#VALID_SNAPSHOTS[@]}
log_info "Snapshots válidos encontrados: $TOTAL"

REMOVED=0  # IMPORTANTE: inicializar antes do if

if [[ $TOTAL -gt $RETENTION_DAYS ]]; then
    REMOVE_COUNT=$((TOTAL - RETENTION_DAYS))
    log_info "Removendo $REMOVE_COUNT snapshots antigos..."
    
    # Remover apenas os primeiros (mais antigos)
    for (( i=0; i<REMOVE_COUNT && i<${#VALID_SNAPSHOTS[@]}; i++ )); do
        if safe_remove "${VALID_SNAPSHOTS[$i]}"; then
            ((REMOVED++))
        fi
    done
    
    log_success "Snapshots removidos: $REMOVED de $REMOVE_COUNT"
else
    log_info "Retenção OK - $TOTAL snapshots ≤ $RETENTION_DAYS (limite)"
fi

# ================================================================================
# EXECUTAR HOOK PÓS-BACKUP
# ================================================================================

if ! run_hook "post"; then
    log_warn "Hook pós-backup falhou"
fi

# ================================================================================
# RELATÓRIO FINAL
# ================================================================================

FINAL_TIME=$(date +%s)
TOTAL_DURATION=$((FINAL_TIME - SCRIPT_START_TIME))
FINAL_SPACE_KB=$(df -k "$DEST_BASE" | awk 'NR==2 {print $4}')
FINAL_SPACE_GB=$((FINAL_SPACE_KB / 1024 / 1024))

log_info "========================================================================"
log_info "  RELATÓRIO FINAL"
log_info "========================================================================"
log_info "Status: $([ $BACKUP_SUCCESS -eq 1 ] && echo 'SUCESSO ✓' || echo 'FALHA ✗')"
log_info "Tempo total de execução: ${TOTAL_DURATION}s ($((TOTAL_DURATION / 60))min)"
log_info "Tempo de rsync: ${DURATION}s"
log_info "Espaço livre no destino: ${FINAL_SPACE_GB}GB"
log_info "Snapshots mantidos: $((TOTAL - REMOVED))"
log_info "Erros/avisos: $ERRORS_COUNT"

# Listar snapshots atuais
log_info ""
log_info "Snapshots disponíveis:"

while IFS= read -r -d '' snap; do
    if [[ -d "$snap" ]]; then
        snap_name=$(basename "$snap")
        snap_size=$(du -sh "$snap" 2>/dev/null | cut -f1 || echo "N/A")
        
        # Status do snapshot
        if [[ -f "$snap/BACKUP_OK" ]]; then
            snap_status="OK"
        elif [[ -f "$snap/BACKUP_PARTIAL" ]]; then
            snap_status="PARCIAL"
        else
            snap_status="DESCONHECIDO"
        fi
        
        # Idade do snapshot
        if snap_mtime=$(stat -c %Y "$snap" 2>/dev/null); then
            : # GNU
        elif snap_mtime=$(stat -f %m "$snap" 2>/dev/null); then
            : # BSD
        else
            snap_mtime=0
        fi
        
        if [[ $snap_mtime -gt 0 ]]; then
            snap_age_days=$(( ($(date +%s) - snap_mtime) / 86400 ))
            log_info "  [$snap_status] $snap_name: $snap_size (${snap_age_days}d)"
        else
            log_info "  [$snap_status] $snap_name: $snap_size"
        fi
    fi
done < <(find "$DEST_BASE" -maxdepth 1 -type d -name "20*" -print0 2>/dev/null | sort -zr)

log_info ""
log_info "========================================================================"
log_info "  BACKUP FINALIZADO COM SUCESSO"
log_info "========================================================================"
log_info "Finalizado em: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "Log completo: $LOGFILE"
log_info "Log rsync: $RSYNC_LOG"
log_info "========================================================================"

# Notificar sucesso (apenas se configurado)
if [[ $BACKUP_SUCCESS -eq 1 ]] && [[ -n "$EMAIL_ADMIN" ]] && [[ "${NOTIFY_SUCCESS:-0}" == "1" ]]; then
    notify_admin "Backup concluído" \
        "Backup de $(basename "$SOURCE") concluído em ${TOTAL_DURATION}s" "INFO"
fi

exit 0