#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

# ------------------------------------------------------------------------------
# Sing-Box AnyTLS + Let's Encrypt 多用户管理脚本（精简版）
#
# 菜单：
#   1. 安装 / 重构 AnyTLS
#   2. 用户管理（查看节点 / 添加 / 删除 / 重置密码）
#   3. 更新（Sing-Box 内核 / AnyTLS 配置与证书）
#   4. 查看状态
#   5. 退出
#
# 快捷命令：any        打开菜单
#           any update 直接进入更新菜单
# ------------------------------------------------------------------------------

readonly CONFIG_PATH="/etc/sing-box/config.json"
readonly INFO_PATH="/root/.sb_info.json"
readonly TLS_DIR="/root/AnyTLS/tls"
readonly SERVICE_NAME="sing-box"
readonly LOCAL_SCRIPT_PATH="/root/any.sh"
readonly SHORTCUT_PATH="/usr/local/bin/any"
readonly DOMAIN_INFO="/root/AnyTLS/domain.txt"
readonly RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/sing-box-restart.sh"
readonly BACKUP_DIR="/root/AnyTLS/backup"
readonly LOCK_FILE="/run/any-sh.lock"

readonly SINGBOX_API_RELEASES="https://api.github.com/repos/SagerNet/sing-box/releases"
readonly SINGBOX_INSTALL_URL="https://sing-box.app/install.sh"
# 首次安装时使用的 Sing-Box 通道：stable（稳定版）或 beta（测试版）
readonly DEFAULT_CHANNEL="stable"

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

banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${CYAN}=====================================================${NC}"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# 基础检查
# ------------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 Root 权限运行，请使用 sudo -i 后再试。"
        exit 1
    fi
}

# 防止同时运行两个实例互相覆盖配置
acquire_lock() {
    command_exists flock || return 0
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "已有另一个 any.sh 实例在运行，请稍后再试。"
        exit 1
    fi
}

register_shortcut() {
    # 通过 bash <(curl ...) 运行时 $0 是 /dev/fd/*，无法保存脚本本体
    if [[ -f "$0" && -s "$0" && "$0" != /dev/fd/* && "$(readlink -f "$0")" != "$LOCAL_SCRIPT_PATH" ]]; then
        cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
        chmod 700 "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi
    if [[ ! -f "$LOCAL_SCRIPT_PATH" ]]; then
        log_warn "脚本未保存到 ${LOCAL_SCRIPT_PATH}，未生成 any 快捷命令。请下载脚本后用 bash any.sh 运行一次。"
        return 0
    fi
    cat > "$SHORTCUT_PATH" <<'SHORTCUT'
#!/usr/bin/env bash
exec bash /root/any.sh "$@"
SHORTCUT
    chmod 755 "$SHORTCUT_PATH" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 校验函数
# ------------------------------------------------------------------------------

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_domain() {
    local domain="$1"
    domain="${domain%.}"
    [[ -n "$domain" ]] || return 1
    [[ "$domain" != *[[:space:]]* ]] || return 1
    [[ "$domain" != */* && "$domain" != *:* && "$domain" != *'?'* && "$domain" != *'#'* ]] || return 1
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_user_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]
}

validate_password() {
    [[ ${#1} -ge 12 && ${#1} -le 128 ]]
}

generate_password() {
    openssl rand -hex 16
}

port_in_use() {
    command_exists ss || return 1
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$1$"
}

open_firewall_port() {
    local port="$1"
    log_info "正在尝试放行防火墙 TCP ${port}..."
    if command_exists ufw && ufw status 2>/dev/null | grep -q "^Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    elif command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    log_success "防火墙处理完成（如使用云厂商安全组，还需放行相应端口）。"
}

# ------------------------------------------------------------------------------
# 配置 / 用户信息读写
#   INFO_PATH 是唯一的数据源，CONFIG_PATH 始终由它生成。
#   密码一律通过环境变量 PW 传给 jq，避免出现在进程参数(ps)里。
# ------------------------------------------------------------------------------

ensure_info_file() {
    [[ -f "$INFO_PATH" ]] || return 1
    jq -e '.anytls.port and .anytls.sni and (.anytls.users | type == "array")' "$INFO_PATH" >/dev/null 2>&1
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$file" "$BACKUP_DIR/$(basename "$file").$(date +%Y%m%d-%H%M%S).bak"
    # 每类文件只保留最近 5 份（备份里含密码，不宜无限堆积）
    ls -1t "$BACKUP_DIR/$(basename "$file")."*.bak 2>/dev/null | tail -n +6 | xargs -r rm -f || true
}

# 从标准输入读取新的 info 内容；内容无效（例如上游 jq 失败）时不覆盖原文件
write_info() {
    local tmp
    tmp=$(mktemp "${INFO_PATH}.XXXXXX")
    cat > "$tmp"
    if ! jq -e '.anytls.port and .anytls.sni and (.anytls.users | type == "array")' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log_error "生成的用户信息无效，已放弃写入。"
        return 1
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$INFO_PATH"
}

generate_config_from_info_file() {
    local info_file="$1" dest_config="$2" tmp
    [[ -f "$info_file" ]] || return 1
    jq -e '.anytls.port and .anytls.sni and (.anytls.users | type == "array")' "$info_file" >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$dest_config")"
    tmp=$(mktemp "${dest_config}.XXXXXX")
    if ! jq --arg crt "$TLS_DIR/server.crt" --arg key "$TLS_DIR/server.key" '{
        log: {level:"info", timestamp:true},
        inbounds: [{
            type:"anytls", listen:"::", listen_port:.anytls.port,
            users:(.anytls.users | map({name, password: .pwd})),
            padding_scheme:["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
            tls:{enabled:true, certificate_path:$crt, key_path:$key}
        }]
    }' "$info_file" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$dest_config"
}

validate_sing_box_config() {
    if ! command_exists sing-box; then
        log_error "未找到 sing-box。"
        return 1
    fi
    sing-box check -c "$CONFIG_PATH"
}

restore_pair() {
    local info_backup="$1" config_backup="$2"
    cp -a "$info_backup" "$INFO_PATH" || return 1
    cp -a "$config_backup" "$CONFIG_PATH" || return 1
    chmod 600 "$INFO_PATH" "$CONFIG_PATH" 2>/dev/null || true
}

# 事务提交：备份 → 写入 → 校验 → 重启 → 失败自动回滚
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

# 用 jq 过滤器修改用户信息 → 生成新配置 → 校验 → 事务提交
# 用法：[PW=密码] modify_users "操作描述" 'jq过滤器' [jq 额外参数...]
modify_users() {
    local desc="$1" filter="$2"
    shift 2
    local tmp_info tmp_config rc=1
    tmp_info=$(mktemp "${INFO_PATH}.XXXXXX")
    tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    if jq "$@" "$filter" "$INFO_PATH" > "$tmp_info" \
        && chmod 600 "$tmp_info" \
        && generate_config_from_info_file "$tmp_info" "$tmp_config" \
        && sing-box check -c "$tmp_config"; then
        if commit_user_change "$tmp_info" "$tmp_config" "$desc"; then rc=0; fi
    else
        log_error "${desc}：新配置校验失败，未修改现有配置。"
    fi
    rm -f "$tmp_info" "$tmp_config"
    return "$rc"
}

# ------------------------------------------------------------------------------
# 安装 / 重构
# ------------------------------------------------------------------------------

# 下载官方安装脚本到临时文件再执行（避免 curl|sh 在下载中断时执行半截脚本，
# 并让 dpkg 在非交互模式下保留已有配置文件）
run_singbox_installer() {
    local channel="$1" tmp rc=0
    tmp=$(mktemp /tmp/singbox-install.XXXXXX) || return 1
    if ! curl -fsSL --retry 2 --connect-timeout 10 -o "$tmp" "$SINGBOX_INSTALL_URL" || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        log_error "下载 Sing-Box 官方安装脚本失败。"
        return 1
    fi
    if [[ "$channel" == "beta" ]]; then
        DEBIAN_FRONTEND=noninteractive sh "$tmp" --beta </dev/null || rc=$?
    else
        DEBIAN_FRONTEND=noninteractive sh "$tmp" </dev/null || rc=$?
    fi
    rm -f "$tmp"
    return "$rc"
}

install_dependencies() {
    log_info "检查并安装必要依赖组件..."
    if command_exists apt-get; then
        apt-get update -y -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl certbot iproute2
    elif command_exists dnf; then
        dnf install -y -q curl jq openssl certbot iproute
    elif command_exists yum; then
        yum install -y -q curl jq openssl certbot iproute
    else
        log_error "不支持的 Linux 包管理器。"
        return 1
    fi
    if command_exists sing-box; then
        log_info "已检测到 Sing-Box $(get_installed_singbox_version || echo 未知)，跳过内核安装（升级请使用“更新”）。"
        return 0
    fi
    log_info "正在安装 Sing-Box（${DEFAULT_CHANNEL}）官方内核..."
    if ! run_singbox_installer "$DEFAULT_CHANNEL"; then
        log_error "Sing-Box 安装失败，请检查服务器网络。"
        return 1
    fi
    if ! command_exists sing-box; then
        log_error "安装脚本执行成功，但未找到 sing-box 可执行文件。"
        return 1
    fi
    log_success "Sing-Box 安装完毕：$(get_installed_singbox_version || echo 未知)"
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

generate_cert() {
    local sni="$1"
    mkdir -p "$TLS_DIR"
    if ! command_exists certbot; then
        log_error "未找到 Certbot。"
        return 1
    fi
    log_info "准备申请 Let's Encrypt 证书：${sni}"
    log_warn "要求：DNS 已将 ${sni} 指向本服务器，并且公网 TCP/80 可以访问。"
    if port_in_use 80; then
        log_warn "检测到本机 TCP/80 已被占用，certbot standalone 可能无法完成验证。"
    fi
    if ! certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring \
        -d "$sni"; then
        log_error "Let's Encrypt 证书申请失败！请确认 DNS、TCP/80、云安全组和域名均正确。"
        return 1
    fi
    if [[ ! -f "/etc/letsencrypt/live/${sni}/fullchain.pem" || ! -f "/etc/letsencrypt/live/${sni}/privkey.pem" ]]; then
        log_error "证书或私钥文件不存在。"
        return 1
    fi
    ln -sfn "/etc/letsencrypt/live/${sni}/fullchain.pem" "$TLS_DIR/server.crt"
    ln -sfn "/etc/letsencrypt/live/${sni}/privkey.pem" "$TLS_DIR/server.key"
    printf '%s\n' "$sni" > "$DOMAIN_INFO"
    chmod 600 "$DOMAIN_INFO"
    setup_renew_hook
    log_success "Let's Encrypt 证书申请成功！"
}

install_node() {
    banner "安装 / 重构 AnyTLS"
    install_dependencies || return 1

    local t_port t_sni cur_port="" cur_sni="" tmp_config
    if ensure_info_file; then
        cur_port=$(jq -r '.anytls.port' "$INFO_PATH")
        cur_sni=$(jq -r '.anytls.sni' "$INFO_PATH")
    fi

    while :; do
        read -rp " 请输入 AnyTLS 端口 [默认: ${cur_port:-2026}]: " t_port
        t_port=${t_port:-${cur_port:-2026}}
        if ! validate_port "$t_port"; then
            log_warn "端口号不合法，请输入 1-65535。"
            continue
        fi
        if [[ "$t_port" == "80" ]]; then
            log_warn "TCP/80 需要留给证书验证与续期，请换一个端口。"
            continue
        fi
        # 当前就是 AnyTLS 在使用该端口，则允许重构；否则检查占用。
        if [[ "$t_port" == "$cur_port" ]] && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_info "端口 ${t_port} 当前由现有 AnyTLS 使用，允许继续重构。"
            break
        fi
        if port_in_use "$t_port"; then
            log_warn "检测到端口 ${t_port} 已被占用！"
            continue
        fi
        log_success "端口 ${t_port} 未被占用，可以使用。"
        break
    done

    while :; do
        read -rp " 请输入你的 TLS 域名（必须已解析到本服务器）${cur_sni:+ [默认: ${cur_sni}]}: " t_sni
        t_sni="${t_sni:-$cur_sni}"
        t_sni="${t_sni%.}"
        if validate_domain "$t_sni"; then
            break
        fi
        log_warn "域名格式不正确。Let's Encrypt 要求你拥有该域名，并且 DNS 已解析到本服务器。"
    done

    open_firewall_port "$t_port"
    open_firewall_port 80
    generate_cert "$t_sni" || return 1

    backup_file "$INFO_PATH"
    if ensure_info_file && [[ "$(jq '.anytls.users | length' "$INFO_PATH")" -gt 0 ]]; then
        # 已有用户则保留，只更新端口和域名
        jq --arg p "$t_port" --arg s "$t_sni" \
            '.anytls.port=($p|tonumber) | .anytls.sni=$s' "$INFO_PATH" | write_info || return 1
    else
        local first_name first_pwd
        while :; do
            read -rp " 请输入第一个用户名称 [默认: default]: " first_name
            first_name=${first_name:-default}
            validate_user_name "$first_name" && break
            log_warn "用户名只能使用 1-32 位字母、数字、下划线、点、短横线。"
        done
        read -rp " 请输入 AnyTLS 密码 [默认: 自动生成]: " first_pwd
        first_pwd=${first_pwd:-$(generate_password)}
        if ! validate_password "$first_pwd"; then
            log_error "密码长度必须为 12-128 个字符。"
            return 1
        fi
        PW="$first_pwd" jq -n --arg p "$t_port" --arg s "$t_sni" --arg n "$first_name" \
            '{anytls:{port:($p|tonumber),sni:$s,users:[{name:$n,pwd:env.PW}]}}' | write_info || return 1
    fi

    backup_file "$CONFIG_PATH"
    mkdir -p "$(dirname "$CONFIG_PATH")"
    tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    if ! generate_config_from_info_file "$INFO_PATH" "$tmp_config" || ! sing-box check -c "$tmp_config"; then
        rm -f "$tmp_config"
        log_error "Sing-Box 配置校验失败，服务不会启动，现有配置未被改动。"
        return 1
    fi
    mv -f "$tmp_config" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if systemctl restart "$SERVICE_NAME" && sleep 1 && systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "AnyTLS 已成功启动！客户端使用 Let's Encrypt 正常证书校验，无需 insecure。"
    else
        log_error "Sing-Box 启动失败，最近日志如下："
        journalctl -u "$SERVICE_NAME" -n 15 --no-pager 2>/dev/null || true
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 用户管理
# ------------------------------------------------------------------------------

user_name_exists() {
    jq -e --arg n "$1" '.anytls.users[]? | select(.name == $n)' "$INFO_PATH" >/dev/null 2>&1
}

password_exists() {
    PW="$1" jq -e '.anytls.users[]? | select(.pwd == env.PW)' "$INFO_PATH" >/dev/null 2>&1
}

list_users() {
    local i=0 name
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    printf '%-5s %-24s\n' "序号" "用户名"
    echo "--------------------------------"
    while IFS= read -r name; do
        i=$((i+1))
        printf '%-5s %-24s\n' "$i" "$name"
    done < <(jq -r '.anytls.users[]?.name' "$INFO_PATH")
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

# 选择用户，输出用户名；所有提示走 stderr，避免被 $(...) 捕获
select_user_name() {
    local prompt="$1" count index
    count=$(jq '.anytls.users | length' "$INFO_PATH")
    if [[ "$count" -eq 0 ]]; then
        log_warn "当前没有用户。" >&2
        return 1
    fi
    list_users >&2
    read -rp " ${prompt} [1-${count}]: " index
    if [[ ! "$index" =~ ^[0-9]{1,4}$ ]]; then
        log_warn "序号无效。" >&2
        return 1
    fi
    index=$((10#$index))
    if (( index < 1 || index > count )); then
        log_warn "序号无效。" >&2
        return 1
    fi
    jq -r --argjson i "$((index-1))" '.anytls.users[$i].name' "$INFO_PATH"
}

# 显示节点链接；可选参数为只显示某个用户。
# 链接里的服务器地址使用 TLS 域名（证书本来就要求域名已解析到本机），
# 不再依赖第三方 IP 查询服务。
show_links() {
    local only="${1:-}" name link
    while IFS=$'\t' read -r name link; do
        echo -e "${GREEN}[ ${name} ]${NC}"
        echo -e "${YELLOW}${link}${NC}\n"
    done < <(jq -r --arg n "$only" '.anytls as $a | $a.users[] | select($n == "" or .name == $n)
        | [.name, "anytls://\(.pwd | @uri)@\($a.sni):\($a.port)/?sni=\($a.sni)&fp=chrome#AnyTLS_\(.name)"] | @tsv' "$INFO_PATH")
    echo -e "${CYAN}TLS: Let's Encrypt（skip-cert-verify: false）${NC}"
}

add_user() {
    banner "添加用户"
    local name pwd
    while :; do
        read -rp " 用户名 [例如 phone/pc/ipad]: " name
        if ! validate_user_name "$name"; then log_warn "用户名只能使用 1-32 位字母、数字、下划线、点、短横线。"; continue; fi
        if user_name_exists "$name"; then log_warn "用户 ${name} 已存在。"; continue; fi
        break
    done
    read -rp " 密码 [默认: 自动生成]: " pwd
    pwd=${pwd:-$(generate_password)}
    if ! validate_password "$pwd"; then log_warn "密码长度必须为 12-128 个字符。"; return 1; fi
    if password_exists "$pwd"; then log_warn "该密码已被其他用户使用，请更换。"; return 1; fi
    if PW="$pwd" modify_users "添加用户 ${name}" '.anytls.users += [{name:$n,pwd:env.PW}]' --arg n "$name"; then
        log_success "用户 ${name} 添加成功。"
        echo
        show_links "$name"
    fi
}

delete_user() {
    banner "删除用户"
    local username count confirm
    username=$(select_user_name "请选择要删除的用户") || return 1
    count=$(jq '.anytls.users | length' "$INFO_PATH")
    if [[ "$count" -le 1 ]]; then log_warn "至少保留一个 AnyTLS 用户。"; return 1; fi
    read -rp " 确定删除用户 ${username}？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消。"; return 0; }
    if modify_users "删除用户 ${username}" '.anytls.users |= map(select(.name != $n))' --arg n "$username"; then
        log_success "用户 ${username} 已删除。"
    fi
}

reset_user_password() {
    banner "重置用户密码"
    local username new_pwd
    username=$(select_user_name "请选择要重置密码的用户") || return 1
    read -rp " 新密码 [默认: 自动生成]: " new_pwd
    new_pwd=${new_pwd:-$(generate_password)}
    if ! validate_password "$new_pwd"; then log_error "密码长度必须为 12-128 个字符。"; return 1; fi
    if password_exists "$new_pwd"; then log_warn "该密码已被其他用户使用，请更换。"; return 1; fi
    if PW="$new_pwd" modify_users "重置用户 ${username} 密码" '(.anytls.users[] | select(.name == $n) | .pwd) = env.PW' --arg n "$username"; then
        log_success "用户 ${username} 密码已重置。新密码：${new_pwd}"
        echo
        show_links "$username"
    fi
}

manage_users() {
    local act
    if ! ensure_info_file; then
        log_warn "尚未安装 AnyTLS，请先执行“安装 / 重构 AnyTLS”。"
        pause
        return
    fi
    while :; do
        banner "AnyTLS 用户管理"
        echo -e " 1. 查看用户与节点链接"
        echo -e " 2. 添加用户"
        echo -e " 3. 删除用户"
        echo -e " 4. 重置用户密码"
        echo -e " 0. 返回上一菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"
        read -rp " 请选择操作 [0-4]: " act
        case "$act" in
            1) banner "节点链接"; show_links; pause ;;
            2) add_user || true; pause ;;
            3) delete_user || true; pause ;;
            4) reset_user_password || true; pause ;;
            0) return ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 更新模块
#   AnyTLS 是 sing-box (>=1.12) 内置的入站协议，所以“更新 AnyTLS”=
#   更新 sing-box 内核 + 按最新模板刷新配置 + 检查/续期证书。
#   更新前备份，更新后校验并确认服务存活，任一步失败自动回滚。
# ------------------------------------------------------------------------------

get_installed_singbox_version() {
    command_exists sing-box || return 1
    sing-box version 2>/dev/null | awk 'NR==1 {print $3}'
}

detect_channel() {
    if [[ "$1" =~ (alpha|beta|rc) ]]; then echo "beta"; else echo "stable"; fi
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

backup_singbox_binary() {
    local ver="${1:-unknown}" bin dest
    bin=$(command -v sing-box) || return 1
    mkdir -p "$BACKUP_DIR"
    dest="$BACKUP_DIR/sing-box.${ver}.$(date +%Y%m%d-%H%M%S).bin"
    cp -a "$bin" "$dest" || return 1
    printf '%s' "$dest"
}

# 先写临时文件再 mv，避免正在运行的二进制报 "Text file busy"
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

update_singbox_core() {
    local cur channel latest ch ans def_idx=1 stamp
    local bin_backup cfg_backup info_backup old_active=0 new_ver

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
    if [[ "$channel" == "beta" ]]; then def_idx=2; fi

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
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then old_active=1; fi
    log_info "已备份当前内核：${bin_backup}"

    # ---- 调用官方安装脚本 ----
    log_info "正在通过官方脚本更新 Sing-Box（${channel}）..."
    if ! run_singbox_installer "$channel"; then
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
            log_info "更新前服务未运行，保持停止状态。"
        fi
    fi

    rm -f "$cfg_backup" "$info_backup"
    # 只保留最近 3 份内核备份
    ls -1t "$BACKUP_DIR"/sing-box.*.bin 2>/dev/null | tail -n +4 | xargs -r rm -f || true
    log_success "Sing-Box 已更新：${cur:-未知} → ${new_ver}"
}

# 检查 / 续期证书
refresh_certificate() {
    local cert="$TLS_DIR/server.crt" end
    if ! command_exists certbot; then
        log_warn "未找到 certbot，跳过证书检查。"
        return 0
    fi
    setup_renew_hook
    log_info "检查证书续期（certbot renew，需要 TCP/80 可访问）..."
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
}

# 续期证书 + 按最新模板重新生成配置（有变化才提交，失败自动回滚）
refresh_anytls_config() {
    local tmp_config
    if ! ensure_info_file || ! command_exists sing-box; then
        log_warn "尚未安装 AnyTLS，请先执行“安装 / 重构 AnyTLS”。"
        return 1
    fi
    refresh_certificate || log_warn "证书检查/续期存在问题，请查看上方输出。"

    tmp_config=$(mktemp "${CONFIG_PATH}.XXXXXX")
    if ! generate_config_from_info_file "$INFO_PATH" "$tmp_config"; then
        rm -f "$tmp_config"
        log_error "生成配置失败，未修改现有配置。"
        return 1
    fi
    if [[ -f "$CONFIG_PATH" ]] && cmp -s "$tmp_config" "$CONFIG_PATH"; then
        rm -f "$tmp_config"
        log_success "AnyTLS 配置已是最新，无需变更。"
        return 0
    fi
    rm -f "$tmp_config"
    if modify_users "刷新 AnyTLS 配置" '.'; then
        log_success "AnyTLS 配置已刷新并重启服务。"
    fi
}

update_all() {
    update_singbox_core || log_warn "内核更新未完成（已取消或已回滚），继续刷新 AnyTLS 配置。"
    echo
    refresh_anytls_config || true
}

update_menu() {
    local act
    while :; do
        banner "Sing-Box / AnyTLS 更新"
        echo -e " 当前 Sing-Box 版本: ${CYAN}$(get_installed_singbox_version || echo 未安装)${NC}"
        echo -e "${CYAN}-----------------------------------------------------${NC}"
        echo -e " 1. 一键全部更新（内核 + 配置/证书）"
        echo -e " 2. 仅更新 Sing-Box 内核"
        echo -e " 3. 仅刷新 AnyTLS 配置 / 检查证书"
        echo -e " 0. 返回上一菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"
        read -rp " 请选择操作 [0-3]: " act
        case "$act" in
            1) echo; update_all; pause ;;
            2) echo; update_singbox_core || true; pause ;;
            3) echo; refresh_anytls_config || true; pause ;;
            0) return ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 状态
# ------------------------------------------------------------------------------

print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    if ensure_info_file && [[ -f "$CONFIG_PATH" ]]; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo -e " 服务状态: ${GREEN}${BOLD}● AnyTLS 正常运行${NC}"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● AnyTLS 已安装但未运行${NC}"
        fi
        echo -e " 用户数: ${CYAN}$(jq '.anytls.users | length' "$INFO_PATH" 2>/dev/null || echo 0)${NC}"
    else
        echo -e " 服务状态: ${RED}${BOLD}○ AnyTLS 未安装 / 未配置${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

show_status() {
    banner "AnyTLS 运行状态"
    local pid end cert="$TLS_DIR/server.crt" port
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        pid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || true)
        echo -e " 服务状态   : ${GREEN}运行中${NC} (PID: ${pid:-未知})"
    else
        echo -e " 服务状态   : ${RED}未运行${NC}"
    fi
    echo -e " 开机自启   : $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo 未设置)"
    echo -e " Sing-Box   : $(get_installed_singbox_version || echo 未安装)"
    if ensure_info_file; then
        port=$(jq -r '.anytls.port' "$INFO_PATH")
        echo -e " 端口       : ${port} ($(port_in_use "$port" && echo 正在监听 || echo 未监听))"
        echo -e " SNI / 域名 : $(jq -r '.anytls.sni' "$INFO_PATH")"
        echo -e " 用户数     : $(jq -r '.anytls.users | length' "$INFO_PATH")"
    else
        log_warn "未找到 AnyTLS 配置。"
    fi
    if [[ -f "$cert" ]] && command_exists openssl; then
        end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 || true)
        echo -e " 证书有效期 : ${end:-未知}"
    fi
    echo -e "\n${CYAN}---------------- 最近 15 行日志 ----------------${NC}"
    journalctl -u "$SERVICE_NAME" -n 15 --no-pager 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------------------------

main_menu() {
    local opt
    register_shortcut
    while :; do
        banner "Sing-Box AnyTLS 多用户管理脚本"
        echo -e " 快捷指令: ${YELLOW}${BOLD}any${NC}"
        print_system_status
        echo -e " ${GREEN}1.${NC} 安装 / 重构 AnyTLS"
        echo -e " ${GREEN}2.${NC} 用户管理"
        echo -e " ${GREEN}3.${NC} 更新 (Sing-Box 内核 / AnyTLS 配置与证书)"
        echo -e " ${GREEN}4.${NC} 查看状态"
        echo -e " ${YELLOW}5.${NC} 退出"
        echo -e "${CYAN}=====================================================${NC}"
        read -rp " 请输入选项 [1-5]: " opt
        case "$opt" in
            1)
                if install_node; then
                    echo
                    show_links
                else
                    log_error "安装未完成，请根据上方提示处理后重试。"
                fi
                pause
                ;;
            2) manage_users ;;
            3) update_menu ;;
            4) show_status; pause ;;
            5) clear 2>/dev/null || true; echo -e "${GREEN}感谢使用！${NC}"; exit 0 ;;
            *) log_error "请输入正确的选项 [1-5]"; sleep 1 ;;
        esac
    done
}

main() {
    check_root
    acquire_lock
    case "${1:-}" in
        update|--update|-u) update_menu ;;
        *) main_menu ;;
    esac
}

main "$@"
