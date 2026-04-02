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
has_systemctl() { command -v systemctl &> /dev/null; }

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
# 模块 24: S-UI 搭建
# ============================================================

install_sui() {
    echo -e "${GREEN}正在安装 s-ui ...${RESET}"

    printf "y\n2095\n/app/\n2096\n/sub/\ny\nsinian\nsinian\n" | bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}s-ui 安装成功！${RESET}"

        if has_systemctl; then
            systemctl restart s-ui 2>/dev/null
        fi

        local server_ip=$(get_server_ip)
        echo -e "${YELLOW}面板地址：http://$server_ip:2095/app/${RESET}"
        echo -e "${YELLOW}订阅地址：http://$server_ip:2096/sub/${RESET}"
        echo -e "${YELLOW}用户名：sinian${RESET}"
        echo -e "${YELLOW}密码：sinian${RESET}"
    else
        echo -e "${RED}s-ui 安装失败，请检查网络！${RESET}"
    fi
}

install_sui
