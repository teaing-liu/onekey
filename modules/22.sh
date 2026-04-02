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
# 模块 22: 网心云安装
# ============================================================

install_wxy() {
    echo -e "${GREEN}正在安装网心云...${RESET}"

    if ! command_exists docker; then
        echo -e "${YELLOW}检测到 Docker 未安装，正在安装...${RESET}"
        check_system
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
        esac
    fi

    local DEFAULT_PORT=18888
    check_port $DEFAULT_PORT || {
        echo -e "${RED}端口 $DEFAULT_PORT 已被占用！${RESET}"
        read -p "请输入其他端口号： " DEFAULT_PORT
    }

    open_firewall_port $DEFAULT_PORT

    local STORAGE_DIR="/root/wxy"
    sudo mkdir -p "$STORAGE_DIR"
    sudo chmod 755 "$STORAGE_DIR"

    echo -e "${YELLOW}正在拉取网心云镜像...${RESET}"
    docker pull images-cluster.xycloud.com/wxedge/wxedge:latest

    if [ $? -ne 0 ]; then
        echo -e "${RED}拉取网心云镜像失败，请检查网络连接！${RESET}"
        return 1
    fi

    if docker ps -a --format '{{.Names}}' | grep -q "^wxedge$"; then
        docker stop wxedge 2>/dev/null
        docker rm wxedge 2>/dev/null
    fi

    docker run -d --name=wxedge --restart=always --privileged --net=host \
        --tmpfs /run --tmpfs /tmp \
        -v "$STORAGE_DIR:/storage:rw" \
        -e WXEDGE_PORT="$DEFAULT_PORT" \
        images-cluster.xycloud.com/wxedge/wxedge:latest

    if [ $? -eq 0 ]; then
        local server_ip=$(get_server_ip)
        echo -e "${GREEN}网心云安装成功！${RESET}"
        echo -e "${YELLOW}访问地址：http://$server_ip:$DEFAULT_PORT${RESET}"
        echo -e "${YELLOW}存储目录：$STORAGE_DIR${RESET}"
    fi
}

install_wxy
