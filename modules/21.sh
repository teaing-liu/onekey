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

check_network() {
    local targets="google.com 8.8.8.8 baidu.com"
    local retries=3
    local success=0
    for target in $targets; do
        for ((i=1; i<=retries; i++)); do
            ping -c 1 "$target" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                success=1
                break
            fi
            sleep 2
        done
        [ $success -eq 1 ] && break
    done
    return $((1 - success))
}

wait_mysql_ready() {
    local max_wait=60
    local interval=5
    local elapsed=0
    local db_pass=$1
    
    echo -e "${YELLOW}等待 MariaDB 初始化（最多 ${max_wait} 秒）...${RESET}"
    while [ $elapsed -lt $max_wait ]; do
        if docker exec wordpress_mariadb mysqladmin ping -h localhost -u root -p"$db_pass" >/dev/null 2>&1; then
            echo -e "${GREEN}MariaDB 初始化完成！${RESET}"
            return 0
        fi
        echo -e "${YELLOW}检查中，已用时 ${elapsed} 秒...${RESET}"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    echo -e "${RED}MariaDB 初始化超时！${RESET}"
    return 1
}

wordpress_install() {
    check_environment() {
        local port_80=0
        local nginx_installed=0
        local nginx_listening=0
        
        if check_port 80 2>/dev/null; then
            port_80=1
        fi
        
        if command_exists nginx 2>/dev/null; then
            nginx_installed=1
            if pgrep -f "nginx: master" > /dev/null 2>&1; then
                if ss -tlnp 2>/dev/null | grep -q ":80 " || netstat -tlnp 2>/dev/null | grep -q ":80 " 2>/dev/null; then
                    nginx_listening=1
                fi
            fi
        fi
        
        echo "$port_80 $nginx_installed $nginx_listening"
    }
    
    setup_nginx_proxy() {
        local target_port=$1
        local domain=$2
        local enable_https=$3
        
        echo -e "${YELLOW}正在配置 Nginx 反代到端口 $target_port ...${RESET}"
        
        if ! command_exists nginx 2>/dev/null; then
            echo -e "${YELLOW}安装 Nginx...${RESET}"
            sudo apt update -y && sudo apt install -y nginx
        fi
        
        local nginx_was_running=0
        if has_systemctl && systemctl is-active --quiet nginx 2>/dev/null; then
            nginx_was_running=1
        fi
        
        if ! check_port 80 2>/dev/null; then
            echo -e "${YELLOW}端口 80 被占用，尝试自动释放...${RESET}"
            if has_systemctl; then
                systemctl stop nginx 2>/dev/null
            fi
            sleep 2
            if ! check_port 80 2>/dev/null; then
                echo -e "${RED}无法释放 80 端口，请先停止占用 80 端口的服务${RESET}"
                if [ "$nginx_was_running" -eq 1 ] && has_systemctl; then
                    systemctl start nginx 2>/dev/null
                fi
                return 1
            fi
        fi
        
        mkdir -p /etc/nginx/snippets
        
        cat > /tmp/wordpress-proxy-params.conf <<'EOF'
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_buffering off;
proxy_request_buffering off;
proxy_intercept_errors off;
EOF
        sudo mv /tmp/wordpress-proxy-params.conf /etc/nginx/snippets/
        
        if [ -n "$domain" ]; then
            if [ "$enable_https" == "yes" ]; then
                cat > /tmp/wordpress-proxy.conf <<EOF
server {
    server_name $domain;
    
    location / {
        proxy_pass http://127.0.0.1:$target_port;
        include /etc/nginx/snippets/wordpress-proxy-params.conf;
    }

    listen 80;
}
EOF
            else
                cat > /tmp/wordpress-proxy.conf <<EOF
server {
    listen 80;
    server_name $domain;
    
    location / {
        proxy_pass http://127.0.0.1:$target_port;
        include /etc/nginx/snippets/wordpress-proxy-params.conf;
    }
}
EOF
            fi
            sudo mv /tmp/wordpress-proxy.conf /etc/nginx/sites-available/wordpress-$domain
            sudo ln -sf /etc/nginx/sites-available/wordpress-$domain /etc/nginx/sites-enabled/
        else
            local server_ip=$(get_server_ip)
            cat > /tmp/wordpress-proxy.conf <<EOF
server {
    listen 80;
    server_name $server_ip;
    
    location / {
        proxy_pass http://127.0.0.1:$target_port;
        include /etc/nginx/snippets/wordpress-proxy-params.conf;
    }
}
EOF
            sudo mv /tmp/wordpress-proxy.conf /etc/nginx/sites-available/wordpress-ip
            sudo ln -sf /etc/nginx/sites-available/wordpress-ip /etc/nginx/sites-enabled/
        fi
        
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo nginx -t
        if has_systemctl; then
            sudo systemctl start nginx
        fi
        echo -e "${GREEN}Nginx 反代配置完成！${RESET}"
        
        if [ "$enable_https" == "yes" ] && [ -n "$domain" ]; then
            echo -e "${YELLOW}正在配置 SSL 证书...${RESET}"
            if ! command_exists certbot 2>/dev/null; then
                echo -e "${YELLOW}安装 Certbot...${RESET}"
                sudo apt update -y && sudo apt install -y certbot python3-certbot-nginx
            fi
            sudo certbot --nginx -d $domain --non-interactive --agree-tos --email admin@${domain} -m admin@${domain}
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}SSL 证书申请成功！${RESET}"
            else
                echo -e "${RED}SSL 证书申请失败，请手动配置${RESET}"
            fi
        fi
    }
    
    pull_images() {
        local images="nginx:latest wordpress:php8.2-fpm mariadb:10.5"
        for image in $images; do
            if ! docker images | grep -q "$(echo $image | cut -d: -f1)"; then
                echo -e "${YELLOW}拉取镜像 $image...${RESET}"
                if ! docker pull "$image"; then
                    echo -e "${RED}拉取镜像 $image 失败，请检查网络！${RESET}"
                    return 1
                fi
            else
                echo -e "${GREEN}镜像 $image 已存在，跳过${RESET}"
            fi
        done
        return 0
    }
    
    config_systemd_service() {
        echo -e "${YELLOW}配置 WordPress 开机自启服务...${RESET}"
        cat > /tmp/wordpress.service <<'EOF'
[Unit]
Description=WordPress Docker Compose Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/docker-compose -f /home/wordpress/docker-compose.yml up -d
ExecStop=/usr/local/bin/docker-compose -f /home/wordpress/docker-compose.yml down
WorkingDirectory=/home/wordpress
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
        sudo mv /tmp/wordpress.service /etc/systemd/system/
        if has_systemctl; then
            sudo systemctl daemon-reload
            if sudo systemctl enable wordpress.service; then
                echo -e "${GREEN}WordPress 服务已配置为开机自启！${RESET}"
            else
                echo -e "${RED}配置 WordPress 服务失败，请手动检查！${RESET}"
            fi
        fi
    }
    
    install_wordpress() {
        echo -e "${GREEN}正在准备处理 WordPress 安装...${RESET}"

        check_system
        if [ "$SYSTEM" == "unknown" ]; then
            echo -e "${RED}无法识别系统，无法继续操作！${RESET}"
            return 1
        fi

        echo -e "${YELLOW}检测网络连接...${RESET}"
        check_network
        if [ $? -ne 0 ]; then
            echo -e "${RED}网络连接失败，请检查网络后重试！${RESET}"
            return 1
        fi

        local DISK_SPACE=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')
        if [ -z "$DISK_SPACE" ] || [ $(echo "$DISK_SPACE 5" | awk '{if ($1 < $2) print 1; else print 0}') -eq 1 ]; then
            echo -e "${RED}磁盘空间不足（需至少 5G），请清理后再试！当前可用空间：${DISK_SPACE}G${RESET}"
            return 1
        fi

        echo -e "${YELLOW}正在检测 Docker 服务...${RESET}"
        if ! command -v docker > /dev/null 2>&1 || ! has_systemctl || ! systemctl is-active docker > /dev/null 2>&1; then
            if ! command -v docker > /dev/null 2>&1; then
                echo -e "${YELLOW}安装 Docker...${RESET}"
                if [ "$SYSTEM" == "centos" ]; then
                    sudo yum install -y yum-utils
                    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
                else
                    curl -fsSL https://get.docker.com | sh
                fi
            fi
            echo -e "${YELLOW}启动 Docker 服务...${RESET}"
            if has_systemctl; then
                sudo systemctl start docker
                sudo systemctl enable docker
            fi
            if [ $? -ne 0 ]; then
                echo -e "${RED}Docker 服务启动失败，请手动检查！${RESET}"
                return 1
            fi
        fi

        if docker ps -q | grep -q "."; then
            echo -e "${YELLOW}检测到运行中的 Docker 容器${RESET}"
            read -p "是否停止并移除运行中的 Docker 容器以继续安装？（y/n，默认 n）： " stop_containers
            if [ "$stop_containers" == "y" ] || [ "$stop_containers" == "Y" ]; then
                echo -e "${YELLOW}正在停止并移除运行中的 Docker 容器...${RESET}"
                docker stop $(docker ps -q) 2>/dev/null || true
                docker rm $(docker ps -aq) 2>/dev/null || true
            else
                echo -e "${RED}保留运行中的容器，可能导致安装冲突！${RESET}"
            fi
        fi

        echo -e "${YELLOW}请选择操作：${RESET}"
        echo "1) 安装 WordPress"
        echo "2) 卸载 WordPress"
        echo "3) 迁移 WordPress 到新服务器"
        echo "4) 查看证书信息"
        echo "5) 设置定时备份 WordPress"
        read -p "请输入选项（1、2、3、4 或 5）： " operation_choice || operation_choice=""

        case $operation_choice in
            "") ;;
            1)
                echo -e "${GREEN}正在安装 WordPress...${RESET}"

                if [ -d "/home/wordpress" ] && { [ -f "/home/wordpress/docker-compose.yml" ] || [ -d "/home/wordpress/html" ]; }; then
                    echo -e "${YELLOW}检测到 /home/wordpress 已存在 WordPress 文件${RESET}"
                    read -p "是否覆盖重新安装？（y/n，默认 n）： " overwrite
                    if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
                        echo -e "${YELLOW}选择不覆盖，尝试启动现有 WordPress...${RESET}"
                        if [ ! -f "/home/wordpress/docker-compose.yml" ]; then
                            echo -e "${RED}缺少 docker-compose.yml，无法启动现有实例！${RESET}"
                            return 1
                        fi
                        cd /home/wordpress
                        pull_images
                        fix_compose_file
                        COMPOSE_FILE=$(get_compose_file)
                        docker compose $COMPOSE_FILE up -d
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}现有 WordPress 启动成功！${RESET}"
                        fi
                        return 0
                    else
                        echo -e "${YELLOW}将覆盖现有 WordPress 文件...${RESET}"
                        rm -rf /home/wordpress
                        mkdir -p /home/wordpress/{html,mysql,conf.d,logs}
                    fi
                fi

                local DEFAULT_PORT=8080
                local DEFAULT_SSL_PORT=443

                check_port "$DEFAULT_PORT"
                if [ $? -ne 0 ]; then
                    echo -e "${RED}端口 $DEFAULT_PORT 已被占用！${RESET}"
                    read -p "请输入新的 HTTP 端口号（例如 8080）： " new_port
                    while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                        echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                        read -p "请输入新的 HTTP 端口号： " new_port
                    done
                    DEFAULT_PORT=$new_port
                fi

                open_firewall_port $DEFAULT_PORT

                echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
                echo -e "${YELLOW}║         WordPress 配置界面         ║${RESET}"
                echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
                read -p "是否绑定域名？（y/n，默认 n）： " bind_domain
                local DOMAIN=""
                local USE_HTTPS="no"
                if [ "$bind_domain" == "y" ] || [ "$bind_domain" == "Y" ]; then
                    read -p "请输入域名（例如 example.com）： " DOMAIN
                    while [ -z "$DOMAIN" ]; do
                        echo -e "${RED}域名不能为空，请重新输入！${RESET}"
                        read -p "请输入域名： " DOMAIN
                    done
                    read -p "是否启用 HTTPS（需域名指向服务器 IP）？（y/n，默认 n）： " enable_https
                    if [ "$enable_https" == "y" ] || [ "$enable_https" == "Y" ]; then
                        USE_HTTPS="yes"
                        open_firewall_port 443
                    fi
                fi

                echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
                echo -e "${YELLOW}║       MariaDB 用户配置界面        ║${RESET}"
                echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
                while true; do
                    read -p "请输入数据库 ROOT 密码： " db_root_passwd
                    if [ -n "$db_root_passwd" ]; then
                        break
                    else
                        echo -e "${RED}ROOT 密码不能为空，请重新输入！${RESET}"
                    fi
                done
                local db_user="wordpress"
                echo -e "${YELLOW}数据库用户名固定为 'wordpress'${RESET}"
                while true; do
                    read -p "请输入数据库用户密码： " db_user_passwd
                    if [ -n "$db_user_passwd" ]; then
                        break
                    else
                        echo -e "${RED}用户密码不能为空，请重新输入！${RESET}"
                    fi
                done

                echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
                echo -e "${YELLOW}║         系统资源检测界面          ║${RESET}"
                echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
                local TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
                local AVAILABLE_MEM=$(free -m | awk '/^Mem:/ {print $7}')
                local FREE_DISK=$(df -h /home | awk 'NR==2 {print $4}')
                echo -e "${YELLOW}检测结果：${RESET}"
                echo -e "  总内存：${GREEN}${TOTAL_MEM} MB${RESET}"
                echo -e "  可用内存：${GREEN}${AVAILABLE_MEM} MB${RESET}"
                echo -e "  可用磁盘空间：${GREEN}${FREE_DISK}${RESET}"

                echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
                echo -e "${YELLOW}║         选择安装模式界面          ║${RESET}"
                echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
                echo "1) 256MB 极简模式（适合低内存测试，禁用 HTTPS）"
                echo "2) 512MB 标准模式（搭配 512MB Swap，支持 HTTPS）"
                echo "3) 1GB 推荐模式（完整功能，推荐配置）"
                read -p "请输入选项（1、2、3）： " install_mode

                local MINIMAL_MODE=""
                case $install_mode in
                    1)
                        echo -e "${YELLOW}已选择 256MB 极简模式安装${RESET}"
                        MINIMAL_MODE="256"
                        if [ "$TOTAL_MEM" -lt 256 ]; then
                            echo -e "${RED}警告：总内存 $TOTAL_MEM MB 低于 256MB，建议至少 256MB！${RESET}"
                        fi
                        ;;
                    2)
                        echo -e "${YELLOW}已选择 512MB 标准模式安装${RESET}"
                        MINIMAL_MODE="512"
                        if [ "$TOTAL_MEM" -lt 512 ]; then
                            echo -e "${RED}错误：总内存 $TOTAL_MEM MB 低于 512MB，无法使用标准模式！${RESET}"
                            return 1
                        fi
                        if [ ! -f /swapfile ]; then
                            echo -e "${YELLOW}创建并启用 512MB 交换空间...${RESET}"
                            sudo fallocate -l 512M /swapfile
                            sudo chmod 600 /swapfile
                            sudo mkswap /swapfile
                            sudo swapon /swapfile
                            echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
                            echo "vm.swappiness=60" | sudo tee /etc/sysctl.d/99-swappiness.conf
                            sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
                            echo -e "${GREEN}交换空间创建并启用成功！${RESET}"
                            sleep 5
                        else
                            echo -e "${YELLOW}交换空间已存在，尝试启用...${RESET}"
                            sudo swapon /swapfile 2>/dev/null || echo -e "${RED}交换空间启用失败，请检查 /swapfile${RESET}"
                            sleep 5
                        fi
                        ;;
                    3)
                        echo -e "${YELLOW}已选择 1GB 推荐模式安装${RESET}"
                        MINIMAL_MODE="1024"
                        if [ "$TOTAL_MEM" -lt 1024 ]; then
                            echo -e "${RED}错误：总内存 $TOTAL_MEM MB 低于 1GB，无法使用推荐模式！${RESET}"
                            return 1
                        fi
                        ;;
                    *)
                        echo -e "${RED}无效选项，请选择 1、2 或 3！${RESET}"
                        return 1
                        ;;
                esac

                if [ "$AVAILABLE_MEM" -lt 256 ] && [ "$MINIMAL_MODE" != "256" ]; then
                    echo -e "${YELLOW}可用内存 $AVAILABLE_MEM MB 不足 256MB，建议释放内存以提升性能。${RESET}"
                fi

                local FREE_DISK_NUM=$(echo "$FREE_DISK" | sed 's/G.*//' | sed 's/M.*//')
                if [ -n "$FREE_DISK_NUM" ] && [ "$FREE_DISK_NUM" -lt 1 ] 2>/dev/null; then
                    echo -e "${RED}错误：可用磁盘空间不足 1GB，MariaDB 可能无法运行！请释放空间后重试。${RESET}"
                    return 1
                fi

                echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
                echo -e "${YELLOW}║         拉取 Docker 镜像         ║${RESET}"
                echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
                if ! command -v docker-compose > /dev/null 2>&1; then
                    echo -e "${YELLOW}正在安装 Docker Compose...${RESET}"
                    sudo curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                    sudo chmod +x /usr/local/bin/docker-compose
                fi

                pull_images
                if [ $? -ne 0 ]; then
                    echo -e "${RED}镜像拉取失败，请检查网络后重试！${RESET}"
                    return 1
                fi

                mkdir -p /home/wordpress/{html,mysql,conf.d,logs}

                echo -e "${YELLOW}正在配置 ${MINIMAL_MODE}MB 模式...${RESET}"

                if [ "$MINIMAL_MODE" == "256" ]; then
                    cat > /home/wordpress/docker-compose.yml <<EOF
services:
  nginx:
    image: nginx:latest
    container_name: wordpress_nginx
    ports:
      - "$DEFAULT_PORT:80"
    volumes:
      - ./html:/var/www/html
      - ./conf.d:/etc/nginx/conf.d
      - ./logs:/var/log/nginx
    depends_on:
      - wordpress
    restart: unless-stopped
  wordpress:
    image: wordpress:php8.2-fpm
    container_name: wordpress
    volumes:
      - ./html:/var/www/html
    environment:
      WORDPRESS_DB_HOST: mariadb:3306
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: "$db_user_passwd"
      WORDPRESS_DB_NAME: wordpress
      PHP_FPM_PM_MAX_CHILDREN: 2
    depends_on:
      - mariadb
    restart: unless-stopped
  mariadb:
    image: mariadb:10.5
    container_name: wordpress_mariadb
    environment:
      MYSQL_ROOT_PASSWORD: "$db_root_passwd"
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: "$db_user_passwd"
      MYSQL_INNODB_BUFFER_POOL_SIZE: 32M
    volumes:
      - ./mysql:/var/lib/mysql
    restart: unless-stopped
EOF
                else
                    cat > /home/wordpress/docker-compose.yml <<EOF
services:
  nginx:
    image: nginx:latest
    container_name: wordpress_nginx
    ports:
      - "$DEFAULT_PORT:80"
    volumes:
      - ./html:/var/www/html
      - ./conf.d:/etc/nginx/conf.d
      - ./logs:/var/log/nginx
    depends_on:
      - wordpress
    restart: unless-stopped
  wordpress:
    image: wordpress:php8.2-fpm
    container_name: wordpress
    volumes:
      - ./html:/var/www/html
    environment:
      WORDPRESS_DB_HOST: mariadb:3306
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: "$db_user_passwd"
      WORDPRESS_DB_NAME: wordpress
    depends_on:
      - mariadb
    restart: unless-stopped
  mariadb:
    image: mariadb:10.5
    container_name: wordpress_mariadb
    environment:
      MYSQL_ROOT_PASSWORD: "$db_root_passwd"
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: "$db_user_passwd"
      MYSQL_INNODB_BUFFER_POOL_SIZE: 64M
    volumes:
      - ./mysql:/var/lib/mysql
    restart: unless-stopped
EOF
                fi

                cat > /home/wordpress/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOF

                cd /home/wordpress
                fix_compose_file
                COMPOSE_FILE=$(get_compose_file)
                
                echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
                echo -e "${YELLOW}║         启动 MariaDB 服务         ║${RESET}"
                echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
                docker compose $COMPOSE_FILE up -d mariadb
                if [ $? -ne 0 ]; then
                    echo -e "${RED}MariaDB 启动失败，请检查日志！${RESET}"
                    docker compose $COMPOSE_FILE logs mariadb
                    return 1
                fi

                wait_mysql_ready "$db_root_passwd"
                if [ $? -ne 0 ]; then
                    echo -e "${RED}MariaDB 健康检查失败！${RESET}"
                    docker compose $COMPOSE_FILE logs mariadb
                    return 1
                fi

                echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
                echo -e "${YELLOW}║         启动所有服务             ║${RESET}"
                echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
                docker compose $COMPOSE_FILE up -d
                
                echo -e "${YELLOW}等待服务启动（最多 60 秒）...${RESET}"
                local TIMEOUT=60
                local INTERVAL=5
                local ELAPSED=0
                while [ $ELAPSED -lt $TIMEOUT ]; do
                    if docker ps --format '{{.Names}}' | grep -q "wordpress_nginx" && \
                       docker ps --format '{{.Names}}' | grep -q "wordpress" && \
                       docker ps --format '{{.Names}}' | grep -q "wordpress_mariadb"; then
                        echo -e "${GREEN}所有服务启动完成！${RESET}"
                        break
                    fi
                    echo -e "${YELLOW}等待中，已用时 $ELAPSED 秒...${RESET}"
                    sleep $INTERVAL
                    ELAPSED=$((ELAPSED + INTERVAL))
                done

                if [ $ELAPSED -ge $TIMEOUT ]; then
                    echo -e "${RED}服务启动超时，请检查日志！${RESET}"
                    docker compose $COMPOSE_FILE logs
                    return 1
                fi

                local NEEDS_NGINX_PROXY=0
                if [ -n "$DOMAIN" ]; then
                    NEEDS_NGINX_PROXY=1
                elif ! check_port 80 2>/dev/null; then
                    NEEDS_NGINX_PROXY=1
                fi

                if [ "$NEEDS_NGINX_PROXY" -eq 1 ] && [ -n "$DOMAIN" ]; then
                    setup_nginx_proxy $DEFAULT_PORT "$DOMAIN" "$USE_HTTPS"
                fi

                config_systemd_service

                local server_ip=$(get_server_ip)
                echo -e "${GREEN}===========================================${RESET}"
                echo -e "${GREEN}WordPress 安装完成！${RESET}"
                echo -e "${GREEN}===========================================${RESET}"
                
                if [ -n "$DOMAIN" ]; then
                    if [ "$USE_HTTPS" == "yes" ]; then
                        echo -e "${YELLOW}访问地址：https://$DOMAIN${RESET}"
                        echo -e "${YELLOW}后台地址：https://$DOMAIN/wp-admin${RESET}"
                    else
                        echo -e "${YELLOW}访问地址：http://$DOMAIN${RESET}"
                        echo -e "${YELLOW}后台地址：http://$DOMAIN/wp-admin${RESET}"
                    fi
                else
                    echo -e "${YELLOW}访问地址：http://$server_ip:$DEFAULT_PORT${RESET}"
                    echo -e "${YELLOW}后台地址：http://$server_ip:$DEFAULT_PORT/wp-admin${RESET}"
                fi
                echo -e "${YELLOW}数据库用户：wordpress${RESET}"
                echo -e "${YELLOW}数据库密码：$db_user_passwd${RESET}"
                if [ "$MINIMAL_MODE" == "256" ]; then
                    echo -e "${YELLOW}注意：当前为 256MB 极简模式，性能较低，仅适合测试用途！${RESET}"
                fi
                ;;
            2)
                uninstall_wordpress
                ;;
            3)
                migrate_wordpress
                ;;
            4)
                view_ssl_cert
                ;;
            5)
                setup_wordpress_backup
                ;;
            *)
                echo -e "${RED}无效选项，请输入 1、2、3、4 或 5！${RESET}"
                ;;
        esac
    }

    uninstall_wordpress() {
        echo -e "${YELLOW}正在卸载 WordPress...${RESET}"
        if [ ! -d "/home/wordpress" ]; then
            echo -e "${RED}WordPress 安装目录不存在！${RESET}"
            return 1
        fi
        
        cd /home/wordpress || {
            echo -e "${RED}无法进入 WordPress 目录！${RESET}"
            return 1
        }
        
        COMPOSE_FILE=$(get_compose_file)
        docker compose $COMPOSE_FILE down -v 2>/dev/null
        
        for container in wordpress_nginx wordpress wordpress_mariadb; do
            if docker ps -a | grep -q "$container"; then
                docker stop "$container" 2>/dev/null || true
                docker rm "$container" 2>/dev/null || true
            fi
        done
        
        rm -rf /home/wordpress
        
        if [ -f /etc/systemd/system/wordpress.service ]; then
            if has_systemctl; then
                sudo systemctl disable wordpress.service 2>/dev/null
            fi
            sudo rm -f /etc/systemd/system/wordpress.service
            if has_systemctl; then
                sudo systemctl daemon-reload
            fi
        fi
        
        if [ -f /etc/nginx/sites-enabled/wordpress-proxy ]; then
            sudo rm -f /etc/nginx/sites-enabled/wordpress-proxy
        fi
        if [ -f /etc/nginx/sites-enabled/wordpress-ip ]; then
            sudo rm -f /etc/nginx/sites-enabled/wordpress-ip
        fi
        if [ -f /etc/nginx/sites-available/wordpress-proxy ]; then
            sudo rm -f /etc/nginx/sites-available/wordpress-proxy
        fi
        if [ -f /etc/nginx/sites-available/wordpress-ip ]; then
            sudo rm -f /etc/nginx/sites-available/wordpress-ip
        fi
        if [ -f /etc/nginx/snippets/wordpress-proxy.conf ]; then
            sudo rm -f /etc/nginx/snippets/wordpress-proxy.conf
        fi
        ls /etc/nginx/sites-enabled/ 2>/dev/null | grep wordpress | while read site; do
            sudo rm -f /etc/nginx/sites-enabled/$site
            sudo rm -f /etc/nginx/sites-available/$site
        done
        if has_systemctl; then
            sudo systemctl reload nginx 2>/dev/null
        fi
        
        crontab -l 2>/dev/null | grep -v "wordpress_backup.sh" | crontab -
        rm -f /usr/local/bin/wordpress_backup.sh 2>/dev/null
        
        echo -e "${GREEN}WordPress 卸载完成！${RESET}"
    }

    migrate_wordpress() {
        echo -e "${GREEN}=== WordPress 迁移到新服务器 ===${RESET}"

        if [ ! -d "/home/wordpress" ]; then
            echo -e "${RED}当前服务器上没有找到 WordPress 安装！${RESET}"
            return 1
        fi

        local ORIGINAL_DOMAIN=""
        local ORIGINAL_PORT="8080"
        if [ -f /home/wordpress/docker-compose.yml ]; then
            local port_line=$(grep '"' /home/wordpress/docker-compose.yml 2>/dev/null | grep -oE '[0-9]+:80' | head -1)
            if [ -n "$port_line" ]; then
                ORIGINAL_PORT=$(echo "$port_line" | cut -d':' -f1)
            fi
        fi
        if [ -f "/home/wordpress/conf.d/default.conf" ]; then
            local domain_line=$(grep "server_name" /home/wordpress/conf.d/default.conf 2>/dev/null | head -1 | awk '{print $2}' | sed 's/;//')
            if [ -n "$domain_line" ]; then
                ORIGINAL_DOMAIN="$domain_line"
            fi
        fi
        if [ -n "$ORIGINAL_DOMAIN" ] && [ "$ORIGINAL_DOMAIN" != "localhost" ]; then
            echo -e "${YELLOW}检测到原始域名：$ORIGINAL_DOMAIN${RESET}"
        fi

        local NEW_SERVER_IP=""
        read -p "请输入新服务器的 IP 地址： " NEW_SERVER_IP
        while [ -z "$NEW_SERVER_IP" ] || ! ping -c 1 "$NEW_SERVER_IP" > /dev/null 2>&1; do
            echo -e "${RED}IP 地址无效或无法连接，请重新输入！${RESET}"
            read -p "请输入新服务器的 IP 地址： " NEW_SERVER_IP
        done

        local SSH_USER="root"
        read -p "请输入新服务器的 SSH 用户名（默认 root）： " SSH_USER
        SSH_USER=${SSH_USER:-root}

        local SSH_PASS=""
        read -p "请输入新服务器的 SSH 密码（或留空使用 SSH 密钥）： " SSH_PASS
        local SSH_KEY=""
        if [ -z "$SSH_PASS" ]; then
            echo -e "${YELLOW}将使用 SSH 密钥连接${RESET}"
            read -p "请输入本地 SSH 密钥路径（默认 ~/.ssh/id_rsa）： " SSH_KEY
            SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
        fi

        if [ -n "$SSH_PASS" ] && ! command -v sshpass > /dev/null 2>&1; then
            echo -e "${YELLOW}安装 sshpass...${RESET}"
            if [ "$SYSTEM" == "centos" ]; then
                sudo yum install -y epel-release sshpass
            else
                sudo apt update && sudo apt install -y sshpass
            fi
        fi

        echo -e "${YELLOW}测试 SSH 连接...${RESET}"
        if [ -n "$SSH_PASS" ]; then
            sshpass -p "$SSH_PASS" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "echo SSH 连接成功" 2>/tmp/ssh_error
        else
            ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "echo SSH 连接成功" 2>/tmp/ssh_error
        fi
        if [ $? -ne 0 ]; then
            echo -e "${RED}SSH 连接失败！${RESET}"
            cat /tmp/ssh_error
            rm -f /tmp/ssh_error
            return 1
        fi
        rm -f /tmp/ssh_error
        echo -e "${GREEN}SSH 连接成功！${RESET}"

        echo -e "${YELLOW}正在打包 WordPress 数据...${RESET}"
        local BACKUP_FILE="/tmp/wordpress_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
        tar -czf "$BACKUP_FILE" -C /home wordpress

        echo -e "${YELLOW}正在传输到新服务器...${RESET}"
        if [ -n "$SSH_PASS" ]; then
            sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$BACKUP_FILE" "$SSH_USER@$NEW_SERVER_IP:~/" 2>/tmp/scp_error
        else
            scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$BACKUP_FILE" "$SSH_USER@$NEW_SERVER_IP:~/" 2>/tmp/scp_error
        fi
        if [ $? -ne 0 ]; then
            echo -e "${RED}数据传输失败！${RESET}"
            cat /tmp/scp_error
            rm -f "$BACKUP_FILE" /tmp/scp_error
            return 1
        fi
        rm -f "$BACKUP_FILE" /tmp/scp_error

        DEPLOY_SCRIPT=$(mktemp)
        cat > "$DEPLOY_SCRIPT" <<'DEOF'
#!/bin/bash
mkdir -p /home/wordpress
tar -xzf ~/wordpress_backup_*.tar.gz -C /home
cd /home/wordpress

if ! command -v docker > /dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
if command -v systemctl &> /dev/null; then
    systemctl start docker
    systemctl enable docker

for image in nginx:latest wordpress:php8.2-fpm mariadb:10.5; do

if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --add-port=8080/tcp 2>/dev/null
    firewall-cmd --reload 2>/dev/null
elif command -v ufw > /dev/null 2>&1; then
    ufw allow 8080/tcp 2>/dev/null

docker compose up -d
echo "WordPress 部署完成！"
echo "请访问 http://localhost:8080 检查"
DEOF

        echo -e "${YELLOW}在新服务器上部署...${RESET}"
        if [ -n "$SSH_PASS" ]; then
            sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$DEPLOY_SCRIPT" "$SSH_USER@$NEW_SERVER_IP:/tmp/deploy.sh"
            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "bash /tmp/deploy.sh && rm -f /tmp/deploy.sh ~/wordpress_backup_*.tar.gz"
        else
            scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$DEPLOY_SCRIPT" "$SSH_USER@$NEW_SERVER_IP:/tmp/deploy.sh"
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "bash /tmp/deploy.sh && rm -f /tmp/deploy.sh ~/wordpress_backup_*.tar.gz"
        fi
        rm -f "$DEPLOY_SCRIPT"

        echo -e "${GREEN}WordPress 迁移完成！${RESET}"
        echo -e "${YELLOW}请访问 http://$NEW_SERVER_IP 检查 WordPress 是否正常运行${RESET}"
    }

    view_ssl_cert() {
        echo -e "${GREEN}=== 查看 SSL 证书信息 ===${RESET}"

        local cert_dirs="/etc/letsencrypt /etc/nginx/ssl /home/wordpress/certs /root/.acme.sh"

        echo -e "${YELLOW}正在搜索 SSL 证书...${RESET}"
        local found=0
        local found_dir=""

        for cert_dir in $cert_dirs; do
            if [ -d "$cert_dir" ]; then
                echo -e "${GREEN}找到证书目录：$cert_dir${RESET}"
                found=1
                found_dir=$cert_dir
                break
            fi
        done

        if [ $found -eq 0 ]; then
            echo -e "${RED}未找到 SSL 证书目录！${RESET}"
            echo -e "${YELLOW}提示：您可能尚未配置 SSL/HTTPS。${RESET}"
            return 1
        fi

        local CERT_DIR=""
        if [ -d "$found_dir/live" ]; then
            CERT_DIR=$(find "$found_dir/live" -type d -maxdepth 1 2>/dev/null | head -1)
        fi
        
        if [ -z "$CERT_DIR" ] || [ ! -d "$CERT_DIR" ]; then
            echo -e "${RED}未找到有效的证书文件！${RESET}"
            return 1
        fi

        local CERT_FILE="$CERT_DIR/fullchain.pem"
        local KEY_FILE="$CERT_DIR/privkey.pem"

        if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
            echo -e "${RED}证书文件不完整！${RESET}"
            return 1
        fi

        echo -e "${YELLOW}证书目录：$CERT_DIR${RESET}"
        echo ""
        echo -e "${YELLOW}证书文件：${RESET}"
        ls -la "$CERT_FILE" "$KEY_FILE" 2>/dev/null
        
        local START_DATE=$(openssl x509 -startdate -noout -in "$CERT_FILE" 2>/dev/null | cut -d'=' -f2)
        local END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d'=' -f2)
        
        if [ -n "$END_DATE" ]; then
            local EXPIRY_EPOCH=$(date -d "$END_DATE" +%s 2>/dev/null)
            local CURRENT_EPOCH=$(date +%s)
            local DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))
            
            echo ""
            echo -e "${GREEN}=== 证书信息 ===${RESET}"
            echo -e "${YELLOW}申请时间：${START_DATE:-未知}${RESET}"
            echo -e "${YELLOW}到期时间：${END_DATE:-未知}${RESET}"
            echo -e "${YELLOW}剩余天数：${DAYS_LEFT:-0} 天${RESET}"
        fi
    }

    setup_wordpress_backup() {
        echo -e "${GREEN}=== 设置 WordPress 定时备份 ===${RESET}"

        if [ ! -d "/home/wordpress" ]; then
            echo -e "${RED}当前服务器上没有 WordPress 安装！${RESET}"
            return 1
        fi

        echo -e "${YELLOW}请选择备份方式：${RESET}"
        echo "1) 本地备份"
        echo "2) 远程备份（到其他服务器）"
        read -p "请输入选项（1 或 2）： " backup_type

        local BACKUP_DIR="/root/wordpress_backups"
        mkdir -p "$BACKUP_DIR"

        if [ "$backup_type" == "2" ]; then
            local BACKUP_SERVER_IP=""
            read -p "请输入备份目标服务器的 IP 地址： " BACKUP_SERVER_IP
            while [ -z "$BACKUP_SERVER_IP" ] || ! ping -c 1 "$BACKUP_SERVER_IP" > /dev/null 2>&1; do
                echo -e "${RED}IP 地址无效或无法连接！${RESET}"
                read -p "请输入备份目标服务器的 IP 地址： " BACKUP_SERVER_IP
            done

            local BACKUP_SSH_USER="root"
            read -p "请输入目标服务器的 SSH 用户名（默认 root）： " BACKUP_SSH_USER
            BACKUP_SSH_USER=${BACKUP_SSH_USER:-root}

            local BACKUP_SSH_PASS=""
            read -p "请输入目标服务器的 SSH 密码（或留空使用 SSH 密钥）： " BACKUP_SSH_PASS
            local BACKUP_SSH_KEY=""
            if [ -z "$BACKUP_SSH_PASS" ]; then
                read -p "请输入本地 SSH 密钥路径（默认 ~/.ssh/id_rsa）： " BACKUP_SSH_KEY
                BACKUP_SSH_KEY=${BACKUP_SSH_KEY:-~/.ssh/id_rsa}
            fi

            if [ -n "$BACKUP_SSH_PASS" ] && ! command -v sshpass > /dev/null 2>&1; then
                echo -e "${YELLOW}安装 sshpass...${RESET}"
                if [ "$SYSTEM" == "centos" ]; then
                    sudo yum install -y epel-release sshpass
                else
                    sudo apt update && sudo apt install -y sshpass
                fi
            fi

            echo -e "${YELLOW}测试 SSH 连接...${RESET}"
            if [ -n "$BACKUP_SSH_PASS" ]; then
                sshpass -p "$BACKUP_SSH_PASS" ssh -o ConnectTimeout=10 "$BACKUP_SSH_USER@$BACKUP_SERVER_IP" "mkdir -p ~/wordpress_backups" 2>/tmp/ssh_error
            else
                ssh -i "$BACKUP_SSH_KEY" -o ConnectTimeout=10 "$BACKUP_SSH_USER@$BACKUP_SERVER_IP" "mkdir -p ~/wordpress_backups" 2>/tmp/ssh_error
            fi
            if [ $? -ne 0 ]; then
                echo -e "${RED}SSH 连接失败！${RESET}"
                cat /tmp/ssh_error
                rm -f /tmp/ssh_error
                return 1
            fi
            rm -f /tmp/ssh_error
            echo -e "${GREEN}SSH 连接成功！${RESET}"
        fi

        echo -e "${YELLOW}请选择备份频率：${RESET}"
        echo "1) 每天备份"
        echo "2) 每周备份"
        echo "3) 每月备份"
        read -p "请输入选项（1/2/3）： " backup_freq

        local cron_time
        case $backup_freq in
            1) cron_time="0 2 * * *" ;;
            2) cron_time="0 2 * * 0" ;;
            3) cron_time="0 2 1 * *" ;;
            *) echo -e "${RED}无效选项！${RESET}" && return ;;
        esac

        if [ "$backup_type" == "2" ]; then
            cat > /usr/local/bin/wordpress_backup.sh <<'BACKUP_SCRIPT'
#!/bin/bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE=/tmp/wordpress_backup_$TIMESTAMP.tar.gz
tar -czf $BACKUP_FILE -C /home wordpress
if [ -n "$BACKUP_SSH_PASS" ]; then
    sshpass -p "$BACKUP_SSH_PASS" scp -o StrictHostKeyChecking=no $BACKUP_FILE $BACKUP_SSH_USER@$BACKUP_SERVER_IP:~/wordpress_backups/
else
    scp -i "$BACKUP_SSH_KEY" -o StrictHostKeyChecking=no $BACKUP_FILE $BACKUP_SSH_USER@$BACKUP_SERVER_IP:~/wordpress_backups/
if [ $? -eq 0 ]; then
    echo "WordPress 备份成功：$TIMESTAMP" >> /var/log/wordpress_backup.log
else
    echo "WordPress 备份失败：$TIMESTAMP" >> /var/log/wordpress_backup.log
rm -f $BACKUP_FILE
BACKUP_SCRIPT
        else
            cat > /usr/local/bin/wordpress_backup.sh <<'BACKUP_SCRIPT'
#!/bin/bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=BACKUP_DIR_PLACEHOLDER
BACKUP_FILE="$BACKUP_DIR/wordpress_backup_$TIMESTAMP.tar.gz"
tar -czf $BACKUP_FILE -C /home wordpress
if [ $? -eq 0 ]; then
    echo "WordPress 备份成功：$TIMESTAMP" >> /var/log/wordpress_backup.log
    cd "$BACKUP_DIR"
    ls -t wordpress_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null
else
    echo "WordPress 备份失败：$TIMESTAMP" >> /var/log/wordpress_backup.log
BACKUP_SCRIPT
            sed -i "s|BACKUP_DIR_PLACEHOLDER|$BACKUP_DIR|g" /usr/local/bin/wordpress_backup.sh
        fi

        chmod +x /usr/local/bin/wordpress_backup.sh

        crontab -l 2>/dev/null | grep -v "wordpress_backup.sh" | crontab -
        (crontab -l 2>/dev/null; echo "$cron_time /usr/local/bin/wordpress_backup.sh") | crontab -

        echo -e "${GREEN}定时备份已设置！${RESET}"
        echo -e "${YELLOW}备份脚本：/usr/local/bin/wordpress_backup.sh${RESET}"
        echo -e "${YELLOW}日志文件：/var/log/wordpress_backup.log${RESET}"
        if [ "$backup_type" == "2" ]; then
            echo -e "${YELLOW}备份目标：${BACKUP_SSH_USER}@${BACKUP_SERVER_IP}:~/wordpress_backups${RESET}"
        else
            echo -e "${YELLOW}备份目录：$BACKUP_DIR${RESET}"
        fi
        echo ""
        echo -e "${YELLOW}当前备份任务：${RESET}"
        crontab -l | grep wordpress_backup
    }
    
    if [ -n "$1" ]; then
        case "$1" in
            1) install_wordpress "$@" ;;
            2) uninstall_wordpress ;;
            3) migrate_wordpress ;;
            4) view_ssl_cert ;;
            5) setup_wordpress_backup ;;
            *) echo -e "${RED}无效选项！${RESET}" ;;
        esac
        return 0
    fi

    while true; do
        echo -e "${GREEN}=== WordPress 管理 ===${RESET}"
        echo "1) 安装 WordPress"
        echo "2) 卸载 WordPress"
        echo "3) 迁移 WordPress 到新服务器"
        echo "4) 查看证书信息"
        echo "5) 设置定时备份 WordPress"
        echo "0) 返回主菜单"
        read -p "请输入选项（1、2、3、4 或 5）： " operation_choice || operation_choice=""
        case $operation_choice in
            1) install_wordpress ;;
            "") ;;
            2) uninstall_wordpress ;;
            3) migrate_wordpress ;;
            4) view_ssl_cert ;;
            5) setup_wordpress_backup ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" ;;
        esac

        echo -e "${YELLOW}按回车键返回子菜单...${RESET}"
        if [ -t 0 ]; then read -p "" </dev/null || true; fi
    done
}

wordpress_install "$@"
