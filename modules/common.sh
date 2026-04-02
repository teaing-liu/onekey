#!/bin/bash

# ============================================================
# 公共函数库
# ============================================================

# 颜色定义
if [ -z "$GREEN" ]; then
    GREEN="\033[32m"
    RED="\033[31m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    CYAN="\033[36m"
    RESET="\033[0m"
fi

# 系统检测函数
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu|debian)
                SYSTEM="debian"
                ;;
            centos|rhel)
                SYSTEM="centos"
                ;;
            fedora)
                SYSTEM="fedora"
                ;;
            arch)
                SYSTEM="arch"
                ;;
            *)
                SYSTEM="unknown"
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        SYSTEM="centos"
    elif [ -f /etc/fedora-release ]; then
        SYSTEM="fedora"
    else
        SYSTEM="unknown"
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" &> /dev/null
}

# 检查 systemctl 是否可用
has_systemctl() {
    command -v systemctl &> /dev/null && systemctl --version &> /dev/null
}

# 安全执行 systemctl 命令（systemd 不可用时返回失败）
safe_systemctl() {
    if has_systemctl; then
        systemctl "$@"
        return $?
    else
        return 1
    fi
}

# 检查并安装 wget
check_wget() {
    if ! command_exists wget; then
        echo -e "${YELLOW}检测到 wget 缺失，正在安装...${RESET}"
        check_system
        case $SYSTEM in
            debian)
                sudo apt update && sudo apt install -y wget
                ;;
            centos)
                sudo yum install -y wget
                ;;
            fedora)
                sudo dnf install -y wget
                ;;
            *)
                echo -e "${RED}无法识别系统，无法安装 wget${RESET}"
                return 1
                ;;
        esac
    fi
}

# 端口检测
check_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
        return 1
    elif ss -tuln 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# 获取服务器IP
get_server_ip() {
    curl -s4 ifconfig.me 2>/dev/null || curl -s4 api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

# 防火墙放行端口
open_firewall_port() {
    local port=$1
    local protocol=${2:-tcp}

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

# 等待按键继续
wait_for_enter() {
    read -p "按回车键返回主菜单..."
}

# 打印分隔线
print_separator() {
    echo -e "${GREEN}=============================================${RESET}"
}

# ============================================================
# Docker 网络管理函数
# ============================================================

# 创建Docker网络（如果不存在）
ensure_docker_network() {
    local network_name="${1:-npm_net}"
    if docker network inspect "$network_name" >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker 网络 $network_name 已存在${RESET}"
    else
        echo -e "${YELLOW}创建 Docker 网络: $network_name${RESET}"
        docker network create "$network_name"
    fi
}

# 将容器连接到网络
connect_container_to_network() {
    local container_name="$1"
    local network_name="${2:-npm_net}"
    
    if ! docker network inspect "$network_name" >/dev/null 2>&1; then
        ensure_docker_network "$network_name"
    fi
    
    # 检查容器是否已连接
    local connected=$(docker inspect "$container_name" --format="{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}" 2>/dev/null | grep -q "$network_name" && echo "yes" || echo "no")
    
    if [ "$connected" = "no" ]; then
        echo -e "${YELLOW}将容器 $container_name 连接到网络 $network_name${RESET}"
        docker network connect "$network_name" "$container_name" 2>/dev/null || true
    fi
}

# 将容器从网络断开
disconnect_container_from_network() {
    local container_name="$1"
    local network_name="${2:-npm_net}"
    
    if docker network inspect "$network_name" >/dev/null 2>&1; then
        docker network disconnect -f "$network_name" "$container_name" 2>/dev/null || true
    fi
}

# ============================================================
# NPM 反代配置管理函数
# ============================================================

# 清理iptables DROP规则
cleanup_iptables_rules() {
    if command_exists iptables; then
        # 清理DOCKER链中的DROP规则
        iptables -F DOCKER 2>/dev/null || true
        # 添加必要的ACCEPT规则
        for port in 80 443 5555 5700 6688 8080 8081 2022; do
            iptables -A DOCKER -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        done
        # 保存规则
        if command_exists iptables-persistent; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
}

# 保存iptables规则
save_iptables_rules() {
    if command_exists iptables; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# 安装并配置NPM（完整版）
install_npm_full() {
    local npm_port="${1:-81}"
    local data_dir="${2:-/root/npm}"
    
    # 停止现有nginx
    systemctl stop nginx 2>/dev/null || true
    
    # 创建目录
    mkdir -p "$data_dir/data"
    
    # 如果NPM容器已存在，先停止删除
    docker stop npm 2>/dev/null || true
    docker rm npm 2>/dev/null || true
    
    # 确保Docker网络存在
    ensure_docker_network "npm_net"
    
    # 启动NPM容器
    docker run -d --name npm \
        --network npm_net \
        -p 80:80 -p $npm_port:81 -p 443:443 \
        -v "$data_dir/data:/data" \
        -v "$data_dir/letsencrypt:/etc/letsencrypt" \
        chishin/nginx-proxy-manager-zh:latest
    
    echo -e "${YELLOW}等待NPM启动...${RESET}"
    sleep 20
    
    # 清理iptables规则
    cleanup_iptables_rules
    
    # 连接所有Docker服务到npm_net
    local containers=$(docker ps --format '{{.Names}}' | grep -v npm | grep -v '^$' | tr '\n' ' ')
    for container in $containers; do
        connect_container_to_network "$container" "npm_net"
    done
    
    echo -e "${GREEN}NPM安装完成，访问地址: http://$(get_server_ip):$npm_port${RESET}"
    echo -e "${YELLOW}默认用户名: admin@example.com${RESET}"
    echo -e "${YELLOW}默认密码: changeme${RESET}"
}

# 配置NPM反代规则（创建nginx配置文件）
config_npm_proxy() {
    local domain="$1"
    local target_service="$2"  # 例如: nekonekostatus, qinglong, wordpress
    local target_port="$3"     # 例如: 5555, 5700, 80
    
    local config_file="/root/npm/data/nginx/proxy_host/${domain}.conf"
    
    cat > "$config_file" <<EOF
server {
    listen 80;
    server_name $domain;
    location / {
        proxy_pass http://$target_service:$target_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    
    # 通知nginx重载配置
    docker exec npm nginx -s reload 2>/dev/null || true
    
    echo -e "${GREEN}已配置 $domain -> $target_service:$target_port${RESET}"
}

# ============================================================
# Docker 服务安装辅助函数
# ============================================================

# 安装Docker（如果未安装）
install_docker_if_needed() {
    if ! command_exists docker; then
        echo -e "${YELLOW}正在安装 Docker...${RESET}"
        check_system
        
        case $SYSTEM in
            debian|ubuntu)
                sudo apt update -y
                sudo apt install -y curl ca-certificates gnupg lsb-release
                sudo mkdir -p /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/${SYSTEM}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                local codename=$(lsb_release -cs)
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${SYSTEM} ${codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
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
        
        sudo systemctl start docker
        sudo systemctl enable docker
    fi
    
    # 确保Docker运行
    sudo systemctl start docker 2>/dev/null || true
}
