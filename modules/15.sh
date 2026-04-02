#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [ "$SCRIPT_DIR" = "" ]; then
    echo "错误: 无法确定脚本目录"
    exit 1
fi

# ============================================================
# 模块 15: 安装探针并绑定域名
# ============================================================

install_probe() {
    local domain="${1:-}"
    local email="${2:-}"
    
    if [ -z "$domain" ]; then
        read -p "请输入您的域名（例如：www.example.com）： " domain
    fi
    while [ -z "$domain" ]; do
        echo -e "${RED}域名不能为空！${RESET}"
        read -p "请输入域名： " domain
    done
    
    if ! [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
        echo -e "${RED}域名格式不正确！${RESET}"
        return 1
    fi
    
    if [ -z "$email" ]; then
        read -p "请输入您的邮箱（用于 Let's Encrypt 证书）： " email
    fi
    while [ -z "$email" ]; do
        echo -e "${RED}邮箱不能为空！${RESET}"
        read -p "请输入邮箱： " email
    done
    
    echo -e "${GREEN}正在安装 NekoNekoStatus 服务器探针并绑定域名...${RESET}"

    install_docker_if_needed

    local container_port=5555
    while ! check_port $container_port 2>/dev/null; do
        echo -e "${YELLOW}端口 $container_port 已被占用，自动选择新端口...${RESET}"
        container_port=$((container_port + 1))
        if [ $container_port -gt 65535 ]; then
            echo -e "${RED}无法找到可用端口${RESET}"
            return 1
        fi
    done
    
    open_firewall_port $container_port

    echo -e "${YELLOW}正在拉取 NekoNekoStatus Docker 镜像...${RESET}"
    docker pull nkeonkeo/nekonekostatus:latest

    echo -e "${YELLOW}正在启动 NekoNekoStatus 容器...${RESET}"
    # 如果npm_net网络存在，加入该网络
    if docker network inspect npm_net >/dev/null 2>&1; then
        docker run --restart=on-failure --name nekonekostatus --network npm_net -p $container_port:5555 -d nkeonkeo/nekonekostatus:latest
    else
        docker run --restart=on-failure --name nekonekostatus -p $container_port:5555 -d nkeonkeo/nekonekostatus:latest
        # 创建npm_net并连接
        ensure_docker_network "npm_net"
        connect_container_to_network "nekonekostatus" "npm_net"
    fi

    echo -e "${YELLOW}正在配置反代...${RESET}"
    
    # 检查是否有NPM在运行
    if docker ps --format '{{.Names}}' | grep -q "^npm$"; then
        echo -e "${YELLOW}检测到NPM已安装，使用NPM配置反代...${RESET}"
        
        # 连接容器到npm_net
        connect_container_to_network "nekonekostatus" "npm_net"
        
        # 使用NPM配置反代
        local config_file="/root/npm/data/nginx/proxy_host/${domain}.conf"
        mkdir -p "$(dirname "$config_file")"
        
        cat > "$config_file" <<EOF
server {
    listen 80;
    server_name $domain;
    location / {
        proxy_pass http://nekonekostatus:5555;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
        docker exec npm nginx -s reload
        echo -e "${GREEN}NPM反代配置完成！${RESET}"
        
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}NekoNekoStatus 安装和域名绑定完成！${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${YELLOW}访问地址：http://$domain${RESET}"
        echo -e "${YELLOW}默认密码: nekonekostatus${RESET}"
        echo -e "${YELLOW}安装后务必修改密码！${RESET}"
        
    else
        # 没有NPM，使用原生Nginx反代
        echo -e "${YELLOW}未检测到NPM，使用原生Nginx配置反代...${RESET}"
        
        if ! command_exists nginx; then
            echo -e "${YELLOW}正在安装 Nginx...${RESET}"
            check_system
            case $SYSTEM in
                debian)
                    sudo apt update -y && sudo apt install -y nginx
                    ;;
                centos)
                    sudo yum install -y nginx
                    ;;
            esac
        fi

        if ! command_exists certbot; then
            echo -e "${YELLOW}正在安装 Certbot...${RESET}"
            check_system
            case $SYSTEM in
                debian)
                    sudo apt install -y certbot python3-certbot-nginx
                    ;;
                centos)
                    sudo yum install -y certbot python3-certbot-nginx
                    ;;
            esac
        fi

        local nginx_was_running=0
        if systemctl is-active --quiet nginx 2>/dev/null; then
            nginx_was_running=1
        fi
        
        if ! check_port 80 2>/dev/null; then
            echo -e "${YELLOW}端口 80 被占用，尝试自动释放...${RESET}"
            systemctl stop nginx 2>/dev/null
            sleep 2
            if ! check_port 80 2>/dev/null; then
                echo -e "${RED}无法释放 80 端口，请先停止占用 80 端口的服务${RESET}"
                if [ "$nginx_was_running" -eq 1 ]; then
                    systemctl start nginx 2>/dev/null
                fi
                return 1
            fi
        fi
        
        local domain_safe="${domain//\//_}"
        
        sudo tee /etc/nginx/sites-available/${domain_safe} > /dev/null <<EOL
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:$container_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

        sudo ln -sf /etc/nginx/sites-available/${domain_safe} /etc/nginx/sites-enabled/
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo nginx -t && sudo systemctl start nginx
        echo -e "${YELLOW}Nginx 配置完成，反代到端口 $container_port${RESET}"

        echo -e "${YELLOW}正在申请 Let's Encrypt 证书...${RESET}"
        if sudo certbot --nginx -d $domain --email $email --agree-tos --non-interactive 2>&1 | grep -q "Certificate not yet due for renewal\|Successfully received certificate"; then
            echo -e "${YELLOW}证书申请成功，配置证书自动续期...${RESET}"
            (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew --quiet && systemctl reload nginx") | crontab -
            echo -e "${GREEN}===========================================${RESET}"
            echo -e "${GREEN}NekoNekoStatus 安装和域名绑定完成！${RESET}"
            echo -e "${GREEN}===========================================${RESET}"
            echo -e "${YELLOW}访问地址：https://$domain${RESET}"
        else
            echo -e "${YELLOW}SSL证书申请失败（可能已达上限），使用HTTP访问${RESET}"
            echo -e "${GREEN}===========================================${RESET}"
            echo -e "${GREEN}NekoNekoStatus 安装完成！${RESET}"
            echo -e "${GREEN}===========================================${RESET}"
            echo -e "${YELLOW}访问地址：http://$domain${RESET}"
        fi
        echo -e "${YELLOW}默认密码: nekonekostatus${RESET}"
        echo -e "${YELLOW}安装后务必修改密码！${RESET}"
    fi
    
    # 保存iptables规则
    save_iptables_rules
}

# 直接调用主函数（被 source 时也会执行）
install_probe
