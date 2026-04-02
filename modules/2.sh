#!/bin/bash

# 公共函数库
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu|debian) SYSTEM="debian" ;;
            centos|rhel) SYSTEM="centos" ;;
            fedora) SYSTEM="fedora" ;;
            arch) SYSTEM="arch" ;;
            *) SYSTEM="unknown" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        SYSTEM="centos"
    elif [ -f /etc/fedora-release ]; then
        SYSTEM="fedora"
    else
        SYSTEM="unknown"
    fi
}

command_exists() { command -v "$1" &> /dev/null; }

check_wget() {
    if ! command_exists wget; then
        echo -e "${YELLOW}检测到 wget 缺失，正在安装...${RESET}"
        check_system
        case $SYSTEM in
            debian) sudo apt update && sudo apt install -y wget ;;
            centos) sudo yum install -y wget ;;
            fedora) sudo dnf install -y wget ;;
            *) echo -e "${RED}无法识别系统，无法安装 wget${RESET}" && return 1 ;;
        esac
    fi
}

check_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":${port} "; then return 1
    elif ss -tuln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    return 0
}

get_server_ip() {
    curl -s4 ifconfig.me 2>/dev/null || curl -s4 api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

open_firewall_port() {
    local port=$1 protocol=${2:-tcp}
    if command_exists ufw; then
        if ufw status | grep -q "Status: active"; then
            sudo ufw allow "${port}/${protocol}" 2>/dev/null
            sudo ufw reload 2>/dev/null
        fi
    elif command_exists firewall-cmd; then
        sudo firewall-cmd --permanent --add-port="${port}/${protocol}" 2>/dev/null
        sudo firewall-cmd --reload 2>/dev/null
    elif command_exists iptables; then
        sudo iptables -A INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null
    fi
}

wait_for_enter() { read -p "按回车键返回主菜单..."; }

is_interactive() {
    if [ -t 0 ] && [ -t 1 ]; then
        return 0
    fi
    return 1
}

check_kernel_version() {
    kernel_version=$(uname -r)
    major_version=$(echo "$kernel_version" | awk -F. '{print $1}')
    minor_version=$(echo "$kernel_version" | awk -F. '{print $2}' | cut -d- -f1)
    if [[ $major_version -lt 5 || ($major_version -eq 5 && $minor_version -lt 6) ]]; then
        echo -e "${RED}当前内核版本 $kernel_version 不支持 BBR v3！${RESET}"
        return 1
    fi
    echo -e "${GREEN}内核版本 $kernel_version 支持 BBR v3。${RESET}"
    return 0
}

check_bbr_status() {
    echo -e "${YELLOW}正在检查 BBR v3 状态...${RESET}"
    if modinfo tcp_bbr >/dev/null 2>&1; then
        if lsmod | grep -q "tcp_bbr"; then
            echo -e "${GREEN}BBR v3 模块 (tcp_bbr) 已加载。${RESET}"
        else
            echo -e "${PURPLE}BBR v3 模块 (tcp_bbr) 未加载，可能未启用。${RESET}"
            return 1
        fi
    else
        echo -e "${RED}BBR v3 模块 (tcp_bbr) 未找到，可能内核不支持！${RESET}"
        return 1
    fi

    current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [ "$current_congestion" = "bbr" ]; then
        echo -e "${PURPLE}拥塞控制算法已设置为 BBR，BBR v3 已成功启动。${RESET}"
    else
        echo -e "${RED}当前拥塞控制算法为 $current_congestion，BBR v3 未成功启动。${RESET}"
        return 1
    fi
    return 0
}

install_bbr_v3() {
    echo -e "${YELLOW}正在安装 BBR v3...${RESET}"
    sudo modprobe tcp_bbr || {
        echo -e "${RED}加载 tcp_bbr 模块失败！${RESET}"
        return 1
    }

    sysctl_file="/etc/sysctl.conf"
    [ -f /etc/centos-release ] && sysctl_file="/etc/sysctl.d/99-bbr.conf"

    echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a "$sysctl_file"
    echo "net.core.default_qdisc = fq" | sudo tee -a "$sysctl_file"
    sudo sysctl -p "$sysctl_file" || {
        echo -e "${RED}应用 sysctl 配置失败！${RESET}"
        return 1
    }

    echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf >/dev/null
    echo -e "${GREEN}已配置 tcp_bbr 模块自动加载。${RESET}"

    check_bbr_status
}

uninstall_bbr() {
    echo -e "${YELLOW}正在卸载当前 BBR 版本...${RESET}"
    sudo modprobe -r tcp_bbr && {
        sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
        echo -e "${GREEN}BBR 版本已卸载！${RESET}"
    }
    sudo rm -f /etc/modules-load.d/bbr.conf 2>/dev/null
}

restore_default_tcp_settings() {
    echo -e "${YELLOW}正在恢复默认 TCP 拥塞控制设置...${RESET}"
    sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
    sudo sysctl -w net.core.default_qdisc=fq
    echo -e "${GREEN}已恢复到默认 TCP 设置。${RESET}"
}

install_original_bbr() {
    echo -e "${YELLOW}正在安装原始 BBR ...${RESET}"
    check_wget
    wget -O /tmp/tcpx.sh "https://github.com/sinian-liu/Linux-NetSpeed-BBR/raw/master/tcpx.sh" && \
    chmod +x /tmp/tcpx.sh && \
    bash /tmp/tcpx.sh && \
    rm -f /tmp/tcpx.sh
}

apply_network_optimizations() {
    echo -e "${YELLOW}正在应用一键网络优化配置...${RESET}"
    sysctl_file="/etc/sysctl.conf"
    [ -f /etc/centos-release ] && sysctl_file="/etc/sysctl.d/99-bbr.conf"

    cat >> "$sysctl_file" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_tw_buckets = 20000
net.ipv4.tcp_tw_reuse = 1
EOF

    sudo sysctl -p "$sysctl_file"

    limits_file="/etc/security/limits.conf"
    [ -f /etc/centos-release ] && limits_file="/etc/security/limits.d/99-custom.conf"

    echo "* soft nofile 1048576" | sudo tee -a "$limits_file"
    echo "* hard nofile 1048576" | sudo tee -a "$limits_file"

    ulimit -n 1048576

    echo -e "${GREEN}一键网络优化完成！${RESET}"
    if is_interactive; then
        read -p "是否立即重启系统以确保配置生效？(y/n): " reboot_choice
        if [[ $reboot_choice == "y" || $reboot_choice == "Y" ]]; then
            sudo reboot
        fi
    else
        echo -e "${YELLOW}非交互模式，跳过重启提示${RESET}"
    fi
}

# ============================================================
# 模块 02: BBR 和 BBR v3 安装与管理
# ============================================================

bbr_management() {
    if ! is_interactive; then
        echo -e "${YELLOW}检测到非交互模式，显示 BBR 管理菜单：${RESET}"
        echo "1) 安装原始 BBR"
        echo "2) 安装 BBR v3"
        echo "3) 卸载当前 BBR 版本"
        echo "4) 检查 BBR 状态"
        echo "5) 应用一键网络优化"
        echo "6) 恢复默认 TCP 设置"
        echo "0) 退出"
        echo ""
        check_bbr_status
        echo -e "${GREEN}请使用交互式终端运行此脚本以获得完整功能${RESET}"
        return 0
    fi

    while true; do
        echo ""
        echo -e "${GREEN}=== BBR 和 BBR v3 管理 ===${RESET}"
        echo "1) 安装原始 BBR"
        echo "2) 安装 BBR v3"
        echo "3) 卸载当前 BBR 版本"
        echo "4) 检查 BBR 状态"
        echo "5) 应用一键网络优化"
        echo "6) 恢复默认 TCP 设置"
        echo "8) 返回主菜单"
        read -p "请输入选项 [1-8]: " bbr_choice

        case $bbr_choice in
            1) install_original_bbr ;;
            2)
                if check_kernel_version; then
                    install_bbr_v3
                fi
                ;;
            3) uninstall_bbr ;;
            4) check_bbr_status ;;
            5) apply_network_optimizations ;;
            6) restore_default_tcp_settings ;;
            8) break ;;
            *) echo -e "${RED}无效选项！${RESET}" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

bbr_management
