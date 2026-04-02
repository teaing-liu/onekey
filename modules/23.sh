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

# ============================================================
# 模块 23: 3X-UI 搭建
# ============================================================

install_3xui() {
    echo -e "${GREEN}正在搭建 3X-UI 并启用 BBR...${RESET}"

    echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p

    if lsmod | grep -q bbr; then
        echo -e "${GREEN}BBR 模块已加载！${RESET}"
    else
        echo -e "${RED}BBR 模块未加载，请检查内核支持！${RESET}"
    fi

    echo -e "${YELLOW}正在下载并运行 3X-UI 安装脚本...${RESET}"

    check_wget

    printf "y\nsinian\nsinian\n5321\na\n" | bash <(curl -Ls https://raw.githubusercontent.com/anjing-liu/3x-ui/master/install.sh)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}3X-UI 搭建完成！${RESET}"
        echo -e "${YELLOW}请访问服务器 IP 的 5321 端口进行管理${RESET}"
    else
        echo -e "${RED}3X-UI 安装失败，请检查网络或脚本输出！${RESET}"
    fi
}

install_3xui
