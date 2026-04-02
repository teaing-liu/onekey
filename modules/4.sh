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
# 模块 04: 安装无人直播云 SRS
# ============================================================

has_systemctl() { command -v systemctl &> /dev/null; }

install_srs() {
    echo -e "${GREEN}正在安装无人直播云 SRS ...${RESET}"

    check_system

    # 检查并安装 Docker
    if ! command_exists docker; then
        echo -e "${YELLOW}正在安装 Docker...${RESET}"
        case $SYSTEM in
            debian)
                sudo apt update
                sudo apt install -y docker.io
                ;;
            centos)
                sudo yum install -y docker
                if has_systemctl; then
                    sudo systemctl enable docker
                    sudo systemctl start docker
                fi
                ;;
            fedora)
                sudo dnf install -y docker
                if has_systemctl; then
                    sudo systemctl enable docker
                    sudo systemctl start docker
                fi
                ;;
            *)
                echo -e "${RED}无法识别系统，无法安装 Docker！${RESET}"
                return 1
                ;;
        esac
    fi

    # 端口选择
    local mgmt_port
    read -p "请输入要使用的管理端口号 (默认为2022): " mgmt_port
    mgmt_port=${mgmt_port:-2022}

    check_port $mgmt_port
    if [ $? -eq 1 ]; then
        echo -e "${RED}端口 $mgmt_port 已被占用！${RESET}"
        read -p "请输入其他端口号作为管理端口: " mgmt_port
    fi

    sudo apt-get update 2>/dev/null || true

    echo -e "${YELLOW}正在启动 SRS 容器...${RESET}"
    docker run --restart always -d --name srs-stack -it \
        -p $mgmt_port:2022 \
        -p 1935:1935/tcp \
        -p 1985:1985/tcp \
        -p 8080:8080/tcp \
        -p 8000:8000/udp \
        -p 10080:10080/udp \
        -v $HOME/db:/data \
        ossrs/srs-stack:5

    if [ $? -eq 0 ]; then
        local server_ip=$(get_server_ip)
        echo -e "${GREEN}SRS 安装完成！您可以通过以下地址访问管理界面:${RESET}"
        echo -e "${YELLOW}http://$server_ip:$mgmt_port/mgmt${RESET}"
    else
        echo -e "${RED}Docker 安装或启动失败，请手动检查！${RESET}"
    fi
}

install_srs
