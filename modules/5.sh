#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

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

get_server_ip() {
    curl -s4 ifconfig.me 2>/dev/null || curl -s4 api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

is_interactive() {
    if [ -t 0 ] && [ -t 1 ]; then
        return 0
    fi
    return 1
}

wait_for_enter() { read -p "按回车键返回主菜单..."; }

install_docker_if_needed() {
    if ! command_exists docker; then
        echo -e "${YELLOW}正在安装 Docker...${RESET}"
        local os_id=""
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            os_id=$ID
        fi
        
        case $os_id in
            ubuntu|debian)
                sudo apt update -y
                sudo apt install -y curl ca-certificates gnupg lsb-release
                sudo mkdir -p /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/${os_id}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                local codename=$(lsb_release -cs)
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                sudo apt update -y
                sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            centos|rhel)
                sudo yum install -y yum-utils
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
                ;;
            fedora)
                sudo dnf -y install dnf-plugins-core
                sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
                sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
                ;;
        esac
        
        sudo systemctl start docker 2>/dev/null || true
        sudo systemctl enable docker 2>/dev/null || true
    fi
}

fix_compose_file() {
    if [ -f "docker compose.yml" ]; then
        echo -e "${YELLOW}发现非标准命名 'docker compose.yml'，正在自动修正为 'docker-compose.yml'...${RESET}"
        mv "docker compose.yml" "docker-compose.yml"
        echo -e "${GREEN}已修正为标准命名 docker-compose.yml${RESET}"
    fi
}

get_compose_file() {
    echo "-f docker-compose.yml"
}

check_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":${port} "; then return 1
    elif ss -tuln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    return 0
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

show_panel_menu() {
    echo -e "${GREEN}=== 面板管理 ===${RESET}"
    echo -e "${YELLOW}请选择操作：${RESET}"
    echo " 1) 安装 1Panel 面板"
    echo " 2) 安装宝塔纯净版"
    echo " 3) 安装宝塔国际版"
    echo " 4) 安装宝塔国内版"
    echo " 5) 安装青龙面板"
    echo " 6) 卸载 1Panel 面板"
    echo " 7) 卸载宝塔面板"
    echo " 8) 卸载青龙面板"
    echo " 9) 一键卸载所有面板"
    echo " 0) 返回主菜单"
    echo ""
}

handle_panel_choice() {
    local panel_choice=$1
    
    case $panel_choice in
        1)
            echo -e "${GREEN}正在安装 1Panel 面板...${RESET}"
            check_system
            case $SYSTEM in
                ubuntu|debian)
                    curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && sudo bash quick_start.sh
                    ;;
                centos)
                    curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
                    ;;
                *)
                    echo -e "${RED}不支持的系统类型！${RESET}"
                    ;;
            esac
            ;;
        2)
            echo -e "${GREEN}正在安装宝塔纯净版...${RESET}"
            check_system
            if [ "$SYSTEM" == "debian" ]; then
                wget -O install.sh https://install.baota.sbs/install/install_6.0.sh && bash install.sh
            elif [ "$SYSTEM" == "centos" ]; then
                yum install -y wget && wget -O install.sh https://install.baota.sbs/install/install_6.0.sh && sh install.sh
            else
                echo -e "${RED}不支持的系统类型！${RESET}"
            fi
            ;;
        3)
            echo -e "${GREEN}正在安装宝塔国际版...${RESET}"
            if command_exists curl; then
                curl -ksSO https://www.aapanel.com/script/install_7.0_en.sh
            else
                wget --no-check-certificate -O install_7.0_en.sh https://www.aapanel.com/script/install_7.0_en.sh
            fi
            bash install_7.0_en.sh aapanel
            ;;
        4)
            echo -e "${GREEN}正在安装宝塔国内版...${RESET}"
            if command_exists curl; then
                curl -sSO https://download.bt.cn/install/install_panel.sh
            else
                wget -O install_panel.sh https://download.bt.cn/install/install_panel.sh
            fi
            bash install_panel.sh ed8484bec
            ;;
        5)
            echo -e "${GREEN}正在安装青龙面板...${RESET}"
            install_docker_if_needed
            local DEFAULT_PORT=5700
            if ! check_port $DEFAULT_PORT; then
                echo -e "${YELLOW}端口 $DEFAULT_PORT 已被占用，自动选择新端口...${RESET}"
                DEFAULT_PORT=5701
                while ! check_port $DEFAULT_PORT 2>/dev/null; do
                    DEFAULT_PORT=$((DEFAULT_PORT + 1))
                    if [ $DEFAULT_PORT -gt 65535 ]; then
                        echo -e "${RED}无法找到可用端口${RESET}"
                        return 1
                    fi
                done
            fi
            open_firewall_port $DEFAULT_PORT
            mkdir -p /home/qinglong
            cd /home/qinglong
            if [ ! -f docker-compose.yml ] && [ ! -f "docker compose.yml" ]; then
                cat > docker-compose.yml <<EOF
version: '3'
services:
  qinglong:
    image: whyour/qinglong:latest
    container_name: qinglong
    restart: unless-stopped
    ports:
      - "${DEFAULT_PORT}:5700"
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - ./data:/data
EOF
            fi
            fix_compose_file
            local COMPOSE_FILE
            COMPOSE_FILE=$(get_compose_file)
            docker compose $COMPOSE_FILE up -d
            echo -e "${GREEN}青龙面板安装完成！${RESET}"
            local server_ip
            server_ip=$(get_server_ip)
            echo -e "${YELLOW}访问 http://${server_ip}:${DEFAULT_PORT} 进行初始化设置${RESET}"
            ;;
        6)
            echo -e "${GREEN}正在卸载 1Panel 面板...${RESET}"
            if command_exists 1pctl; then
                1pctl uninstall
            else
                echo -e "${RED}未检测到 1Panel 面板安装！${RESET}"
            fi
            ;;
        7)
            echo -e "${GREEN}正在卸载宝塔面板...${RESET}"
            if [ -f /usr/bin/bt ] || [ -f /usr/bin/aapanel ]; then
                wget https://download.bt.cn/install/bt-uninstall.sh
                sudo sh bt-uninstall.sh
            else
                echo -e "${RED}未检测到宝塔面板安装！${RESET}"
            fi
            ;;
        8)
            echo -e "${GREEN}正在卸载青龙面板...${RESET}"
            if docker ps -a | grep -q "qinglong"; then
                cd /home/qinglong 2>/dev/null || mkdir -p /home/qinglong
                local COMPOSE_FILE
                COMPOSE_FILE=$(get_compose_file)
                docker compose $COMPOSE_FILE down -v 2>/dev/null
                rm -rf /home/qinglong
            else
                echo -e "${RED}未检测到青龙面板安装！${RESET}"
            fi
            ;;
        9)
            echo -e "${GREEN}正在卸载所有面板...${RESET}"
            if command_exists 1pctl; then
                1pctl uninstall
            fi
            if [ -f /usr/bin/bt ] || [ -f /usr/bin/aapanel ]; then
                wget https://download.bt.cn/install/bt-uninstall.sh
                sudo sh bt-uninstall.sh
            fi
            if docker ps -a | grep -q "qinglong"; then
                cd /home/qinglong 2>/dev/null || mkdir -p /home/qinglong
                local COMPOSE_FILE
                COMPOSE_FILE=$(get_compose_file)
                docker compose $COMPOSE_FILE down -v 2>/dev/null
                rm -rf /home/qinglong
            fi
            echo -e "${GREEN}所有面板卸载完成！${RESET}"
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选项！${RESET}"
            return 1
            ;;
    esac
}

panel_management() {
    if ! is_interactive; then
        echo -e "${YELLOW}检测到非交互模式，显示面板管理菜单${RESET}"
        show_panel_menu
        return 0
    fi
    
    while true; do
        show_panel_menu
        read -p "请输入选项: " panel_choice
        
        if [ -z "$panel_choice" ]; then
            break
        fi
        
        if [[ "$panel_choice" =~ ^[0-9]+$ ]] && [ "$panel_choice" -ge 0 ] && [ "$panel_choice" -le 9 ]; then
            handle_panel_choice "$panel_choice"
            
            if [ "$panel_choice" = "0" ]; then
                break
            fi
            
            wait_for_enter
        else
            echo -e "${RED}无效选项，请输入 0-9 之间的数字${RESET}"
            wait_for_enter
        fi
    done
}

panel_management
