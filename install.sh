#!/usr/bin/env bash
# ============================================================
# Linux 系统配置小工具（sysconfig-tool）
# ------------------------------------------------------------
# 功能模块：
#   1) SSH 管理      : 修改端口、修改用户密码
#   2) 网络管理      : DNS、端口放行/禁止、IPv4/IPv6、Ping、
#                      防火墙总开关、hosts、网络诊断、端口占用
#   3) 系统设置      : 时间/时区/NTP、磁盘内存概览、软件源切换
#   4) 维护工具      : 配置备份回滚、操作日志查看
#
# 兼容系统：
#   - Debian/Ubuntu（含 DEB822 与传统 sources.list）
#   - CentOS Stream / RHEL / Rocky / AlmaLinux / Fedora
#   - 防火墙：ufw / firewalld / iptables
#   - 网络管理：NetworkManager（nmcli）与非 NetworkManager
#
# 用法：
#   sudo bash sysconfig-tool.sh
#
# 说明：
#   - 所有修改前自动备份原文件（*.bak_时间戳）
#   - 所有写操作记入 /var/log/sysconfig-tool.log
#   - 涉及破坏性操作（关闭 IPv4、恢复默认源）有二次确认
# ============================================================

# ---------- 严格模式 ----------
# -e 遇错退出；-u 未定义变量报错；-o pipefail 管道任一环节失败即失败
# 注意：脚本内对可能返回非零的命令大量使用 "|| true" 或 if 判断，
#       以避免严格模式导致交互流程中断。
set -euo pipefail

# ---------- 全局配置 ----------
# 审计日志文件路径（所有写操作都会记录）
LOG_FILE="/var/log/sysconfig-tool.log"
# 由脚本管理的配置文件清单（用于备份回滚）
MANAGED_FILES=(
    /etc/ssh/sshd_config
    /etc/sysctl.conf
    /etc/resolv.conf
    /etc/gai.conf
    /etc/hosts
)
# 国内镜像站列表，格式 "名称:基础URL"
MIRRORS=(
    "aliyun:https://mirrors.aliyun.com"
    "tuna:https://mirrors.tuna.tsinghua.edu.cn"
    "ustc:https://mirrors.ustc.edu.cn"
    "huawei:https://mirrors.huaweicloud.com"
)

# ---------- 颜色定义 ----------
# 仅在交互终端下启用颜色；重定向到文件时自动降级为无色
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

# ---------- 权限检查 ----------
# 脚本涉及系统配置修改，必须以 root 运行
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本（sudo bash $0）${NC}"
    exit 1
fi

# ============================================================
# 通用工具函数
# ============================================================

# 信息输出（绿色）
info()  { echo -e "${GREEN}[信息]${NC} $*"; }
# 警告输出（黄色）
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
# 错误输出（红色）
error() { echo -e "${RED}[错误]${NC} $*"; }

# 暂停等待用户按回车，避免执行结果一闪而过
pause() { read -rp "按 Enter 键继续..." _; }

# 记录审计日志
# 参数：$* 日志内容
# 说明：记录时间、操作用户（优先 SUDO_USER）与实际动作
log_action() {
    local msg=$*
    local stamp user
    stamp=$(date '+%Y-%m-%d %H:%M:%S')
    user=${SUDO_USER:-$(whoami)}
    echo "[${stamp}] [${user}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}

# 备份单个文件
# 参数：$1 文件路径
# 行为：生成 文件名.bak_YYYYmmdd_HHMMSS，并记录日志
backup_file() {
    local file=$1
    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    cp -a "$file" "${file}.bak_${stamp}"
    info "已备份 ${file} -> ${file}.bak_${stamp}"
    log_action "备份 ${file} -> ${file}.bak_${stamp}"
}

# 检测系统可用的防火墙类型
# 返回："ufw" / "firewalld" / "iptables" / "none"
# 说明：按优先级检测，有 ufw 优先用 ufw，有 firewalld 用 firewalld，
#       最后兜底 iptables。若都没有则返回 none。
detect_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        echo "ufw"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        echo "firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

# 获取 NetworkManager 活跃连接名
# 返回：连接名或空字符串
# 说明：非 NetworkManager 系统（如纯 systemd-networkd）会返回空
get_active_connection() {
    nmcli -t -f NAME connection show --active 2>/dev/null | head -n1 || true
}

# 判断系统是否使用 systemd 且 timedatectl 可用
has_timedatectl() {
    command -v timedatectl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

# 解析系统发行版信息
# 设置全局变量：
#   OS_ID        发行版 ID（ubuntu/debian/centos/rhel/rocky/almalinux/fedora）
#   OS_VER       版本号
#   OS_CODENAME  代号（Ubuntu/Debian 有，EL 系通常为空）
#   OS_PRETTY    完整名称
#   PKG_TYPE     包管理器类型（apt / yum / unknown）
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID=${ID:-unknown}
        OS_VER=${VERSION_ID:-unknown}
        OS_CODENAME=${VERSION_CODENAME:-}
        OS_PRETTY=${PRETTY_NAME:-unknown}
    else
        OS_ID="unknown"; OS_VER="unknown"; OS_CODENAME=""; OS_PRETTY="unknown"
    fi
    # 统一归类到包管理器
    case "$OS_ID" in
        ubuntu|debian)                    PKG_TYPE="apt" ;;
        centos|rhel|rocky|almalinux|fedora) PKG_TYPE="yum" ;;
        *)                                PKG_TYPE="unknown" ;;
    esac
}

# 获取本机 IPv4 地址（用于摘要展示）
get_local_ip() {
    # 优先用 ip route get 取默认路由源地址，比 hostname -I 更稳
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1
}

# ============================================================
# 模块 1：SSH 管理
# ============================================================

# 修改 SSH 端口
# 安全策略：默认保留 Port 22，追加新端口，确认新端口可登录后再手动删除 22
change_ssh_port() {
    local SSH_CONFIG="/etc/ssh/sshd_config"
    # 兼容性：某些系统配置文件路径可能不同，优先用主配置
    if [[ ! -f "$SSH_CONFIG" ]]; then
        error "未找到 $SSH_CONFIG，系统可能未安装 SSH 服务。"
        return 1
    fi

    echo -e "\n${CYAN}===== 修改 SSH 端口 =====${NC}"
    read -rp "请输入新的 SSH 端口（1024-65535，直接回车取消）: " new_port
    [[ -z "$new_port" ]] && return 0

    # 校验端口范围
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1024 || new_port > 65535 )); then
        error "端口无效，请输入 1024-65535 之间的数字。"
        return 1
    fi

    # 已存在则跳过
    if grep -qE "^[[:space:]]*Port[[:space:]]+${new_port}$" "$SSH_CONFIG"; then
        warn "端口 ${new_port} 已在配置中，无需修改。"
        return 0
    fi

    backup_file "$SSH_CONFIG"

    # 保留 22 端口策略
    if grep -qE "^[[:space:]]*Port[[:space:]]+22$" "$SSH_CONFIG"; then
        info "检测到已有 Port 22，将同时保留 22 和新端口 ${new_port}。"
        echo "Port ${new_port}" >> "$SSH_CONFIG"
    else
        # 没有显式 Port 22：先注释所有 Port 行，再追加 22 和新端口
        sed -i -E 's/^[[:space:]]*Port[[:space:]]+[0-9]+/#&/' "$SSH_CONFIG"
        {
            echo "Port 22"
            echo "Port ${new_port}"
        } >> "$SSH_CONFIG"
    fi

    # 按防火墙类型自动放行新端口
    local fw
    fw=$(detect_firewall)
    case "$fw" in
        ufw)
            ufw allow "${new_port}/tcp" >/dev/null 2>&1 \
                && info "ufw 已放行 ${new_port}/tcp" \
                || warn "ufw 放行失败，请手动检查。"
            ufw reload >/dev/null 2>&1 || true
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null 2>&1 \
                && firewall-cmd --reload >/dev/null 2>&1 \
                && info "firewalld 已放行 ${new_port}/tcp" \
                || warn "firewalld 操作失败，请手动检查。"
            ;;
        *)
            warn "未检测到 ufw 或 firewalld，如使用云安全组/iptables，请手动放行 ${new_port}/tcp。"
            ;;
    esac

    # 重启 SSH 服务：兼容 sshd（RHEL 系）和 ssh（Debian 系）
    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        info "SSH 服务已重启，新端口 ${new_port} 已生效（22 端口暂时保留）。"
        warn "确认新端口可正常登录后，请手动编辑 $SSH_CONFIG 删除 Port 22 并重启 SSH。"
        log_action "SSH 端口新增 ${new_port}"
    else
        error "SSH 服务重启失败，请检查配置：sshd -t"
    fi
}

# 修改 SSH 用户密码
# 说明：使用 chpasswd 以标准输入方式修改，避免密码出现在命令历史/进程列表
change_ssh_password() {
    echo -e "\n${CYAN}===== 修改 SSH 用户密码 =====${NC}"
    read -rp "请输入要修改密码的用户名（直接回车取消）: " target_user
    [[ -z "$target_user" ]] && return 0

    if ! id "$target_user" &>/dev/null; then
        error "用户 ${target_user} 不存在。"
        return 1
    fi

    read -rsp "请输入新密码: " new_pass; echo
    read -rsp "请再次输入新密码: " new_pass_confirm; echo

    if [[ "$new_pass" != "$new_pass_confirm" ]]; then
        error "两次输入的密码不一致。"
        return 1
    fi
    if [[ ${#new_pass} -lt 8 ]]; then
        warn "密码长度小于 8 位，部分系统可能拒绝。"
    fi

    if echo "${target_user}:${new_pass}" | chpasswd; then
        info "用户 ${target_user} 的密码已成功修改。"
        log_action "修改用户 ${target_user} 的密码"
    else
        error "密码修改失败，可能不满足系统密码策略（pam_pwquality）。"
        return 1
    fi
}

# ============================================================
# 模块 2：网络管理
# ============================================================

# 开启/禁用 Ping（ICMP Echo 响应）
# 实现：同时修改 /proc（立即生效）和 /etc/sysctl.conf（永久生效）
toggle_ping() {
    local SYSCTL_CONF="/etc/sysctl.conf"
    local CURRENT
    CURRENT=$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null || echo "0")

    echo -e "\n${CYAN}===== Ping 响应开关 =====${NC}"
    if [[ "$CURRENT" == "1" ]]; then
        echo "当前状态：已禁用 Ping（不响应 ICMP Echo）"
    else
        echo "当前状态：已启用 Ping（允许响应 ICMP Echo）"
    fi

    echo "1) 启用 Ping（允许被 ping）"
    echo "2) 禁用 Ping（禁止被 ping）"
    echo "0) 返回"
    read -rp "请选择: " ping_choice

    local target_value
    case "$ping_choice" in
        1) target_value=0 ;;
        2) target_value=1 ;;
        0) return 0 ;;
        *) error "无效选项。"; return 1 ;;
    esac

    # 立即生效
    echo "$target_value" > /proc/sys/net/ipv4/icmp_echo_ignore_all

    # 永久生效：写入 sysctl.conf
    backup_file "$SYSCTL_CONF"
    if grep -q "^[[:space:]]*net.ipv4.icmp_echo_ignore_all" "$SYSCTL_CONF" 2>/dev/null; then
        sed -i -E "s/^[[:space:]]*net\.ipv4\.icmp_echo_ignore_all[[:space:]]*=.*/net.ipv4.icmp_echo_ignore_all = ${target_value}/" "$SYSCTL_CONF"
    else
        echo "net.ipv4.icmp_echo_ignore_all = ${target_value}" >> "$SYSCTL_CONF"
    fi
    sysctl -p >/dev/null 2>&1 || true

    if [[ "$target_value" == "1" ]]; then
        info "Ping 已禁用（永久生效）。"
        log_action "禁用 Ping"
    else
        info "Ping 已启用（永久生效）。"
        log_action "启用 Ping"
    fi
}

# 修改 DNS 服务器
# 策略：优先 nmcli 持久化，再写 /etc/resolv.conf 作为回退
change_dns() {
    echo -e "\n${CYAN}===== 修改 DNS =====${NC}"
    read -rp "请输入新的 DNS 地址（多个用空格分隔，如 8.8.8.8 1.1.1.1，回车取消）: " dns_input
    [[ -z "$dns_input" ]] && return 0

    # 简单格式校验
    local dns_array=($dns_input)
    for ip in "${dns_array[@]}"; do
        if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "DNS 地址格式无效：$ip"
            return 1
        fi
    done

    # 优先用 nmcli 持久化（NetworkManager 环境下重启不丢）
    if command -v nmcli >/dev/null 2>&1; then
        local conn
        conn=$(get_active_connection)
        if [[ -z "$conn" ]]; then
            warn "未找到活跃的 NetworkManager 连接，将回退到直接修改 /etc/resolv.conf。"
        else
            info "检测到活跃连接：${conn}"
            nmcli connection modify "$conn" ipv4.dns "$dns_input" >/dev/null 2>&1 \
                && nmcli connection modify "$conn" ipv4.ignore-auto-dns yes >/dev/null 2>&1 \
                && nmcli connection up "$conn" >/dev/null 2>&1 \
                && info "DNS 已通过 nmcli 持久化设置为：${dns_input}" \
                || warn "nmcli 设置失败，将回退到直接修改 /etc/resolv.conf。"
        fi
    fi

    # 无论 nmcli 是否成功，都更新 resolv.conf 确保当前生效
    backup_file /etc/resolv.conf
    {
        echo "# Generated by sysconfig-tool $(date)"
        for ip in "${dns_array[@]}"; do
            echo "nameserver $ip"
        done
    } > /etc/resolv.conf
    info "/etc/resolv.conf 已更新为：${dns_input}"
    warn "直接修改 /etc/resolv.conf 可能在重启或 NetworkManager 刷新后丢失，已尝试使用 nmcli 持久化。"
    log_action "设置 DNS 为 ${dns_input}"
}

# ---------- 端口放行 / 禁止管理 ----------

# 放行端口
port_allow() {
    echo -e "\n${CYAN}----- 放行端口 -----${NC}"
    read -rp "端口号（多个用空格分隔，如 80 443 8080）: " port_input
    [[ -z "$port_input" ]] && return 0
    read -rp "协议 [tcp/udp/both] (默认 tcp): " proto
    proto=${proto:-tcp}

    local ports=($port_input)
    local fw
    fw=$(detect_firewall)

    case "$fw" in
        ufw)
            for p in "${ports[@]}"; do
                case "$proto" in
                    both) ufw allow "${p}/tcp" >/dev/null 2>&1 && ufw allow "${p}/udp" >/dev/null 2>&1 ;;
                    tcp)  ufw allow "${p}/tcp" >/dev/null 2>&1 ;;
                    udp)  ufw allow "${p}/udp" >/dev/null 2>&1 ;;
                    *)    error "协议无效：$proto"; return 1 ;;
                esac
                info "ufw 已放行 ${p}/${proto}"
            done
            ufw reload >/dev/null 2>&1 || true
            ;;
        firewalld)
            for p in "${ports[@]}"; do
                if [[ "$proto" == "both" ]]; then
                    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
                    firewall-cmd --permanent --add-port="${p}/udp" >/dev/null
                else
                    firewall-cmd --permanent --add-port="${p}/${proto}" >/dev/null
                fi
                info "firewalld 已放行 ${p}/${proto}"
            done
            firewall-cmd --reload >/dev/null 2>&1 && info "firewalld 已重载。" || warn "firewalld 重载失败。"
            ;;
        iptables)
            warn "iptables 规则仅当前生效，重启后可能丢失，请确认已安装 iptables-persistent 或手动保存。"
            for p in "${ports[@]}"; do
                if [[ "$proto" == "both" || "$proto" == "tcp" ]]; then
                    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
                    info "iptables 已放行 ${p}/tcp"
                fi
                if [[ "$proto" == "both" || "$proto" == "udp" ]]; then
                    iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT -p udp --dport "$p" -j ACCEPT
                    info "iptables 已放行 ${p}/udp"
                fi
            done
            ;;
        *) error "未检测到可用的防火墙工具。"; return 1 ;;
    esac
    log_action "放行端口 ${port_input} (${proto})"
}

# 禁止端口
port_deny() {
    echo -e "\n${CYAN}----- 禁止端口 -----${NC}"
    read -rp "端口号（多个用空格分隔）: " port_input
    [[ -z "$port_input" ]] && return 0
    read -rp "协议 [tcp/udp/both] (默认 tcp): " proto
    proto=${proto:-tcp}

    local ports=($port_input)
    local fw
    fw=$(detect_firewall)

    case "$fw" in
        ufw)
            for p in "${ports[@]}"; do
                case "$proto" in
                    both) ufw deny "${p}/tcp" >/dev/null 2>&1 && ufw deny "${p}/udp" >/dev/null 2>&1 ;;
                    tcp)  ufw deny "${p}/tcp" >/dev/null 2>&1 ;;
                    udp)  ufw deny "${p}/udp" >/dev/null 2>&1 ;;
                    *)    error "协议无效：$proto"; return 1 ;;
                esac
                info "ufw 已禁止 ${p}/${proto}"
            done
            ufw reload >/dev/null 2>&1 || true
            ;;
        firewalld)
            # firewalld 无直接 deny port，用 rich rule reject 实现
            for p in "${ports[@]}"; do
                if [[ "$proto" == "both" ]]; then
                    firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" port port=\"${p}\" protocol=\"tcp\" reject" >/dev/null
                    firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" port port=\"${p}\" protocol=\"udp\" reject" >/dev/null
                else
                    firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" port port=\"${p}\" protocol=\"${proto}\" reject" >/dev/null
                fi
                info "firewalld 已禁止 ${p}/${proto}"
            done
            firewall-cmd --reload >/dev/null 2>&1 && info "firewalld 已重载。" || warn "firewalld 重载失败。"
            ;;
        iptables)
            warn "iptables 规则仅当前生效，重启后可能丢失。"
            for p in "${ports[@]}"; do
                if [[ "$proto" == "both" || "$proto" == "tcp" ]]; then
                    iptables -C INPUT -p tcp --dport "$p" -j REJECT 2>/dev/null || \
                    iptables -I INPUT -p tcp --dport "$p" -j REJECT
                    info "iptables 已禁止 ${p}/tcp"
                fi
                if [[ "$proto" == "both" || "$proto" == "udp" ]]; then
                    iptables -C INPUT -p udp --dport "$p" -j REJECT 2>/dev/null || \
                    iptables -I INPUT -p udp --dport "$p" -j REJECT
                    info "iptables 已禁止 ${p}/udp"
                fi
            done
            ;;
        *) error "未检测到可用的防火墙工具。"; return 1 ;;
    esac
    log_action "禁止端口 ${port_input} (${proto})"
}

# 查看当前防火墙规则
port_list() {
    echo -e "\n${CYAN}----- 当前放行/禁止的端口 -----${NC}"
    local fw
    fw=$(detect_firewall)
    case "$fw" in
        ufw)
            ufw status numbered || true
            ;;
        firewalld)
            echo "默认区域: $(firewall-cmd --get-default-zone 2>/dev/null)"
            echo "--- 放行端口 ---"; firewall-cmd --list-ports 2>/dev/null || true
            echo "--- 放行服务 ---"; firewall-cmd --list-services 2>/dev/null || true
            echo "--- Rich Rules ---"; firewall-cmd --list-rich-rules 2>/dev/null || true
            ;;
        iptables)
            iptables -L INPUT -n --line-numbers 2>/dev/null || true
            ;;
        *) warn "未检测到可用的防火墙工具。" ;;
    esac
}

# 端口管理子菜单
manage_ports() {
    while true; do
        echo -e "\n${CYAN}===== 端口放行 / 禁止管理 =====${NC}"
        echo "  防火墙：$(detect_firewall)"
        echo "  1) 放行端口"
        echo "  2) 禁止端口"
        echo "  3) 查看当前规则"
        echo "  0) 返回"
        read -rp "请选择 [0-3]: " pc
        case "$pc" in
            1) port_allow; pause ;;
            2) port_deny; pause ;;
            3) port_list; pause ;;
            0) return 0 ;;
            *) error "无效选项。"; sleep 1 ;;
        esac
    done
}

# ---------- IPv4 / IPv6 优先级与开关 ----------
GAI_CONF="/etc/gai.conf"   # glibc 地址排序配置文件

# 显示当前 IP 协议栈状态
show_ip_status() {
    echo -e "\n${CYAN}----- 当前网络协议状态 -----${NC}"

    # IPv6 是否禁用（读 proc）
    local v6_disable
    v6_disable=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "N/A")
    if [[ "$v6_disable" == "1" ]]; then
        echo "IPv6 状态：已禁用"
    elif [[ "$v6_disable" == "0" ]]; then
        echo "IPv6 状态：已启用"
    else
        echo "IPv6 状态：未知（/proc/sys/net/ipv6 不存在）"
    fi

    # IPv4 是否有地址（一般不会禁用）
    echo "IPv4 状态：$(ip -4 addr show 2>/dev/null | grep -q inet && echo '已启用（有地址）' || echo '未检测到地址')"

    # gai.conf 中是否设置了 IPv4 优先
    if [[ -f "$GAI_CONF" ]]; then
        local prec
        prec=$(grep -E "^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96" "$GAI_CONF" 2>/dev/null | awk '{print $NF}' || true)
        if [[ -n "$prec" ]]; then
            echo "解析优先级：IPv4 优先（precedence ::ffff:0:0/96 = ${prec}）"
        else
            echo "解析优先级：IPv6 优先（系统默认）"
        fi
    else
        echo "解析优先级：$GAI_CONF 不存在（默认 IPv6 优先）"
    fi

    echo; echo "当前地址："
    ip -brief addr show 2>/dev/null || true
}

# 设置 IPv4 优先（通过 gai.conf）
set_ipv4_priority() {
    echo -e "\n${CYAN}----- 设置 IPv4 优先 -----${NC}"
    [[ ! -f "$GAI_CONF" ]] && touch "$GAI_CONF"
    backup_file "$GAI_CONF"

    # precedence ::ffff:0:0/96 数值越大越优先，默认 35；设为 100 高于 IPv6
    if grep -qE "^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96" "$GAI_CONF"; then
        sed -i -E "s|^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96.*|precedence ::ffff:0:0/96  100|" "$GAI_CONF"
    else
        echo "" >> "$GAI_CONF"
        echo "# IPv4 优先（由 sysconfig-tool 添加）" >> "$GAI_CONF"
        echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
    fi
    info "已将解析优先级设置为 IPv4 优先。新的连接将优先使用 IPv4。"
    warn "对已建立的连接无影响；部分应用可能需要重启。"
    log_action "设置 IPv4 优先"
}

# 恢复 IPv6 优先（注释掉 gai.conf 中的 IPv4 优先规则）
set_ipv6_priority() {
    echo -e "\n${CYAN}----- 恢复 IPv6 优先（默认）-----${NC}"
    if [[ -f "$GAI_CONF" ]]; then
        backup_file "$GAI_CONF"
        sed -i -E "s|^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96|#&|" "$GAI_CONF"
        info "已注释 IPv4 优先规则，恢复系统默认（IPv6 优先）。"
        log_action "恢复 IPv6 优先"
    else
        info "未找到 $GAI_CONF，当前已是系统默认（IPv6 优先）。"
    fi
}

# 关闭 IPv6（写 sysctl.conf 并立即生效）
disable_ipv6() {
    echo -e "\n${CYAN}----- 关闭 IPv6 -----${NC}"
    warn "关闭 IPv6 可能影响依赖 IPv6 的服务，请谨慎操作。"
    read -rp "确认关闭 IPv6？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { info "已取消。"; return 0; }

    local SYSCTL_CONF="/etc/sysctl.conf"
    backup_file "$SYSCTL_CONF"

    local lines=(
        "net.ipv6.conf.all.disable_ipv6 = 1"
        "net.ipv6.conf.default.disable_ipv6 = 1"
        "net.ipv6.conf.lo.disable_ipv6 = 1"
    )
    for line in "${lines[@]}"; do
        local key=${line%% =*}
        if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_CONF" 2>/dev/null; then
            sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${line}|" "$SYSCTL_CONF"
        else
            echo "$line" >> "$SYSCTL_CONF"
        fi
        # 立即生效：把点号路径转为 /proc 路径
        echo "1" > "/proc/sys/${key//./\/}" 2>/dev/null || true
    done
    sysctl -p >/dev/null 2>&1 || true

    info "IPv6 已关闭（永久生效）。"
    log_action "关闭 IPv6"
}

# 开启 IPv6
enable_ipv6() {
    echo -e "\n${CYAN}----- 开启 IPv6 -----${NC}"
    local SYSCTL_CONF="/etc/sysctl.conf"
    backup_file "$SYSCTL_CONF"

    local lines=(
        "net.ipv6.conf.all.disable_ipv6 = 0"
        "net.ipv6.conf.default.disable_ipv6 = 0"
        "net.ipv6.conf.lo.disable_ipv6 = 0"
    )
    for line in "${lines[@]}"; do
        local key=${line%% =*}
        if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_CONF" 2>/dev/null; then
            sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${line}|" "$SYSCTL_CONF"
        else
            echo "$line" >> "$SYSCTL_CONF"
        fi
        echo "0" > "/proc/sys/${key//./\/}" 2>/dev/null || true
    done
    sysctl -p >/dev/null 2>&1 || true

    info "IPv6 已开启（永久生效）。"
    log_action "开启 IPv6"
}

# 关闭 IPv4（仅警告，不自动执行）
# 原因：关闭 IPv4 会立即断开 SSH，属于破坏性操作
disable_ipv4() {
    echo -e "\n${CYAN}----- 关闭 IPv4 -----${NC}"
    warn "！！！极度危险：关闭 IPv4 会导致绝大多数网络服务不可用，可能立即断开 SSH 连接 ！！！"
    warn "在大多数服务器上不建议关闭 IPv4。"
    read -rp "确实要关闭 IPv4 吗？请输入 'YES' 确认: " confirm
    if [[ "$confirm" != "YES" ]]; then
        info "已取消。"
        return 0
    fi
    warn "本脚本不自动执行 IPv4 关闭，以避免破坏系统可用性。"
    warn "如确需关闭，请手动操作（风险自负），推荐保留 IPv4 仅调整优先级。"
    log_action "尝试关闭 IPv4（已阻止）"
}

# IP 协议栈子菜单
configure_ip_stack() {
    while true; do
        echo -e "\n${CYAN}===== IPv4 / IPv6 优先级与开关 =====${NC}"
        echo "  1) 查看当前状态"
        echo "  2) 设置 IPv4 优先"
        echo "  3) 恢复 IPv6 优先（默认）"
        echo "  4) 关闭 IPv6"
        echo "  5) 开启 IPv6"
        echo "  6) 关闭 IPv4（危险）"
        echo "  0) 返回"
        read -rp "请选择 [0-6]: " ic
        case "$ic" in
            1) show_ip_status; pause ;;
            2) set_ipv4_priority; pause ;;
            3) set_ipv6_priority; pause ;;
            4) disable_ipv6; pause ;;
            5) enable_ipv6; pause ;;
            6) disable_ipv4; pause ;;
            0) return 0 ;;
            *) error "无效选项。"; sleep 1 ;;
        esac
    done
}

# 防火墙总开关
firewall_toggle() {
    local fw
    fw=$(detect_firewall)
    echo -e "\n${CYAN}===== 防火墙总开关 =====${NC}"
    echo "当前防火墙：${fw}"
    case "$fw" in
        ufw)
            ufw status 2>/dev/null | head -n1 || true
            echo "  1) 启用    2) 停用    0) 返回"
            read -rp "请选择: " c
            case "$c" in
                1) ufw --force enable && log_action "ufw 启用" && info "ufw 已启用" ;;
                2) ufw disable && log_action "ufw 停用" && info "ufw 已停用" ;;
                0) return 0 ;;
            esac
            ;;
        firewalld)
            firewall-cmd --state 2>/dev/null || true
            echo "  1) 启动    2) 停止    0) 返回"
            read -rp "请选择: " c
            case "$c" in
                1) systemctl start firewalld && log_action "firewalld 启动" && info "firewalld 已启动" ;;
                2) systemctl stop firewalld && log_action "firewalld 停止" && info "firewalld 已停止" ;;
                0) return 0 ;;
            esac
            ;;
        iptables)
            warn "iptables 无统一“总开关”，请使用端口放行/禁止逐条管理。"
            ;;
        *) error "未检测到 ufw / firewalld" ;;
    esac
}

# hosts 管理
manage_hosts() {
    local HOSTS="/etc/hosts"
    while true; do
        echo -e "\n${CYAN}===== hosts 管理 =====${NC}"
        echo "  1) 查看"
        echo "  2) 添加"
        echo "  3) 删除"
        echo "  0) 返回"
        read -rp "请选择: " c
        case "$c" in
            1)
                echo "--- 当前有效条目 ---"
                grep -vE '^\s*#' "$HOSTS" 2>/dev/null | grep -vE '^\s*$' || echo "（无）"
                ;;
            2)
                local ip names
                read -rp "IP 地址: " ip
                read -rp "域名（多个空格分隔）: " names
                [[ -z "$ip" || -z "$names" ]] && continue
                # 简单校验 IPv4 或含冒号的 IPv6
                if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$ip" == *:* ]]; then
                    error "IP 格式无效"
                    continue
                fi
                backup_file "$HOSTS"
                echo "${ip} ${names}" >> "$HOSTS"
                log_action "hosts 添加: ${ip} ${names}"
                info "已添加"
                ;;
            3)
                echo "--- 可删除条目（带行号）---"
                grep -vnE '^\s*#' "$HOSTS" 2>/dev/null | grep -vE ':\s*$' || echo "（无）"
                local ln
                read -rp "要删除的行号（回车取消）: " ln
                [[ -z "$ln" ]] && continue
                if ! [[ "$ln" =~ ^[0-9]+$ ]]; then
                    error "行号无效"; continue
                fi
                backup_file "$HOSTS"
                sed -i "${ln}d" "$HOSTS"
                log_action "hosts 删除第 ${ln} 行"
                info "已删除"
                ;;
            0) return 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

# 网络诊断工具
network_diagnostics() {
    echo -e "\n${CYAN}===== 网络诊断 =====${NC}"
    echo "  1) Ping 测试"
    echo "  2) 路由追踪"
    echo "  3) DNS 解析"
    echo "  4) 端口连通性探测"
    echo "  5) 本机监听端口"
    echo "  0) 返回"
    read -rp "请选择: " c
    local host port domain
    case "$c" in
        1)
            read -rp "目标主机/IP: " host
            [[ -z "$host" ]] && return 0
            ping -c 4 "$host" || warn "ping 失败或目标不可达"
            ;;
        2)
            read -rp "目标主机/IP: " host
            [[ -z "$host" ]] && return 0
            # 兼容性：优先 traceroute，回退 tracepath
            if command -v traceroute >/dev/null 2>&1; then
                traceroute -n "$host"
            elif command -v tracepath >/dev/null 2>&1; then
                tracepath -n "$host"
            else
                error "未安装 traceroute / tracepath"
            fi
            ;;
        3)
            read -rp "域名: " domain
            [[ -z "$domain" ]] && return 0
            # 兼容性：优先 dig，回退 nslookup
            if command -v dig >/dev/null 2>&1; then
                dig +short "$domain"
            elif command -v nslookup >/dev/null 2>&1; then
                nslookup "$domain"
            else
                error "未安装 dig / nslookup"
            fi
            ;;
        4)
            read -rp "主机: " host
            read -rp "端口: " port
            [[ -z "$host" || -z "$port" ]] && return 0
            # 使用 bash 内置 /dev/tcp 探测，无需安装 nc
            if timeout 5 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
                info "${host}:${port} 可连通"
            else
                warn "${host}:${port} 不可达或被拒绝"
            fi
            ;;
        5)
            # 兼容性：优先 ss，回退 netstat
            ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || error "无 ss / netstat"
            ;;
        0) return 0 ;;
        *) error "无效选项" ;;
    esac
}

# 端口占用查看
show_port_usage() {
    echo -e "\n${CYAN}===== 端口占用查看 =====${NC}"
    read -rp "输入端口号过滤（回车显示全部）: " p
    if [[ -z "$p" ]]; then
        ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || error "无 ss / netstat"
    else
        ss -tulnp 2>/dev/null | grep -E ":${p}\b" || echo "未找到端口 ${p} 的监听"
    fi
}

# ============================================================
# 模块 3：系统设置
# ============================================================

# 显示当前时间/时区/NTP 状态
show_time_status() {
    echo -e "\n${CYAN}----- 当前时间状态 -----${NC}"
    echo "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
    echo "硬件时钟：$(hwclock --show 2>/dev/null || echo 'N/A')"

    # 兼容性：systemd 系统用 timedatectl，否则读文件
    if has_timedatectl; then
        local tz ntp
        tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "未知")
        ntp=$(timedatectl show -p NTP --value 2>/dev/null || echo "unknown")
        echo "系统时区：${tz}"
        echo "NTP 状态：${ntp}（yes=自动同步，no=可手动设置时间）"
        echo "NTP 同步：$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'unknown')"
    else
        echo "系统时区：$(cat /etc/timezone 2>/dev/null || readlink -f /etc/localtime | sed 's#.*/zoneinfo/##')"
        echo "NTP 状态：非 systemd 系统，请检查 chrony/ntpd 服务。"
    fi
    echo
    echo "提示：NTP 开启时手动修改时间会被拒绝，需先关闭 NTP。"
}

# 手动设置时间
set_manual_time() {
    echo -e "\n${CYAN}----- 手动设置时间 -----${NC}"
    echo "当前时间：$(date '+%Y-%m-%d %H:%M:%S')"
    read -rp "请输入新时间（格式：YYYY-MM-DD HH:MM:SS，回车取消）: " new_time
    [[ -z "$new_time" ]] && return 0

    # 用 date -d 做语法校验
    if ! date -d "$new_time" >/dev/null 2>&1; then
        error "时间格式无效，请使用 YYYY-MM-DD HH:MM:SS。"
        return 1
    fi

    if has_timedatectl; then
        # NTP 开启时 set-time 会被拒绝，先提示关闭
        local ntp
        ntp=$(timedatectl show -p NTP --value 2>/dev/null || echo "no")
        if [[ "$ntp" == "yes" ]]; then
            warn "NTP 已开启，手动修改时间会被拒绝。"
            read -rp "是否临时关闭 NTP？[y/N]: " c
            if [[ "$c" == "y" || "$c" == "Y" ]]; then
                timedatectl set-ntp false
                info "NTP 已关闭。"
            else
                warn "已取消。"
                return 0
            fi
        fi
        if timedatectl set-time "$new_time"; then
            info "时间已设置为：$(date '+%Y-%m-%d %H:%M:%S')"
            warn "如需恢复自动同步，请在菜单中选择“开启 / 关闭 NTP”。"
            log_action "设置时间 ${new_time}"
        else
            error "设置时间失败。"
            return 1
        fi
    else
        # 非 systemd：date -s + hwclock 同步
        if date -s "$new_time" >/dev/null 2>&1; then
            hwclock --systohc >/dev/null 2>&1 || true
            info "时间已设置为：$(date '+%Y-%m-%d %H:%M:%S')（已同步硬件时钟）"
            log_action "设置时间 ${new_time}"
        else
            error "设置时间失败。"
            return 1
        fi
    fi
}

# 选择时区
set_timezone() {
    echo -e "\n${CYAN}----- 选择时区 -----${NC}"
    local cur_tz
    cur_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "未知")
    echo "当前时区：${cur_tz}"
    echo
    echo "常用时区："

    # 常用时区列表（名称:说明）
    local tzs=(
        "Asia/Shanghai:中国标准时间 (UTC+8)"
        "Asia/Hong_Kong:香港 (UTC+8)"
        "Asia/Taipei:台北 (UTC+8)"
        "Asia/Tokyo:东京 (UTC+9)"
        "Asia/Seoul:首尔 (UTC+9)"
        "Asia/Singapore:新加坡 (UTC+8)"
        "Asia/Kolkata:印度 (UTC+5:30)"
        "Asia/Dubai:迪拜 (UTC+4)"
        "UTC:协调世界时 (UTC+0)"
        "Europe/London:伦敦 (UTC+0/+1)"
        "Europe/Paris:巴黎 (UTC+1/+2)"
        "Europe/Moscow:莫斯科 (UTC+3)"
        "America/New_York:纽约 (UTC-5/-4)"
        "America/Chicago:芝加哥 (UTC-6/-5)"
        "America/Denver:丹佛 (UTC-7/-6)"
        "America/Los_Angeles:洛杉矶 (UTC-8/-7)"
        "Australia/Sydney:悉尼 (UTC+10/+11)"
        "Pacific/Auckland:奥克兰 (UTC+12/+13)"
    )
    local i=1
    local -a tz_names=()
    for entry in "${tzs[@]}"; do
        local name=${entry%%:*}
        local desc=${entry#*:}
        printf "  %2d) %-22s %s\n" "$i" "$name" "$desc"
        tz_names+=("$name")
        i=$((i+1))
    done
    echo "   0) 返回"
    echo "   s) 搜索全部时区（timedatectl list-timezones）"
    read -rp "请选择: " tz_choice

    local selected_tz=""
    case "$tz_choice" in
        0) return 0 ;;
        s|S)
            read -rp "输入关键字（如 Asia/Shang、America/New）: " kw
            [[ -z "$kw" ]] && return 0
            local matches
            matches=$(timedatectl list-timezones 2>/dev/null | grep -i "$kw" || true)
            if [[ -z "$matches" ]]; then
                error "未找到匹配的时区。"
                return 1
            fi
            echo "匹配结果："; echo "$matches"
            read -rp "请输入完整时区名: " selected_tz
            ;;
        *)
            if [[ "$tz_choice" =~ ^[0-9]+$ ]] && (( tz_choice >= 1 && tz_choice <= ${#tz_names[@]} )); then
                selected_tz="${tz_names[$((tz_choice-1))]}"
            else
                error "无效选项。"; return 1
            fi
            ;;
    esac

    [[ -z "$selected_tz" ]] && { warn "未指定时区。"; return 0; }

    if has_timedatectl; then
        if timedatectl set-timezone "$selected_tz"; then
            info "时区已设置为：$selected_tz"
            info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
            log_action "设置时区 ${selected_tz}"
        else
            error "设置时区失败（请确认时区名有效）。"
        fi
    else
        # 非 systemd：修改 /etc/localtime 符号链接 + /etc/timezone
        if [[ -f "/usr/share/zoneinfo/$selected_tz" ]]; then
            ln -sf "/usr/share/zoneinfo/$selected_tz" /etc/localtime
            echo "$selected_tz" > /etc/timezone
            info "时区已设置为：$selected_tz"
            info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
            log_action "设置时区 ${selected_tz}"
        else
            error "时区文件不存在：/usr/share/zoneinfo/$selected_tz"
        fi
    fi
}

# NTP 时间同步开关
toggle_ntp() {
    echo -e "\n${CYAN}----- NTP 时间同步开关 -----${NC}"
    if ! has_timedatectl; then
        error "当前系统不支持 timedatectl（非 systemd 系统），请手动管理 chrony/ntpd。"
        return 1
    fi
    local ntp
    ntp=$(timedatectl show -p NTP --value 2>/dev/null || echo "unknown")
    echo "当前 NTP 状态：$ntp"
    echo "1) 开启 NTP（自动同步时间）"
    echo "2) 关闭 NTP（允许手动设置时间）"
    echo "0) 返回"
    read -rp "请选择: " c
    case "$c" in
        1)
            if timedatectl set-ntp true; then
                info "NTP 已开启。"
                warn "若无可用 NTP 客户端（systemd-timesyncd/chrony），同步可能不会生效。"
                log_action "开启 NTP"
            else
                error "开启失败。"
            fi
            ;;
        2)
            timedatectl set-ntp false && { info "NTP 已关闭。"; log_action "关闭 NTP"; } || error "关闭失败。"
            ;;
        0) return 0 ;;
        *) error "无效选项。" ;;
    esac
}

# 时间时区子菜单
manage_time() {
    while true; do
        echo -e "\n${CYAN}===== 时间与时区管理 =====${NC}"
        echo "  当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "  1) 查看时间 / 时区 / NTP 状态"
        echo "  2) 手动设置时间"
        echo "  3) 选择时区"
        echo "  4) 开启 / 关闭 NTP"
        echo "  0) 返回"
        read -rp "请选择 [0-4]: " tc
        case "$tc" in
            1) show_time_status; pause ;;
            2) set_manual_time; pause ;;
            3) set_timezone; pause ;;
            4) toggle_ntp; pause ;;
            0) return 0 ;;
            *) error "无效选项。"; sleep 1 ;;
        esac
    done
}

# 磁盘 / 内存概览
show_disk_mem() {
    echo -e "\n${CYAN}===== 磁盘 / 内存概览 =====${NC}"
    echo "--- 磁盘使用 ---"
    df -hT 2>/dev/null | grep -vE 'tmpfs|devtmpfs' || df -h
    echo
    echo "--- inode 使用 ---"
    df -i 2>/dev/null | grep -vE 'tmpfs|devtmpfs' || true
    echo
    echo "--- 内存 ---"
    free -h
    echo
    echo "--- / 下占用 Top 10 目录 ---"
    du -xhd1 / 2>/dev/null | sort -rh | head -n 10 || true
}

# ---------- 软件源切换 ----------

# 选择镜像站，设置全局 MIRROR_NAME / MIRROR_BASE
pick_mirror() {
    echo -e "\n${CYAN}----- 选择镜像站 -----${NC}"
    local i=1
    for m in "${MIRRORS[@]}"; do
        echo "  ${i}) ${m%%:*}  ${m#*:}"
        i=$((i+1))
    done
    read -rp "请选择镜像 [1-${#MIRRORS[@]}] (默认 1=阿里云): " mc
    mc=${mc:-1}
    if ! [[ "$mc" =~ ^[0-9]+$ ]] || (( mc < 1 || mc > ${#MIRRORS[@]} )); then
        error "编号无效"
        return 1
    fi
    MIRROR_NAME=${MIRRORS[$((mc-1))]%%:*}
    MIRROR_BASE=${MIRRORS[$((mc-1))]#*:}
}

# APT 换源（兼容 DEB822 与传统 sources.list）
switch_apt_source() {
    local base=$1
    local codename=$2

    # 判断使用 DEB822 格式还是传统格式
    local use_deb822=0
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] && [[ -s /etc/apt/sources.list.d/ubuntu.sources ]]; then
        use_deb822=1
    elif [[ -f /etc/apt/sources.list.d/debian.sources ]] && [[ -s /etc/apt/sources.list.d/debian.sources ]]; then
        use_deb822=1
    fi

    if [[ "$use_deb822" == "1" ]]; then
        # ---- DEB822 格式（Ubuntu 24.04+ / Debian 12+ 容器默认）----
        local src_file
        if [[ "$OS_ID" == "ubuntu" ]]; then
            src_file="/etc/apt/sources.list.d/ubuntu.sources"
        else
            src_file="/etc/apt/sources.list.d/debian.sources"
        fi
        backup_file "$src_file"

        local suites comps
        if [[ "$OS_ID" == "ubuntu" ]]; then
            suites="${codename} ${codename}-updates ${codename}-backports ${codename}-security"
            comps="main restricted universe multiverse"
        else
            suites="${codename} ${codename}-updates ${codename}-backports"
            comps="main contrib non-free non-free-firmware"
        fi

        {
            echo "Types: deb"
            echo "URIs: ${base}/$( [[ "$OS_ID" == "ubuntu" ]] && echo ubuntu || echo debian )"
            echo "Suites: ${suites}"
            echo "Components: ${comps}"
            if [[ "$OS_ID" == "ubuntu" ]]; then
                echo "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
            else
                echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
            fi
            # Debian 安全源单独一段
            if [[ "$OS_ID" == "debian" ]]; then
                echo ""
                echo "Types: deb"
                echo "URIs: ${base}/debian-security"
                echo "Suites: ${codename}-security"
                echo "Components: ${comps}"
                echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
            fi
        } > "$src_file"
        info "已写入 DEB822 格式源：${src_file}"
    else
        # ---- 传统 sources.list 格式 ----
        local src_file="/etc/apt/sources.list"
        backup_file "$src_file"

        local path comps
        if [[ "$OS_ID" == "ubuntu" ]]; then
            path="ubuntu"
            comps="main restricted universe multiverse"
        else
            path="debian"
            comps="main contrib non-free non-free-firmware"
        fi

        {
            echo "# Generated by sysconfig-tool $(date '+%Y-%m-%d %H:%M:%S')"
            echo "deb ${base}/${path}/ ${codename} ${comps}"
            echo "deb ${base}/${path}/ ${codename}-updates ${comps}"
            echo "deb ${base}/${path}/ ${codename}-backports ${comps}"
            if [[ "$OS_ID" == "ubuntu" ]]; then
                echo "deb ${base}/${path}/ ${codename}-security ${comps}"
            else
                echo "deb ${base}/debian-security ${codename}-security ${comps}"
            fi
        } > "$src_file"
        info "已写入传统格式源：${src_file}"
    fi

    # DEB822 时提醒清理可能残留的旧 sources.list
    if [[ "$use_deb822" == "1" ]]; then
        warn "检测到 DEB822 格式，请确认 /etc/apt/sources.list 中无残留旧条目，必要时手动清空该文件。"
    fi

    # 刷新缓存并展示结果尾部
    apt clean >/dev/null 2>&1 || true
    if apt update -q 2>&1 | tail -n 5; then
        info "软件源已切换为 ${MIRROR_NAME}，apt update 成功。"
    else
        warn "apt update 有报错，请检查源地址或网络。"
    fi
}

# 生成 EL 系（CentOS/RHEL/Rocky/Alma）的 repo 文件
# 参数：$1 镜像基础 URL，$2 发行版 ID
# 说明：使用 $releasever 变量，让 yum/dnf 按系统版本自动解析
write_yum_el_repo() {
    local base=$1
    local os_id=$2
    local repo_dir="/etc/yum.repos.d"
    local repo_file="${repo_dir}/${MIRROR_NAME}.repo"

    # 按发行版决定镜像路径
    local path
    case "$os_id" in
        centos)    path="centos-stream" ;;
        rhel)      path="centos-stream" ;;   # RHEL 借用 CentOS Stream 源
        rocky)     path="rockylinux" ;;
        almalinux) path="almalinux" ;;
        *)         path="centos-stream" ;;
    esac

    # CentOS Stream / RHEL 的版本目录是 "9-stream" 形式；
    # Rocky/Alma 是 "9" 形式。用 $releasever 变量拼接。
    local ver_suffix=""
    if [[ "$os_id" == "centos" || "$os_id" == "rhel" ]]; then
        ver_suffix="-stream"
    fi

    # GPG 公钥路径（部分镜像有）
    local gpg_key=""
    if [[ "$MIRROR_NAME" == "aliyun" ]]; then
        gpg_key="${base}/${path}/RPM-GPG-KEY-centosofficial"
    fi

    # 写入 BaseOS 和 AppStream 两个仓库
    cat > "$repo_file" <<EOF
[${MIRROR_NAME}_baseos]
name=${OS_PRETTY} - BaseOS (${MIRROR_NAME})
baseurl=${base}/${path}/\$releasever${ver_suffix}/BaseOS/\$basearch/os/
gpgcheck=1
enabled=1
EOF
    if [[ -n "$gpg_key" ]]; then
        echo "gpgkey=${gpg_key}" >> "$repo_file"
    else
        echo "gpgcheck=0" >> "$repo_file"
    fi

    cat >> "$repo_file" <<EOF

[${MIRROR_NAME}_appstream]
name=${OS_PRETTY} - AppStream (${MIRROR_NAME})
baseurl=${base}/${path}/\$releasever${ver_suffix}/AppStream/\$basearch/os/
gpgcheck=1
enabled=1
EOF
    if [[ -n "$gpg_key" ]]; then
        echo "gpgkey=${gpg_key}" >> "$repo_file"
    else
        echo "gpgcheck=0" >> "$repo_file"
    fi

    info "已写入 repo 文件：${repo_file}"
}

# 生成 Fedora 的 repo 文件
write_yum_fedora_repo() {
    local base=$1
    local repo_dir="/etc/yum.repos.d"
    local repo_file="${repo_dir}/${MIRROR_NAME}.repo"

    cat > "$repo_file" <<EOF
[${MIRROR_NAME}_fedora]
name=Fedora \$releasever - \$basearch (${MIRROR_NAME})
baseurl=${base}/fedora/releases/\$releasever/Everything/\$basearch/os/
gpgcheck=1
enabled=1

[${MIRROR_NAME}_updates]
name=Fedora \$releasever - \$basearch - Updates (${MIRROR_NAME})
baseurl=${base}/fedora/updates/\$releasever/Everything/\$basearch/
gpgcheck=1
enabled=1
EOF
    info "已写入 Fedora repo 文件：${repo_file}"
}

# YUM/DNF 换源入口
switch_yum_source() {
    local base=$1
    local repo_dir="/etc/yum.repos.d"
    local backup_dir="${repo_dir}/backup_$(date +%Y%m%d_%H%M%S)"

    # 备份所有现有 repo
    mkdir -p "$backup_dir"
    mv "${repo_dir}"/*.repo "$backup_dir/" 2>/dev/null || true
    info "原 repo 文件已移至 ${backup_dir}"

    # 按发行版写 repo
    if [[ "$OS_ID" == "fedora" ]]; then
        write_yum_fedora_repo "$base"
    else
        write_yum_el_repo "$base" "$OS_ID"
    fi

    # 刷新缓存
    if command -v dnf >/dev/null 2>&1; then
        dnf clean all >/dev/null 2>&1 || true
        if dnf makecache 2>&1 | tail -n 5; then
            info "软件源已切换为 ${MIRROR_NAME}，dnf makecache 成功。"
        else
            warn "dnf makecache 有报错，请检查源地址或网络。"
        fi
    else
        yum clean all >/dev/null 2>&1 || true
        if yum makecache 2>&1 | tail -n 5; then
            info "软件源已切换为 ${MIRROR_NAME}，yum makecache 成功。"
        else
            warn "yum makecache 有报错，请检查源地址或网络。"
        fi
    fi
}

# 恢复系统默认软件源（从最近备份）
restore_default_source() {
    read -rp "确认恢复系统默认软件源？[y/N]: " c
    [[ "$c" != "y" && "$c" != "Y" ]] && { info "已取消"; return 0; }

    if [[ "$PKG_TYPE" == "apt" ]]; then
        local restored=0
        # 逐个文件找最近备份
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/debian.sources; do
            local latest
            latest=$(ls -1t "${f}".bak_* 2>/dev/null | head -n1 || true)
            if [[ -n "$latest" ]]; then
                cp -a "$latest" "$f"
                info "已从 ${latest} 恢复 ${f}"
                restored=1
            fi
        done
        if [[ "$restored" == "0" ]]; then
            warn "未找到备份文件，无法恢复。"; return 1
        fi
        apt update -q 2>&1 | tail -n 5 || true
    else
        local repo_dir="/etc/yum.repos.d"
        local latest_backup
        latest_backup=$(ls -1dt "${repo_dir}"/backup_* 2>/dev/null | head -n1 || true)
        if [[ -z "$latest_backup" ]]; then
            warn "未找到 repo 备份目录。"; return 1
        fi
        rm -f "${repo_dir}"/*.repo
        cp -a "${latest_backup}"/*.repo "$repo_dir/" 2>/dev/null || true
        info "已从 ${latest_backup} 恢复 repo 文件"
        if command -v dnf >/dev/null 2>&1; then
            dnf makecache 2>&1 | tail -n 5 || true
        else
            yum makecache 2>&1 | tail -n 5 || true
        fi
    fi
}

# 软件源管理入口
manage_software_source() {
    get_os_info
    echo -e "\n${CYAN}===== 软件源切换 =====${NC}"
    echo "系统：${OS_PRETTY}"
    echo "包管理器：${PKG_TYPE}"

    if [[ "$PKG_TYPE" == "unknown" ]]; then
        error "不支持的发行版：${OS_ID}"
        return 1
    fi

    while true; do
        echo -e "\n${CYAN}----- 软件源操作 -----${NC}"
        echo "  1) 切换国内镜像源"
        echo "  2) 恢复系统默认源（从备份）"
        echo "  0) 返回"
        read -rp "请选择 [0-2]: " c
        case "$c" in
            1)
                pick_mirror || continue
                if [[ "$PKG_TYPE" == "apt" ]]; then
                    # Ubuntu/Debian 需要版本代号
                    if [[ -z "$OS_CODENAME" ]]; then
                        error "无法获取系统版本代号（VERSION_CODENAME），请检查 /etc/os-release。"
                        continue
                    fi
                    switch_apt_source "$MIRROR_BASE" "$OS_CODENAME"
                else
                    switch_yum_source "$MIRROR_BASE"
                fi
                log_action "软件源切换为 ${MIRROR_NAME}"
                pause
                ;;
            2)
                restore_default_source
                log_action "恢复系统默认软件源"
                pause
                ;;
            0) return 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 模块 4：维护工具
# ============================================================

# 配置备份与回滚
manage_backups() {
    echo -e "\n${CYAN}===== 配置备份与回滚 =====${NC}"
    local i=1
    local -a backups=()
    local f b
    # 扫描受管文件的备份，按修改时间倒序排列
    for f in "${MANAGED_FILES[@]}"; do
        while IFS= read -r b; do
            [[ -z "$b" ]] && continue
            backups+=("$b")
            printf "  %2d) %s\n" "$i" "$b"
            i=$((i+1))
        done < <(ls -1t "${f}".bak_* 2>/dev/null || true)
    done
    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "未找到备份文件"
        return 0
    fi
    local n
    read -rp "选择要回滚的编号（0 取消）: " n
    [[ "$n" == "0" || -z "$n" ]] && return 0
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#backups[@]} )); then
        error "编号无效"; return 1
    fi
    local bak="${backups[$((n-1))]}"
    local orig="${bak%.bak_*}"   # 从备份文件名还原原始路径
    read -rp "确认用 ${bak} 覆盖 ${orig}？[y/N]: " c
    [[ "$c" != "y" && "$c" != "Y" ]] && { info "已取消"; return 0; }
    cp -a "$bak" "$orig"
    log_action "回滚 ${orig} 从 ${bak}"
    info "已回滚 ${orig}"
}

# 查看操作日志（最近 50 条）
show_action_log() {
    echo -e "\n${CYAN}===== 操作日志（最近 50 条）=====${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 50 "$LOG_FILE"
    else
        warn "暂无日志（${LOG_FILE} 不存在）"
    fi
}

# ============================================================
# 菜单与主流程
# ============================================================

# 主菜单顶部系统摘要
show_summary() {
    local ip ssh_ports
    ip=$(get_local_ip || true)
    # 读取 sshd_config 中显式配置的端口（grep 无匹配会返回非零，必须 || true，
    # 否则配合 set -e -o pipefail 会导致主菜单直接退出）
    ssh_ports=$(grep -E "^[[:space:]]*Port[[:space:]]+" /etc/ssh/sshd_config 2>/dev/null \
                | awk '{print $2}' | sort -u | tr '\n' ' ' || true)
    echo -e "${CYAN}----------------------------------------${NC}"
    echo -e " 时间   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo -e " 主机   : $(hostname)  IP: ${ip:-N/A}"
    echo -e " SSH   : 端口 ${ssh_ports:-22 (默认)}"
    echo -e " 系统   : $(get_os_info; echo "${OS_PRETTY}")"
    echo -e " 防火墙 : $(detect_firewall)"
    echo -e "${CYAN}----------------------------------------${NC}"
}

# 1) SSH 管理
ssh_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}            SSH 管理${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo "  1) 修改 SSH 端口"
        echo "  2) 修改 SSH 用户密码"
        echo "  0) 返回主菜单"
        echo -e "${CYAN}========================================${NC}"
        read -rp "请选择 [0-2]: " c
        case "$c" in
            1) change_ssh_port; pause ;;
            2) change_ssh_password; pause ;;
            0) return 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

# 2) 网络管理
network_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}            网络管理${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo "  1) 修改 DNS 服务器"
        echo "  2) 端口放行 / 禁止管理"
        echo "  3) IPv4 / IPv6 优先级与开关"
        echo "  4) 开启 / 禁用 Ping 响应"
        echo "  5) 防火墙总开关"
        echo "  6) hosts 管理"
        echo "  7) 网络诊断工具"
        echo "  8) 端口占用查看"
        echo "  0) 返回主菜单"
        echo -e "${CYAN}========================================${NC}"
        echo -e "  防火墙: $(detect_firewall)"
        read -rp "请选择 [0-8]: " c
        case "$c" in
            1) change_dns; pause ;;
            2) manage_ports ;;
            3) configure_ip_stack ;;
            4) toggle_ping; pause ;;
            5) firewall_toggle; pause ;;
            6) manage_hosts ;;
            7) network_diagnostics; pause ;;
            8) show_port_usage; pause ;;
            0) return 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

# 3) 系统设置
system_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}            系统设置${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo "  1) 时间与时区管理"
        echo "  2) 磁盘 / 内存概览"
        echo "  3) 软件源切换"
        echo "  0) 返回主菜单"
        echo -e "${CYAN}========================================${NC}"
        echo -e "  当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        read -rp "请选择 [0-3]: " c
        case "$c" in
            1) manage_time ;;
            2) show_disk_mem; pause ;;
            3) manage_software_source ;;
            0) return 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

# 4) 维护工具
maintenance_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}            维护工具${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo "  1) 配置备份与回滚"
        echo "  2) 查看操作日志"
        echo "  0) 返回主菜单"
        echo -e "${CYAN}========================================${NC}"
        read -rp "请选择 [0-2]: " c
        case "$c" in
            1) manage_backups; pause ;;
            2) show_action_log; pause ;;
            0) return 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}        Linux 系统配置小工具${NC}"
        echo -e "${CYAN}========================================${NC}"
        show_summary
        echo "  1) SSH 管理      端口 / 密码"
        echo "  2) 网络管理      DNS / 端口 / IP协议 / Ping / 诊断"
        echo "  3) 系统设置      时间 / 磁盘内存 / 软件源"
        echo "  4) 维护工具      备份回滚 / 操作日志"
        echo "  0) 退出"
        echo -e "${CYAN}========================================${NC}"
        read -rp "请选择 [0-4]: " choice
        case "$choice" in
            1) ssh_menu ;;
            2) network_menu ;;
            3) system_menu ;;
            4) maintenance_menu ;;
            0) echo "再见。"; exit 0 ;;
            *) error "无效选项，请重新选择。"; sleep 1 ;;
        esac
    done
}

# 入口
main() {
    main_menu
}

main
