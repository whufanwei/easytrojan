#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

# ------------------------------------------------------------------------------
# AnyTLS + Let's Encrypt 多用户管理脚本
# 基于原 AnyTLS-LetsEncrypt(1).sh 优化
# 仅部署 AnyTLS，不包含 AnyReality
#
# 主要功能：
# 1. 安装 / 重构 AnyTLS
# 2. 服务管理（启动 / 停止 / 重启）
# 3. 查看全部 AnyTLS 用户节点链接
# 4. 查看运行状态
# 5. 查看实时日志
# 6. 卸载 AnyTLS
# 7. 多用户管理（添加 / 删除 / 重置密码 / 查看节点）
# 8. 更新模块（Sing-Box 内核 / AnyTLS 配置与证书）  [新增]
#    也可直接运行：any update
# ------------------------------------------------------------------------------

readonly CONFIG_PATH="/etc/sing-box/config.json"
readonly INFO_PATH="/root/.sb_info.json"
readonly TLS_DIR="/root/AnyTLS/tls"
readonly SERVICE_NAME="sing-box"
readonly LOCAL_SCRIPT_PATH="/root/any.sh"
readonly DOMAIN_INFO="/root/AnyTLS/domain.txt"
readonly RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/sing-box-restart.sh"
readonly BACKUP_DIR="/root/AnyTLS/backup"

# 更新模块使用
readonly SINGBOX_API_RELEASES="https://api.github.com/repos/SagerNet/sing-box/releases"
readonly SINGBOX_INSTALL_URL="https://sing-box.app/install.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

pause() {
    echo -e "\n${YELLOW}按任意键继续...${NC}"
    read -n 1 -s -r || true
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 Root 权限运行，请使用 sudo -i 后再试。"
        exit 1
    fi
}

force_register_shortcut() {
    if [[ -f "$0" && -s "$0" && "$0" != /dev/fd/* ]]; then
        cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
        chmod 700 "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi
    local target_paths=("/usr/local/bin/any" "/usr/bin/any")
    local path
    for path in "${target_paths[@]}"; do
        rm -f "$path" 2>/dev/null || true
        cat > "$path" <<'SHORTCUT'
#!/usr/bin/env bash
if [[ -f /root/any.sh ]]; then
    exec bash /root/any.sh "$@"
else
    echo "[ERROR] /root/any.sh 不存在，无法启动 AnyTLS 管理脚本。"
    echo "请重新运行安装脚本以恢复快捷命令。"
    exit 1
fi
SHORTCUT
        chmod 755 "$path" 2>/dev/null || true
    done
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

check_and_print_port_status() {
    local port="$1"
    local is_busy=0
    if command_exists ss; then
        if ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
            is_busy=1
        fi
    elif command_exists netstat; then
        if netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)$port$"; then
            is_busy=1
        fi
    elif command_exists lsof; then
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            is_busy=1
        fi
    fi
    if [[ $is_busy -eq 1 ]]; then
        log_warn "检测到端口 ${port} 已被占用！"
        return 1
    fi
    log_success "端口 ${port} 未被占用，可以使用。"
    return 0
}

get_public_ip() {
    local ip=""
    ip=$(curl -4 -fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -6 -fsS --connect-timeout 5 https://api64.ipify.org 2>/dev/null || true)
    fi
    echo "${ip:-127.0.0.1}"
}

format_server_address() {
    local ip="$1"
    if [[ "$ip" == *:* && "$ip" != \[*\] ]]; then
        printf '[%s]' "$ip"
    else
        printf '%s' "$ip"
    fi
}

url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

open_firewall_port() {
    local port="$1"
    log_info "正在尝试放行防火墙 TCP ${port}..."
    if command_exists ufw && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    elif command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    log_success "防火墙处理完成（如使用云厂商安全组，还需放行相应端口）。"
}

print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    if [[ -f "$CONFIG_PATH" && -f "$INFO_PATH" ]] && jq -e '.anytls' "$INFO_PATH" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            local pid
            pid=$(pgrep -x sing-box | head -n 1 || true)
            echo -e " 服务状态: ${GREEN}${BOLD}● AnyTLS 正常运行${NC} (PID: ${pid:-未知})"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● AnyTLS 已安装但未运行${NC}"
        fi
        echo -e " 协议: ${CYAN}AnyTLS${NC}"
        echo -e " TLS: ${CYAN}Let's Encrypt${NC}"
        echo -e " 用户数: ${CYAN}$(jq '.anytls.users | length' "$INFO_PATH" 2>/dev/null || echo 0)${NC}"
    else
        echo -e " 服务状态: ${RED}${BOLD}○ AnyTLS 未安装 / 未配置${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

install_dependencies() {
    log_info "检查并安装必要依赖组件..."
    if command_exists apt-get; then
        apt-get update -y -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq net-tools openssl lsof certbot
    elif command_exists dnf; then
        dnf install -y -q curl jq net-tools openssl lsof certbot
    elif command_exists yum; then
        yum install -y -q curl jq net-tools openssl lsof certbot
    else
        log_error "不支持的 Linux 包管理器。"
        return 1
    fi
    log_info "正在安装/更新 Sing-Box Beta 官方内核..."
    if curl -fsSL https://sing-box.app/install.sh | sh -s -- --beta; then
        if command_exists sing-box; then
            log_success "Sing-Box 核心组件安装/更新完毕！"
        else
            log_error "安装脚本执行成功，但未找到 sing-box 可执行文件。"
            return 1
        fi
    else
        log_error "Sing-Box 安装失败，请检查服务器网络。"
        return 1
    fi
}

setup_renew_hook() {
    mkdir -p "$(dirname "$RENEW_HOOK")"
    cat > "$RENEW_HOOK" <<EOF2
#!/usr/bin/env bash
systemctl restart ${SERVICE_NAME}
EOF2
    chmod 755 "$RENEW_HOOK"
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

validate_domain() {
    local domain="$1"
    domain="${domain%.}"
    [[ -n "$domain" ]] || return 1
    [[ "$domain" != *[[:space:]]* ]] || return 1
    [[ "$domain" != */* && "$domain" != *:* && "$domain" != *'?'* && "$domain" != *'#'* ]] || return 1
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

generate_cert() {
    local sni="$1"
    local was_active=0
    mkdir -p "$TLS_DIR"
    if ! command_exists certbot; then
        log_error "未找到 Certbot。"
        return 1
    fi
    log_info "准备申请 Let's Encrypt 证书：${sni}"
    log_warn "要求：DNS 已将 ${sni} 指向本服务器，并且公网 TCP/80 可以访问。"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        was_active=1
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if ! certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring \
        -d "$sni"; then
        log_error "Let's Encrypt 证书申请失败！"
        log_error "请确认 DNS、TCP/80、云安全组和域名均正确。"
        [[ $was_active -eq 1 ]] && systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
        return 1
    fi
    [[ -f "/etc/letsencrypt/live/${sni}/fullchain.pem" ]] || {
        log_error "证书文件不存在。"
        [[ $was_active -eq 1 ]] && systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
        return 1
    }
    [[ -f "/etc/letsencrypt/live/${sni}/privkey.pem" ]] || {
        log_error "私钥文件不存在。"
        [[ $was_active -eq 1 ]] && systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
        return 1
    }
    ln -sfn "/etc/letsencrypt/live/${sni}/fullchain.pem" "$TLS_DIR/server.crt"
    ln -sfn "/etc/letsencrypt/live/${sni}/privkey.pem" "$TLS_DIR/server.key"
    printf '%s\n' "$sni" > "$DOMAIN_INFO"
    chmod 600 "$DOMAIN_INFO"
    setup_renew_hook
    log_success "Let's Encrypt 证书申请成功！"
    log_info "证书：$TLS_DIR/server.crt"
    log_info "私钥：$TLS_DIR/server.key"
    [[ $was_active -eq 1 ]] && systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$file" "$BACKUP_DIR/$(basename "$file").$(date +%Y%m%d-%H%M%S).bak"
}

validate_sing_box_config() {
    if ! command_exists sing-box; then
        log_error "未找到 sing-box。"
        return 1
    fi
    sing-box check -c "$CONFIG_PATH"
}

ensure_info_file() {
    [[ -f "$INFO_PATH" ]] || return 1
    jq -e '.anytls.port and .anytls.sni and (.anytls.users | type == "array")' "$INFO_PATH" >/dev/null 2>&1
}

user_name_exists() {
    local name="$1"
    jq -e --arg n "$name" '.anytls.users[]? | select(.name == $n)' "$INFO_PATH" >/dev/null 2>&1
}

validate_user_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]
}

validate_password() {
    local pwd="$1"
    [[ ${#pwd} -ge 8 && ${#pwd} -le 128 ]]
}

generate_password() {
    openssl rand -hex 16
}

write_info() {
    local tmp
    tmp=$(mktemp "${INFO_PATH}.XXXXXX")
    cat > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$INFO_PATH"
}

generate_config_from_info_file() {
    local info_file="$1" dest_config="$2"
    local port sni users_json tmp
    [[ -f "$info_file" ]] || return 1
    jq -e '.anytls.port and .anytls.sni and (.anytls.users | type == "array")' "$info_file" >/dev/null 2>&1 || return 1
    port=$(jq -r '.anytls.port' "$info_file")
    sni=$(jq -r '.anytls.sni' "$info_file")
    users_json=$(jq -c '.anytls.users | map({name, password: .pwd})' "$info_file")
    tmp=$(mktemp "${dest_config}.XXXXXX")
    mkdir -p "$(dirname "$dest_config")"
    jq -n --argjson port "$port" --argjson users "$users_json" '{
        log: {level:"info", timestamp:true},
        inbounds: [{
            type:"anytls", listen:"::", listen_port:$port, users:$users,
            padding_scheme:["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
            tls:{enabled:true, certificate_path:"/root/AnyTLS/tls/server.crt", key_path:"/root/AnyTLS/tls/server.key"}
        }]
    }' > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$dest_config"
    : "$sni"
}

write_config_from_info() {
    local tmp_config
    tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    if ! generate_config_from_info_file "$INFO_PATH" "$tmp_config"; then
        rm -f "$tmp_config"; return 1
    fi
    mv -f "$tmp_config" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
}

restore_pair() {
    local info_backup="$1" config_backup="$2"
    cp -a "$info_backup" "$INFO_PATH" || return 1
    cp -a "$config_backup" "$CONFIG_PATH" || return 1
    chmod 600 "$INFO_PATH" "$CONFIG_PATH" 2>/dev/null || true
}

commit_user_change() {
    local new_info="$1" new_config="$2" action_desc="$3"
    local stamp info_backup config_backup old_active=0
    stamp=$(date +%Y%m%d-%H%M%S)-$$
    mkdir -p "$BACKUP_DIR"
    info_backup="$BACKUP_DIR/transaction-${stamp}-info.json"
    config_backup="$BACKUP_DIR/transaction-${stamp}-config.json"
    cp -a "$INFO_PATH" "$info_backup" || { log_error "备份用户信息失败，未执行${action_desc}。"; return 1; }
    cp -a "$CONFIG_PATH" "$config_backup" || { log_error "备份 Sing-Box 配置失败，未执行${action_desc}。"; rm -f "$info_backup"; return 1; }
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && old_active=1
    if ! cp -a "$new_info" "$INFO_PATH" || ! cp -a "$new_config" "$CONFIG_PATH"; then
        log_error "写入新配置失败，正在自动回滚。"; restore_pair "$info_backup" "$config_backup" || true; return 1
    fi
    chmod 600 "$INFO_PATH" "$CONFIG_PATH"
    if ! validate_sing_box_config; then
        log_error "配置校验失败，正在自动回滚。"; restore_pair "$info_backup" "$config_backup" || true; return 1
    fi
    if ! systemctl restart "$SERVICE_NAME" || ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "${action_desc}后 Sing-Box 启动失败，正在自动回滚。"
        restore_pair "$info_backup" "$config_backup" || true
        if [[ $old_active -eq 1 ]]; then systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true; else systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then log_warn "原配置已恢复，Sing-Box 已恢复运行。"; else log_error "原配置已恢复，但 Sing-Box 未能恢复运行，请执行：systemctl status sing-box"; fi
        return 1
    fi
    rm -f "$info_backup" "$config_backup"
    return 0
}

create_user_interactive() {
    local name pwd tmp_info tmp_config
    while :; do
        read -rp " 用户名 [例如 phone/pc/ipad]: " name
        if ! validate_user_name "$name"; then log_warn "用户名只能使用 1-32 位字母、数字、下划线、点、短横线。"; continue; fi
        if user_name_exists "$name"; then log_warn "用户 ${name} 已存在。"; continue; fi
        break
    done
    read -rp " 密码 [默认: 自动生成]: " pwd; pwd=${pwd:-$(generate_password)}
    if ! validate_password "$pwd"; then log_warn "密码长度必须为 8-128 个字符。"; return 1; fi
    tmp_info=$(mktemp "${INFO_PATH}.XXXXXX"); tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    if ! jq --arg n "$name" --arg p "$pwd" '.anytls.users += [{name:$n,pwd:$p}]' "$INFO_PATH" > "$tmp_info"; then rm -f "$tmp_info" "$tmp_config"; log_error "生成用户信息失败。"; return 1; fi
    chmod 600 "$tmp_info"
    if ! generate_config_from_info_file "$tmp_info" "$tmp_config" || ! sing-box check -c "$tmp_config"; then rm -f "$tmp_info" "$tmp_config"; log_error "新用户配置校验失败，未修改现有配置。"; return 1; fi
    if commit_user_change "$tmp_info" "$tmp_config" "添加用户 ${name}"; then
        rm -f "$tmp_info" "$tmp_config"; log_success "用户 ${name} 添加成功。"; log_success "密码：${pwd}"; return 0
    fi
    rm -f "$tmp_info" "$tmp_config"; return 1
}

list_users() {
    ensure_info_file || {
        log_warn "尚未安装 AnyTLS。"
        return 1
    }
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    echo -e "${BOLD}当前 AnyTLS 用户${NC}"
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    printf '%-5s %-24s\n' "序号" "用户名"
    echo "--------------------------------"
    local i=0 name
    while IFS= read -r name; do
        i=$((i+1))
        printf '%-5s %-24s\n' "$i" "$name"
    done < <(jq -r '.anytls.users[]?.name' "$INFO_PATH")
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

select_user_name() {
    local prompt="$1"
    local count name index
    count=$(jq '.anytls.users | length' "$INFO_PATH")
    if [[ "$count" -eq 0 ]]; then
        log_warn "当前没有用户。"
        return 1
    fi
    list_users >&2
    read -rp " ${prompt} [1-${count}]: " index
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    [[ "$index" -ge 1 && "$index" -le "$count" ]] || return 1
    name=$(jq -r ".anytls.users[$((index-1))].name" "$INFO_PATH")
    printf '%s' "$name"
}

show_user_link() {
    local username="$1"
    local ip p s pwd enc_pwd addr
    ip=$(get_public_ip)
    addr=$(format_server_address "$ip")
    p=$(jq -r '.anytls.port' "$INFO_PATH")
    s=$(jq -r '.anytls.sni' "$INFO_PATH")
    pwd=$(jq -r --arg n "$username" '.anytls.users[] | select(.name == $n) | .pwd' "$INFO_PATH")
    enc_pwd=$(url_encode "$pwd")
    echo -e "${GREEN}[ ${username} ]${NC}"
    echo -e "${YELLOW}anytls://${enc_pwd}@${addr}:${p}/?sni=${s}&fp=chrome#AnyTLS_${username}${NC}"
}

show_links() {
    clear
    if ! ensure_info_file; then
        log_warn "未找到 AnyTLS 配置，请先安装。"
        pause
        return
    fi
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                 AnyTLS 节点信息                     ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    local count
    count=$(jq '.anytls.users | length' "$INFO_PATH")
    echo -e "${CYAN}用户数量：${count}${NC}\n"
    local name
    while IFS= read -r name; do
        show_user_link "$name"
        echo
    done < <(jq -r '.anytls.users[]?.name' "$INFO_PATH")
    echo -e "${CYAN}TLS: Let's Encrypt${NC}"
    echo -e "${CYAN}skip-cert-verify: false${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    pause
}

add_user() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                    添加用户                         ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    create_user_interactive || true
    pause
}

delete_user() {
    clear; echo -e "${CYAN}=====================================================${NC}"; echo -e "${BOLD}                    删除用户                         ${NC}"; echo -e "${CYAN}=====================================================${NC}"
    local username count tmp_info tmp_config confirm
    username=$(select_user_name "请选择要删除的用户") || { pause; return; }
    count=$(jq '.anytls.users | length' "$INFO_PATH")
    if [[ "$count" -le 1 ]]; then log_warn "至少保留一个 AnyTLS 用户。"; pause; return; fi
    read -rp " 确定删除用户 ${username}？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消。"; pause; return; }
    tmp_info=$(mktemp "${INFO_PATH}.XXXXXX"); tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    if ! jq --arg n "$username" '.anytls.users |= map(select(.name != $n))' "$INFO_PATH" > "$tmp_info"; then rm -f "$tmp_info" "$tmp_config"; log_error "生成删除后的用户信息失败。"; pause; return; fi
    chmod 600 "$tmp_info"
    if [[ "$(jq '.anytls.users | length' "$tmp_info")" -ne $((count - 1)) ]]; then rm -f "$tmp_info" "$tmp_config"; log_error "删除校验失败：用户数量异常，未修改现有配置。"; pause; return; fi
    if ! generate_config_from_info_file "$tmp_info" "$tmp_config" || ! sing-box check -c "$tmp_config"; then rm -f "$tmp_info" "$tmp_config"; log_error "删除后的 Sing-Box 配置校验失败，未修改现有配置。"; pause; return; fi
    if commit_user_change "$tmp_info" "$tmp_config" "删除用户 ${username}"; then log_success "用户 ${username} 已删除。"; fi
    rm -f "$tmp_info" "$tmp_config"; pause
}

reset_user_password() {
    clear; echo -e "${CYAN}=====================================================${NC}"; echo -e "${BOLD}                  重置用户密码                       ${NC}"; echo -e "${CYAN}=====================================================${NC}"
    local username new_pwd tmp_info tmp_config
    username=$(select_user_name "请选择要重置密码的用户") || { pause; return; }
    read -rp " 新密码 [默认: 自动生成]: " new_pwd; new_pwd=${new_pwd:-$(generate_password)}
    if ! validate_password "$new_pwd"; then log_error "密码长度必须为 8-128 个字符。"; pause; return; fi
    tmp_info=$(mktemp "${INFO_PATH}.XXXXXX"); tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    if ! jq --arg n "$username" --arg p "$new_pwd" '(.anytls.users[] | select(.name == $n) | .pwd) = $p' "$INFO_PATH" > "$tmp_info"; then rm -f "$tmp_info" "$tmp_config"; log_error "生成新密码配置失败。"; pause; return; fi
    chmod 600 "$tmp_info"
    if ! generate_config_from_info_file "$tmp_info" "$tmp_config" || ! sing-box check -c "$tmp_config"; then rm -f "$tmp_info" "$tmp_config"; log_error "新密码配置校验失败，未修改现有配置。"; pause; return; fi
    if commit_user_change "$tmp_info" "$tmp_config" "重置用户 ${username} 密码"; then log_success "用户 ${username} 密码已重置。"; log_success "新密码：${new_pwd}"; fi
    rm -f "$tmp_info" "$tmp_config"; pause
}

show_selected_user_link() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                  指定用户节点                       ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    local username
    username=$(select_user_name "请选择用户") || {
        pause
        return
    }
    echo
    show_user_link "$username"
    echo
    echo -e "${CYAN}TLS: Let's Encrypt${NC}"
    echo -e "${CYAN}skip-cert-verify: false${NC}"
    pause
}

manage_users() {
    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}                 AnyTLS 用户管理                     ${NC}"
        echo -e "${CYAN}=====================================================${NC}"
        echo -e " 1. 查看用户"
        echo -e " 2. 添加用户"
        echo -e " 3. 删除用户"
        echo -e " 4. 重置用户密码"
        echo -e " 5. 查看指定用户节点"
        echo -e " 6. 查看全部用户节点"
        echo -e " 0. 返回上一菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"
        read -rp " 请选择操作 [0-6]: " act
        case "$act" in
            1) clear; list_users || true; pause ;;
            2) add_user ;;
            3) delete_user ;;
            4) reset_user_password ;;
            5) show_selected_user_link ;;
            6) show_links ;;
            0) return ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

install_node() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                安装 / 重构 AnyTLS                   ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    install_dependencies || return
    local t_port
    while :; do
        read -rp " 请输入 AnyTLS 端口 [默认: 2026]: " t_port
        t_port=${t_port:-2026}
        if ! validate_port "$t_port"; then
            log_warn "端口号不合法，请输入 1-65535。"
            continue
        fi
        # 如果当前就是 AnyTLS 在使用该端口，则允许重构；否则检查占用。
        local current_port=""
        if ensure_info_file; then
            current_port=$(jq -r '.anytls.port // empty' "$INFO_PATH" 2>/dev/null || true)
        fi
        if [[ "$current_port" == "$t_port" ]] && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_info "端口 ${t_port} 当前由现有 AnyTLS 使用，允许继续重构。"
            break
        fi
        if ! check_and_print_port_status "$t_port"; then
            continue
        fi
        break
    done
    local t_sni
    while :; do
        read -rp " 请输入你的 TLS 域名（必须已解析到本服务器）: " t_sni
        t_sni="${t_sni%.}"
        if validate_domain "$t_sni"; then
            break
        fi
        log_warn "域名格式不正确。Let's Encrypt 要求你拥有该域名，并且 DNS 已解析到本服务器。"
    done
    open_firewall_port "$t_port"
    open_firewall_port 80
    generate_cert "$t_sni" || return
    # 首次安装创建一个默认用户；已有用户则保留。
    if ! ensure_info_file || [[ "$(jq -r '.anytls.users | length' "$INFO_PATH" 2>/dev/null || echo 0)" -eq 0 ]]; then
        local first_name first_pwd
        while :; do
            read -rp " 请输入第一个用户名称 [默认: default]: " first_name
            first_name=${first_name:-default}
            validate_user_name "$first_name" && break
            log_warn "用户名只能使用 1-32 位字母、数字、下划线、点、短横线。"
        done
        read -rp " 请输入 AnyTLS 密码 [默认: 自动生成]: " first_pwd
        first_pwd=${first_pwd:-$(generate_password)}
        validate_password "$first_pwd" || {
            log_error "密码长度必须为 8-128 个字符。"
            return
        }
        jq -n \
            --arg p "$t_port" \
            --arg s "$t_sni" \
            --arg n "$first_name" \
            --arg w "$first_pwd" \
            '{anytls:{port:($p|tonumber),sni:$s,users:[{name:$n,pwd:$w}]}}' | write_info
    else
        backup_file "$INFO_PATH"
        jq --arg p "$t_port" --arg s "$t_sni" \
            '.anytls.port=($p|tonumber) | .anytls.sni=$s' "$INFO_PATH" | write_info
    fi
    backup_file "$CONFIG_PATH"
    mkdir -p "$(dirname "$CONFIG_PATH")"
    write_config_from_info
    if ! validate_sing_box_config; then
        log_error "Sing-Box 配置校验失败，服务不会启动。"
        return
    fi
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if systemctl restart "$SERVICE_NAME"; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log_success "AnyTLS 已成功启动！"
            log_success "客户端不需要 insecure=1，使用 Let's Encrypt 正常 TLS 证书校验。"
        else
            log_error "Sing-Box 启动失败，请查看日志。"
            systemctl status "$SERVICE_NAME" --no-pager || true
        fi
    else
        log_error "Sing-Box 重启失败，请查看日志。"
    fi
    pause
    show_links
}

manage_service() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                 AnyTLS 服务控制                     ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e " 1. 启动服务"
    echo -e " 2. 停止服务"
    echo -e " 3. 重启服务"
    echo -e " 0. 返回上一菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    read -rp " 请选择操作 [0-3]: " act
    case "$act" in
        1)
            if systemctl start "$SERVICE_NAME"; then log_success "AnyTLS 服务启动成功！"; else log_error "启动失败！"; fi
            ;;
        2)
            if systemctl stop "$SERVICE_NAME"; then log_success "AnyTLS 服务已停止！"; else log_error "停止失败！"; fi
            ;;
        3)
            if systemctl restart "$SERVICE_NAME"; then log_success "AnyTLS 服务重启成功！"; else log_error "重启失败！"; fi
            ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac
    pause
}

show_status() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                 AnyTLS 运行状态                     ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    systemctl status "$SERVICE_NAME" --no-pager || true
    echo -e "\n${CYAN}-----------------------------------------------------${NC}"
    if ensure_info_file; then
        echo "端口: $(jq -r '.anytls.port' "$INFO_PATH")"
        echo "SNI: $(jq -r '.anytls.sni' "$INFO_PATH")"
        echo "用户: $(jq -r '.anytls.users | length' "$INFO_PATH")"
    fi
    echo -e "${CYAN}=====================================================${NC}"
    pause
}

show_logs() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}           AnyTLS 实时日志（Ctrl+C 返回）            ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    journalctl -u "$SERVICE_NAME" -e -f -n 50 || true
}

uninstall_all() {
    clear
    echo -e "${RED}=====================================================${NC}"
    echo -e "${BOLD}                   卸载 AnyTLS                       ${NC}"
    echo -e "${RED}=====================================================${NC}"
    read -rp " 确定要卸载 Sing-Box AnyTLS 及配置吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/"$SERVICE_NAME".service
        rm -f /usr/bin/"$SERVICE_NAME" /usr/local/bin/"$SERVICE_NAME"
        rm -f /usr/local/bin/any /usr/bin/any "$LOCAL_SCRIPT_PATH"
        rm -f "$RENEW_HOOK"
        rm -rf /etc/"$SERVICE_NAME" "$INFO_PATH" /root/AnyTLS
        systemctl daemon-reload
        log_success "AnyTLS 脚本、用户配置及服务配置已清理。"
        log_warn "Let's Encrypt / Certbot 本身未自动卸载。"
    else
        log_info "已取消卸载。"
    fi
    pause
}

# ==============================================================================
# 更新模块（新增）
# ------------------------------------------------------------------------------
# 说明：AnyTLS 不是独立程序，而是 sing-box (>=1.12) 内置的 inbound 协议。
#       因此“更新 AnyTLS” = 更新 sing-box 内核 + 重新生成 AnyTLS 配置 + 检查证书。
# 安全措施：更新前备份二进制 / 配置 / 用户信息；更新后做配置校验并确认服务存活，
#           任一步失败都会自动回滚到更新前的状态。
# ==============================================================================

# 取得已安装的 sing-box 版本号，例如 1.12.0 / 1.13.0-beta.4
get_installed_singbox_version() {
    command_exists sing-box || return 1
    sing-box version 2>/dev/null | awk 'NR==1 {print $3}'
}

# 根据版本号判断当前所处通道：含 alpha/beta/rc 视为 beta，否则 stable
detect_channel() {
    local ver="$1"
    if [[ "$ver" =~ (alpha|beta|rc) ]]; then
        echo "beta"
    else
        echo "stable"
    fi
}

# 查询某通道最新版本号（失败时输出空字符串）
get_latest_singbox_version() {
    local channel="$1" tag=""
    if [[ "$channel" == "beta" ]]; then
        tag=$(curl -fsSL --connect-timeout 8 "${SINGBOX_API_RELEASES}?per_page=30" 2>/dev/null \
            | jq -r '[.[] | select(.draft == false and .prerelease == true)][0].tag_name // empty' 2>/dev/null || true)
    else
        tag=$(curl -fsSL --connect-timeout 8 "${SINGBOX_API_RELEASES}/latest" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null || true)
    fi
    printf '%s' "${tag#v}"
}

# 版本比较：$1 严格大于 $2 时返回 0（正式版 > 同号预发布版；alpha < beta < rc）
version_gt() {
    local a="$1" b="$2" ba bb pa="" pb=""
    ba="${a%%-*}"; bb="${b%%-*}"
    [[ "$a" == *-* ]] && pa="${a#*-}"
    [[ "$b" == *-* ]] && pb="${b#*-}"
    if [[ "$ba" != "$bb" ]]; then
        [[ "$(printf '%s\n%s\n' "$ba" "$bb" | sort -V | tail -n 1)" == "$ba" ]]
        return
    fi
    [[ "$pa" == "$pb" ]] && return 1
    [[ -z "$pa" ]] && return 0
    [[ -z "$pb" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$pa" "$pb" | sort -V | tail -n 1)" == "$pa" ]]
}

# 备份当前 sing-box 二进制，输出备份文件路径
backup_singbox_binary() {
    local ver="${1:-unknown}" bin dest
    bin=$(command -v sing-box) || return 1
    mkdir -p "$BACKUP_DIR"
    dest="$BACKUP_DIR/sing-box.${ver}.$(date +%Y%m%d-%H%M%S).bin"
    cp -a "$bin" "$dest" || return 1
    printf '%s' "$dest"
}

# 用备份覆盖 sing-box 二进制（先写临时文件再 mv，避免 "Text file busy"）
restore_singbox_binary() {
    local backup="$1" bin tmp
    bin=$(command -v sing-box 2>/dev/null || echo /usr/bin/sing-box)
    tmp=$(mktemp "${bin}.XXXXXX") || return 1
    if cp -a "$backup" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$bin"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# 只保留最近 3 份内核二进制备份
prune_singbox_backups() {
    ls -1t "$BACKUP_DIR"/sing-box.*.bin 2>/dev/null | tail -n +4 | xargs -r rm -f || true
}

# 回滚：内核 + 配置 + 用户信息，并按更新前的状态恢复服务
rollback_singbox_update() {
    local bin_backup="$1" cfg_backup="$2" info_backup="$3" old_active="$4"
    log_warn "正在回滚到更新前的内核与配置..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    restore_singbox_binary "$bin_backup" || log_error "内核回滚失败，备份文件位于：${bin_backup}"
    if [[ -f "$cfg_backup" ]]; then cp -a "$cfg_backup" "$CONFIG_PATH" || true; fi
    if [[ -f "$info_backup" ]]; then cp -a "$info_backup" "$INFO_PATH" || true; fi
    chmod 600 "$CONFIG_PATH" "$INFO_PATH" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "$old_active" -eq 1 ]]; then
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_warn "已回滚，Sing-Box 已恢复运行（版本：$(get_installed_singbox_version || echo 未知)）。"
        else
            log_error "已回滚，但 Sing-Box 未能恢复运行，请执行：systemctl status sing-box"
        fi
    else
        log_warn "已回滚（更新前服务本就未运行，保持停止状态）。"
    fi
}

# 更新 Sing-Box 内核
update_singbox_core() {
    local cur channel latest ch ans def_idx=1 stamp
    local bin_backup cfg_backup info_backup old_active=0 install_ok=0 new_ver

    if ! command_exists sing-box; then
        log_warn "未检测到 sing-box，请先执行“安装 / 重构 AnyTLS”。"
        return 1
    fi
    if ! command_exists curl || ! command_exists jq; then
        log_warn "缺少 curl 或 jq，请先执行“安装 / 重构 AnyTLS”以安装依赖。"
        return 1
    fi

    cur=$(get_installed_singbox_version || true)
    channel=$(detect_channel "${cur:-}")
    [[ "$channel" == "beta" ]] && def_idx=2

    log_warn "AnyTLS 协议需要 Sing-Box >= 1.12.0。"
    read -rp " 更新通道 [1=稳定版 2=Beta 测试版] (默认 ${def_idx}): " ch
    ch=${ch:-$def_idx}
    case "$ch" in
        1) channel="stable" ;;
        2) channel="beta" ;;
        *) log_warn "无效选项。"; return 1 ;;
    esac

    log_info "正在查询 ${channel} 通道最新版本..."
    latest=$(get_latest_singbox_version "$channel")
    echo -e " 当前版本: ${CYAN}${cur:-未知}${NC}"
    echo -e " 最新版本: ${CYAN}${latest:-获取失败}${NC}  (${channel})"

    if [[ -n "$latest" && -n "$cur" ]]; then
        if [[ "$latest" == "$cur" ]]; then
            log_success "已是最新版本，无需更新。"
            return 0
        fi
        if ! version_gt "$latest" "$cur"; then
            log_warn "当前版本高于所选通道的最新版本，不执行降级。"
            return 0
        fi
    elif [[ -z "$latest" ]]; then
        log_warn "无法获取最新版本号（可能是网络问题或 GitHub API 限流），将直接调用官方安装脚本。"
    fi

    read -rp " 确认更新 Sing-Box 内核？[y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log_info "已取消。"; return 0; }

    # ---- 备份 ----
    stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_DIR"
    cfg_backup="$BACKUP_DIR/update-${stamp}-config.json"
    info_backup="$BACKUP_DIR/update-${stamp}-info.json"
    if ! bin_backup=$(backup_singbox_binary "${cur:-unknown}"); then
        log_error "备份当前内核失败，已取消更新。"
        return 1
    fi
    if [[ -f "$CONFIG_PATH" ]]; then cp -a "$CONFIG_PATH" "$cfg_backup" || { log_error "备份配置失败，已取消更新。"; return 1; }; fi
    if [[ -f "$INFO_PATH" ]]; then cp -a "$INFO_PATH" "$info_backup" || { log_error "备份用户信息失败，已取消更新。"; return 1; }; fi
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && old_active=1
    log_info "已备份当前内核：${bin_backup}"

    # ---- 调用官方安装脚本 ----
    log_info "正在通过官方脚本更新 Sing-Box（${channel}）..."
    if [[ "$channel" == "beta" ]]; then
        if curl -fsSL "$SINGBOX_INSTALL_URL" | sh -s -- --beta; then install_ok=1; fi
    else
        if curl -fsSL "$SINGBOX_INSTALL_URL" | sh; then install_ok=1; fi
    fi
    if [[ $install_ok -ne 1 ]]; then
        log_error "官方安装脚本执行失败。"
        rollback_singbox_update "$bin_backup" "$cfg_backup" "$info_backup" "$old_active"
        return 1
    fi

    new_ver=$(get_installed_singbox_version || true)
    if [[ -z "$new_ver" ]]; then
        log_error "更新后未找到可用的 sing-box 可执行文件。"
        rollback_singbox_update "$bin_backup" "$cfg_backup" "$info_backup" "$old_active"
        return 1
    fi

    # 安装包可能改动配置文件：以更新前的配置为准
    if [[ -f "$cfg_backup" ]] && ! cmp -s "$cfg_backup" "$CONFIG_PATH"; then
        log_warn "检测到安装过程改动了配置文件，已恢复为更新前的配置。"
        cp -a "$cfg_backup" "$CONFIG_PATH"
        chmod 600 "$CONFIG_PATH"
    fi

    # ---- 校验并重启 ----
    if [[ -f "$CONFIG_PATH" ]]; then
        if ! validate_sing_box_config; then
            log_error "新内核无法通过现有配置校验（可能不兼容）。"
            rollback_singbox_update "$bin_backup" "$cfg_backup" "$info_backup" "$old_active"
            return 1
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [[ $old_active -eq 1 ]]; then
            if ! systemctl restart "$SERVICE_NAME"; then
                log_error "新内核启动失败。"
                rollback_singbox_update "$bin_backup" "$cfg_backup" "$info_backup" "$old_active"
                return 1
            fi
            sleep 2
            if ! systemctl is-active --quiet "$SERVICE_NAME"; then
                log_error "新内核启动后服务未保持运行。"
                rollback_singbox_update "$bin_backup" "$cfg_backup" "$info_backup" "$old_active"
                return 1
            fi
        else
            log_info "更新前服务未运行，保持停止状态。如需启动请使用“服务管理”。"
        fi
    fi

    rm -f "$cfg_backup" "$info_backup"
    prune_singbox_backups
    log_success "Sing-Box 已更新：${cur:-未知} → ${new_ver}"
    return 0
}

# 检查 / 续期证书
refresh_certificate() {
    local cert="$TLS_DIR/server.crt" end
    if ! command_exists certbot; then
        log_warn "未找到 certbot，跳过证书检查。"
        return 0
    fi
    setup_renew_hook
    log_info "检查证书续期 (certbot renew，需要 TCP/80 可访问)..."
    if ! certbot renew --quiet; then
        log_warn "certbot renew 执行失败，请确认 DNS、TCP/80 与云安全组。"
        return 1
    fi
    if [[ -f "$cert" ]] && command_exists openssl; then
        end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 || true)
        log_info "证书有效期至：${end:-未知}"
        if ! openssl x509 -checkend 604800 -noout -in "$cert" >/dev/null 2>&1; then
            log_warn "证书将在 7 天内过期或已过期！"
            return 1
        fi
    fi
    return 0
}

# 刷新 AnyTLS 配置：续期证书 + 按最新模板重新生成 config.json（事务提交，失败自动回滚）
refresh_anytls_config() {
    local tmp_info tmp_config
    if ! ensure_info_file; then
        log_warn "未找到 AnyTLS 配置，请先执行“安装 / 重构 AnyTLS”。"
        return 1
    fi
    if ! command_exists sing-box; then
        log_warn "未检测到 sing-box，请先执行“安装 / 重构 AnyTLS”。"
        return 1
    fi

    refresh_certificate || log_warn "证书检查/续期存在问题，请查看上方输出。"

    tmp_info=$(mktemp "${INFO_PATH}.XXXXXX"); tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    cp -a "$INFO_PATH" "$tmp_info"; chmod 600 "$tmp_info"
    if ! generate_config_from_info_file "$tmp_info" "$tmp_config" || ! sing-box check -c "$tmp_config"; then
        rm -f "$tmp_info" "$tmp_config"
        log_error "按最新模板生成的配置校验失败，未修改现有配置。"
        return 1
    fi
    if [[ -f "$CONFIG_PATH" ]] && cmp -s "$tmp_config" "$CONFIG_PATH"; then
        rm -f "$tmp_info" "$tmp_config"
        log_success "AnyTLS 配置已是最新，无需变更。"
        return 0
    fi
    if commit_user_change "$tmp_info" "$tmp_config" "刷新 AnyTLS 配置"; then
        rm -f "$tmp_info" "$tmp_config"
        log_success "AnyTLS 配置已刷新并重启服务。"
        return 0
    fi
    rm -f "$tmp_info" "$tmp_config"
    return 1
}

# 一键全部更新
update_all() {
    update_singbox_core || log_warn "内核更新未完成（已取消或已回滚），继续刷新 AnyTLS 配置。"
    echo
    refresh_anytls_config || true
}

# 查看版本信息
show_version_info() {
    local cur channel stable beta cert="$TLS_DIR/server.crt" end
    cur=$(get_installed_singbox_version || true)
    channel=$(detect_channel "${cur:-}")
    echo -e " 已安装 Sing-Box : ${CYAN}${cur:-未安装}${NC} (${channel})"
    if command_exists curl && command_exists jq; then
        log_info "正在查询最新版本..."
        stable=$(get_latest_singbox_version stable)
        beta=$(get_latest_singbox_version beta)
        echo -e " 最新稳定版     : ${CYAN}${stable:-获取失败}${NC}"
        echo -e " 最新 Beta 版   : ${CYAN}${beta:-获取失败}${NC}"
    fi
    if [[ -f "$cert" ]] && command_exists openssl; then
        end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 || true)
        echo -e " 证书有效期至   : ${CYAN}${end:-未知}${NC}"
    fi
}

update_menu() {
    local act
    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}             Sing-Box / AnyTLS 更新                  ${NC}"
        echo -e "${CYAN}=====================================================${NC}"
        echo -e " 1. 更新 Sing-Box 内核（含 AnyTLS 协议支持）"
        echo -e " 2. 刷新 AnyTLS 配置（重新生成配置 + 检查/续期证书）"
        echo -e " 3. 一键全部更新（1 + 2）"
        echo -e " 4. 查看当前 / 最新版本"
        echo -e " 0. 返回上一菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"
        read -rp " 请选择操作 [0-4]: " act
        case "$act" in
            1) clear; update_singbox_core || true; pause ;;
            2) clear; refresh_anytls_config || true; pause ;;
            3) clear; update_all; pause ;;
            4) clear; show_version_info; pause ;;
            0) return ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu() {
    check_root
    force_register_shortcut
    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}          Sing-Box AnyTLS 多用户管理脚本             ${NC}"
        echo -e "   快捷指令: ${YELLOW}${BOLD}any${NC}"
        print_system_status
        echo -e " ${GREEN}1.${NC} 安装 / 重构 AnyTLS"
        echo -e " ${GREEN}2.${NC} 服务管理 (启动/停止/重启)"
        echo -e " ${GREEN}3.${NC} 查看 AnyTLS 节点链接"
        echo -e " ${GREEN}4.${NC} 查看运行状态"
        echo -e " ${GREEN}5.${NC} 查看实时日志"
        echo -e " ${GREEN}6.${NC} 用户管理 (多用户)"
        echo -e " ${RED}7.${NC} 卸载 AnyTLS"
        echo -e " ${GREEN}8.${NC} 更新 (Sing-Box 内核 / AnyTLS 配置与证书)"
        echo -e " ${YELLOW}0.${NC} 退出脚本"
        echo -e "${CYAN}=====================================================${NC}"
        read -rp " 请输入选项 [0-8]: " opt
        case "$opt" in
            1) install_node ;;
            2) manage_service ;;
            3) show_links ;;
            4) show_status ;;
            5) show_logs ;;
            6) manage_users ;;
            7) uninstall_all ;;
            8) update_menu ;;
            0) clear; echo -e "${GREEN}感谢使用！${NC}"; exit 0 ;;
            *) log_error "请输入正确的选项 [0-8]"; sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    update|--update|-u)
        check_root
        update_menu
        ;;
    *)
        main_menu
        ;;
esac
