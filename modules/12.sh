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

get_ssh_service_name() {
    if command_exists systemctl; then
        if systemctl list-unit-files | grep -q "^ssh\.service"; then
            echo "ssh"
        elif systemctl list-unit-files | grep -q "^sshd\.service"; then
            echo "sshd"
        else
            echo "ssh"
        fi
    else
        echo "ssh"
    fi
}

# ============================================================
# 模块 12: 保持 SSH 会话连接
# ============================================================

ssh_keepalive() {
    echo -e "${GREEN}正在配置 SSH 保持连接...${RESET}"

    if is_interactive; then
        read -p "请输入每次心跳请求的间隔时间（单位：分钟，默认为5分钟）： " interval
        interval=${interval:-5}
        read -p "请输入客户端最大无响应次数（默认为50次）： " max_count
        max_count=${max_count:-50}
    else
        interval=${interval:-5}
        max_count=${max_count:-50}
    fi

    local interval_seconds=$((interval * 60))
    local ssh_service=$(get_ssh_service_name)

    echo "正在更新 SSH 配置文件..."
    sudo sed -i "/^ClientAliveInterval/c\ClientAliveInterval $interval_seconds" /etc/ssh/sshd_config
    sudo sed -i "/^ClientAliveCountMax/c\ClientAliveCountMax $max_count" /etc/ssh/sshd_config

    echo "正在重启 SSH 服务以应用配置..."
    sudo systemctl restart $ssh_service

    echo -e "${GREEN}配置完成！心跳请求间隔为 $interval 分钟，最大无响应次数为 $max_count。${RESET}"
}

ssh_keepalive
