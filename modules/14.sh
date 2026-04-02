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
# 模块 14: 服务器对服务器文件传输
# ============================================================

file_transfer() {
    echo -e "${GREEN}服务器对服务器传文件${RESET}"

    if ! command_exists sshpass; then
        echo -e "${YELLOW}检测到 sshpass 缺失，正在安装...${RESET}"
        check_system
        case $SYSTEM in
            debian)
                sudo apt update && sudo apt install -y sshpass
                ;;
            centos)
                sudo yum install -y sshpass
                ;;
            fedora)
                sudo dnf install -y sshpass
                ;;
        esac
    fi

    read -p "请输入目标服务器IP地址（例如：185.106.96.93）： " target_ip
    read -p "请输入目标服务器SSH端口（默认为22）： " ssh_port
    ssh_port=${ssh_port:-22}
    read -s -p "请输入目标服务器密码：" ssh_password
    echo

    echo -e "${YELLOW}正在验证目标服务器的 SSH 连接...${RESET}"
    sshpass -p "$ssh_password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$ssh_port" root@"$target_ip" "echo 'SSH 连接成功！'" &> /dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SSH 连接验证成功！${RESET}"
        read -p "请输入源文件路径（例如：/root/data/vlive/test.mp4）： " source_file
        read -p "请输入目标文件路径（例如：/root/data/vlive/）： " target_path

        echo -e "${YELLOW}正在传输文件，请稍候...${RESET}"
        sshpass -p "$ssh_password" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$ssh_port" "$source_file" root@"$target_ip":"$target_path"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}文件传输成功！${RESET}"
        else
            echo -e "${RED}文件传输失败，请检查路径和网络连接。${RESET}"
        fi
    else
        echo -e "${RED}SSH 连接失败，请检查以下内容：${RESET}"
        echo -e "${YELLOW}1. 目标服务器 IP 地址是否正确。${RESET}"
        echo -e "${YELLOW}2. 目标服务器的 SSH 服务是否已开启。${RESET}"
        echo -e "${YELLOW}3. 目标服务器的 root 用户密码是否正确。${RESET}"
        echo -e "${YELLOW}4. 目标服务器的防火墙是否允许 SSH 连接。${RESET}"
    fi
}

file_transfer
