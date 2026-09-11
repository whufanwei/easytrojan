#!/usr/bin/env bash
set -eo pipefail

# ------------------------------------------------------------------------------
# AnyTLS + Let's Encrypt 管理脚本
# 仅部署 AnyTLS，不包含 AnyReality
# ------------------------------------------------------------------------------

readonly CONFIG_PATH="/etc/sing-box/config.json"
readonly INFO_PATH="/root/.sb_info.json"
readonly TLS_DIR="/root/AnyTLS/tls"
readonly SERVICE_NAME="sing-box"
readonly LOCAL_SCRIPT_PATH="/root/any.sh"
readonly DOMAIN_INFO="/root/AnyTLS/domain.txt"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

pause() {
    echo -e "\n${YELLOW}按任意键继续...${NC}"
    read -n 1 -s -r
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 Root 权限运行，请使用 sudo -i 后再试。"
        exit 1
    fi
}

force_register_shortcut() {
    if [[ -s "$0" ]]; then
        cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi

    chmod +x "$LOCAL_SCRIPT_PATH" 2>/dev/null || true

    local target_paths=("/usr/local/bin/any" "/usr/bin/any")
    for path in "${target_paths[@]}"; do
        rm -rf "$path" 2>/dev/null || true
        cat > "$path" << 'EOF'
#!/usr/bin/env bash
if [[ -f /root/any.sh ]]; then
    bash /root/any.sh "$@"
else
    bash <(curl -fsSL https://raw.githubusercontent.com/meng-jin/AnyTLS/main/Any.sh) "$@"
fi
EOF
        chmod +x "$path" 2>/dev/null || true
    done
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

check_and_print_port_status() {
    local port="$1"
    local is_busy=0

    if command -v ss &>/dev/null; then
        ss -tuln | grep -q ":${port} " && is_busy=1
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":${port} " && is_busy=1
    elif command -v lsof &>/dev/null; then
        lsof -i:"${port}" &>/dev/null && is_busy=1
    fi

    if [[ $is_busy -eq 1 ]]; then
        log_warn "检测到端口 ${port} 已被占用！"
        return 1
    fi

    log_success "端口 ${port} 未被占用，可以使用。"
    return 0
}

get_public_ip() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    fi
    echo "${ip:-127.0.0.1}"
}

open_firewall_port() {
    local port="$1"
    log_info "正在尝试放行防火墙 TCP ${port}..."
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    log_success "防火墙处理完成（如使用云厂商安全组，还需放行相应端口）。"
}

print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    if [[ -f "$CONFIG_PATH" && -f "$INFO_PATH" ]] && jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            local pid
            pid=$(pgrep -f "sing-box" | head -n 1 || echo "未知")
            echo -e " 服务状态: ${GREEN}${BOLD}● AnyTLS 正常运行${NC} (PID: ${pid})"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● AnyTLS 已安装但未运行${NC}"
        fi
        echo -e " 协议: ${CYAN}AnyTLS${NC}"
        echo -e " TLS:  ${CYAN}Let's Encrypt${NC}"
    else
        echo -e " 服务状态: ${RED}${BOLD}○ AnyTLS 未安装 / 未配置${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

install_dependencies() {
    log_info "检查并安装必要依赖组件..."

    if command -v apt-get &>/dev/null; then
        apt-get update -y -qq
        apt-get install -y -qq curl jq net-tools openssl lsof certbot
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl jq net-tools openssl lsof certbot
    elif command -v yum &>/dev/null; then
        yum install -y -q curl jq net-tools openssl lsof certbot
    else
        log_error "不支持的 Linux 包管理器。"
        return 1
    fi

    log_info "正在安装/更新 Sing-Box Beta 官方内核..."
    if curl -fsSL https://sing-box.app/install.sh | sh -s -- --beta; then
        log_success "Sing-Box 核心组件安装/更新完毕！"
    else
        log_error "Sing-Box 安装失败，请检查服务器网络。"
        return 1
    fi
}

setup_renew_hook() {
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    cat > /etc/letsencrypt/renewal-hooks/deploy/sing-box-restart.sh << EOF
#!/usr/bin/env bash
systemctl restart ${SERVICE_NAME}
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/sing-box-restart.sh

    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

generate_cert() {
    local sni="$1"

    mkdir -p "$TLS_DIR"

    if ! command -v certbot >/dev/null 2>&1; then
        log_error "未找到 Certbot。"
        return 1
    fi

    log_info "准备申请 Let's Encrypt 证书：${sni}"
    log_warn "要求：DNS 已将 ${sni} 指向本服务器，并且公网 TCP/80 可以访问。"

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

    if ! certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring \
        -d "$sni"; then

        log_error "Let's Encrypt 证书申请失败！"
        log_error "请确认 DNS、TCP/80、云安全组和域名均正确。"
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
        return 1
    fi

    ln -sfn "/etc/letsencrypt/live/${sni}/fullchain.pem" "$TLS_DIR/server.crt"
    ln -sfn "/etc/letsencrypt/live/${sni}/privkey.pem" "$TLS_DIR/server.key"

    echo "$sni" > "$DOMAIN_INFO"
    setup_renew_hook

    log_success "Let's Encrypt 证书申请成功！"
    log_info "证书：$TLS_DIR/server.crt"
    log_info "私钥：$TLS_DIR/server.key"
}

install_node() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                  安装 AnyTLS                       ${NC}"
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

        if ! check_and_print_port_status "$t_port"; then
            continue
        fi
        break
    done

    local t_pwd
    read -rp " 请输入 AnyTLS 密码 [默认: 自动生成]: " t_pwd
    t_pwd=${t_pwd:-$(openssl rand -hex 16)}

    local t_sni
    while :; do
        read -rp " 请输入你的 TLS 域名（必须已解析到本服务器）: " t_sni
        if [[ -n "$t_sni" && "$t_sni" != *" "* ]]; then
            break
        fi
        log_warn "域名不能为空。Let's Encrypt 不支持使用 genshin.hoyoverse.com 等非自有域名。"
    done

    open_firewall_port "$t_port"
    open_firewall_port 80

    generate_cert "$t_sni" || return

    local t_inbound
    t_inbound=$(jq -n \
        --arg p "$t_port" \
        --arg w "$t_pwd" \
        '{
            type: "anytls",
            listen: "::",
            listen_port: ($p | tonumber),
            users: [{ password: $w }],
            padding_scheme: [
                "stop=8",
                "0=30-80",
                "1=100-400",
                "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
                "3=9-9,500-1000",
                "4=500-1000",
                "5=500-1000",
                "6=500-1000",
                "7=500-1000"
            ],
            tls: {
                enabled: true,
                certificate_path: "/root/AnyTLS/tls/server.crt",
                key_path: "/root/AnyTLS/tls/server.key"
            }
        }')

    echo '{"anytls":{}}' > /dev/null
    echo "$(
        jq -n \
          --arg p "$t_port" \
          --arg w "$t_pwd" \
          --arg s "$t_sni" \
          '{anytls:{port:$p,pwd:$w,sni:$s}}'
    )" > "$INFO_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"
    jq -n --argjson ib "[$t_inbound]" \
        '{log:{level:"info",timestamp:true}, inbounds:$ib}' > "$CONFIG_PATH"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "AnyTLS 已成功启动！"
        log_success "客户端不需要 insecure=1，使用正常 TLS 证书校验。"
    else
        log_error "Sing-Box 启动失败，请查看日志。"
        systemctl status "$SERVICE_NAME" --no-pager || true
    fi

    pause
    show_links
}

show_links() {
    clear

    if [[ ! -f "$INFO_PATH" ]] || ! jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
        log_warn "未找到 AnyTLS 配置，请先安装。"
        pause
        return
    fi

    local ip p w s
    ip=$(get_public_ip)
    p=$(jq -r .anytls.port "$INFO_PATH")
    w=$(jq -r .anytls.pwd "$INFO_PATH")
    s=$(jq -r .anytls.sni "$INFO_PATH")

    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                 AnyTLS 节点信息                    ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"

    echo -e "${GREEN}[ AnyTLS ]${NC}"
    echo -e "${YELLOW}anytls://${w}@${ip}:${p}/?sni=${s}&fp=chrome#AnyTLS_${ip}${NC}\n"
    echo -e "${CYAN}TLS: Let's Encrypt${NC}"
    echo -e "${CYAN}skip-cert-verify: false${NC}"

    echo -e "${CYAN}=====================================================${NC}"
    pause
}

manage_service() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                 AnyTLS 服务控制                    ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e " 1. 启动服务"
    echo -e " 2. 停止服务"
    echo -e " 3. 重启服务"
    echo -e " 0. 返回上一菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    read -rp " 请选择操作 [0-3]: " act
    case "$act" in
        1) systemctl start "$SERVICE_NAME" && log_success "AnyTLS 服务启动成功！" ;;
        2) systemctl stop "$SERVICE_NAME" && log_success "AnyTLS 服务已停止！" ;;
        3) systemctl restart "$SERVICE_NAME" && log_success "AnyTLS 服务重启成功！" ;;
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
    echo -e "\n${CYAN}=====================================================${NC}"
    pause
}

show_logs() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}          AnyTLS 实时日志（Ctrl+C 返回）             ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    journalctl -u "$SERVICE_NAME" -e -f -n 50 || true
}

uninstall_all() {
    clear
    echo -e "${RED}=====================================================${NC}"
    echo -e "${BOLD}                    卸载 AnyTLS                     ${NC}"
    echo -e "${RED}=====================================================${NC}"
    read -rp " 确定要卸载 Sing-Box AnyTLS 及配置吗？[y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

        rm -f /etc/systemd/system/"$SERVICE_NAME".service
        rm -f /usr/bin/"$SERVICE_NAME" /usr/local/bin/"$SERVICE_NAME"
        rm -f /usr/local/bin/any /usr/bin/any "$LOCAL_SCRIPT_PATH"
        rm -rf /etc/"$SERVICE_NAME" "$INFO_PATH" /root/AnyTLS

        systemctl daemon-reload
        log_success "AnyTLS 脚本及配置已清理。"
        log_warn "Let's Encrypt / Certbot 本身未自动卸载。"
    else
        log_info "已取消卸载。"
    fi
    pause
}

main_menu() {
    check_root
    force_register_shortcut

    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}             Sing-Box AnyTLS 管理脚本                ${NC}"
        echo -e "         快捷指令: ${YELLOW}${BOLD}any${NC}"
        print_system_status

        echo -e " ${GREEN}1.${NC} 安装 / 重构 AnyTLS"
        echo -e " ${GREEN}2.${NC} 服务管理 (启动/停止/重启)"
        echo -e " ${GREEN}3.${NC} 查看 AnyTLS 节点链接"
        echo -e " ${GREEN}4.${NC} 查看运行状态"
        echo -e " ${GREEN}5.${NC} 查看实时日志"
        echo -e " ${RED}6.${NC} 卸载 AnyTLS"
        echo -e " ${YELLOW}0.${NC} 退出脚本"
        echo -e "${CYAN}=====================================================${NC}"

        read -rp " 请输入选项 [0-6]: " opt
        case "$opt" in
            1) install_node ;;
            2) manage_service ;;
            3) show_links ;;
            4) show_status ;;
            5) show_logs ;;
            6) uninstall_all ;;
            0) clear; echo -e "${GREEN}感谢使用！${NC}"; exit 0 ;;
            *) log_error "请输入正确的选项 [0-6]"; sleep 1 ;;
        esac
    done
}

main_menu
