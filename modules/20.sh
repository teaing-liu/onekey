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

# 检查并修正docker compose配置文件命名
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

is_interactive() {
    if [ -t 0 ] && [ -t 1 ]; then
        return 0
    fi
    return 1
}

get_docker_repo_url() {
    local os_id=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id=$ID
    fi
    
    case $os_id in
        ubuntu) echo "ubuntu" ;;
        debian) echo "debian" ;;
        centos|rhel) echo "centos" ;;
        fedora) echo "fedora" ;;
        *) echo "debian" ;;
    esac
}

install_docker_if_needed() {
    if ! command_exists docker; then
        echo -e "${YELLOW}正在安装 Docker...${RESET}"
        local os_name=$(get_docker_repo_url)
        
        case $os_name in
            debian|ubuntu)
                sudo apt update -y
                sudo apt install -y curl ca-certificates gnupg lsb-release
                sudo mkdir -p /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/${os_name}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                local codename=$(lsb_release -cs)
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_name} ${codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
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
        
        if has_systemctl; then
            sudo systemctl start docker
            sudo systemctl enable docker
        fi
    fi
}

# ============================================================
# 模块 20: Speedtest 测速面板
# ============================================================

install_als() {
    echo -e "${GREEN}正在安装 ALS 测速面板...${RESET}"

    install_docker_if_needed

    local DEFAULT_PORT=80
    check_port $DEFAULT_PORT || DEFAULT_PORT=8080

    open_firewall_port $DEFAULT_PORT

    cd /home && mkdir -p web
    cat > /home/web/docker-compose.yml <<EOF
services:
  als:
    image: wikihostinc/looking-glass-server:latest
    container_name: als_speedtest_panel
    ports:
      - "$DEFAULT_PORT:80"
    restart: always
EOF

    cd /home/web
    fix_compose_file
    COMPOSE_FILE=$(get_compose_file)
    docker compose $COMPOSE_FILE up -d

    local server_ip=$(get_server_ip)
    echo -e "${GREEN}ALS 测速面板安装完成！${RESET}"
    echo -e "${YELLOW}访问 http://$server_ip:$DEFAULT_PORT${RESET}"
}

install_speedtest() {
    echo -e "${GREEN}正在安装 SpeedTest 测速面板...${RESET}"

    install_docker_if_needed

    local DEFAULT_PORT=6688
    if ! check_port $DEFAULT_PORT; then
        echo -e "\${YELLOW}端口 6688 被占用，将自动选择可用端口...\${RESET}"
        for PORT in 8080 8081 8082 8083 8084 8085 8086 8087 8088 8089; do
            if check_port $PORT; then
                DEFAULT_PORT=$PORT
                break
            fi
        done
    fi

    open_firewall_port $DEFAULT_PORT

    cd /home && mkdir -p speedtest
    cat > /home/speedtest/docker-compose.yml <<EOF
services:
  speedtest:
    image: ilemonrain/html5-speedtest:alpine
    container_name: speedtest_html5_panel
    ports:
      - "$DEFAULT_PORT:80"
    restart: always
EOF

    cd /home/speedtest
    fix_compose_file
    COMPOSE_FILE=$(get_compose_file)
    docker compose $COMPOSE_FILE up -d

    local server_ip=$(get_server_ip)
    echo -e "${GREEN}SpeedTest 测速面板安装完成！${RESET}"
    echo -e "${YELLOW}访问 http://$server_ip:$DEFAULT_PORT${RESET}"
}

uninstall_speedtest() {
    local name=$1
    local path=$2

    if [ -d "$path" ]; then
        cd "$path"
        if [ -f "docker-compose.yml" ] || [ -f "docker compose.yml" ]; then
            COMPOSE_FILE=$(get_compose_file)
            docker compose $COMPOSE_FILE down -v 2>/dev/null
        fi
        cd /
        rm -rf "$path"
    fi

    if docker ps -a | grep -q "$name"; then
        docker stop "$name" 2>/dev/null
        docker rm "$name" 2>/dev/null
    fi
}

handle_speedtest_choice() {
    local choice=$1
    case $choice in
        1) install_als ;;
        2) uninstall_speedtest "als_speedtest_panel" "/home/web" ;;
        3) install_speedtest ;;
        4) uninstall_speedtest "speedtest_html5_panel" "/home/speedtest" ;;
        0) return 0 ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
}

speedtest_panel() {
    local choice="${1:-}"
    
    if [ -n "$choice" ]; then
        handle_speedtest_choice "$choice"
        return $?
    fi

    while true; do
        echo -e "${GREEN}=== Speedtest 测速面板管理 ===${RESET}"
        echo "1) 安装 ALS 测速面板"
        echo "2) 卸载 ALS 测速面板"
        echo "3) 安装 SpeedTest 测速面板"
        echo "4) 卸载 SpeedTest 测速面板"
        echo "0) 返回主菜单"
        
        # 检查是否有残留输入
        local operation_choice=""
        if [ -t 0 ]; then
            read -p "请输入选项: " operation_choice
        else
            # 在非终端中，尝试读取一行
            if read -r operation_choice; then
                : # 成功读取
            else
                operation_choice=""
            fi
        fi

        case $operation_choice in
            "") ;;
            1) install_als ;;
            2) uninstall_speedtest "als_speedtest_panel" "/home/web" ;;
            3) install_speedtest ;;
            4) uninstall_speedtest "speedtest_html5_panel" "/home/speedtest" ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" ;;
        esac

        echo -e "${YELLOW}按回车键返回子菜单...${RESET}"
        if [ -t 0 ]; then if [ -t 0 ]; then read -p "" </dev/null || true; fi; fi
    done
}

speedtest_panel
