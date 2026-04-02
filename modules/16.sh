#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [ "$SCRIPT_DIR" = "" ]; then
    echo "错误: 无法确定脚本目录"
    exit 1
fi

# ============================================================
# 模块 16: 反代 Nginx Proxy Manager
# ============================================================

install_npm() {
    echo "正在安装 Nginx Proxy Manager 面板..."

    install_docker_if_needed

    if ! systemctl is-active --quiet docker; then
        sudo systemctl start docker
    fi

    local DEFAULT_PORT=81
    if check_port $DEFAULT_PORT; then
        :
    else
        echo -e "${YELLOW}端口 $DEFAULT_PORT 被占用，自动选择新端口...${RESET}"
        DEFAULT_PORT=8080
        while ! check_port $DEFAULT_PORT 2>/dev/null; do
            DEFAULT_PORT=$((DEFAULT_PORT + 1))
            if [ $DEFAULT_PORT -gt 65535 ]; then
                echo -e "${RED}无法找到可用端口${RESET}"
                return 1
            fi
        done
    fi

    open_firewall_port 80
    open_firewall_port 443
    open_firewall_port $DEFAULT_PORT

    # 停止现有nginx
    systemctl stop nginx 2>/dev/null || true
    
    # 创建目录
    mkdir -p /root/npm/data
    
    # 如果NPM容器已存在，先停止删除
    docker stop npm 2>/dev/null || true
    docker rm npm 2>/dev/null || true
    
    # 确保Docker网络存在
    ensure_docker_network "npm_net"
    
    # 拉取镜像
    docker pull chishin/nginx-proxy-manager-zh:latest
    
    # 启动NPM容器（使用host网络模式避免端口冲突）
    docker run -d --name npm \
        --network npm_net \
        -p 80:80 -p $DEFAULT_PORT:81 -p 443:443 \
        -v /root/npm/data:/data \
        -v /root/npm/letsencrypt:/etc/letsencrypt \
        chishin/nginx-proxy-manager-zh:latest

    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}等待NPM启动...${RESET}"
        sleep 20
        
        # 清理iptables规则，确保Docker容器可以访问
        cleanup_iptables_rules
        
        # 连接所有已运行的Docker服务到npm_net网络
        for container in $(docker ps --format '{{.Names}}' | grep -v npm); do
            connect_container_to_network "$container" "npm_net"
        done
        
        # 保存iptables规则
        save_iptables_rules
        
        local server_ip=$(get_server_ip)
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}Nginx Proxy Manager 安装成功！${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${YELLOW}访问地址：http://$server_ip:$DEFAULT_PORT${RESET}"
        echo -e "${YELLOW}默认用户名：admin@example.com${RESET}"
        echo -e "${YELLOW}默认密码：changeme${RESET}"
        echo -e "${YELLOW}安装后请及时修改密码！${RESET}"
    else
        echo -e "${RED}NPM 安装失败！${RESET}"
        return 1
    fi
}

uninstall_npm() {
    echo "正在卸载 Nginx Proxy Manager..."

    if docker ps -a --format '{{.Names}}' | grep -q "^npm$"; then
        docker stop npm
        docker rm npm
    fi

    rm -rf ./data ./letsencrypt /root/npm
    echo -e "${GREEN}卸载完成！${RESET}"
}

# NPM反代配置 - 为指定域名配置反代
config_npm_proxy_rule() {
    local domain="$1"
    local target_service="$2"
    local target_port="$3"
    
    if [ -z "$domain" ] || [ -z "$target_service" ] || [ -z "$target_port" ]; then
        echo -e "${RED}参数不足！用法: config_npm_proxy_rule <域名> <目标服务名> <目标端口>${RESET}"
        return 1
    fi
    
    # 确保NPM在运行
    if ! docker ps --format '{{.Names}}' | grep -q "^npm$"; then
        echo -e "${RED}NPM容器未运行，请先安装NPM！${RESET}"
        return 1
    fi
    
    # 连接目标服务到npm_net
    connect_container_to_network "$target_service" "npm_net"
    
    # 创建反代配置
    local config_file="/root/npm/data/nginx/proxy_host/${domain}.conf"
    mkdir -p "$(dirname "$config_file")"
    
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
    
    # 重载nginx配置
    docker exec npm nginx -s reload 2>/dev/null
    
    echo -e "${GREEN}已配置反代: $domain -> $target_service:$target_port${RESET}"
}

handle_proxy_choice() {
    local proxy_choice=$1
    case $proxy_choice in
        "") ;;
        1)
            echo "=== 手动设置反代需要交互模式，跳过 ==="
            ;;
        2) install_npm ;;
        3) uninstall_npm ;;
        0) return 0 ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
}

proxy_management() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用sudo或root用户运行此脚本${RESET}"
        return 1
    fi

    local choice="${1:-}"
    
    if [ -n "$choice" ]; then
        handle_proxy_choice "$choice"
        return $?
    fi

    while true; do
        echo "=== Nginx 多域名部署管理 ==="
        echo "1) 手动设置反代"
        echo "2) Nginx Proxy Manager 面板安装"
        echo "3) Nginx Proxy Manager 面板卸载"
        echo "4) 返回主菜单"
        read -p "请输入选项 [1-4]: " proxy_choice

        handle_proxy_choice "$proxy_choice"

        if [ "$proxy_choice" = "4" ]; then
            return 0
        fi

        echo -e "${YELLOW}按回车键返回子菜单...${RESET}"
        if [ -t 0 ]; then read -p "" </dev/null || true; fi
    done
}

# 直接调用主函数（被 source 时也会执行）
proxy_management
