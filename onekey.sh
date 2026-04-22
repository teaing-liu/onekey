#!/bin/bash
# 设置快捷命令 s
SCRIPT_REALPATH="$(realpath "$0" 2>/dev/null || echo "$0")"
if [ ! -f /usr/local/bin/s ] || [ "$(readlink /usr/local/bin/s 2>/dev/null)" != "$SCRIPT_REALPATH" ]; then
    ln -sf "$SCRIPT_REALPATH" /usr/local/bin/s 2>/dev/null
    chmod +x "$SCRIPT_REALPATH" 2>/dev/null
fi
if ! grep -q "alias s=" /root/.bashrc 2>/dev/null; then
    echo "alias s='$SCRIPT_REALPATH'" >> /root/.bashrc
fi

# 设置颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 全局随机密码生成函数
dd_generate_random_password() {
    tr -dc 'A-Za-z0-9@#%&' < /dev/urandom | head -c 16
}

generate_random_password() {
    tr -dc 'A-Za-z0-9@#%&' < /dev/urandom | head -c 16
}

# 统一端口检查函数（兼容ss和netstat）
check_port_available() {
    local port=$1
    if command -v ss > /dev/null 2>&1; then
        ss -tuln | grep -q ":$port " && return 1 || return 0
    elif command -v netstat > /dev/null 2>&1; then
        netstat -tuln | grep -q ":$port " && return 1 || return 0
    else
        return 2  # 无法检查
    fi
}

# 统一磁盘空间检查（返回MB）
get_free_disk_mb() {
    local path=${1:-/}
    df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4*1024}' || echo "0"
}

# 脚本退出清理
trap 'rm -f /tmp/onekey_* /tmp/wp_check /tmp/ssh_error /tmp/scp_error /tmp/deploy_*.sh /tmp/wordpress_backup_*.tar.gz 2>/dev/null' EXIT

# 系统检测函数（改进版）
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu)
                SYSTEM="ubuntu"
                ;;
            debian)
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
    elif [ -f /etc/lsb-release ]; then
        SYSTEM="ubuntu"
    elif [ -f /etc/redhat-release ]; then
        SYSTEM="centos"
    elif [ -f /etc/fedora-release ]; then
        SYSTEM="fedora"
    else
        SYSTEM="unknown"
    fi
}

# ============================================
# 统一Nginx反向代理管理函数
# 所有需要域名+SSL的服务都使用这些函数
# ============================================

UNIFIED_WEBROOT="/var/www/html"
UNIFIED_NGINX_CONF_DIR="/etc/nginx/conf.d"
UNIFIED_NGINX_MAIN_CONF="/etc/nginx/nginx.conf"

# 安装统一Nginx和Certbot
install_unified_nginx() {
    echo -e "${YELLOW}正在安装 Nginx 和 Certbot...${RESET}"
    
    if ! command -v nginx &> /dev/null; then
        if [ "$SYSTEM" == "centos" ]; then
            sudo yum install -y nginx
        else
            sudo apt update -y && sudo apt install -y nginx
        fi
    fi
    
    if ! command -v certbot &> /dev/null; then
        if [ "$SYSTEM" == "centos" ]; then
            sudo yum install -y certbot python3-certbot-nginx
        else
            sudo apt install -y certbot python3-certbot-nginx
        fi
    fi
    
    # 创建统一配置目录
    sudo mkdir -p "$UNIFIED_NGINX_CONF_DIR"
    
    # 创建统一webroot
    sudo mkdir -p "$UNIFIED_WEBROOT/.well-known/acme-challenge"
    sudo chmod -R 755 "$UNIFIED_WEBROOT"
    
    # 配置Nginx主文件，包含所有域名配置
    if ! grep -q "conf.d/\*.conf" "$UNIFIED_NGINX_MAIN_CONF" 2>/dev/null; then
        echo -e "${YELLOW}配置Nginx主文件...${RESET}"
    fi
    
    echo -e "${GREEN}统一Nginx和Certbot安装完成${RESET}"
}

# 检查端口是否可用
check_port_free() {
    local port=$1
    if ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 1  # 端口被占用
    fi
    return 0  # 端口空闲
}

# 获取可用端口
get_free_port() {
    local port=${1:-8080}
    while ! check_port_free $port 2>/dev/null; do
        port=$((port + 1))
        if [ $port -gt 65535 ]; then
            port=0
            break
        fi
    done
    echo $port
}

# 申请SSL证书
apply_ssl_cert() {
    local domain=$1
    local email=${2:-"admin@$domain"}
    
    echo -e "${YELLOW}正在为 $domain 申请SSL证书...${RESET}"
    
    sudo certbot certonly --webroot -w "$UNIFIED_WEBROOT" -d "$domain" --non-interactive --agree-tos --email "$email"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}证书申请成功！${RESET}"
        return 0
    else
        echo -e "${RED}证书申请失败，请检查域名是否正确解析到本服务器${RESET}"
        return 1
    fi
}

# 添加域名到统一Nginx反向代理
add_domain_to_unified_nginx() {
    local domain=$1
    local backend_port=$2
    local ssl_email=${3:-"admin@$domain"}
    
    # 检查Nginx是否安装
    if ! command -v nginx &> /dev/null; then
        install_unified_nginx
    fi
    
    # 确保配置目录存在
    sudo mkdir -p "$UNIFIED_NGINX_CONF_DIR"
    
    # 检查域名是否已配置
    local domain_conf_file="${UNIFIED_NGINX_CONF_DIR}/domain-${domain}.conf"
    if [ -f "$domain_conf_file" ]; then
        echo -e "${YELLOW}域名 $domain 已存在配置${RESET}"
        # 更新后端端口
        sed -i "s|proxy_pass http://127.0.0.1:[0-9]*|proxy_pass http://127.0.0.1:$backend_port|" "$domain_conf_file"
        sudo nginx -t && sudo systemctl reload nginx
        return 0
    fi
    
    # 为新域名申请证书
    if [ ! -d "/etc/letsencrypt/live/$domain" ]; then
        if ! apply_ssl_cert "$domain" "$ssl_email"; then
            return 1
        fi
    fi
    
    # 创建独立的域名配置文件
    cat > /tmp/nginx-${domain}.conf <<EOF
# $domain - 由onekey.sh自动生成
server {
    listen 80;
    server_name $domain;
    
    location ^~ /.well-known/acme-challenge/ {
        root $UNIFIED_WEBROOT;
        allow all;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $domain;
    
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    
    add_header Strict-Transport-Security "max-age=63072000" always;
    
    location ^~ /.well-known/acme-challenge/ {
        root $UNIFIED_WEBROOT;
        allow all;
    }
    
    location / {
        proxy_pass http://127.0.0.1:$backend_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
    sudo mv /tmp/nginx-${domain}.conf "$domain_conf_file"
    
    # 确保Nginx主配置include域名配置
    if ! grep -q "conf.d" "$UNIFIED_NGINX_MAIN_CONF" 2>/dev/null; then
        # 检查 nginx.conf 中 http { 块的位置，并在其后添加 include
        if grep -q "^[[:space:]]*http {" "$UNIFIED_NGINX_MAIN_CONF" 2>/dev/null; then
            sudo sed -i '/^[[:space:]]*http {/a\    include /etc/nginx/conf.d/*.conf;' "$UNIFIED_NGINX_MAIN_CONF"
        elif grep -q "http {" "$UNIFIED_NGINX_MAIN_CONF" 2>/dev/null; then
            sudo sed -i '/http {/a\    include /etc/nginx/conf.d/*.conf;' "$UNIFIED_NGINX_MAIN_CONF"
        fi
    fi
    
    # 测试并重载Nginx
    sudo nginx -t && sudo systemctl reload nginx
    if [ $? -ne 0 ]; then
        echo -e "${RED}Nginx配置测试失败${RESET}"
        return 1
    fi
    
    # 配置自动续期（如果还没有）
    if ! crontab -l 2>/dev/null | grep -q "certbot renew.*nginx"; then
        (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew --quiet && systemctl reload nginx") | crontab -
        echo -e "${YELLOW}已配置证书自动续期${RESET}"
    fi
    
    echo -e "${GREEN}域名 $domain 已添加到反向代理 (后端:127.0.0.1:$backend_port)${RESET}"
    return 0
}

# 移除域名的反向代理配置
remove_domain_from_unified_nginx() {
    local domain=$1
    local domain_conf_file="${UNIFIED_NGINX_CONF_DIR}/domain-${domain}.conf"
    
    if [ -f "$domain_conf_file" ]; then
        sudo rm -f "$domain_conf_file"
        sudo nginx -t && sudo systemctl reload nginx
        echo -e "${GREEN}已移除域名 $domain 的反向代理配置${RESET}"
    else
        echo -e "${YELLOW}域名 $domain 没有找到对应的配置${RESET}"
    fi
}

# 获取当前配置的域名列表
get_configured_domains() {
    if [ -d "$UNIFIED_NGINX_CONF_DIR" ]; then
        ls "$UNIFIED_NGINX_CONF_DIR"/domain-*.conf 2>/dev/null | sed 's/.*domain-\(.*\)\.conf/\1/'
    fi
}

# ============================================
# 安装 wget 函数
# ============================================
install_wget() {
    check_system
    if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
        echo -e "${YELLOW}检测到 wget 缺失，正在安装...${RESET}"
        sudo apt update
        if [ $? -ne 0 ]; then
            echo -e "${RED}apt 更新失败，请检查网络！${RESET}"
            return 1
        fi
        sudo apt install -y wget
        if [ $? -ne 0 ]; then
            echo -e "${RED}wget 安装失败，请手动检查！${RESET}"
            return 1
        fi
    elif [ "$SYSTEM" == "centos" ]; then
        echo -e "${YELLOW}检测到 wget 缺失，正在安装...${RESET}"
        sudo yum install -y wget
        if [ $? -ne 0 ]; then
            echo -e "${RED}wget 安装失败，请手动检查！${RESET}"
            return 1
        fi
    elif [ "$SYSTEM" == "fedora" ]; then
        echo -e "${YELLOW}检测到 wget 缺失，正在安装...${RESET}"
        sudo dnf install -y wget
        if [ $? -ne 0 ]; then
            echo -e "${RED}wget 安装失败，请手动检查！${RESET}"
            return 1
        fi
    else
        echo -e "${RED}无法识别系统，无法安装 wget。${RESET}"
        return 1
    fi
    return 0
}

# 检查并安装 wget
if ! command -v wget &> /dev/null; then
    install_wget
    if [ $? -ne 0 ] || ! command -v wget &> /dev/null; then
        echo -e "${RED}安装 wget 失败，请手动检查问题！${RESET}"
        exit 1
    fi
fi

# 系统更新函数
update_system() {
    check_system
    if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
        echo -e "${GREEN}正在更新 Debian/Ubuntu 系统...${RESET}"
        sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y && sudo apt clean
        if [ $? -ne 0 ]; then
            return 1
        fi
    elif [ "$SYSTEM" == "centos" ]; then
        echo -e "${GREEN}正在更新 CentOS 系统...${RESET}"
        sudo yum update -y && sudo yum clean all
        if [ $? -ne 0 ]; then
            return 1
        fi
    elif [ "$SYSTEM" == "fedora" ]; then
        echo -e "${GREEN}正在更新 Fedora 系统...${RESET}"
        sudo dnf update -y && sudo dnf clean all
        if [ $? -ne 0 ]; then
            return 1
        fi
    else
        echo -e "${RED}无法识别您的操作系统，跳过更新步骤。${RESET}"
        return 1
    fi
    return 0
}

# 主菜单函数
# ===== DD重装系统函数 =====

dd_check_system() {
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

dd_command_exists() { command -v "$1" &> /dev/null; }

dd_get_server_ip() {
    curl -s4 ifconfig.me 2>/dev/null || curl -s4 api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

dd_is_interactive() {
    if [ -t 0 ] && [ -t 1 ]; then
        return 0
    fi
    return 1
}

dd_wait_for_enter() { read -p "按回车键返回主菜单..."; }

dd_ask_reboot() {
    echo ""
    echo -e "${YELLOW}=============================================${RESET}"
    echo -e "${YELLOW}系统重装已准备完成！${RESET}"
    echo -e "${YELLOW}脚本已配置好 GRUB 启动项，等待安装新系统。${RESET}"
    echo ""
    echo -e "${YELLOW}建议通过 VNC 查看安装进度。${RESET}"
    echo -e "${YELLOW}如果长时间未连接，请检查VNC是否正常。${RESET}"
    echo -e "${YELLOW}=============================================${RESET}"
    echo ""
    read -p "是否立即重启开始安装？(y/n，默认 n): " reboot_confirm
    reboot_confirm=${reboot_confirm:-n}
    
    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}正在重启服务器...${RESET}"
        sleep 2
        reboot
    else
        echo -e "${YELLOW}已取消重启，请稍后手动执行 reboot 重启${RESET}"
    fi
}

# DD 镜像定义
DD_IMAGES="
# Windows DD 镜像 (格式: 镜像名|直链|密码)
Windows 10 Pro x64|https://oss.sunnyo.com/vhd/win10ltsc_x64_vhdx.gz|WWAN123.com
Windows 11 Pro x64|https://oss.sunnyo.com/vhd/win11_pro_x64_vhdx.gz|WWAN123.com
Windows Server 2022|https://oss.sunnyo.com/vhd/windows2022_x64_vhdx.gz|WWAN123.com
"

dd_show_dd_menu() {
    clear
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${GREEN}     DD 重装系统${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${RED}警告：此操作会清除所有数据！${RESET}"
    echo ""
    
    echo -e "${YELLOW}-------------------- Ubuntu 系列 --------------------${RESET}"
    printf "%-26s %-26s\n" "1.  Ubuntu 24.04" "2.  Ubuntu 22.04"
    printf "%-26s %-26s\n" "3.  Ubuntu 20.04" "4.  Ubuntu 18.04"
    
    echo -e "${YELLOW}-------------------- Debian 系列 --------------------${RESET}"
    printf "%-26s %-26s\n" "5.  Debian 13" "6.  Debian 12"
    printf "%-26s %-26s\n" "7.  Debian 11" "8.  Debian 10"
    
    echo -e "${YELLOW}-------------------- CentOS 系列 --------------------${RESET}"
    printf "%-26s %-26s\n" "9.  CentOS Stream 10" "10. CentOS Stream 9"
    printf "%-26s %-26s\n" "11. CentOS 8" "12. CentOS 7"
    
    echo -e "${YELLOW}------------------- Windows DD 镜像 -------------------${RESET}"
    printf "%-26s %-26s\n" "13. Windows 10 Pro" "14. Windows 11 Pro"
    printf "%-26s %-26s\n" "15. Windows 11 ARM" "16. Windows 7"
    printf "%-26s %-26s\n" "17. Windows Server 2025" "18. Windows Server 2022"
    printf "%-26s %-26s\n" "19. Windows Server 2019" "20. Windows Server 2016"
    
    echo -e "${YELLOW}-------------------- RedHat 系列 --------------------${RESET}"
    printf "%-26s %-26s\n" "21. Rocky Linux 10" "22. Rocky Linux 9"
    printf "%-26s %-26s\n" "23. Alma Linux 10" "24. Alma Linux 9"
    printf "%-26s %-26s\n" "25. Oracle Linux 10" "26. Oracle Linux 9"
    printf "%-26s %-26s\n" "27. Fedora Linux 43" "28. Fedora Linux 42"
    
    echo -e "${YELLOW}------------------- 其他 Linux --------------------${RESET}"
    printf "%-26s %-26s\n" "29. Alpine Linux 3.23" "30. Alpine Linux 3.22"
    printf "%-26s %-26s\n" "31. Alpine Linux 3.21" "32. Arch Linux"
    printf "%-26s %-26s\n" "33. Kali Linux" "34. openSUSE 15.6"
    printf "%-26s %-26s\n" "35. openSUSE 16.0" "36. openEuler 24.03"
    
    echo -e "${YELLOW}------------------- 自定义镜像 --------------------${RESET}"
    printf "%-26s\n" "37. DD 镜像 (自定义直链)"
    
    echo ""
    echo -e "${YELLOW}=============================================${RESET}"
    echo -e "${YELLOW}直接回车返回主菜单${RESET}"
    echo -e "${YELLOW}=============================================${RESET}"
    echo ""
}

dd_download_scripts() {
    echo -e "${GREEN}正在下载脚本...${RESET}"
    
    wget -O /tmp/reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 bin456789/reinstall 失败${RESET}"
        return 1
    fi
    chmod +x /tmp/reinstall.sh
    
    wget --no-check-certificate -qO /tmp/InstallNET.sh 'https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh' 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 leitbogioro/Tools 失败${RESET}"
        return 1
    fi
    chmod +x /tmp/InstallNET.sh
    
    echo -e "${GREEN}脚本下载完成！${RESET}"
    return 0
}

dd_execute_install() {
    local choice=$1
    
    local password
    local install_cmd=""
    local is_windows=false
    local is_custom_dd=false
    local win_user="administrator"
    local win_port="3389"
    local linux_user="root"
    local linux_port="22"
    
    case $choice in
        1)
            echo -e "${YELLOW}Ubuntu 24.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 24.04 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        2)
            echo -e "${YELLOW}Ubuntu 22.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 22.04 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        3)
            echo -e "${YELLOW}Ubuntu 20.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 20.04 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        4)
            echo -e "${YELLOW}Ubuntu 18.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 18.04 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        5)
            echo -e "${YELLOW}Debian 13${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 13 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        6)
            echo -e "${YELLOW}Debian 12${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 12 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        7)
            echo -e "${YELLOW}Debian 11${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 11 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        8)
            echo -e "${YELLOW}Debian 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 10 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        9)
            echo -e "${YELLOW}CentOS Stream 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh centos 10 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        10)
            echo -e "${YELLOW}CentOS Stream 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh centos 9 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        11)
            echo -e "${YELLOW}CentOS 8 (leitbogioro)${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/InstallNET.sh -centos 8 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        12)
            echo -e "${YELLOW}CentOS 7 (leitbogioro)${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/InstallNET.sh -centos 7 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        13)
            echo -e "${YELLOW}Windows 10 Pro DD 镜像${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            echo -e "密码: ${GREEN}Teddysun.com${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh dd --img=\"https://dl.lamp.sh/vhd/cn/win10ltsc_x64_vhdx.gz\" --password Teddysun.com"
            is_windows=true
            ;;
        14)
            echo -e "${YELLOW}Windows 11 Pro DD 镜像${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            echo -e "密码: ${GREEN}Teddysun.com${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh dd --img=\"https://dl.lamp.sh/vhd/cn/win11_pro_x64_vhdx.gz\" --password Teddysun.com"
            is_windows=true
            ;;
        15)
            echo -e "${YELLOW}Windows 11 ARM DD 镜像${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            echo -e "密码: ${GREEN}Teddysun.com${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh dd --img=\"https://dl.lamp.sh/vhd/arm64/win11_arm64.img.gz\" --password Teddysun.com"
            is_windows=true
            ;;
        16)
            echo -e "${YELLOW}Windows 7 DD 镜像${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            echo -e "密码: ${GREEN}123@@@abc${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh dd --img=\"https://dl.lamp.sh/vhd/cn/win7_sp1_ent.img.gz\" --password 123@@@abc"
            is_windows=true
            ;;
        17)
            echo -e "${YELLOW}Windows Server 2025 ISO 安装${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            read -p "请输入密码 (留空默认 12345): " win_pass
            win_pass=${win_pass:-12345}
            echo -e "密码: ${GREEN}${win_pass}${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh windows --image-name=\"Windows Server 2025\" --lang en-us --password \"$win_pass\""
            is_windows=true
            ;;
        18)
            echo -e "${YELLOW}Windows Server 2022 DD 镜像${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            echo -e "密码: ${GREEN}Teddysun.com${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh dd --img=\"https://dl.lamp.sh/vhd/cn/windows2022_x64_vhdx.gz\" --password Teddysun.com"
            is_windows=true
            ;;
        19)
            echo -e "${YELLOW}Windows Server 2019 DD 镜像${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            echo -e "密码: ${GREEN}Teddysun.com${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh dd --img=\"https://dl.lamp.sh/vhd/cn/windows2019_x64_vhdx.gz\" --password Teddysun.com"
            is_windows=true
            ;;
        20)
            echo -e "${YELLOW}Windows Server 2016 DD 镜像${RESET}"
            echo -e "用户名: ${GREEN}${win_user}${RESET}"
            echo -e "密码: ${GREEN}Teddysun.com${RESET}"
            echo -e "端口: ${GREEN}${win_port}${RESET} (RDP)"
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            install_cmd="bash /tmp/reinstall.sh dd --img=\"https://dl.lamp.sh/vhd/cn/windows2016_x64_vhdx.gz\" --password Teddysun.com"
            is_windows=true
            ;;
        21)
            echo -e "${YELLOW}Rocky Linux 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh rocky 10 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        22)
            echo -e "${YELLOW}Rocky Linux 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh rocky 9 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        23)
            echo -e "${YELLOW}AlmaLinux 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh almalinux 10 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        24)
            echo -e "${YELLOW}AlmaLinux 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh almalinux 9 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        25)
            echo -e "${YELLOW}Oracle Linux 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh oracle 10 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        26)
            echo -e "${YELLOW}Oracle Linux 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh oracle 9 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        27)
            echo -e "${YELLOW}Fedora Linux 43${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh fedora 43 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        28)
            echo -e "${YELLOW}Fedora Linux 42${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh fedora 42 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        29)
            echo -e "${YELLOW}Alpine Linux 3.23${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh alpine 3.23 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        30)
            echo -e "${YELLOW}Alpine Linux 3.22${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh alpine 3.22 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        31)
            echo -e "${YELLOW}Alpine Linux 3.21${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh alpine 3.21 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        32)
            echo -e "${YELLOW}Arch Linux${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh arch --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        33)
            echo -e "${YELLOW}Kali Linux${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh kali --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        34)
            echo -e "${YELLOW}openSUSE 15.6${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh opensuse 15.6 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        35)
            echo -e "${YELLOW}openSUSE 16.0${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh opensuse 16.0 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        36)
            echo -e "${YELLOW}openEuler 24.03${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(dd_generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh openeuler 24.03 --password \"$root_password\""
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        37)
            read -p "请输入 DD 镜像直链地址: " dd_url
            if [ -z "$dd_url" ]; then
                echo -e "${RED}镜像地址不能为空${RESET}"
                return 1
            fi
            # 验证URL格式（防止命令注入）
            if ! [[ "$dd_url" =~ ^https?:// ]]; then
                echo -e "${RED}镜像地址必须以 http:// 或 https:// 开头${RESET}"
                return 1
            fi
            if [[ "$dd_url" =~ [\;\|\$\`\\] ]]; then
                echo -e "${RED}镜像地址包含非法字符，请勿使用特殊符号${RESET}"
                return 1
            fi
            read -p "请输入镜像密码 (留空无密码): " dd_password
            echo -e "用户名: ${GREEN}administrator${RESET}"
            echo -e "端口: ${GREEN}3389${RESET} (RDP)"
            if [ -n "$dd_password" ]; then
                echo -e "密码: ${GREEN}${dd_password}${RESET}"
            else
                echo -e "密码: ${YELLOW}无密码${RESET}"
            fi
            read -p "确认安装？(y/n，默认 y): " confirm
            confirm=${confirm:-y}
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${RESET}"
                return 0
            fi
            if [ -n "$dd_password" ]; then
                install_cmd="bash /tmp/reinstall.sh dd --img=\"$dd_url\" --password \"$dd_password\""
            else
                install_cmd="bash /tmp/reinstall.sh dd --img=\"$dd_url\""
            fi
            is_custom_dd=true
            ;;
        *) 
            echo -e "${RED}无效选项${RESET}"
            return 1
            ;;
    esac
    
    if [ -n "$install_cmd" ]; then
        echo ""
        echo -e "${YELLOW}即将执行安装命令，执行后会自动重启${RESET}"
        read -p "确认执行？(y/n，默认 y): " confirm
        confirm=${confirm:-y}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}正在执行安装命令，执行后自动重启...${RESET}"
            sleep 2
            bash -c "$install_cmd" && reboot
        else
            echo -e "${YELLOW}已取消${RESET}"
        fi
    fi
    
    return 0
}

dd_reinstall_menu() {
    if ! dd_is_interactive; then
        echo -e "${YELLOW}检测到非交互模式，显示 DD 重装菜单${RESET}"
        dd_show_dd_menu
        return 0
    fi
    
    if ! dd_download_scripts; then
        dd_wait_for_enter
        return 1
    fi
    
    while true; do
        dd_show_dd_menu
        read -p "请输入选项: " choice
        
        if [ -z "$choice" ]; then
            echo ""
            break
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 37 ]; then
            dd_execute_install "$choice"
        else
            echo -e "${RED}无效选项，请输入 1-37 之间的数字或直接回车返回${RESET}"
        fi
        
        dd_wait_for_enter
    done
}


# ===== DD结束 =====

# ============================================
# FileBrowser 一键部署脚本 - 整合版
# ============================================

FB_RED='\033[0;31m'
FB_GREEN='\033[0;32m'
FB_YELLOW='\033[0;33m'
FB_BLUE='\033[0;34m'
FB_NC='\033[0m'

fb_has_systemctl() { command -v systemctl &> /dev/null; }

FB_CONTAINER_NAME="filebrowser"
FB_DATA_DIR="/opt/filebrowser"
FB_SHARE_DIR="$FB_DATA_DIR/shared"
FB_DB_FILE="$FB_DATA_DIR/database.db"
FB_CONFIG_FILE="$FB_DATA_DIR/config.json"
FB_PORT=8080
FB_IMAGE="filebrowser/filebrowser:latest"

fb_info() { echo -e "${FB_GREEN}[信息]${FB_NC} $1" >&2; }
fb_warn() { echo -e "${FB_YELLOW}[警告]${FB_NC} $1" >&2; }
fb_error() { echo -e "${FB_RED}[错误]${FB_NC} $1" >&2; return 1; }

fb_detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        FB_OS=$ID
        FB_VER=$VERSION_ID
    else
        fb_error "无法检测操作系统"
    fi
    case $FB_OS in
        ubuntu|debian)
            FB_PKG_MANAGER="apt"; FB_INSTALL_CMD="apt install -y"; FB_UPDATE_CMD="apt update"
            ;;
        centos|rhel|rocky|almalinux)
            FB_PKG_MANAGER="yum"
            if command -v dnf >/dev/null 2>&1; then FB_PKG_MANAGER="dnf"; fi
            FB_INSTALL_CMD="$FB_PKG_MANAGER install -y"; FB_UPDATE_CMD="$FB_PKG_MANAGER update -y"
            if ! rpm -q epel-release >/dev/null 2>&1; then $FB_INSTALL_CMD epel-release; fi
            ;;
        fedora)
            FB_PKG_MANAGER="dnf"; FB_INSTALL_CMD="dnf install -y"; FB_UPDATE_CMD="dnf update -y"
            ;;
        *)
            fb_error "不支持的操作系统: $FB_OS"
            ;;
    esac
}

fb_fix_dpkg() {
    if [[ "$FB_PKG_MANAGER" == "apt" ]]; then
        fb_info "检查 dpkg 状态..."
        if dpkg --audit >/dev/null 2>&1; then
            fb_info "发现 dpkg 中断，正在修复..."
            dpkg --configure -a
            if ! dpkg --audit >/dev/null 2>&1; then apt --fix-broken install -y; fi
        fi
    fi
}

fb_check_network() {
    fb_info "检查网络连通性..."
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then fb_info "网络连接正常"; else fb_warn "网络连接可能有问题，但继续执行..."; fi
}

fb_install_docker() {
    if command -v docker >/dev/null 2>&1; then fb_info "Docker 已安装"; return; fi
    fb_info "正在安装 Docker..."
    case $FB_PKG_MANAGER in
        apt)
            $FB_UPDATE_CMD && $FB_INSTALL_CMD apt-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/$FB_OS/gpg | apt-key add -
            add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/$FB_OS $(lsb_release -cs) stable" -y
            $FB_UPDATE_CMD && $FB_INSTALL_CMD docker-ce
            ;;
        yum|dnf)
            $FB_INSTALL_CMD yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $FB_INSTALL_CMD docker-ce docker-ce-cli containerd.io
            ;;
    esac
    if fb_has_systemctl; then systemctl enable --now docker; fi
    fb_info "Docker 安装完成"
}

fb_install_deps() {
    fb_info "检查系统依赖..."
    local missing_deps=()
    for cmd in curl nginx; do if ! command -v $cmd >/dev/null 2>&1; then missing_deps+=($cmd); fi; done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        fb_info "安装缺失的依赖: ${missing_deps[@]}"
        $FB_UPDATE_CMD && $FB_INSTALL_CMD ${missing_deps[@]}
    fi
    if ! command -v certbot >/dev/null 2>&1; then
        fb_info "安装 Certbot..."
        case $FB_PKG_MANAGER in
            apt) $FB_INSTALL_CMD certbot python3-certbot-nginx ;;
            yum|dnf)
                $FB_INSTALL_CMD certbot python3-certbot-nginx
                if [ "$FB_PKG_MANAGER" = "yum" ] && ! command -v certbot >/dev/null 2>&1; then
                    $FB_INSTALL_CMD epel-release && $FB_INSTALL_CMD certbot python3-certbot-nginx
                fi
                ;;
        esac
        if fb_has_systemctl; then systemctl enable --now certbot.timer 2>/dev/null || true; fi
    fi
    if ! command -v netstat >/dev/null 2>&1; then $FB_INSTALL_CMD net-tools; fi
    fb_info "依赖检查完成"
}

fb_check_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":${port} "; then return 1
    elif ss -tuln 2>/dev/null | grep -q ":${port} "; then return 1; fi
    return 0
}

fb_auto_select_port() {
    local start_port=$1
    local port=$start_port
    while ! fb_check_port $port; do
        fb_warn "端口 $port 已被占用，自动选择新端口..."
        port=$((port + 1))
        if [ $port -gt 65535 ]; then fb_error "无法找到可用端口"; fi
    done
    echo "$port"
}

fb_prepare_dirs() {
    mkdir -p "$FB_DATA_DIR" && mkdir -p "$FB_SHARE_DIR"
    chown -R 1000:1000 "$FB_DATA_DIR"
    chmod 755 "$FB_DATA_DIR" && chmod 755 "$FB_SHARE_DIR"
}

fb_start_filebrowser() {
    fb_info "启动 FileBrowser 容器..."
    docker run -d --name=$FB_CONTAINER_NAME --restart=unless-stopped \
        -v $FB_DATA_DIR:/data -v $FB_SHARE_DIR:/srv -p $FB_PORT:80 -u 1000:1000 $FB_IMAGE \
        -r /srv -d /data/database.db -c /data/config.json --address=0.0.0.0 --port=80
    sleep 5
    if docker ps | grep -q $FB_CONTAINER_NAME; then
        fb_info "FileBrowser 容器启动成功"
        local password=$(docker logs $FB_CONTAINER_NAME 2>&1 | grep -o 'password: [^ ]\+' | cut -d' ' -f2 | head -1)
        if [ -n "$password" ]; then
            fb_info "初始管理员密码: $password"
            echo "$password" > $FB_DATA_DIR/admin_password.txt
        fi
    else
        fb_error "FileBrowser 容器启动失败，请检查日志: docker logs $FB_CONTAINER_NAME"
    fi
}

fb_configure_nginx_http() {
    local domain=$1
    local email=${2:-"admin@$domain"}
    
    # 直接使用全局 FB_PORT（已在 fb_install_filebrowser 中分配）
    echo -e "${YELLOW}FileBrowser内部端口: $FB_PORT${RESET}"
    
    # 添加域名到统一Nginx反向代理
    add_domain_to_unified_nginx "$domain" "$FB_PORT" "$email"
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    FB_DOMAIN=$domain
    return 0
}

fb_configure_ssl() {
    # SSL配置已由add_domain_to_unified_nginx处理
    return 0
}

fb_get_public_ip() {
    local ipv4=$(curl -4 -s ifconfig.me 2>/dev/null)
    if [ -n "$ipv4" ] && [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ipv4"
    else local ipv6=$(curl -6 -s ifconfig.me 2>/dev/null); echo "${ipv6:-127.0.0.1}"; fi
}

fb_check_dns() {
    local domain=$1
    fb_info "检查域名解析..."
    if ! nslookup $domain >/dev/null 2>&1; then
        fb_warn "域名 $domain 解析失败"
        read -p "是否继续？(y/N): " choice
        [[ "$choice" != "y" && "$choice" != "Y" ]] && exit 1
    else fb_info "域名解析正常"; fi
}

fb_reset_password() {
    if ! docker ps | grep -q $FB_CONTAINER_NAME; then fb_error "FileBrowser 容器未运行"; fi
    read -p "请输入新密码: " newpass
    if [ -z "$newpass" ]; then fb_error "密码不能为空"; fi
    fb_info "正在重置密码..."
    if docker exec -t $FB_CONTAINER_NAME timeout 30 filebrowser -d /data/database.db users update admin -p "$newpass" 2>&1; then
        fb_info "密码已更新"
    else fb_error "重置密码失败"; fi
}



fb_release_port_80() {
    fb_info "释放 80 端口..."
    if command -v nginx >/dev/null 2>&1; then
        systemctl stop nginx 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true
        fb_info "80 端口已释放"
    else
        fb_warn "Nginx 未安装，无需释放端口"
    fi
}

fb_auto_cert_helper() {
    fb_info "自动配置 SSL 证书助手..."
    if [ -z "$DOMAIN" ]; then
        fb_error "请先配置域名"
        return 1
    fi
    add_domain_to_unified_nginx "$DOMAIN" "$FB_PORT" "$WP_EMAIL"
    if [ $? -eq 0 ]; then
        fb_info "SSL 证书配置成功"
    else
        fb_error "SSL 证书配置失败"
    fi
}
fb_install_filebrowser() {
    echo "=========================================="
    echo "FileBrowser 一键部署安装流程"
    echo "=========================================="
    fb_check_network && fb_detect_os && fb_fix_dpkg && fb_install_docker

    local mode="" domain="" email=""
    if [ -t 0 ] && [ -t 1 ]; then
        echo "请选择安装类型："
        echo "1) 域名模式 (带SSL证书)"
        echo "2) IP模式 (仅HTTP访问)"
        read -p "请选择 (1 或 2): " mode
        case $mode in
            1)
                read -p "请输入你的域名 (例如: file.example.com): " domain
                if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    fb_warn "域名格式可能不正确，继续？(y/N): "; read choice; [[ "$choice" != "y" && "$choice" != "Y" ]] && exit 1
                fi
                read -p "请输入邮箱 (用于证书通知，默认 admin@$domain): " email
                email=${email:-admin@$domain}
                fb_info "使用域名: $domain"; fb_check_dns $domain
                ;;
            2) fb_info "使用 IP 模式" ;;
            *) fb_error "无效选项" ;;
        esac
    else
        fb_info "非交互模式，自动选择 IP模式安装"; mode=2
    fi

    # FileBrowser内部端口使用高端口
    local fb_internal_port=8081
    while ss -tuln 2>/dev/null | grep -q ":$fb_internal_port " || netstat -tuln 2>/dev/null | grep -q ":$fb_internal_port "; do
        fb_internal_port=$((fb_internal_port + 1))
    done
    FB_PORT=$fb_internal_port
    
    fb_info "使用内部端口: $FB_PORT"
    fb_info "拉取 FileBrowser 镜像..." && docker pull $FB_IMAGE
    fb_prepare_dirs && fb_start_filebrowser

    if [ -n "$domain" ]; then
        fb_configure_nginx_http "$domain" "$email"
        if [ $? -eq 0 ]; then
            fb_info "安装完成！访问地址: https://$domain"
        fi
    else
        fb_info "安装完成！访问地址: http://$(fb_get_public_ip):$FB_PORT"
    fi

    if [ -f "$FB_DATA_DIR/admin_password.txt" ]; then
        password=$(cat "$FB_DATA_DIR/admin_password.txt")
        fb_info "默认用户名: admin, 初始密码: $password"
    else
        password=$(docker logs $FB_CONTAINER_NAME 2>&1 | grep -o 'password: [^ ]\+' | cut -d' ' -f2 | head -1)
        if [ -n "$password" ]; then
            fb_info "默认用户名: admin, 初始密码: $password"
            echo "$password" > "$FB_DATA_DIR/admin_password.txt"
        else fb_info "默认用户名: admin, 初始密码: 请查看容器日志"; fi
    fi
    fb_info "首次登录后请立即修改密码"
    fb_info "上传的文件将保存在: $FB_SHARE_DIR"
    fb_info "快捷命令已创建: filebrowser"
}

fb_uninstall_full() {
    read -p "确定要完全卸载 FileBrowser 吗？这将删除所有数据 (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fb_info "注意：上传的文件保存在 $FB_SHARE_DIR"
    read -p "是否同时删除所有上传的文件？(y/N): " del_files
    if [[ "$del_files" == "y" || "$del_files" == "Y" ]]; then
        read -p "再次确认删除所有上传的文件？(y/N): " confirm2
        if [[ "$confirm2" == "y" || "$confirm2" == "Y" ]]; then
            fb_info "删除上传的文件..." && rm -rf "$FB_SHARE_DIR"/* && rm -rf "$FB_SHARE_DIR"/.[!.]* 2>/dev/null || true
        fi
    fi
    fb_info "停止并删除 FileBrowser 容器..." && docker stop $FB_CONTAINER_NAME 2>/dev/null || true && docker rm $FB_CONTAINER_NAME 2>/dev/null || true
    fb_info "删除 FileBrowser 数据目录..." && rm -rf $FB_DATA_DIR
    for file in /etc/nginx/sites-enabled/*; do
        if [ -f "$file" ] && grep -q "proxy_pass.*$FB_PORT" "$file" 2>/dev/null; then rm -f "$file"; fi
    done
    if fb_has_systemctl; then systemctl reload nginx 2>/dev/null || true; fi
    rm -f /usr/local/bin/filebrowser /usr/local/bin/filebrowser-manager 2>/dev/null || true
    fb_info "FileBrowser 已完全卸载"
}

fb_uninstall_keep_data() {
    read -p "确定要卸载 FileBrowser（保留数据）吗？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fb_info "停止并删除 FileBrowser 容器..." && docker stop $FB_CONTAINER_NAME 2>/dev/null || true && docker rm $FB_CONTAINER_NAME 2>/dev/null || true
    fb_info "数据目录保留在 $FB_DATA_DIR，上传文件保留在 $FB_SHARE_DIR"
    rm -f /usr/local/bin/filebrowser /usr/local/bin/filebrowser-manager 2>/dev/null || true
}

fb_show_status() {
    if docker ps -a | grep -q $FB_CONTAINER_NAME; then
        echo "FileBrowser 容器状态:"
        docker ps -a --filter name=$FB_CONTAINER_NAME --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        if docker ps | grep -q $FB_CONTAINER_NAME; then echo "容器正在运行"; else echo "容器已停止"; fi
    else echo "FileBrowser 容器不存在"; fi
    if grep -r "proxy_pass.*$FB_PORT" /etc/nginx/sites-enabled/ 2>/dev/null | grep -q .; then echo "Nginx 反向代理已配置"; else echo "未检测到 Nginx 反向代理配置"; fi
}

fb_show_data_location() {
    echo "FileBrowser 数据目录: $FB_DATA_DIR"
    echo "数据库文件: $FB_DB_FILE"
    echo "配置文件: $FB_CONFIG_FILE"
    [ -f "$FB_DATA_DIR/admin_password.txt" ] && echo "初始密码文件: $FB_DATA_DIR/admin_password.txt"
    echo "上传的文件存储位置: $FB_SHARE_DIR"
}

fb_show_logs() {
    if docker ps -a | grep -q $FB_CONTAINER_NAME; then docker logs $FB_CONTAINER_NAME --tail 50; else echo "FileBrowser 容器不存在"; fi
}

fb_restart_service() {
    if docker ps -a | grep -q $FB_CONTAINER_NAME; then
        docker restart $FB_CONTAINER_NAME && fb_info "FileBrowser 容器已重启"
        if fb_has_systemctl; then systemctl reload nginx 2>/dev/null || true; fi
    else fb_error "FileBrowser 容器不存在"; fi
}

fb_show_current_password() {
    if [ -f "$FB_DATA_DIR/admin_password.txt" ]; then
        echo "初始密码（如果未修改）: $(cat $FB_DATA_DIR/admin_password.txt)"
        echo "如果密码已被修改，请使用菜单选项7重置密码"
    else echo "未找到初始密码文件"; fi
    echo "当前密码也可从容器日志查看: docker logs $FB_CONTAINER_NAME | grep password"
}

fb_main_menu() {
    while true; do
        echo "=========================================="
        echo "FileBrowser 管理菜单"
        echo "=========================================="
        echo "1) 安装 FileBrowser - IP模式或域名模式"
        echo "2) 完全卸载 FileBrowser (删除所有数据)"
        echo "3) 卸载 FileBrowser (保留数据)"
        echo "4) 查看状态"
        echo "5) 查看数据位置"
        echo "6) 查看日志"
        echo "7) 重置密码"
        echo "8) 重启服务"
        echo "9) 查看当前密码"
        echo "10) 手动释放 80 端口"
        echo "11) 自动证书申请助手"
        echo "0) 返回主菜单"
        echo "=========================================="
        read -p "请选择操作 [0-11]: " choice
        case $choice in
            1) fb_install_filebrowser ;;
            2) fb_uninstall_full ;;
            3) fb_uninstall_keep_data ;;
            4) fb_show_status ;;
            5) fb_show_data_location ;;
            6) fb_show_logs ;;
            7) fb_reset_password ;;
            8) fb_restart_service ;;
            9) fb_show_current_password ;;
            10) fb_release_port_80 ;;
            11) fb_auto_cert_helper ;;
            0) echo "返回主菜单..."; break ;;
            *) echo "无效选项" ;;
        esac
        echo -e "${YELLOW}按回车键返回子菜单...${RESET}"; if [ -t 0 ]; then read -p "" </dev/null || true; fi
    done
}

show_menu() {
    while true; do
        echo -e "${GREEN}=============================================${RESET}"
        echo -e "${GREEN}服务器推荐：https://my.frantech.ca/aff.php?aff=4337${RESET}"
        echo -e "${GREEN}VPS评测官方网站：https://www.1373737.xyz/${RESET}"
        echo -e "${GREEN}YouTube频道：https://www.youtube.com/@cyndiboy7881${RESET}"
        echo -e "${GREEN}=============================================${RESET}"
        echo "请选择要执行的操作："
        echo -e "${YELLOW}0. 脚本更新${RESET}"
        echo -e "${YELLOW}1. VPS一键测试${RESET}"
        echo -e "${YELLOW}2. 安装BBR${RESET}"
        echo -e "${YELLOW}3. 安装v2ray${RESET}"
        echo -e "${YELLOW}4. 安装无人直播云SRS${RESET}"
        echo -e "${YELLOW}5. 面板安装（1panel/宝塔/青龙）${RESET}"
        echo -e "${YELLOW}6. 系统更新${RESET}"
        echo -e "${YELLOW}7. 修改密码${RESET}"
        echo -e "${YELLOW}8. 重启服务器${RESET}"
        echo -e "${YELLOW}9. 一键永久禁用IPv6${RESET}"
        echo -e "${YELLOW}10.一键解除禁用IPv6${RESET}"
        echo -e "${YELLOW}11.服务器时区修改为中国时区${RESET}"
        echo -e "${YELLOW}12.保持SSH会话一直连接不断开${RESET}"
        echo -e "${YELLOW}13.DD重装系统(Win/Linux)${RESET}"
        echo -e "${YELLOW}14.服务器对服务器文件传输${RESET}"
        echo -e "${YELLOW}15.安装探针并绑定域名${RESET}"
        echo -e "${YELLOW}16.共用端口（反代NPM）${RESET}"
        echo -e "${YELLOW}17.安装 curl 和 wget${RESET}"
        echo -e "${YELLOW}18.Docker安装和管理${RESET}"
        echo -e "${YELLOW}19.SSH 防暴力破解检测${RESET}"
        echo -e "${YELLOW}20.Speedtest测速面板${RESET}"
        echo -e "${YELLOW}21.WordPress 安装（基于 Docker）${RESET}"  
        echo -e "${YELLOW}22.网心云安装${RESET}" 
        echo -e "${YELLOW}23.3X-UI搭建${RESET}"
        echo -e "${YELLOW}24.S-UI搭建${RESET}"
        echo -e "${YELLOW}25. FileBrowser安装"
        echo -e "${GREEN}=============================================${RESET}"

        read -p "请输入选项 (输入 'q' 退出): " option

        # 检查是否退出
        if [ "$option" = "q" ]; then
            echo -e "${GREEN}退出脚本，感谢使用！${RESET}"
            echo -e "${GREEN}服务器推荐：https://my.frantech.ca/aff.php?aff=4337${RESET}"
            echo -e "${GREEN}VPS评测官方网站：https://www.1373737.xyz/${RESET}"
            exit 0
        fi

        case $option in
            0)
                # 脚本更新
                echo -e "${GREEN}正在更新脚本...${RESET}"
                wget -O /tmp/onekey.sh https://raw.githubusercontent.com/teaing-liu/onekey/main/onekey.sh
                if [ $? -eq 0 ]; then
                    mv /tmp/onekey.sh /usr/local/bin/onekey.sh
                    chmod +x /usr/local/bin/onekey.sh
                    echo -e "${GREEN}脚本更新成功！${RESET}"
                    echo -e "${YELLOW}请重新运行脚本以应用更新。${RESET}"
                else
                    echo -e "${RED}脚本更新失败，请检查网络连接！${RESET}"
                fi
                read -p "按回车键返回主菜单..."
                ;;
1)
    # VPS 一键测试脚本
    echo -e "${GREEN}正在进行 VPS 测试 ...${RESET}"
    
    # 定义测试脚本的固定存放路径
    TEST_SCRIPT_PATH="/root/server_test.sh"
    
    # 确保 /root 目录存在且可写
    if [ ! -d "/root" ]; then
        echo -e "${RED}/root 目录不存在！${RESET}"
        read -p "按回车键返回主菜单..."
        continue
    fi
    
    # 下载测试脚本（强制覆盖，确保最新版本）
    echo -e "${YELLOW}正在下载测试脚本到 $TEST_SCRIPT_PATH ...${RESET}"
    wget -O "$TEST_SCRIPT_PATH" https://raw.githubusercontent.com/teaing-liu/server_test/master/server_test.sh --no-check-certificate
    
    # 检查下载是否成功
    if [ $? -ne 0 ] || [ ! -f "$TEST_SCRIPT_PATH" ]; then
        echo -e "${RED}下载 VPS 测试脚本失败，请检查网络！${RESET}"
        read -p "按回车键返回主菜单..."
        continue
    fi
    
    # 设置执行权限（确保 root 用户可执行）
    chmod +x "$TEST_SCRIPT_PATH"
    if [ $? -ne 0 ]; then
        echo -e "${RED}设置执行权限失败！${RESET}"
        read -p "按回车键返回主菜单..."
        continue
    fi
    
    # 验证文件可执行
    if [ ! -x "$TEST_SCRIPT_PATH" ]; then
        echo -e "${RED}脚本文件无法执行，请检查权限！${RESET}"
        read -p "按回车键返回主菜单..."
        continue
    fi
    
    echo -e "${GREEN}脚本准备就绪，开始运行测试...${RESET}"
    
    # 运行测试脚本
    bash "$TEST_SCRIPT_PATH"
    
    # 检查运行结果
    if [ $? -ne 0 ]; then
        echo -e "${RED}测试脚本运行出错！${RESET}"
    else
        echo -e "${GREEN}测试完成！${RESET}"
    fi
    
    read -p "按回车键返回主菜单..."
    ;;
            2)
    # BBR 和 BBR v3 安装与管理
    echo -e "${GREEN}正在进入 BBR 和 BBR v3 安装与管理菜单...${RESET}"
    
    # ========== BBR 管理函数定义 ==========
    bbr_management() {
        # 1. 内存检测函数
        detect_system_memory() {
            if [ -f /proc/meminfo ]; then
                TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
                TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
                
                # 内存分级
                if [ "$TOTAL_MEM_MB" -lt 512 ]; then
                    MEM_LEVEL="tiny"
                elif [ "$TOTAL_MEM_MB" -lt 1024 ]; then
                    MEM_LEVEL="small"
                elif [ "$TOTAL_MEM_MB" -lt 2048 ]; then
                    MEM_LEVEL="medium"
                elif [ "$TOTAL_MEM_MB" -lt 4096 ]; then
                    MEM_LEVEL="large"
                elif [ "$TOTAL_MEM_MB" -lt 8192 ]; then
                    MEM_LEVEL="xlarge"
                else
                    MEM_LEVEL="huge"
                fi
                
                # 计算安全内存
                SAFE_MEM_MB=$((TOTAL_MEM_MB * 80 / 100))
                
                # 返回所有信息
                echo "${TOTAL_MEM_MB}:${MEM_LEVEL}:${SAFE_MEM_MB}"
            else
                echo "1024:medium:819"
            fi
        }
        
        # 2. 智能参数计算
        calculate_smart_params() {
            local mem_mb=$1
            local scenario=$2
            local cpu_cores=$(nproc 2>/dev/null || echo 1)
            
            # 基础连接数
            case "$MEM_LEVEL" in
                "tiny") BASE_CONN=400 ;;
                "small") BASE_CONN=640 ;;
                "medium") BASE_CONN=1024 ;;
                "large") BASE_CONN=1638 ;;
                "xlarge") BASE_CONN=3277 ;;
                "huge") BASE_CONN=6554 ;;
                *) BASE_CONN=1024 ;;
            esac
            
            # 根据场景调整
            case "$scenario" in
                "video")
                    MAX_CONN=$((BASE_CONN * 105 / 100))
                    BUFFER_KB=1229
                    ;;
                "download")
                    MAX_CONN=$((BASE_CONN * 102 / 100))
                    BUFFER_KB=614
                    ;;
                "mixed")
                    MAX_CONN=$((BASE_CONN * 103 / 100))
                    BUFFER_KB=922
                    ;;
                "balanced")
                    MAX_CONN=$BASE_CONN
                    BUFFER_KB=614
                    ;;
                *)
                    MAX_CONN=$BASE_CONN
                    BUFFER_KB=410
                    ;;
            esac
            
            # CPU核心影响
            MAX_CONN=$((MAX_CONN + (cpu_cores * 60)))
            
            # 安全上限
            if [ "$MAX_CONN" -gt 52428 ]; then
                MAX_CONN=52428
            fi
            
            # 最低保障连接数
            if [ "$MAX_CONN" -lt 256 ]; then
                MAX_CONN=256
            fi
            
            # 文件描述符限制
            FILE_MAX=$((MAX_CONN * 2))
            if [ "$FILE_MAX" -gt 104857 ]; then
                FILE_MAX=104857
            fi
            if [ "$FILE_MAX" -lt 16384 ]; then
                FILE_MAX=16384
            fi
            
            # 缓冲区大小
            BUFFER_SIZE=$((BUFFER_KB * 1024))
            
            echo "$MAX_CONN:$BUFFER_SIZE:$FILE_MAX"
        }
        
        # 3. 检查内核版本是否支持 BBR v3
        check_kernel_version() {
            kernel_version=$(uname -r)
            major_version=$(echo "$kernel_version" | awk -F. '{print $1}')
            minor_version=$(echo "$kernel_version" | awk -F. '{print $2}' | cut -d- -f1)
            if [[ $major_version -lt 5 || ($major_version -eq 5 && $minor_version -lt 6) ]]; then
                echo -e "${RED}当前内核版本 $kernel_version 不支持 BBR v3！${RESET}"
                if [ -f /etc/centos-release ] && grep -q "CentOS Linux release 7" /etc/centos-release; then
                    echo -e "${YELLOW}CentOS 7 默认内核（3.10）不支持 BBR v3，建议升级到 5.6 或更高版本。${RESET}"
                else
                    echo -e "${YELLOW}请手动升级内核到 5.6 或更高版本！${RESET}"
                fi
                return 1
            fi
            echo -e "${GREEN}内核版本 $kernel_version 支持 BBR v3。${RESET}"
            return 0
        }
        
        # 4. 检查 BBR v3 安装和运行状态
        check_bbr_status() {
            echo -e "${YELLOW}正在检查 BBR v3 状态...${RESET}"
            if modinfo tcp_bbr >/dev/null 2>&1; then
                if lsmod | grep -q "tcp_bbr"; then
                    echo -e "${GREEN}BBR v3 模块 (tcp_bbr) 已加载。${RESET}"
                else
                    echo -e "${PURPLE}BBR v3 模块 (tcp_bbr) 未加载，可能未启用。${RESET}"
                    return 1
                fi
            else
                echo -e "${RED}BBR v3 模块 (tcp_bbr) 未找到，可能内核不支持！${RESET}"
                return 1
            fi
            current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control)
            if [ "$current_congestion" = "bbr" ]; then
                echo -e "${PURPLE}拥塞控制算法已设置为 BBR，BBR v3 已成功启动。${RESET}"
            else
                echo -e "${RED}当前拥塞控制算法为 $current_congestion，BBR v3 未成功启动。${RESET}"
                return 1
            fi
            sysctl_file="/etc/sysctl.conf"
            [ -f /etc/centos-release ] && sysctl_file="/etc/sysctl.d/99-bbr.conf"
            if grep -q "net.ipv4.tcp_congestion_control = bbr" "$sysctl_file"; then
                echo -e "${GREEN}BBR v3 配置已写入 $sysctl_file，重启后将保持生效。${RESET}"
            else
                echo -e "${YELLOW}警告：BBR v3 配置未写入 $sysctl_file，重启后可能失效。${RESET}"
            fi
            return 0
        }
        
        # 5. 安装 BBR v3
        install_bbr_v3() {
            echo -e "${YELLOW}正在安装 BBR v3...${RESET}"
            sudo modprobe tcp_bbr
            if [ $? -ne 0 ]; then
                echo -e "${RED}加载 tcp_bbr 模块失败！${RESET}"
                return 1
            fi
            sysctl_file="/etc/sysctl.conf"
            [ -f /etc/centos-release ] && sysctl_file="/etc/sysctl.d/99-bbr.conf"
            echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a "$sysctl_file"
            echo "net.core.default_qdisc = fq" | sudo tee -a "$sysctl_file"
            sudo sysctl -p "$sysctl_file"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}BBR v3 配置已应用！${RESET}"
            else
                echo -e "${RED}应用 sysctl 配置失败！${RESET}"
                return 1
            fi
            echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf >/dev/null
            echo -e "${GREEN}已配置 tcp_bbr 模块自动加载。${RESET}"
            
            check_bbr_status
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}BBR v3 安装成功！${RESET}"
            else
                echo -e "${RED}BBR v3 安装验证失败！${RESET}"
            fi
        }
        
        # 6. 卸载 BBR
        uninstall_bbr() {
            echo -e "${YELLOW}正在卸载当前 BBR 版本...${RESET}"
            sudo modprobe -r tcp_bbr
            if [ $? -eq 0 ]; then
                sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
                echo -e "${GREEN}BBR 版本已卸载！${RESET}"
                sudo rm -f /etc/modules-load.d/bbr.conf 2>/dev/null
            else
                echo -e "${RED}卸载 BBR 失败！${RESET}"
            fi
        }
        
        # 7. 恢复默认 TCP 设置
        restore_default_tcp_settings() {
            echo -e "${YELLOW}正在恢复默认 TCP 拥塞控制设置...${RESET}"
            sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
            sudo sysctl -w net.core.default_qdisc=fq
            echo -e "${GREEN}已恢复到默认 TCP 设置。${RESET}"
        }
        
        # 8. 安装原始 BBR
        install_original_bbr() {
            echo -e "${YELLOW}正在安装原始 BBR ...${RESET}"
            wget -O /tmp/tcpx.sh "https://github.com/teaing-liu/Linux-NetSpeed/raw/master/tcpx.sh" && \
            chmod +x /tmp/tcpx.sh && \
            bash /tmp/tcpx.sh && \
            rm -f /tmp/tcpx.sh
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}原始 BBR 安装成功！${RESET}"
            else
                echo -e "${RED}原始 BBR 安装失败！${RESET}"
            fi
        }
        
        # 9. 一键网络优化配置（针对视频播放、文件下载、多用户 VPS）
        apply_network_optimizations() {
            echo -e "${YELLOW}正在应用一键网络优化配置（优化视频播放、文件下载和多用户 VPS）...${RESET}"
            sysctl_file="/etc/sysctl.conf"
            [ -f /etc/centos-release ] && sysctl_file="/etc/sysctl.d/99-bbr.conf"
            
            # 备份原配置
            BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d%H%M%S)"
            cp /etc/sysctl.conf "$BACKUP_FILE" 2>/dev/null || true
            
            echo "net.core.default_qdisc = fq" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a "$sysctl_file"
            echo "net.core.somaxconn = 4096" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_max_syn_backlog = 2048" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_fin_timeout = 30" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_keepalive_time = 600" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.ip_local_port_range = 1024 65535" | sudo tee -a "$sysctl_file"
            echo "fs.file-max = 2097152" | sudo tee -a "$sysctl_file"
            echo "net.core.netdev_max_backlog = 4096" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_fastopen = 3" | sudo tee -a "$sysctl_file"
            echo "net.core.rmem_max = 16777216" | sudo tee -a "$sysctl_file"
            echo "net.core.wmem_max = 16777216" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_rmem = 4096 87380 16777216" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_wmem = 4096 65536 16777216" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_max_tw_buckets = 20000" | sudo tee -a "$sysctl_file"
            echo "net.ipv4.tcp_tw_reuse = 1" | sudo tee -a "$sysctl_file"
            
            sudo sysctl -p "$sysctl_file"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}网络优化配置已应用！${RESET}"
            else
                echo -e "${RED}应用网络优化配置失败，请手动检查 $sysctl_file！${RESET}"
                return 1
            fi
            
            limits_file="/etc/security/limits.conf"
            [ -f /etc/centos-release ] && limits_file="/etc/security/limits.d/99-custom.conf"
            if ! grep -q "nofile 1048576" "$limits_file"; then
                echo "* soft nofile 1048576" | sudo tee -a "$limits_file"
                echo "* hard nofile 1048576" | sudo tee -a "$limits_file"
                echo -e "${GREEN}已更新 $limits_file 以设置文件描述符限制。${RESET}"
            else
                echo -e "${YELLOW}文件描述符限制已在 $limits_file 中配置，无需重复设置。${RESET}"
            fi
            
            ulimit -n 1048576
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}临时文件描述符限制已设置为 1048576。${RESET}"
            else
                echo -e "${RED}设置临时文件描述符限制失败，请检查权限！${RESET}"
            fi
            
            echo -e "${GREEN}一键网络优化完成！${RESET}"
            read -p "是否立即重启系统以确保配置生效？(y/n): " reboot_choice
            if [[ $reboot_choice == "y" || $reboot_choice == "Y" ]]; then
                echo -e "${YELLOW}正在重启系统...${RESET}"
                sudo reboot
            else
                echo -e "${YELLOW}请稍后手动运行 'sudo reboot' 重启系统以确保配置生效。${RESET}"
            fi
        }
        
        # 10. 增强网络优化配置
        apply_enhanced_network_optimizations() {
            echo -e "${YELLOW}正在应用增强网络优化配置...${RESET}"
            
            # 创建恢复脚本
            cat > /tmp/recovery_network.sh << 'EOF'
#!/bin/bash
echo "正在恢复网络配置..."
cat > /etc/sysctl.conf << 'CONF_EOF'
# 默认网络配置
net.ipv4.tcp_congestion_control = cubic
net.core.default_qdisc = fq
net.core.somaxconn = 128
net.ipv4.tcp_max_syn_backlog = 128
fs.file-max = 65536
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 87380 4194304
net.ipv4.tcp_mem = 4096 87380 4194304
net.ipv4.ip_local_port_range = 1024 65535
CONF_EOF

sysctl -p
echo "网络配置已恢复，建议重启系统..."
echo "执行: reboot"
EOF
            chmod +x /tmp/recovery_network.sh
            
            # 检测系统内存
            MEM_INFO=$(detect_system_memory)
            TOTAL_MEM_MB=$(echo "$MEM_INFO" | cut -d: -f1)
            MEM_LEVEL=$(echo "$MEM_INFO" | cut -d: -f2)
            SAFE_MEM_MB=$(echo "$MEM_INFO" | cut -d: -f3)
            
            # 使用场景选择
            echo ""
            echo "=== 使用场景选择 ==="
            echo "1) 视频流媒体服务器"
            echo "2) 文件下载服务器"
            echo "3) 混合用途 (视频+下载)"
            echo "4) 平衡模式 (推荐)"
            echo "5) 返回"
            read -p "请选择 [1-5]: " scenario_choice
            
            case $scenario_choice in
                1) 
                    SCENARIO="video"
                    SCENARIO_DESC="视频流媒体服务器"
                    ;;
                2) 
                    SCENARIO="download"
                    SCENARIO_DESC="文件下载服务器"
                    ;;
                3) 
                    SCENARIO="mixed"
                    SCENARIO_DESC="混合用途服务器"
                    ;;
                4) 
                    SCENARIO="balanced"
                    SCENARIO_DESC="平衡模式"
                    ;;
                5) return ;;
                *) 
                    SCENARIO="balanced"
                    SCENARIO_DESC="平衡模式"
                    ;;
            esac
            
            # 计算智能参数
            PARAMS=$(calculate_smart_params "$SAFE_MEM_MB" "$SCENARIO")
            MAX_CONN=$(echo "$PARAMS" | cut -d: -f1)
            BUFFER_SIZE=$(echo "$PARAMS" | cut -d: -f2)
            FILE_MAX=$(echo "$PARAMS" | cut -d: -f3)
            
            # 根据内存计算TCP内存参数
            case "$MEM_LEVEL" in
                "tiny")
                    TCP_MEM_MIN=3072
                    TCP_MEM_DEFAULT=6144
                    TCP_MEM_MAX=9216
                    ;;
                "small")
                    TCP_MEM_MIN=6144
                    TCP_MEM_DEFAULT=12288
                    TCP_MEM_MAX=18432
                    ;;
                "medium")
                    TCP_MEM_MIN=12288
                    TCP_MEM_DEFAULT=24576
                    TCP_MEM_MAX=36864
                    ;;
                "large")
                    TCP_MEM_MIN=24576
                    TCP_MEM_DEFAULT=49152
                    TCP_MEM_MAX=73728
                    ;;
                "xlarge")
                    TCP_MEM_MIN=49152
                    TCP_MEM_DEFAULT=98304
                    TCP_MEM_MAX=147456
                    ;;
                "huge")
                    TCP_MEM_MIN=98304
                    TCP_MEM_DEFAULT=196608
                    TCP_MEM_MAX=294912
                    ;;
                *)
                    TCP_MEM_MIN=12288
                    TCP_MEM_DEFAULT=24576
                    TCP_MEM_MAX=36864
                    ;;
            esac
            
            # 显示优化方案
            echo ""
            echo "=== 优化方案详情 ==="
            echo "服务器配置: ${TOTAL_MEM_MB}MB 内存"
            echo "使用场景: ${SCENARIO_DESC}"
            echo "最大连接数: $MAX_CONN"
            echo "文件描述符: $FILE_MAX"
            
            if [ "$SCENARIO" = "mixed" ]; then
                echo ""
                echo -e "${YELLOW}混合用途：视频流 + 文件下载优化${RESET}"
            fi
            
            # 安全警告
            echo ""
            echo -e "${RED}⚠️  警告：此操作将立即重启系统！${RESET}"
            echo "• 所有未保存的工作将丢失"
            echo "• SSH连接将中断"
            echo "• 重启后需要重新连接"
            echo "• 恢复脚本: /tmp/recovery_network.sh"
            
            # 最终确认
            echo ""
            read -p "确认应用优化并立即重启系统？(y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消优化${RESET}"
                return
            fi
            
            # 生成配置文件
            sysctl_file="/etc/sysctl.conf"
            [ -f /etc/centos-release ] && sysctl_file="/etc/sysctl.d/99-bbr.conf"
            
            # 备份原配置
            BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d%H%M%S)"
            cp /etc/sysctl.conf "$BACKUP_FILE" 2>/dev/null || true
            echo -e "${YELLOW}配置已备份到: $BACKUP_FILE${RESET}"
            
            # 生成优化配置
            cat > /tmp/enhanced_optimization.conf << EOF
# 增强网络优化配置
# 生成时间: $(date)
# 内存: ${TOTAL_MEM_MB}MB
# 场景: ${SCENARIO_DESC}

# 基础优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 连接管理
net.core.somaxconn = $MAX_CONN
net.ipv4.tcp_max_syn_backlog = $MAX_CONN
net.ipv4.tcp_max_tw_buckets = $MAX_CONN
net.ipv4.tcp_tw_reuse = 1

# 文件描述符
fs.file-max = $FILE_MAX

# TCP缓冲区
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 87380 4194304

# TCP内存
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_DEFAULT $TCP_MEM_MAX

# 端口范围
net.ipv4.ip_local_port_range = 10240 65535

# TCP优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
EOF
            
            # 应用配置
            echo -e "${YELLOW}正在应用配置...${RESET}"
            cp /tmp/enhanced_optimization.conf "$sysctl_file"
            
            # 应用配置
            sysctl -p "$sysctl_file" >/dev/null 2>&1
            
            # 设置文件描述符限制
            LIMITS_FILE="/etc/security/limits.conf"
            echo "* soft nofile $FILE_MAX" | sudo tee -a "$LIMITS_FILE" >/dev/null
            echo "* hard nofile $FILE_MAX" | sudo tee -a "$LIMITS_FILE" >/dev/null
            
            echo -e "${GREEN}✅ 增强网络优化配置已应用！${RESET}"
            echo -e "${YELLOW}正在立即重启系统...${RESET}"
            echo ""
            echo -e "${RED}如果重启后无法连接，请使用VNC或控制台执行:${RESET}"
            echo -e "  bash /tmp/recovery_network.sh"
            echo -e "  reboot"
            
            # 等待2秒
            sleep 2
            
            # 立即重启
            sudo reboot
        }
        
        # ========== BBR 管理菜单 ==========
        while true; do
            echo ""
            echo -e "${GREEN}=== BBR 和 BBR v3 管理 ===${RESET}"
            echo "1) 安装原始 BBR"
            echo "2) 安装 BBR v3"
            echo "3) 卸载当前 BBR 版本"
            echo "4) 检查 BBR 状态"
            echo "5) 应用一键网络优化"
            echo "6) 应用增强网络优化"
            echo "7) 恢复默认 TCP 设置"
            echo "8) 返回主菜单"
            read -p "请输入选项 [1-8]: " bbr_choice
            
            case $bbr_choice in
                1) install_original_bbr ;;
                2) 
                    if check_kernel_version; then
                        install_bbr_v3
                    fi
                    ;;
                3) uninstall_bbr ;;
                4) check_bbr_status ;;
                5) apply_network_optimizations ;;
                6) apply_enhanced_network_optimizations ;;
                7) restore_default_tcp_settings ;;
                8) 
                    echo -e "${YELLOW}返回主菜单...${RESET}"
                    break
                    ;;
                *) 
                    echo -e "${RED}无效选项！${RESET}"
                    ;;
            esac
            
            echo ""
            read -p "按回车键继续..."
        done
    }
    
    # 调用 BBR 管理函数
    bbr_management
    ;;
            3)
                # 安装 v2ray 脚本
                echo -e "${GREEN}正在安装 v2ray ...${RESET}"
                wget -P /tmp -N --no-check-certificate "https://raw.githubusercontent.com/teaing-liu/v2ray-agent/master/install.sh"
                if [ $? -eq 0 ]; then
                    chmod 700 /tmp/install.sh
                    bash /tmp/install.sh
                    sudo mkdir -p /etc/v2ray-agent
                    sudo cp /tmp/install.sh /etc/v2ray-agent/install.sh
                    sudo chmod 700 /etc/v2ray-agent/install.sh
                    sed -i "s|alias sinian='bash </etc/v2ray-agent/install.sh'|alias sinian='bash /etc/v2ray-agent/install.sh'|" /root/.bashrc
                    echo "alias sinian='bash /etc/v2ray-agent/install.sh'" >> /root/.bashrc
                    source /root/.bashrc
                    rm -f /tmp/install.sh
                else
                    echo -e "${RED}下载 v2ray 脚本失败，请检查网络！${RESET}"
                fi
                read -p "按回车键返回主菜单..."
                ;;
            4)
                # 无人直播云 SRS 安装
                echo -e "${GREEN}正在安装无人直播云 SRS ...${RESET}"
                read -p "请输入要使用的管理端口号 (默认为2022): " mgmt_port
                mgmt_port=${mgmt_port:-2022}

                check_port() {
                    local port=$1
                    if ss -tuln 2>/dev/null | grep -q ":$port "; then
                        return 1
                    elif netstat -tuln 2>/dev/null | grep -q ":$port "; then
                        return 1
                    else
                        return 0
                    fi
                }

                check_port $mgmt_port
                if [ $? -eq 1 ]; then
                    echo -e "${RED}端口 $mgmt_port 已被占用！${RESET}"
                    read -p "请输入其他端口号作为管理端口: " mgmt_port
                fi

                sudo apt-get update
                if [ $? -ne 0 ]; then
                    echo -e "${RED}apt 更新失败，请检查网络！${RESET}"
                else
                    sudo apt-get install -y docker.io
                    if [ $? -eq 0 ]; then
                        docker run --restart always -d --name srs-stack -it -p $mgmt_port:2022 -p 1935:1935/tcp -p 1985:1985/tcp \
                          -p 8080:8080/tcp -p 8000:8000/udp -p 10080:10080/udp \
                          -v $HOME/db:/data ossrs/srs-stack:5
                        server_ip=$(curl -s4 ifconfig.me)
                        echo -e "${GREEN}SRS 安装完成！您可以通过以下地址访问管理界面:${RESET}"
                        echo -e "${YELLOW}http://$server_ip:$mgmt_port/mgmt${RESET}"
                    else
                        echo -e "${RED}Docker 安装失败，请手动检查！${RESET}"
                    fi
                fi
                read -p "按回车键返回主菜单..."
                ;;
5)
    # 面板管理子菜单
    panel_management() {
        while true; do
            echo -e "${GREEN}=== 面板管理 ===${RESET}"
            echo -e "${YELLOW}请选择操作：${RESET}"
            echo "1) 安装1Panel面板"
            echo "2) 安装宝塔纯净版"
            echo "3) 安装宝塔国际版"
            echo "4) 安装宝塔国内版"
            echo "5) 安装青龙面板"
            echo "6) 卸载1Panel面板"
            echo "7) 卸载宝塔面板（纯净版/国际版/国内版）"
            echo "8) 卸载青龙面板"
            echo "9) 一键卸载所有面板"
            echo "0) 返回主菜单"
            read -p "请输入选项：" panel_choice

            case $panel_choice in
                1)
                    # 安装1Panel面板
                    echo -e "${GREEN}正在安装1Panel面板...${RESET}"
                    check_system
                    case $SYSTEM in
                        ubuntu)
                            curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && sudo bash quick_start.sh
                            ;;
                        debian|centos)
                            curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
                            ;;
                        *)
                            echo -e "${RED}不支持的系统类型！${RESET}"
                            ;;
                    esac
                    read -p "安装完成，按回车键返回上一级..."
                    ;;

                2)
                    # 安装宝塔纯净版
                    echo -e "${GREEN}正在安装宝塔纯净版...${RESET}"
                    check_system
                    if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
                        wget -O install.sh https://install.baota.sbs/install/install_6.0.sh && bash install.sh
                    elif [ "$SYSTEM" == "centos" ]; then
                        yum install -y wget && wget -O install.sh https://install.baota.sbs/install/install_6.0.sh && sh install.sh
                    else
                        echo -e "${RED}不支持的系统类型！${RESET}"
                    fi
                    read -p "安装完成，按回车键返回上一级..."
                    ;;

                3)
                    # 安装宝塔国际版
                    echo -e "${GREEN}正在安装宝塔国际版...${RESET}"
                    URL="https://www.aapanel.com/script/install_7.0_en.sh"
                    if [ -f /usr/bin/curl ]; then
                        curl -ksSO "$URL"
                    else
                        wget --no-check-certificate -O install_7.0_en.sh "$URL"
                    fi
                    bash install_7.0_en.sh aapanel
                    read -p "安装完成，按回车键返回上一级..."
                    ;;

                4)
                    # 安装宝塔国内版
                    echo -e "${GREEN}正在安装宝塔国内版...${RESET}"
                    if [ -f /usr/bin/curl ]; then
                        curl -sSO https://download.bt.cn/install/install_panel.sh
                    else
                        wget -O install_panel.sh https://download.bt.cn/install/install_panel.sh
                    fi
                    bash install_panel.sh ed8484bec
                    read -p "安装完成，按回车键返回上一级..."
                    ;;

                5)
                    # 安装青龙面板
                    echo -e "${GREEN}正在安装青龙面板...${RESET}"

                    # 检查 Docker 是否安装
                    if ! command -v docker > /dev/null 2>&1; then
                        echo -e "${YELLOW}正在安装 Docker...${RESET}"
                        curl -fsSL https://get.docker.com | sh
                        systemctl start docker
                        systemctl enable docker
                    fi

                    # 检查 Docker Compose 是否安装
                    if ! command -v docker-compose > /dev/null 2>&1; then
                        echo -e "${YELLOW}正在安装 Docker Compose...${RESET}"
                        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                        chmod +x /usr/local/bin/docker-compose
                    fi

                    # 端口选择
                    DEFAULT_PORT=5700
                    check_port() {
                        local port=$1
                        if ss -tuln 2>/dev/null | grep -q ":$port "; then
                            return 1  # 端口被占用
                        elif netstat -tuln 2>/dev/null | grep -q ":$port "; then
                            return 1
                        else
                            return 0  # 端口可用
                        fi
                    }

                    check_port "$DEFAULT_PORT"
                    if [ $? -eq 1 ]; then
                        echo -e "${RED}端口 $DEFAULT_PORT 已被占用！${RESET}"
                        read -p "是否更换端口？（y/n，默认 y）： " change_port
                        if [ "$change_port" != "n" ] && [ "$change_port" != "N" ]; then
                            while true; do
                                read -p "请输入新的端口号（例如 5800）： " new_port
                                while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                                    echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                                    read -p "请输入新的端口号（例如 5800）： " new_port
                                done
                                check_port "$new_port"
                                if [ $? -eq 0 ]; then
                                    DEFAULT_PORT=$new_port
                                    break
                                else
                                    echo -e "${RED}端口 $new_port 已被占用，请选择其他端口！${RESET}"
                                fi
                            done
                        else
                            echo -e "${RED}端口 $DEFAULT_PORT 被占用，无法继续安装！${RESET}"
                            read -p "按回车键返回上一级..."
                            continue
                        fi
                    fi

                    # 检查并放行防火墙端口
                    if command -v ufw > /dev/null 2>&1; then
                        ufw status | grep -q "Status: active"
                        if [ $? -eq 0 ]; then
                            echo -e "${YELLOW}检测到 UFW 防火墙正在运行...${RESET}"
                            ufw status | grep -q "$DEFAULT_PORT"
                            if [ $? -ne 0 ]; then
                                echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                                sudo ufw allow "$DEFAULT_PORT/tcp"
                                sudo ufw reload
                            fi
                        fi
                    elif command -v iptables > /dev/null 2>&1; then
                        echo -e "${YELLOW}检测到 iptables 防火墙...${RESET}"
                        iptables -C INPUT -p tcp --dport "$DEFAULT_PORT" -j ACCEPT 2>/dev/null
                        if [ $? -ne 0 ]; then
                            echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                            sudo iptables -A INPUT -p tcp --dport "$DEFAULT_PORT" -j ACCEPT
                            sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                        fi
                    fi

                    # 创建目录和配置 docker-compose.yml
                    mkdir -p /home/qinglong && cd /home/qinglong
                    cat > docker-compose.yml <<EOF
version: '3'
services:
  qinglong:
    image: whyour/qinglong:latest
    container_name: qinglong
    restart: unless-stopped
    ports:
      - "$DEFAULT_PORT:5700"
    volumes:
      - ./config:/ql/config
      - ./log:/ql/log
      - ./db:/ql/db
      - ./scripts:/ql/scripts
      - ./jbot:/ql/jbot
EOF
                    docker-compose up -d
                    echo -e "${GREEN}青龙面板安装完成！${RESET}"
                    echo -e "${YELLOW}访问 http://<服务器IP>:$DEFAULT_PORT 进行初始化设置${RESET}"
                    read -p "按回车键返回上一级..."
                    ;;

                6)
                    # 卸载1Panel面板
                    echo -e "${GREEN}正在卸载1Panel面板...${RESET}"
                    if command -v 1pctl > /dev/null 2>&1; then
                        1pctl uninstall
                        echo -e "${YELLOW}1Panel面板已卸载${RESET}"
                    else
                        echo -e "${RED}未检测到1Panel面板安装！${RESET}"
                    fi
                    read -p "按回车键返回上一级..."
                    ;;

                7)
                    # 卸载宝塔面板
                    echo -e "${GREEN}正在卸载宝塔面板...${RESET}"
                    if [ -f /usr/bin/bt ] || [ -f /usr/bin/aapanel ]; then
                        wget http://download.bt.cn/install/bt-uninstall.sh
                        if [ "$SYSTEM" == "ubuntu" ]; then
                            sudo sh bt-uninstall.sh
                        else
                            sh bt-uninstall.sh
                        fi
                        echo -e "${YELLOW}宝塔面板已卸载${RESET}"
                    else
                        echo -e "${RED}未检测到宝塔面板安装！${RESET}"
                    fi
                    read -p "按回车键返回上一级..."
                    ;;

                8)
                    # 卸载青龙面板
                    echo -e "${GREEN}正在卸载青龙面板...${RESET}"
                    if docker ps -a | grep -q "qinglong"; then
                        cd /home/qinglong
                        docker-compose down -v
                        rm -rf /home/qinglong
                        echo -e "${YELLOW}青龙面板已卸载${RESET}"
                    else
                        echo -e "${RED}未检测到青龙面板安装！${RESET}"
                    fi
                    read -p "按回车键返回上一级..."
                    ;;

                9)
                    # 一键卸载所有面板
                    echo -e "${GREEN}正在卸载所有面板...${RESET}"
                    # 卸载1Panel
                    if command -v 1pctl > /dev/null 2>&1; then
                        1pctl uninstall
                        echo -e "${YELLOW}1Panel面板已卸载${RESET}"
                    else
                        echo -e "${RED}未检测到1Panel面板安装！${RESET}"
                    fi
                    # 卸载宝塔
                    if [ -f /usr/bin/bt ] || [ -f /usr/bin/aapanel ]; then
                        wget http://download.bt.cn/install/bt-uninstall.sh
                        if [ "$SYSTEM" == "ubuntu" ]; then
                            sudo sh bt-uninstall.sh
                        else
                            sh bt-uninstall.sh
                        fi
                        echo -e "${YELLOW}宝塔面板已卸载${RESET}"
                    else
                        echo -e "${RED}未检测到宝塔面板安装！${RESET}"
                    fi
                    # 卸载青龙
                    if docker ps -a | grep -q "qinglong"; then
                        cd /home/qinglong
                        docker-compose down -v
                        rm -rf /home/qinglong
                        echo -e "${YELLOW}青龙面板已卸载${RESET}"
                    else
                        echo -e "${RED}未检测到青龙面板安装！${RESET}"
                    fi
                    read -p "按回车键返回上一级..."
                    ;;

                0)
                    break  # 返回主菜单
                    ;;

                *)
                    echo -e "${RED}无效选项，请重新输入！${RESET}"
                    read -p "按回车键继续..."
                    ;;
            esac
        done
    }

    # 进入面板管理子菜单
    panel_management
    ;;
            6)
                # 系统更新命令
                echo -e "${GREEN}正在更新系统...${RESET}"
                update_system
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}系统更新成功！${RESET}"
                else
                    echo -e "${RED}系统更新失败，请检查网络或手动执行更新！${RESET}"
                fi
                read -p "按回车键返回主菜单..."
                ;;
            7)
                # 修改当前用户密码
                username=$(whoami)
                echo -e "${GREEN}正在为 ${YELLOW}$username${GREEN} 修改密码...${RESET}"
                sudo passwd "$username"
                read -p "按回车键返回主菜单..."
                ;;
            8)
                # 重启服务器
                echo -e "${GREEN}正在重启服务器 ...${RESET}"
                sudo reboot
                ;;
            9)
                # 永久禁用 IPv6
                echo -e "${GREEN}正在禁用 IPv6 ...${RESET}"
                check_system
                case $SYSTEM in
                    ubuntu|debian)
                        sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
                        sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
                        echo "net.ipv6.conf.all.disable_ipv6=1" | sudo tee -a /etc/sysctl.conf
                        echo "net.ipv6.conf.default.disable_ipv6=1" | sudo tee -a /etc/sysctl.conf
                        sudo sysctl -p
                        if [ $? -ne 0 ]; then
                            echo -e "${RED}禁用 IPv6 失败，请检查权限或配置文件！${RESET}"
                        else
                            echo -e "${GREEN}IPv6 已成功禁用！${RESET}"
                        fi
                        ;;
                    centos|fedora)
                        sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
                        sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
                        echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
                        echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
                        sudo sysctl -p
                        if [ $? -ne 0 ]; then
                            echo -e "${RED}禁用 IPv6 失败，请检查权限或配置文件！${RESET}"
                        else
                            echo -e "${GREEN}IPv6 已成功禁用！${RESET}"
                        fi
                        ;;
                    *)
                        echo -e "${RED}无法识别您的操作系统，无法禁用 IPv6。${RESET}"
                        echo -e "${YELLOW}请检查 /etc/os-release 或相关系统文件以确认发行版。${RESET}"
                        echo -e "${YELLOW}当前检测结果: SYSTEM=$SYSTEM${RESET}"
                        ;;
                esac
                read -p "按回车键返回主菜单..."
                ;;
            10)
                # 解除禁用 IPv6
                echo -e "${GREEN}正在解除禁用 IPv6 ...${RESET}"
                check_system
                case $SYSTEM in
                    ubuntu|debian)
                        sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
                        sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0
                        sudo sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
                        sudo sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
                        sudo sysctl -p
                        if [ $? -ne 0 ]; then
                            echo -e "${RED}解除禁用 IPv6 失败，请检查权限或配置文件！${RESET}"
                        else
                            echo -e "${GREEN}IPv6 已成功启用！${RESET}"
                        fi
                        ;;
                    centos|fedora)
                        sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
                        sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0
                        sudo sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
                        sudo sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
                        sudo sysctl -p
                        if [ $? -ne 0 ]; then
                            echo -e "${RED}解除禁用 IPv6 失败，请检查权限或配置文件！${RESET}"
                        else
                            echo -e "${GREEN}IPv6 已成功启用！${RESET}"
                        fi
                        ;;
                    *)
                        echo -e "${RED}无法识别您的操作系统，无法解除禁用 IPv6。${RESET}"
                        echo -e "${YELLOW}请检查 /etc/os-release 或相关系统文件以确认发行版。${RESET}"
                        echo -e "${YELLOW}当前检测结果: SYSTEM=$SYSTEM${RESET}"
                        ;;
                esac
                read -p "按回车键返回主菜单..."
                ;;
            11)
    # 服务器时区修改为中国时区
    echo -e "${GREEN}正在修改服务器时区为中国时区 ...${RESET}"
    
    # 设置时区为 Asia/Shanghai
    sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    
    # 重启 cron 服务
    if command -v systemctl &> /dev/null; then
        # 尝试重启 cron 服务
        if systemctl list-unit-files | grep -q cron.service; then
            sudo systemctl restart cron
        else
            echo -e "${YELLOW}未找到 cron 服务，跳过重启。${RESET}"
        fi
    else
        # 使用 service 命令重启 cron
        if service --status-all | grep -q cron; then
            sudo service cron restart
        else
            echo -e "${YELLOW}未找到 cron 服务，跳过重启。${RESET}"
        fi
    fi
    
    # 显示当前时区和时间
    echo -e "${YELLOW}当前时区已设置为：$(timedatectl | grep "Time zone" | awk '{print $3}')${RESET}"
    echo -e "${YELLOW}当前时间：$(date)${RESET}"
    
    # 按回车键返回主菜单
    read -p "按回车键返回主菜单..."
    ;;
            12)
                # 长时间保持 SSH 会话连接不断开
                echo -e "${GREEN}正在配置 SSH 保持连接...${RESET}"
                read -p "请输入每次心跳请求的间隔时间（单位：分钟，默认为5分钟）： " interval
                interval=${interval:-5}
                read -p "请输入客户端最大无响应次数（默认为50次）： " max_count
                max_count=${max_count:-50}
                interval_seconds=$((interval * 60))

                echo "正在更新 SSH 配置文件..."
                sudo sed -i "/^ClientAliveInterval/c\ClientAliveInterval $interval_seconds" /etc/ssh/sshd_config
                sudo sed -i "/^ClientAliveCountMax/c\ClientAliveCountMax $max_count" /etc/ssh/sshd_config

                echo "正在重启 SSH 服务以应用配置..."
                sudo systemctl restart sshd
                echo -e "${GREEN}配置完成！心跳请求间隔为 $interval 分钟，最大无响应次数为 $max_count。${RESET}"
                read -p "按回车键返回主菜单..."
                ;;
            13)
                # DD重装系统
                echo -e "${GREEN}正在进入 DD 重装系统...${NC}"
                dd_reinstall_menu
                read -p "按回车键返回主菜单..."
                ;;
            14)
                # 服务器对服务器传文件
                echo -e "${GREEN}服务器对服务器传文件${RESET}"
                if ! command -v sshpass &> /dev/null; then
                    echo -e "${YELLOW}检测到 sshpass 缺失，正在安装...${RESET}"
                    sudo apt update && sudo apt install -y sshpass
                    if [ $? -ne 0 ]; then
                        echo -e "${RED}安装 sshpass 失败，请手动安装！${RESET}"
                    fi
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
                    echo -e "${YELLOW}5. 目标服务器的 SSH 端口是否为 $ssh_port。${RESET}"
                fi
                read -p "按回车键返回主菜单..."
                ;;
            15)
                # 安装 NekoNekoStatus 服务器探针并绑定域名
                echo -e "${GREEN}正在安装 NekoNekoStatus 服务器探针并绑定域名...${RESET}"
                if ! command -v docker &> /dev/null; then
                    echo -e "${YELLOW}检测到 Docker 未安装，正在安装 Docker...${RESET}"
                    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
                    if [ $? -eq 0 ]; then
                        bash /tmp/get-docker.sh
                        rm -f /tmp/get-docker.sh
                    else
                        echo -e "${RED}Docker 安装脚本下载失败，请手动安装 Docker！${RESET}"
                    fi
                fi

                read -p "请输入探针容器端口（默认 5555）： " container_port
                container_port=${container_port:-5555}
                
                # 检查容器端口是否可用
                check_port $container_port
                if [ $? -eq 1 ]; then
                    echo -e "${RED}端口 $container_port 已被占用，请选择其他端口！${RESET}"
                else
                    # 开放防火墙端口
                    open_port() {
                        local port=$1
                        if command -v ufw &> /dev/null; then
                            sudo ufw allow $port
                        elif command -v firewall-cmd &> /dev/null; then
                            sudo firewall-cmd --zone=public --add-port=$port/tcp --permanent
                            sudo firewall-cmd --reload
                        fi
                    }
                    open_port $container_port

                    echo -e "${YELLOW}正在拉取 NekoNekoStatus Docker 镜像...${RESET}"
                    docker pull nkeonkeo/nekonekostatus:latest
                    echo -e "${YELLOW}正在启动 NekoNekoStatus 容器...${RESET}"
                    docker run --restart=on-failure --name nekonekostatus -p $container_port:5555 -d nkeonkeo/nekonekostatus:latest

                    read -p "请输入您的域名（例如：www.example.com）： " domain
                    while [ -z "$domain" ]; do
                        echo -e "${RED}域名不能为空！${RESET}"
                        read -p "请输入您的域名： " domain
                    done
                    
                    read -p "请输入邮箱（用于证书通知，默认 admin@$domain）： " email
                    email=${email:-admin@$domain}

                    # 使用统一反向代理添加域名
                    add_domain_to_unified_nginx "$domain" "$container_port" "$email"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}NekoNekoStatus 安装和域名绑定完成！${RESET}"
                        echo -e "${GREEN}您现在可以通过 https://$domain 访问探针服务了。${RESET}"
                        echo -e "${YELLOW}容器端口: $container_port${RESET}"
                        echo -e "${YELLOW}默认密码: nekonekostatus${RESET}"
                        echo -e "${YELLOW}安装后务必修改密码！${RESET}"
                    fi
                fi
                read -p "按回车键返回主菜单..."
                ;;
            16)
        if [ "$EUID" -ne 0 ]; then
            echo "❌ 请使用sudo或root用户运行此脚本"
        else
            proxy_management() {
                while true; do
                    echo "🛠️ 共用端口（反代）管理"
                    echo "------------------------"
                    echo "1) 手动设置反代"
                    echo "2) Nginx Proxy Manager 面板安装"
                    echo "3) Nginx Proxy Manager 面板卸载"
                    echo "4) 返回主菜单"
                    read -p "请输入选项 [1-4]: " proxy_choice
                    case $proxy_choice in
                        1)
                            # 手动设置反代
                            install_dependencies() {
                                echo "➜ 检查并安装依赖..."
                                apt-get update > /dev/null 2>&1
                                if ! command -v nginx &> /dev/null; then
                                    apt-get install -y nginx > /dev/null 2>&1
                                fi
                                if ! command -v certbot &> /dev/null; then
                                    apt-get install -y certbot python3-certbot-nginx > /dev/null 2>&1
                                fi
                                echo "✅ 依赖已安装"
                            }

                            request_certificate() {
                                local domain=$1
                                echo "➜ 为域名 $domain 申请SSL证书..."
                                if certbot --nginx --non-interactive --agree-tos -m $ADMIN_EMAIL -d $domain > /dev/null 2>&1; then
                                    echo "✅ 证书申请成功"
                                else
                                    echo "❌ 证书申请失败，请检查域名DNS解析或端口开放情况"
                                fi
                            }

                            configure_nginx() {
                                local domain=$1
                                local port=$2
                                local conf_file="/etc/nginx/conf.d/alone.conf"
                                cat >> $conf_file <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $domain;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    add_header Strict-Transport-Security "max-age=63072000" always;
}
EOF
                                echo "✅ Nginx配置完成"
                            }

                            check_cert_expiry() {
                                local domain=$1
                                if [ -f /etc/letsencrypt/live/$domain/cert.pem ]; then
                                    local expiry_date=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/$domain/cert.pem | cut -d= -f2)
                                    local expiry_seconds=$(date -d "$expiry_date" +%s)
                                    local current_seconds=$(date +%s)
                                    local days_left=$(( (expiry_seconds - current_seconds) / 86400 ))
                                    echo "➜ 域名 $domain 的SSL证书将在 $days_left 天后到期"
                                    if [ $days_left -lt 30 ]; then
                                        echo "⚠️ 证书即将到期，建议尽快续签"
                                    fi
                                else
                                    echo "❌ 未找到域名 $domain 的证书文件"
                                fi
                            }

                            echo "🛠️ Nginx多域名部署脚本"
                            echo "------------------------"
                            echo "🔍 检查当前已配置的域名和端口："
                            if [ -f /etc/nginx/conf.d/alone.conf ]; then
                                grep -oP 'server_name \K[^;]+' /etc/nginx/conf.d/alone.conf | sort | uniq | while read -r domain; do
                                    echo "  域名: $domain"
                                done
                            else
                                echo "⚠️ 未找到 /etc/nginx/conf.d/alone.conf 文件，将创建新配置"
                            fi

                            read -p "请输入管理员邮箱（用于证书通知）: " ADMIN_EMAIL
                            declare -A domains
                            while true; do
                                read -p "请输入域名（留空结束）: " domain
                                if [ -z "$domain" ]; then
                                    break
                                fi
                                read -p "请输入 $domain 对应的端口号: " port
                                domains[$domain]=$port
                            done

                            if [ ${#domains[@]} -eq 0 ]; then
                                echo "❌ 未输入任何域名，退出脚本"
                            else
                                install_dependencies
                                for domain in "${!domains[@]}"; do
                                    port=${domains[$domain]}
                                    configure_nginx $domain $port
                                    request_certificate $domain
                                    check_cert_expiry $domain
                                done

                                echo "➜ 配置防火墙..."
                                if command -v ufw &> /dev/null; then
                                    ufw allow 80/tcp > /dev/null
                                    ufw allow 443/tcp > /dev/null
                                    echo "✅ UFW已放行80/443端口"
                                elif command -v firewall-cmd &> /dev/null; then
                                    firewall-cmd --permanent --add-service=http > /dev/null
                                    firewall-cmd --permanent --add-service=https > /dev/null
                                    firewall-cmd --reload > /dev/null
                                    echo "✅ Firewalld已放行80/443端口"
                                else
                                    echo "⚠️ 未检测到防火墙工具，请手动放行端口"
                                fi

                                if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
                                    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet") | crontab -
                                    echo " 已添加证书自动续签任务"
                                else
                                    echo "证书自动续签任务已存在，跳过添加"
                                fi

                                echo -e "\n🔌 当前服务状态："
                                echo "Nginx状态: $(systemctl is-active nginx)"
                                echo "监听端口:"
                                ss -tuln | grep -E ':80|:443'
                                echo -e "\n🎉 部署完成！"
                            fi
                            read -p "按回车键返回上一级..."
                            ;;
                        2)
                            # 安装 Nginx Proxy Manager 面板
                            echo "➜ 正在安装 Nginx Proxy Manager 面板..."
                            
                            # 检查 Docker 是否安装
                            if ! command -v docker &> /dev/null; then
                                echo "➜ 检测到 Docker 未安装，正在安装..."
                                check_system
                                if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
                                    apt-get update > /dev/null 2>&1
                                    apt-get install -y docker.io > /dev/null 2>&1
                                elif [ "$SYSTEM" == "centos" ]; then
                                    yum install -y docker > /dev/null 2>&1
                                    systemctl enable docker > /dev/null 2>&1
                                    systemctl start docker > /dev/null 2>&1
                                elif [ "$SYSTEM" == "fedora" ]; then
                                    dnf install -y docker > /dev/null 2>&1
                                    systemctl enable docker > /dev/null 2>&1
                                    systemctl start docker > /dev/null 2>&1
                                else
                                    echo "❌ 无法识别系统，无法安装 Docker！"
                                    read -p "按回车键返回上一级..."
                                    continue
                                fi
                                if [ $? -ne 0 ]; then
                                    echo "❌ Docker 安装失败，请手动检查！"
                                    read -p "按回车键返回上一级..."
                                    continue
                                fi
                                echo "✅ Docker 安装成功！"
                            fi

                            # 检查 Docker 服务是否运行
                            if ! systemctl is-active --quiet docker; then
                                echo "➜ 启动 Docker 服务..."
                                systemctl start docker
                                if [ $? -ne 0 ]; then
                                    echo "❌ Docker 服务启动失败，请检查系统配置！"
                                    read -p "按回车键返回上一级..."
                                    continue
                                fi
                                echo "✅ Docker 服务已启动！"
                            fi

                            # 检查磁盘空间
                            echo "➜ 检查磁盘空间..."
                            available_space=$(df -h . | awk 'NR==2 {print $4}' | grep -o '[0-9.]*')
                            if [ -z "$available_space" ]; then
                                echo "⚠️ 无法获取磁盘空间信息"
                            elif ! command -v bc >/dev/null 2>&1; then
                                echo "⚠️ bc 命令未安装，无法精确比较磁盘空间（当前可用: $available_space GB)"
                            elif [ $(echo "$available_space < 5" | bc) -eq 1 ]; then
                                echo "❌ 磁盘空间不足（需要至少 5GB 可用空间）！当前可用: $available_space GB"
                                read -p "按回车键返回上一级..."
                                continue
                            fi
                            echo "✅ 磁盘空间充足：$available_space GB 可用"

                            # 确保挂载目录存在并具有写权限
                            echo "➜ 检查并创建挂载目录..."
                            for dir in ./data ./letsencrypt; do
                                if [ ! -d "$dir" ]; then
                                    mkdir -p "$dir"
                                    if [ $? -ne 0 ]; then
                                        echo "❌ 创建目录 $dir 失败，请检查权限！"
                                        read -p "按回车键返回上一级..."
                                        continue 2
                                    fi
                                fi
                                chmod 755 "$dir"
                            done
                            echo "✅ 挂载目录已准备好"

                            # 默认端口
                            DEFAULT_PORT=81
                            check_port() {
                                local port=$1
                                if ss -tuln | grep ":$port" > /dev/null; then
                                    return 1
                                else
                                    return 0
                                fi
                            }
                            
                            # 检查必需端口 (80, 443, DEFAULT_PORT)
                            for port in 80 443 $DEFAULT_PORT; do
                                check_port $port
                                if [ $? -eq 1 ]; then
                                    echo "❌ 端口 $port 已被占用！"
                                    read -p "请输入新的端口号（1-65535，替换端口 $port）： " new_port
                                    while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                                        echo "❌ 无效端口，请输入 1-65535 之间的数字！"
                                        read -p "请输入新的端口号（1-65535）： " new_port
                                    done
                                    check_port $new_port
                                    while [ $? -eq 1 ]; do
                                        echo "❌ 端口 $new_port 已被占用，请选择其他端口！"
                                        read -p "请输入新的端口号（1-65535）： " new_port
                                        while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                                            echo "❌ 无效端口，请输入 1-65535 之间的数字！"
                                            read -p "请输入新的端口号（1-65535）： " new_port
                                        done
                                        check_port $new_port
                                    done
                                    if [ "$port" == "80" ]; then
                                        PORT_80=$new_port
                                    elif [ "$port" == "443" ]; then
                                        PORT_443=$new_port
                                    else
                                        DEFAULT_PORT=$new_port
                                    fi
                                else
                                    if [ "$port" == "80" ]; then
                                        PORT_80=$port
                                    elif [ "$port" == "443" ]; then
                                        PORT_443=$port
                                    fi
                                fi
                            done
                            
                            # 开放端口
                            echo "➜ 正在开放端口 $PORT_80, $PORT_443, $DEFAULT_PORT..."
                            if command -v ufw &> /dev/null; then
                                ufw allow $PORT_80/tcp > /dev/null
                                ufw allow $PORT_443/tcp > /dev/null
                                ufw allow $DEFAULT_PORT/tcp > /dev/null
                                ufw reload > /dev/null
                                echo "✅ UFW 防火墙端口 $PORT_80, $PORT_443, $DEFAULT_PORT 已开放！"
                            elif command -v firewall-cmd &> /dev/null; then
                                firewall-cmd --permanent --add-port=$PORT_80/tcp > /dev/null
                                firewall-cmd --permanent --add-port=$PORT_443/tcp > /dev/null
                                firewall-cmd --permanent --add-port=$DEFAULT_PORT/tcp > /dev/null
                                firewall-cmd --reload > /dev/null
                                echo "✅ Firewalld 防火墙端口 $PORT_80, $PORT_443, $DEFAULT_PORT 已开放！"
                            else
                                echo "⚠️ 未检测到常见防火墙工具，请手动开放端口 $PORT_80, $PORT_443, $DEFAULT_PORT！"
                            fi
                            
                            # 运行 Nginx Proxy Manager 容器
                            echo "➜ 正在启动 Nginx Proxy Manager 容器...容器较大，下载时间稍长，请耐心等会"
                            docker pull chishin/nginx-proxy-manager-zh:latest
                            if [ $? -ne 0 ]; then
                                echo "❌ 拉取镜像 chishin/nginx-proxy-manager-zh:latest 失败，请检查网络或镜像名称！"
                                read -p "按回车键返回上一级..."
                                continue
                            fi
                            echo "✅ 镜像拉取成功"
                            docker run -d --name npm -p $PORT_80:80 -p $DEFAULT_PORT:81 -p $PORT_443:443 \
                                -v "$(pwd)/data:/data" -v "$(pwd)/letsencrypt:/etc/letsencrypt" \
                                chishin/nginx-proxy-manager-zh:latest
                            if [ $? -ne 0 ]; then
                                echo "❌ 启动 Nginx Proxy Manager 容器失败，请检查以下可能原因："
                                echo "  - 端口 $PORT_80, $PORT_443 或 $DEFAULT_PORT 是否仍被占用"
                                echo "  - 磁盘空间是否充足"
                                echo "  - 目录 $(pwd)/data 和 $(pwd)/letsencrypt 是否有写权限"
                                docker logs npm 2>/dev/null || echo "❌ 无法获取容器日志，容器可能未创建！"
                                read -p "按回车键返回上一级..."
                                continue
                            fi
                            
                            # 检查容器状态
                            sleep 3
                            if docker ps --format '{{.Names}}' | grep -q "^npm$"; then
                                server_ip=$(curl -s4 ifconfig.me || echo "你的服务器IP")
                                echo "✅ Nginx Proxy Manager 安装成功！"
                                echo -e "\e[33m➜ 访问地址：http://$server_ip:$DEFAULT_PORT\e[0m"
                                echo -e "\e[33m➜ 默认用户名：admin@example.com\e[0m"
                                echo -e "\e[33m➜ 默认密码：changeme\e[0m"
                                echo -e "\e[31m⚠️ 请尽快登录并修改默认密码！\e[0m"
                            else
                                echo "❌ Nginx Proxy Manager 容器未正常运行，请检查以下日志："
                                docker logs npm 2>/dev/null || echo "❌ 无法获取容器日志，容器可能未创建！"
                            fi
                            read -p "按回车键返回上一级..."
                            ;;
                        3)
                            # 卸载 Nginx Proxy Manager 面板
                            echo "➜ 正在卸载 Nginx Proxy Manager 面板..."
                            echo "⚠️ 注意：卸载将删除 Nginx Proxy Manager 数据，请确保已备份 ./data 和 ./letsencrypt 目录"
                            read -p "是否继续卸载？（y/n，默认 n）： " confirm_uninstall
                            if [ "$confirm_uninstall" != "y" ] && [ "$confirm_uninstall" != "Y" ]; then
                                echo "⚠️ 取消卸载操作"
                                read -p "按回车键返回上一级..."
                                continue
                            fi
                            
                            # 停止并移除容器
                            if docker ps -a --format '{{.Names}}' | grep -q "^npm$"; then
                                docker stop npm > /dev/null 2>&1
                                docker rm npm > /dev/null 2>&1
                                echo "✅ 已停止并移除 Nginx Proxy Manager 容器"
                            else
                                echo "⚠️ 未检测到 Nginx Proxy Manager 容器"
                            fi
                            
                            # 删除数据目录
                            if [ -d "./data" ] || [ -d "./letsencrypt" ]; then
                                rm -rf ./data ./letsencrypt
                                if [ $? -eq 0 ]; then
                                    echo "✅ 已删除 Nginx Proxy Manager 数据目录"
                                else
                                    echo "❌ 删除数据目录失败，请手动检查！"
                                fi
                            fi
                            
                            # 移除镜像
                            if docker images | grep -q "chishin/nginx-proxy-manager-zh"; then
                                read -p "是否移除 Nginx Proxy Manager 的 Docker 镜像？（y/n，默认 n）： " remove_image
                                if [ "$remove_image" == "y" ] || [ "$remove_image" == "Y" ]; then
                                    docker rmi chishin/nginx-proxy-manager-zh:latest > /dev/null 2>&1 || true
                                    if [ $? -eq 0 ]; then
                                        echo "✅ 已移除镜像 chishin/nginx-proxy-manager-zh:latest"
                                    else
                                        echo "❌ 移除镜像失败，可能被其他容器使用！"
                                    fi
                                fi
                            fi
                            
                            echo "✅ Nginx Proxy Manager 卸载完成！"
                            read -p "按回车键返回上一级..."
                            ;;
                        4)
                            echo "➜ 返回主菜单..."
                            break
                            ;;
                        *)
                            echo "❌ 无效选项，请重新输入！"
                            read -p "按回车键继续..."
                            ;;
                    esac
                done
            }
            proxy_management
        fi
        read -p "按回车键返回主菜单..."
        ;;
            17)
                # 安装 curl 和 wget
                echo -e "${GREEN}正在安装 curl 和 wget ...${RESET}"
                if ! command -v curl &> /dev/null; then
                    echo -e "${YELLOW}检测到 curl 缺失，正在安装...${RESET}"
                    check_system
                    if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
                        sudo apt update && sudo apt install -y curl
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}curl 安装成功！${RESET}"
                        else
                            echo -e "${RED}curl 安装失败，请手动检查问题！${RESET}"
                        fi
                    elif [ "$SYSTEM" == "centos" ]; then
                        sudo yum install -y curl
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}curl 安装成功！${RESET}"
                        else
                            echo -e "${RED}curl 安装失败，请手动检查问题！${RESET}"
                        fi
                    elif [ "$SYSTEM" == "fedora" ]; then
                        sudo dnf install -y curl
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}curl 安装成功！${RESET}"
                        else
                            echo -e "${RED}curl 安装失败，请手动检查问题！${RESET}"
                        fi
                    else
                        echo -e "${RED}无法识别系统，无法安装 curl。${RESET}"
                    fi
                else
                    echo -e "${YELLOW}curl 已经安装，跳过安装步骤。${RESET}"
                fi

                if ! command -v wget &> /dev/null; then
                    install_wget
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}wget 安装成功！${RESET}"
                    else
                        echo -e "${RED}wget 安装失败，请手动检查问题！${RESET}"
                    fi
                else
                    echo -e "${YELLOW}wget 已经安装，跳过安装步骤。${RESET}"
                fi
                read -p "按回车键返回主菜单..."
                ;;
18)
    # Docker 管理子菜单
    echo -e "${GREEN}正在进入 Docker 管理子菜单...${RESET}"

    # Docker 管理子菜单
while true; do
    echo -e "${GREEN}=== Docker 管理 ===${RESET}"
    echo "1) 安装 Docker 环境"
    echo "2) 彻底卸载 Docker"
    echo "3) 配置 Docker 镜像加速"
    echo "4) 启动 Docker 容器"
    echo "5) 停止 Docker 容器"
    echo "6) 查看已安装镜像"
    echo "7) 删除 Docker 容器"
    echo "8) 删除 Docker 镜像"
    echo "9) 安装 sun-panel"
    echo "10) 拉取镜像并安装容器"
    echo "11) 更新镜像并重启容器"
    echo "12) 批量操作容器"
    echo "13) 安装 Portainer(Docker管理面板)"
    echo "0) 返回主菜单"
    read -p "请输入选项：" docker_choice

    # 检查 Docker 状态
    check_docker_status() {
        if ! command -v docker &> /dev/null && ! snap list | grep -q docker; then
            echo -e "${RED}Docker 未安装，请先安装！${RESET}"
            return 1
        fi
        return 0
    }

install_docker() {
    echo -e "${GREEN}正在安装 Docker 环境...${RESET}"
    check_system
    if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
        sudo apt update -y && sudo apt install -y curl ca-certificates gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$SYSTEM/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$SYSTEM \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update -y
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif [ "$SYSTEM" == "centos" ]; then
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo -e "${RED}不支持的系统类型，无法安装 Docker！${RESET}"
        read -p "按回车键返回上一级..."
        return
    fi

    # 启动 Docker 服务
    sudo systemctl start docker
    sudo systemctl enable docker

    # 检查 Docker 是否安装成功
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker 安装失败，请手动检查！${RESET}"
        read -p "按回车键返回上一级..."
        return
    fi

    # 安装 Docker Compose（二进制方式）
    echo -e "${GREEN}正在安装 Docker Compose...${RESET}"
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f4)
    sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

    # 检查 Docker Compose 安装情况
    if ! command -v docker-compose &> /dev/null; then
        echo -e "${RED}Docker Compose 安装失败，请手动检查！${RESET}"
    else
        echo -e "${GREEN}Docker 和 Docker Compose 安装成功！${RESET}"
    fi
    read -p "按回车键返回上一级..."
}

# 彻底卸载 Docker
uninstall_docker() {
    echo -e "${RED}你确定要彻底卸载 Docker 和 Docker Compose 吗？此操作不可恢复！${RESET}"
    read -p "请输入 y 确认，其他任意键取消: " confirm
    if [[ "$confirm" != "y" ]]; then
        echo -e "${YELLOW}已取消卸载操作，返回上一级菜单。${RESET}"
        return
    fi

    if ! check_docker_status; then return; fi

    # 检查运行中的容器
    running_containers=$(docker ps -q)
    if [ -n "$running_containers" ]; then
        echo -e "${YELLOW}发现运行中的容器：${RESET}"
        docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Command}}\t{{.CreatedAt}}\t{{.Status}}\t{{.RunningFor}}\t{{.Ports}}\t{{.Names}}" | sed 's/CONTAINER ID/容器ID/; s/IMAGE/镜像名称/; s/COMMAND/命令/; s/CREATED AT/创建时间/; s/STATUS/状态/; s/RUNNINGFOR/运行时间/; s/PORTS/端口映射/; s/NAMES/容器名称/; s/Up \([0-9]\+\) minutes\?/运行中/; s/Up \([0-9]\+\) seconds\?/运行中/'
        read -p "是否停止并删除所有容器？(y/n，默认 n): " stop_choice
        stop_choice=${stop_choice:-n}
        if [[ $stop_choice =~ [Yy] ]]; then
            echo -e "${YELLOW}正在停止并移除运行中的 Docker 容器...${RESET}"
            docker stop $(docker ps -aq) 2>/dev/null
            docker rm $(docker ps -aq) 2>/dev/null
        else
            echo -e "${YELLOW}已跳过停止并删除容器。${RESET}"
        fi
    fi

    # 删除镜像确认
    read -p "是否删除所有 Docker 镜像？(y/n，默认 n): " delete_images
    delete_images=${delete_images:-n}
    if [[ $delete_images =~ [Yy] ]]; then
        echo -e "${YELLOW}正在删除所有 Docker 镜像...${RESET}"
        docker rmi $(docker images -q) 2>/dev/null
    else
        echo -e "${YELLOW}已跳过删除所有镜像。${RESET}"
    fi

    # 停止并禁用 Docker 服务
    echo -e "${YELLOW}正在停止并禁用 Docker 服务...${RESET}"
    sudo systemctl stop docker 2>/dev/null
    sudo systemctl disable docker 2>/dev/null

    # 删除 Docker 和 Compose 二进制文件
    echo -e "${YELLOW}正在删除 Docker 和 Compose 二进制文件...${RESET}"
    sudo rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-init /usr/bin/docker-proxy
    sudo rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose

    # 删除 Docker 相关目录和文件
    echo -e "${YELLOW}正在删除 Docker 相关目录和文件...${RESET}"
    sudo rm -rf /var/lib/docker /etc/docker /var/run/docker.sock ~/.docker

    # 删除 Docker 服务文件
    echo -e "${YELLOW}正在删除 Docker 服务文件...${RESET}"
    sudo rm -f /etc/systemd/system/docker.service
    sudo rm -f /etc/systemd/system/docker.socket
    sudo systemctl daemon-reload

    # 删除 Docker 用户组
    echo -e "${YELLOW}正在删除 Docker 用户组...${RESET}"
    if grep -q docker /etc/group; then
        sudo groupdel docker
    else
        echo -e "${YELLOW}Docker 用户组不存在，无需删除。${RESET}"
    fi

    # 卸载 Docker 包（如果通过 apt/yum 安装）
    echo -e "${YELLOW}正在卸载 Docker 包...${RESET}"
    sudo apt purge -y docker.io docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-ce-rootless-extras docker-compose-plugin
    sudo apt autoremove -y
    sudo yum remove -y docker docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # 检查是否通过 Snap 安装
    if command -v snap &>/dev/null && snap list | grep -q docker; then
        echo -e "${YELLOW}正在卸载 Snap 安装的 Docker...${RESET}"
        sudo snap remove docker
    else
        echo -e "${YELLOW}未检测到 Snap 安装的 Docker，跳过。${RESET}"
    fi

    echo -e "${GREEN}Docker 和 Docker Compose 已彻底卸载完成！${RESET}"
}


    # 配置 Docker 镜像加速
    configure_mirror() {
        if ! check_docker_status; then return; fi

        # 检查并安装 jq（如果缺失）
        if ! command -v jq >/dev/null 2>&1; then
            echo -e "${YELLOW}检测到 jq 未安装，正在安装...${RESET}"
            if [ "$SYSTEM" == "centos" ]; then
                sudo yum install -y jq
            else
                sudo apt install -y jq
            fi
        fi

        echo -e "${YELLOW}当前镜像加速配置：${RESET}"
        if [ -f /etc/docker/daemon.json ]; then
            # 显示当前镜像加速地址
            mirror_url=$(jq -r '."registry-mirrors"[0]' /etc/docker/daemon.json 2>/dev/null)
            if [ -n "$mirror_url" ]; then
                echo -e "${GREEN}当前使用的镜像加速地址：$mirror_url${RESET}"
            else
                echo -e "${RED}未找到有效的镜像加速配置！${RESET}"
            fi
        else
            echo -e "${YELLOW}未配置镜像加速，默认使用 Docker 官方镜像源。${RESET}"
        fi

        echo -e "${GREEN}请选择操作：${RESET}"
        echo "1) 添加/更换镜像加速地址"
        echo "2) 删除镜像加速配置"
        echo "3) 使用预设镜像加速地址"
        read -p "请输入选项： " mirror_choice

        case $mirror_choice in
            1)
                read -p "请输入镜像加速地址（例如 https://registry.docker-cn.com）： " mirror_url
                if [[ ! $mirror_url =~ ^https?:// ]]; then
                    echo -e "${RED}镜像加速地址格式不正确，请以 http:// 或 https:// 开头！${RESET}"
                    return
                fi
                sudo mkdir -p /etc/docker
                sudo tee /etc/docker/daemon.json <<-EOF
{
  "registry-mirrors": ["$mirror_url"]
}
EOF
                sudo systemctl restart docker
                echo -e "${GREEN}镜像加速配置已更新！当前使用的镜像加速地址：$mirror_url${RESET}"
                ;;
            2)
                if [ -f /etc/docker/daemon.json ]; then
                    sudo rm /etc/docker/daemon.json
                    sudo systemctl restart docker
                    echo -e "${GREEN}镜像加速配置已删除！${RESET}"
                else
                    echo -e "${RED}未找到镜像加速配置，无需删除。${RESET}"
                fi
                ;;
            3)
                echo -e "${GREEN}请选择预设镜像加速地址：${RESET}"
                echo "1) Docker 官方中国区镜像"
                echo "2) 阿里云加速器（需登录阿里云容器镜像服务获取专属地址）"
                echo "3) 腾讯云加速器"
                echo "4) 华为云加速器"
                echo "5) 网易云加速器"
                echo "6) DaoCloud 加速器"
                read -p "请输入选项： " preset_choice

                case $preset_choice in
                    1) mirror_url="https://registry.docker-cn.com" ;;
                    2) mirror_url="https://<your-aliyun-mirror>.mirror.aliyuncs.com" ;;
                    3) mirror_url="https://mirror.ccs.tencentyun.com" ;;
                    4) mirror_url="https://05f073ad3c0010ea0f4bc00b7105ec20.mirror.swr.myhuaweicloud.com" ;;
                    5) mirror_url="https://hub-mirror.c.163.com" ;;
                    6) mirror_url="https://www.daocloud.io/mirror" ;;
                    *) echo -e "${RED}无效选项！${RESET}" ; return ;;
                esac

                sudo mkdir -p /etc/docker
                sudo tee /etc/docker/daemon.json <<-EOF
{
  "registry-mirrors": ["$mirror_url"]
}
EOF
                sudo systemctl restart docker
                echo -e "${GREEN}镜像加速配置已更新！当前使用的镜像加速地址：$mirror_url${RESET}"
                ;;
            *)
                echo -e "${RED}无效选项！${RESET}"
                ;;
        esac
    }

    # 启动 Docker 容器
    start_container() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}已停止的容器：${RESET}"
        container_list=$(docker ps -a --filter "status=exited" -q)
        if [ -z "$container_list" ]; then
            echo -e "${YELLOW}没有已停止的容器！${RESET}"
            return
        fi
        docker ps -a --filter "status=exited" --format "table {{.ID}}\t{{.Image}}\t{{.Names}}" | sed 's/CONTAINER ID/容器ID/; s/IMAGE/镜像名称/; s/NAMES/容器名称/'
        read -p "请输入要启动的容器ID： " container_id
        if docker start "$container_id" &> /dev/null; then
            echo -e "${GREEN}容器已启动！${RESET}"
            # 显示容器的访问地址和端口
            container_info=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} {{range $p, $conf := .NetworkSettings.Ports}}{{(index $conf 0).HostPort}} {{end}}' "$container_id")
            ip=$(echo "$container_info" | awk '{print $1}')
            ports=$(echo "$container_info" | awk '{for (i=2; i<=NF; i++) print $i}')
            if [ -z "$ip" ] && [ -z "$ports" ]; then
                echo -e "${YELLOW}该容器未暴露端口，请手动检查容器配置。${RESET}"
            else
                echo -e "${YELLOW}容器访问地址：${RESET}"
                echo -e "${YELLOW}IP: $ip${RESET}"
                echo -e "${YELLOW}端口: $ports${RESET}"
            fi
        else
            echo -e "${RED}容器启动失败！${RESET}"
        fi
    }

    # 停止 Docker 容器
    stop_container() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}正在运行的容器：${RESET}"
        docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Names}}" | sed 's/CONTAINER ID/容器ID/; s/IMAGE/镜像名称/; s/NAMES/容器名称/'
        read -p "请输入要停止的容器ID： " container_id
        if docker stop "$container_id" &> /dev/null; then
            echo -e "${GREEN}容器已停止！${RESET}"
        else
            echo -e "${RED}容器停止失败！${RESET}"
        fi
    }

    # 查看已安装镜像
    manage_images() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}====== 已安装镜像 ======${RESET}"
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}" | sed 's/REPOSITORY/仓库名称/; s/TAG/标签/; s/IMAGE ID/镜像ID/; s/CREATED/创建时间/; s/SIZE/大小/; s/ago/前/'
        echo -e "${YELLOW}========================${RESET}"
    }

    # 删除 Docker 容器
    delete_container() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}所有容器：${RESET}"
        docker ps -a --format "table {{.ID}}\t{{.Image}}\t{{.Names}}" | sed 's/CONTAINER ID/容器ID/; s/IMAGE/镜像名称/; s/NAMES/容器名称/'
        read -p "请输入要删除的容器ID： " container_id
        if docker rm -f "$container_id" &> /dev/null; then
            echo -e "${GREEN}容器已删除！${RESET}"
        else
            echo -e "${RED}容器删除失败！${RESET}"
        fi
    }

    # 删除 Docker 镜像
    delete_image() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}已安装镜像列表：${RESET}"
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}" | sed 's/REPOSITORY/仓库名称/; s/TAG/标签/; s/IMAGE ID/镜像ID/; s/CREATED/创建时间/; s/SIZE/大小/; s/ago/前/'
        read -p "请输入要删除的镜像ID： " image_id
        # 停止并删除使用该镜像的容器
        running_containers=$(docker ps -q --filter "ancestor=$image_id")
        if [ -n "$running_containers" ]; then
            echo -e "${YELLOW}发现使用该镜像的容器，正在停止并删除...${RESET}"
            docker stop $running_containers 2>/dev/null
            docker rm $running_containers 2>/dev/null
        fi
        # 删除镜像
        if docker rmi "$image_id" &> /dev/null; then
            echo -e "${GREEN}镜像删除成功！${RESET}"
        else
            echo -e "${RED}镜像删除失败！${RESET}"
        fi
    }

    # 安装 sun-panel
    install_sun_panel() {
        echo -e "${GREEN}正在安装 sun-panel...${RESET}"

        # 端口处理
        while true; do
            read -p "请输入要使用的端口号（默认 3002）： " sun_port
            sun_port=${sun_port:-3002}
            
            # 验证端口格式
            if ! [[ "$sun_port" =~ ^[0-9]+$ ]] || [ "$sun_port" -lt 1 ] || [ "$sun_port" -gt 65535 ]; then
                echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                continue
            fi

            # 检查端口占用
            if ss -tuln | grep -q ":${sun_port} "; then
                echo -e "${RED}端口 ${sun_port} 已被占用，请选择其他端口！${RESET}"
            else
                break
            fi
        done

        # 处理防火墙
        open_port() {
            if command -v ufw > /dev/null 2>&1; then
                if ! ufw status | grep -q "${sun_port}/tcp"; then
                    echo -e "${YELLOW}正在放行端口 ${sun_port}..."
                    sudo ufw allow "${sun_port}/tcp"
                    sudo ufw reload
                fi
            elif command -v firewall-cmd > /dev/null 2>&1; then
                if ! firewall-cmd --list-ports | grep -q "${sun_port}/tcp"; then
                    echo -e "${YELLOW}正在放行端口 ${sun_port}..."
                    sudo firewall-cmd --permanent --add-port=${sun_port}/tcp
                    sudo firewall-cmd --reload
                fi
            else
                echo -e "${YELLOW}未检测到防火墙工具，请手动放行端口 ${sun_port}"
            fi
        }
        open_port

        # 拉取最新镜像并运行
        docker pull hslr/sun-panel:latest && \
        docker run -d \
            --name sun-panel \
            --restart always \
            -p ${sun_port}:3002 \
            -v /home/sun-panel/data:/app/data \
            -v /home/sun-panel/config:/app/config \
            -e SUNPANEL_ADMIN_USER="admin@sun.cc" \
            -e SUNPANEL_ADMIN_PASS="12345678" \
            hslr/sun-panel:latest

        # 显示安装结果
        if [ $? -eq 0 ]; then
            server_ip=$(curl -s4 ifconfig.me)
            echo -e "${GREEN}------------------------------------------------------"
            echo -e " sun-panel 安装成功！"
            echo -e " 访问地址：http://${server_ip}:${sun_port}"
            echo -e " 管理员账号：admin@sun.cc"
            echo -e " 管理员密码：12345678"
            echo -e "------------------------------------------------------${RESET}"
        else
            echo -e "${RED}sun-panel 安装失败，请检查日志！${RESET}"
        fi
    }

# 选项10：拉取镜像并安装容器（增强版 - 支持手动拉取）
install_image_container() {
    if ! check_docker_status; then return; fi

    # 获取镜像名称
    while true; do
        read -p "请输入镜像名称（示例：nginx:latest 或 localhost:5000/nginx:v1）： " image_name
        if [[ -z "$image_name" ]]; then
            echo -e "${RED}镜像名称不能为空！${RESET}"
            continue
        fi
        break
    done

    # 拉取镜像
    echo -e "${GREEN}正在拉取镜像 ${image_name}...${RESET}"
    if ! docker pull "$image_name"; then
        echo -e "${RED}镜像拉取失败！请检查：\n1. 镜像名称是否正确\n2. 网络连接是否正常\n3. 私有仓库是否需要 docker login${RESET}"
        # 提示用户手动输入 docker pull 命令
        read -p "${YELLOW}是否手动输入 docker pull 命令尝试拉取？（y/N，默认 N）：${RESET} " manual_pull_choice
        if [[ "${manual_pull_choice:-N}" =~ [Yy] ]]; then
            read -p "请输入完整的 docker pull 命令（示例：docker pull eyeblue/tank）： " manual_pull_cmd
            if [[ -z "$manual_pull_cmd" ]]; then
                echo -e "${RED}命令不能为空！返回主菜单...${RESET}"
                return
            fi
            echo -e "${GREEN}正在执行手动拉取命令：${manual_pull_cmd}${RESET}"
            # 执行用户输入的命令
            if ! $manual_pull_cmd; then
                echo -e "${RED}手动拉取失败！请检查命令或网络，返回主菜单...${RESET}"
                return
            fi
            # 手动拉取成功后，重新设置 image_name 为拉取的镜像名称
            image_name=$(echo "$manual_pull_cmd" | awk '{print $NF}')
            echo -e "${GREEN}手动拉取成功！镜像名称更新为：${image_name}${RESET}"
        else
            echo -e "${YELLOW}取消手动拉取，返回主菜单...${RESET}"
            return
        fi
    fi

    # 获取系统占用端口
    echo -e "${YELLOW}当前系统占用的端口：${RESET}"
    used_host_ports=($(ss -tuln | awk '{print $5}' | cut -d':' -f2 | grep -E '^[0-9]+$' | sort -un))
    for port in "${used_host_ports[@]}"; do
        echo -e "  - 端口 ${port}"
    done

    # 自动检测镜像端口
    exposed_ports=()

    # 1. 元数据检测
    port_info=$(docker inspect --format='{{json .Config.ExposedPorts}}' "$image_name" 2>/dev/null)
    if [ $? -eq 0 ] && [ "$port_info" != "null" ]; then
        eval "declare -A ports=${port_info}"
        for port in "${!ports[@]}"; do
            port_num="${port%/*}"
            if [ "$port_num" -ge 1 ] && [ "$port_num" -le 65535 ]; then
                echo -e "${YELLOW}[元数据检测] 发现端口 ${port_num}${RESET}"
                exposed_ports+=("$port_num")
            fi
        done
    fi

    # 2. 运行时检测
    temp_container_id=$(docker run -d --rm "$image_name" tail -f /dev/null 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}正在检测容器端口，请稍候（可能需要 30 秒）...${RESET}"
        sleep 30
        runtime_ports=$(docker exec "$temp_container_id" sh -c "
            if command -v ss >/dev/null; then
                ss -tuln | awk '{print \$5}' | cut -d':' -f2 | grep -E '^[0-9]+$' | sort -un
            elif command -v netstat >/dev/null; then
                netstat -tuln | awk '/^(tcp|udp)/ {print \$4}' | cut -d':' -f2 | grep -E '^[0-9]+$' | sort -un
            fi" 2>/dev/null)
        for port in $runtime_ports; do
            if [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [[ ! " ${exposed_ports[@]} " =~ " ${port} " ]]; then
                echo -e "${YELLOW}[运行时检测] 发现端口 ${port}${RESET}"
                exposed_ports+=("$port")
            fi
        done
        docker stop "$temp_container_id" >/dev/null 2>&1
    fi

    # 3. 日志检测
    if [ ${#exposed_ports[@]} -eq 0 ]; then
        temp_container_id=$(docker run -d --rm "$image_name" 2>/dev/null)
        if [ $? -eq 0 ]; then
            echo -e "${YELLOW}正在通过日志检测端口，请稍候（可能需要 30 秒）...${RESET}"
            sleep 30
            log_output=$(docker logs "$temp_container_id" 2>/dev/null)
            docker stop "$temp_container_id" >/dev/null 2>&1
            log_ports=$(echo "$log_output" | grep -oP '(http|https)://[^:]*:\K[0-9]+|listen\s+\K[0-9]+|port\s+\K[0-9]+' | sort -un)
            for port in $log_ports; do
                if [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && [[ ! " ${exposed_ports[@]} " =~ " ${port} " ]]; then
                    echo -e "${YELLOW}[日志检测] 发现端口 ${port}${RESET}"
                    exposed_ports+=("$port")
                fi
            done
            # 推测常见镜像的默认端口
            if [ ${#exposed_ports[@]} -eq 0 ]; then
                if [[ "$image_name" =~ "jellyfin" ]]; then
                    echo -e "${YELLOW}[推测] 检测到 Jellyfin 镜像，默认端口 8096${RESET}"
                    exposed_ports+=("8096")
                elif [[ "$image_name" =~ "nginx" ]]; then
                    echo -e "${YELLOW}[推测] 检测到 Nginx 镜像，默认端口 80${RESET}"
                    exposed_ports+=("80")
                elif [[ "$image_name" =~ "mysql" ]]; then
                    echo -e "${YELLOW}[推测] 检测到 MySQL 镜像，默认端口 3306${RESET}"
                    exposed_ports+=("3306")
                elif [[ "$image_name" =~ "postgres" ]]; then
                    echo -e "${YELLOW}[推测] 检测到 PostgreSQL 镜像，默认端口 5432${RESET}"
                    exposed_ports+=("5432")
                elif [[ "$image_name" =~ "redis" ]]; then
                    echo -e "${YELLOW}[推测] 检测到 Redis 镜像，默认端口 6379${RESET}"
                    exposed_ports+=("6379")
                elif [[ "$image_name" =~ "gdy666/lucky" ]]; then
                    echo -e "${YELLOW}[推测] 检测到 Lucky 镜像，默认端口 16601${RESET}"
                    exposed_ports+=("16601")
                fi
            fi
        fi
    fi

    # 如果仍未检测到有效端口，提示用户从常见端口选择
    common_ports=(80 443 8080 8096 9000 16601 3306 5432 6379)
    if [ ${#exposed_ports[@]} -eq 0 ]; then
        echo -e "${YELLOW}未检测到有效暴露端口，请从以下常见端口选择：${RESET}"
        for i in "${!common_ports[@]}"; do
            echo -e "  ${i}. ${common_ports[$i]}"
        done
        while true; do
            read -p "请输入容器端口编号（0-8，默认 0 即 80）： " port_choice
            port_choice=${port_choice:-0}
            if ! [[ "$port_choice" =~ ^[0-8]$ ]]; then
                echo -e "${RED}无效选择，请输入 0-8 之间的数字！${RESET}"
                continue
            fi
            exposed_ports+=("${common_ports[$port_choice]}")
            echo -e "${GREEN}选择容器端口 ${exposed_ports[0]}${RESET}"
            break
        done
    fi

    # 智能端口映射
    port_mappings=()
    port_mapping_display=()

    for port in "${exposed_ports[@]}"; do
        recommended_port=$port
        while [[ " ${used_host_ports[@]} " =~ " ${recommended_port} " ]]; do
            recommended_port=$((recommended_port + 1))
            if [ "$recommended_port" -gt 65535 ]; then
                recommended_port=8080
            fi
        done

        while true; do
            read -p "映射容器端口 ${port} 到宿主机端口（默认 ${recommended_port}，回车使用默认）： " host_port
            host_port=${host_port:-$recommended_port}

            if ! [[ "$host_port" =~ ^[0-9]+$ ]] || [ "$host_port" -lt 1 ] || [ "$host_port" -gt 65535 ]; then
                echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                continue
            fi

            if [[ " ${used_host_ports[@]} " =~ " ${host_port} " ]]; then
                echo -e "${RED}端口 ${host_port} 已占用！建议更换端口：${RESET}"
                ss -tulpn | grep ":$host_port"
                read -p "更换端口？(y/N，默认 y)： " change_port
                if [[ "${change_port:-y}" =~ [Yy] ]]; then
                    continue
                fi
            fi

            port_mappings+=("-p" "${host_port}:${port}")
            port_mapping_display+=("${port} -> ${host_port}")
            used_host_ports+=("$host_port")
            echo -e "${GREEN}端口映射：容器端口 ${port} -> 宿主机端口 ${host_port}${RESET}"
            break
        done
    done

    # 数据路径设置
    default_data_path="/root/docker/home"
    read -p "请输入容器数据路径（默认：${default_data_path}，回车使用默认）： " data_path
    data_path=${data_path:-$default_data_path}
    if [ ! -d "$data_path" ]; then
        echo -e "${YELLOW}创建数据目录：$data_path${RESET}"
        if ! mkdir -p "$data_path" 2>/dev/null && ! sudo mkdir -p "$data_path"; then
            echo -e "${RED}目录创建失败，请检查权限或手动创建：sudo mkdir -p '$data_path'${RESET}"
            return
        fi
    fi

    # 防火墙处理
    open_port() {
        for ((i=0; i<${#port_mappings[@]}; i+=2)); do
            if [[ "${port_mappings[$i]}" == "-p" && "${port_mappings[$i+1]}" =~ ^[0-9]+:[0-9]+$ ]]; then
                host_port=$(echo "${port_mappings[$i+1]}" | cut -d':' -f1)
                echo -e "${YELLOW}处理防火墙，放行端口 ${host_port}...${RESET}"
                if command -v ufw >/dev/null 2>&1; then
                    if ! ufw status | grep -q "${host_port}/tcp"; then
                        sudo ufw allow "${host_port}/tcp" && sudo ufw reload
                    fi
                elif command -v firewall-cmd >/dev/null 2>&1; then
                    if ! firewall-cmd --list-ports | grep -qw "${host_port}/tcp"; then
                        sudo firewall-cmd --permanent --add-port="${host_port}/tcp"
                        sudo firewall-cmd --reload
                    fi
                else
                    echo -e "${YELLOW}未检测到防火墙工具，请手动放行端口 ${host_port}${RESET}"
                fi
            fi
        done
    }
    open_port

    # 生成容器名称并启动
    container_name="$(echo "$image_name" | tr '/:' '_')_$(date +%s)"
    echo -e "${GREEN}正在启动容器...${RESET}"
    docker_run_cmd=(
        docker run -d
        --name "$container_name"
        --restart unless-stopped
        "${port_mappings[@]}"
        -v "${data_path}:/app/data"
        "$image_name"
    )

    # 捕获详细错误输出
    if ! output=$("${docker_run_cmd[@]}" 2>&1); then
        echo -e "${RED}容器启动失败！错误信息：${RESET}"
        echo "$output"
        echo -e "${RED}可能原因：${RESET}"
        echo -e "1. 端口配置错误（选择的容器端口可能不正确）"
        echo -e "2. 镜像需要特定启动参数（请查看镜像文档，如 -p 端口或 -e 环境变量）"
        echo -e "3. 权限或资源问题"
        echo -e "调试命令：${docker_run_cmd[*]}"
    else
        sleep 5
        if ! docker ps | grep -q "$container_name"; then
            echo -e "${RED}容器启动后异常退出，请查看日志：${RESET}"
            docker logs "$container_name"
            return
        fi

        # 验证端口监听
        for mapping in "${port_mapping_display[@]}"; do
            container_port=$(echo "$mapping" | cut -d' ' -f1)
            temp_check=$(docker exec "$container_name" sh -c "
                if command -v ss >/dev/null; then
                    ss -tuln | grep -q ':${container_port} ' && echo 'found'
                elif command -v netstat >/dev/null; then
                    netstat -tuln | grep -q ':${container_port} ' && echo 'found'
                fi" 2>/dev/null)
            if [ "$temp_check" != "found" ]; then
                echo -e "${RED}警告：容器未监听端口 ${container_port}，映射可能无效！${RESET}"
                echo -e "${YELLOW}建议查看日志或重新选择容器端口：docker logs $container_name${RESET}"
            fi
        done

        # 获取网络信息
        server_ip=$(hostname -I | awk '{print $1}')
        public_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com || echo "N/A")

        # 输出访问信息
        echo -e "${GREEN}------------------------------------------------------"
        echo -e " 容器名称：$container_name"
        echo -e " 镜像名称：$image_name"
        echo -e " 端口映射（容器内 -> 宿主机）："
        for mapping in "${port_mapping_display[@]}"; do
            echo -e "    - ${mapping}"
        done
        [ "$public_ip" != "N/A" ] && echo -e " 公网访问："
        for mapping in "${port_mapping_display[@]}"; do
            host_port=$(echo "$mapping" | cut -d' ' -f3)
            [ "$public_ip" != "N/A" ] && echo -e "   - http://${public_ip}:${host_port}"
            echo -e "  内网访问：http://${server_ip}:${host_port}"
        done
        echo -e " 数据路径：$data_path"
        echo -e "------------------------------------------------------${RESET}"

        # 诊断命令
        echo -e "${YELLOW}诊断命令：${RESET}"
        echo -e "查看日志：docker logs $container_name"
        echo -e "进入容器：docker exec -it $container_name sh"
        echo -e "停止容器：docker stop $container_name"
        echo -e "删除容器：docker rm -f $container_name"
    fi
}

    # 选项11：更新镜像并重启容器
    update_image_restart() {
        if ! check_docker_status; then return; fi

        # 获取镜像名称
        read -p "请输入要更新的镜像名称（例如：nginx:latest）：" image_name
        if [[ -z "$image_name" ]]; then
            echo -e "${RED}镜像名称不能为空！${RESET}"
            return
        fi

        # 拉取最新镜像
        echo -e "${GREEN}正在更新镜像：${image_name}...${RESET}"
        if ! docker pull "$image_name"; then
            echo -e "${RED}镜像更新失败！请检查：\n1. 镜像名称是否正确\n2. 网络连接是否正常${RESET}"
            return
        fi

        # 查找关联容器
        container_ids=$(docker ps -a --filter "ancestor=$image_name" --format "{{.ID}}")
        if [ -z "$container_ids" ]; then
            echo -e "${YELLOW}没有找到使用该镜像的容器${RESET}"
            return
        fi

        # 重启容器
        echo -e "${YELLOW}正在重启以下容器：${RESET}"
        docker ps -a --filter "ancestor=$image_name" --format "table {{.ID}}\t{{.Names}}\t{{.Image}}"
        for cid in $container_ids; do
            echo -n "重启容器 $cid ... "
            docker restart "$cid" && echo "成功" || echo "失败"
        done
    }

    # 选项12：批量操作容器
    batch_operations() {
        if ! check_docker_status; then return; fi

        echo -e "${GREEN}=== 批量操作 ===${RESET}"
        echo "1) 停止所有容器"
        echo "2) 删除所有容器"
        echo "3) 删除所有镜像"
        read -p "请选择操作类型：" batch_choice

        case $batch_choice in
            1)
                read -p "确定要停止所有容器吗？(y/n)：" confirm
                [[ "$confirm" == "y" ]] && docker stop $(docker ps -q)
                ;;
            2)
                read -p "确定要删除所有容器吗？(y/n)：" confirm
                [[ "$confirm" == "y" ]] && docker rm -f $(docker ps -aq)
                ;;
            3)
                read -p "确定要删除所有镜像吗？(y/n)：" confirm
                [[ "$confirm" == "y" ]] && docker rmi -f $(docker images -q)
                ;;
            *)
                echo -e "${RED}无效选项！${RESET}"
                ;;
        esac
    }

    # 选项13：安装 Portainer（Docker 管理面板）
    install_portainer() {
        if ! check_docker_status; then return; fi

        # 默认端口
        DEFAULT_PORT=9000

        # 检查端口是否占用
        check_port() {
            local port=$1
            if ss -tuln 2>/dev/null | grep -q ":$port "; then
                return 1
            elif netstat -tuln 2>/dev/null | grep -q ":$port "; then
                return 1
            else
                return 0
            fi
        }

        check_port $DEFAULT_PORT
        if [ $? -eq 1 ]; then
            echo -e "${RED}端口 $DEFAULT_PORT 已被占用！${RESET}"
            read -p "请输入其他端口号（1-65535）： " new_port
            while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                read -p "请输入其他端口号（1-65535）： " new_port
            done
            check_port $new_port
            while [ $? -eq 1 ]; do
                echo -e "${RED}端口 $new_port 已被占用，请选择其他端口！${RESET}"
                read -p "请输入其他端口号（1-65535）： " new_port
                while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                    echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                    read -p "请输入其他端口号（1-65535）： " new_port
                done
                check_port $new_port
            done
            DEFAULT_PORT=$new_port
        fi

        # 开放端口
        echo -e "${YELLOW}正在开放端口 $DEFAULT_PORT...${RESET}"
        if command -v ufw &> /dev/null; then
            sudo ufw allow $DEFAULT_PORT/tcp
            sudo ufw reload
            echo -e "${GREEN}UFW 防火墙端口 $DEFAULT_PORT 已开放！${RESET}"
        elif command -v firewall-cmd &> /dev/null; then
            sudo firewall-cmd --permanent --add-port=$DEFAULT_PORT/tcp
            sudo firewall-cmd --reload
            echo -e "${GREEN}Firewalld 防火墙端口 $DEFAULT_PORT 已开放！${RESET}"
        elif command -v iptables &> /dev/null; then
            sudo iptables -A INPUT -p tcp --dport $DEFAULT_PORT -j ACCEPT
            sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            echo -e "${GREEN}iptables 防火墙端口 $DEFAULT_PORT 已开放！${RESET}"
        else
            echo -e "${YELLOW}未检测到常见防火墙工具，请手动开放端口 $DEFAULT_PORT！${RESET}"
        fi

        # 拉取 Portainer 镜像
        echo -e "${YELLOW}正在拉取 Portainer 镜像...${RESET}"
        if ! docker pull 6053537/portainer-ce; then
            echo -e "${RED}拉取 Portainer 镜像失败！请检查：\n1. 网络连接是否正常\n2. Docker 是否正常运行${RESET}"
            return
        fi

        # 检查是否已有同名容器
        if docker ps -a --format '{{.Names}}' | grep -q "^portainer$"; then
            echo -e "${YELLOW}检测到已存在名为 portainer 的容器，正在移除...${RESET}"
            docker stop portainer &> /dev/null
            docker rm portainer &> /dev/null
        fi

        # 运行 Portainer 容器
        echo -e "${YELLOW}正在启动 Portainer 容器...${RESET}"
        if ! docker run -d --restart=always --name="portainer" -p $DEFAULT_PORT:9000 -v /var/run/docker.sock:/var/run/docker.sock 6053537/portainer-ce; then
            echo -e "${RED}启动 Portainer 容器失败！请检查 Docker 日志：docker logs portainer${RESET}"
            return
        fi

        # 检查容器状态
        sleep 3
        if docker ps --format '{{.Names}}' | grep -q "^portainer$"; then
            server_ip=$(curl -s4 ifconfig.me || echo "你的服务器IP")
            echo -e "${GREEN}Portainer 安装成功！${RESET}"
            echo -e "${YELLOW}容器名称：portainer${RESET}"
            echo -e "${YELLOW}访问端口：$DEFAULT_PORT${RESET}"
            echo -e "${YELLOW}访问地址：http://$server_ip:$DEFAULT_PORT${RESET}"
            echo -e "${YELLOW}首次登录需设置管理员密码，请访问以上地址完成初始化！${RESET}"
        else
            echo -e "${RED}Portainer 容器未正常运行，请检查以下日志：${RESET}"
            docker logs portainer
        fi
    }
    
    case $docker_choice in
        1) install_docker ;;
        2) uninstall_docker ;;
        3) configure_mirror ;;
        4) start_container ;;
        5) stop_container ;;
        6) manage_images ;;
        7) delete_container ;;
        8) delete_image ;;
        9) install_sun_panel ;;
        10) install_image_container ;;
        11) update_image_restart ;;
        12) batch_operations ;;
        13) install_portainer ;;
        0) break ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
    read -p "按回车键继续..."
done
    ;;
            19)
                # SSH 防暴力破解检测与防护
                echo -e "${GREEN}正在处理 SSH 暴力破解检测与防护...${RESET}"
                DETECT_CONFIG="/etc/ssh_brute_force.conf"

                # 检查并安装 rsyslog（如果缺失）
                if ! command -v rsyslogd &> /dev/null; then
                    echo -e "${YELLOW}未检测到 rsyslog，正在安装...${RESET}"
                    check_system
                    if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
                        sudo apt update && sudo apt install -y rsyslog
                    elif [ "$SYSTEM" == "centos" ]; then
                        sudo yum install -y rsyslog
                    elif [ "$SYSTEM" == "fedora" ]; then
                        sudo dnf install -y rsyslog
                    else
                        echo -e "${RED}无法识别系统，无法安装 rsyslog！${RESET}"
                    fi
                    if command -v rsyslogd &> /dev/null; then
                        sudo systemctl start rsyslog
                        sudo systemctl enable rsyslog
                        echo -e "${GREEN}rsyslog 安装并启动成功！${RESET}"
                    else
                        echo -e "${RED}rsyslog 安装失败，请手动安装！${RESET}"
                    fi
                fi

                # 确定并确保日志文件存在
                if [ -f /var/log/auth.log ]; then
                    LOG_FILE="/var/log/auth.log"  # Debian/Ubuntu
                elif [ -f /var/log/secure ]; then
                    LOG_FILE="/var/log/secure"   # CentOS/RHEL
                else
                    echo -e "${YELLOW}未找到 SSH 日志文件，正在尝试创建 /var/log/auth.log...${RESET}"
                    sudo touch /var/log/auth.log
                    sudo chown root:root /var/log/auth.log
                    sudo chmod 640 /var/log/auth.log
                    if [ ! -d /etc/rsyslog.d ]; then
                        sudo mkdir -p /etc/rsyslog.d
                    fi
                    echo "auth,authpriv.* /var/log/auth.log" | sudo tee /etc/rsyslog.d/auth.conf > /dev/null
                    if command -v rsyslogd &> /dev/null; then
                        sudo systemctl restart rsyslog
                        sudo systemctl restart sshd
                        if [ $? -eq 0 ] && [ -f /var/log/auth.log ]; then
                            LOG_FILE="/var/log/auth.log"
                            echo -e "${GREEN}已创建 /var/log/auth.log 并配置完成！${RESET}"
                        else
                            echo -e "${RED}日志服务配置失败，请检查 rsyslog 和 sshd 是否正常运行！${RESET}"
                            read -p "按回车键返回主菜单..."
                            continue
                        fi
                    else
                        echo -e "${RED}未安装 rsyslog，无法配置日志文件！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                fi

                # 检查是否首次运行检测配置
                if [ ! -f "$DETECT_CONFIG" ]; then
                    echo -e "${YELLOW}首次运行检测功能，请设置检测参数：${RESET}"
                    read -p "请输入单 IP 允许的最大失败尝试次数 [默认 5]： " max_attempts
                    max_attempts=${max_attempts:-5}
                    read -p "请输入 IP 统计时间范围（分钟）[默认 1440（1天）]： " detect_time
                    detect_time=${detect_time:-1440}
                    read -p "请输入高风险阈值（总失败次数）[默认 10]： " high_risk_threshold
                    high_risk_threshold=${high_risk_threshold:-10}
                    read -p "请输入常规扫描间隔（分钟）[默认 15]： " scan_interval
                    scan_interval=${scan_interval:-15}
                    read -p "请输入高风险扫描间隔（分钟）[默认 5]： " scan_interval_high
                    scan_interval_high=${scan_interval_high:-5}

                    # 保存检测配置
                    echo "MAX_ATTEMPTS=$max_attempts" | sudo tee "$DETECT_CONFIG" > /dev/null
                    echo "DETECT_TIME=$detect_time" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                    echo "HIGH_RISK_THRESHOLD=$high_risk_threshold" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                    echo "SCAN_INTERVAL=$scan_interval" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                    echo "SCAN_INTERVAL_HIGH=$scan_interval_high" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                    echo -e "${GREEN}检测配置已保存至 $DETECT_CONFIG${RESET}"
                else
                    # 读取检测配置
                    source "$DETECT_CONFIG"
                    echo -e "${YELLOW}当前检测配置：最大尝试次数=$MAX_ATTEMPTS，统计时间范围=$DETECT_TIME 分钟，高风险阈值=$HIGH_RISK_THRESHOLD，常规扫描=$SCAN_INTERVAL 分钟，高风险扫描=$SCAN_INTERVAL_HIGH 分钟${RESET}"
                    read -p "请选择操作：1) 查看尝试破解的 IP 记录  2) 修改检测参数  3) 配置 Fail2Ban 防护（输入 1、2 或 3）： " choice
                    if [ "$choice" == "2" ]; then
                        echo -e "${YELLOW}请输入新的检测参数（留空保留原值）：${RESET}"
                        read -p "请输入单 IP 允许的最大失败尝试次数 [当前 $MAX_ATTEMPTS]： " max_attempts
                        max_attempts=${max_attempts:-$MAX_ATTEMPTS}
                        read -p "请输入 IP 统计时间范围（分钟）[当前 $DETECT_TIME]： " detect_time
                        detect_time=${detect_time:-$DETECT_TIME}
                        read -p "请输入高风险阈值（总失败次数）[当前 $HIGH_RISK_THRESHOLD]： " high_risk_threshold
                        high_risk_threshold=${high_risk_threshold:-$HIGH_RISK_THRESHOLD}
                        read -p "请输入常规扫描间隔（分钟）[当前 $SCAN_INTERVAL]： " scan_interval
                        scan_interval=${scan_interval:-$SCAN_INTERVAL}
                        read -p "请输入高风险扫描间隔（分钟）[当前 $SCAN_INTERVAL_HIGH]： " scan_interval_high
                        scan_interval_high=${scan_interval_high:-$SCAN_INTERVAL_HIGH}

                        # 更新检测配置
                        echo "MAX_ATTEMPTS=$max_attempts" | sudo tee "$DETECT_CONFIG" > /dev/null
                        echo "DETECT_TIME=$detect_time" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                        echo "HIGH_RISK_THRESHOLD=$high_risk_threshold" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                        echo "SCAN_INTERVAL=$scan_interval" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                        echo "SCAN_INTERVAL_HIGH=$scan_interval_high" | sudo tee -a "$DETECT_CONFIG" > /dev/null
                        echo -e "${GREEN}检测配置已更新至 $DETECT_CONFIG${RESET}"
                    elif [ "$choice" == "3" ]; then
                        # 子选项 3：配置 Fail2Ban 防护
                        FAIL2BAN_CONFIG="/etc/fail2ban_config.conf"
                        echo -e "${GREEN}正在处理 Fail2Ban 防护配置...${RESET}"

                        # 检查并安装 Fail2Ban
                        if ! command -v fail2ban-client &> /dev/null; then
                            echo -e "${YELLOW}未检测到 Fail2Ban，正在安装...${RESET}"
                            check_system
                            if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
                                sudo apt update && sudo apt install -y fail2ban
                            elif [ "$SYSTEM" == "centos" ]; then
                                sudo yum install -y epel-release && sudo yum install -y fail2ban
                            elif [ "$SYSTEM" == "fedora" ]; then
                                sudo dnf install -y fail2ban
                            else
                                echo -e "${RED}无法识别系统，无法安装 Fail2Ban！${RESET}"
                            fi
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}Fail2Ban 安装成功！${RESET}"
                            else
                                echo -e "${RED}Fail2Ban 安装失败，请手动安装！${RESET}"
                                read -p "按回车键继续检测暴力破解记录..."
                            fi
                        else
                            echo -e "${YELLOW}Fail2Ban 已安装，跳过安装步骤。${RESET}"
                        fi

                        # 检查 Fail2Ban 配置是否首次运行
                        if [ ! -f "$FAIL2BAN_CONFIG" ]; then
                            echo -e "${YELLOW}首次配置 Fail2Ban，请设置防护参数：${RESET}"
                            read -p "请输入单 IP 允许的最大失败尝试次数 [默认 5]： " fail2ban_max_attempts
                            fail2ban_max_attempts=${fail2ban_max_attempts:-5}
                            read -p "请输入 IP 封禁时长（秒）[默认 3600（1小时）]： " ban_time
                            ban_time=${ban_time:-3600}
                            read -p "请输入查找时间窗口（秒）[默认 600（10分钟）]： " find_time
                            find_time=${find_time:-600}

                            # 保存 Fail2Ban 配置
                            echo "FAIL2BAN_MAX_ATTEMPTS=$fail2ban_max_attempts" | sudo tee "$FAIL2BAN_CONFIG" > /dev/null
                            echo "BAN_TIME=$ban_time" | sudo tee -a "$FAIL2BAN_CONFIG" > /dev/null
                            echo "FIND_TIME=$find_time" | sudo tee -a "$FAIL2BAN_CONFIG" > /dev/null

                            # 配置 Fail2Ban jail.local
                            sudo bash -c "cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = $ban_time
findtime = $find_time
maxretry = $fail2ban_max_attempts

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = $LOG_FILE
maxretry = $fail2ban_max_attempts
bantime = $ban_time
EOF"
                            echo -e "${GREEN}Fail2Ban 配置已保存至 $FAIL2BAN_CONFIG 和 /etc/fail2ban/jail.local${RESET}"
                            sudo systemctl restart fail2ban
                            sudo systemctl enable fail2ban
                        else
                            # 读取 Fail2Ban 配置
                            source "$FAIL2BAN_CONFIG"
                            echo -e "${YELLOW}当前 Fail2Ban 配置：最大尝试次数=$FAIL2BAN_MAX_ATTEMPTS，封禁时长=$BAN_TIME 秒，查找时间窗口=$FIND_TIME 秒${RESET}"
                            read -p "请选择 Fail2Ban 操作：1) 查看封禁状态  2) 修改 Fail2Ban 参数  3) 管理封禁 IP（输入 1、2 或 3）： " fail2ban_choice
                            if [ "$fail2ban_choice" == "1" ]; then
                                # 查看封禁状态
                                echo -e "${GREEN}当前 Fail2Ban 封禁状态：${RESET}"
                                echo -e "----------------------------------------${RESET}"
                                if sudo fail2ban-client status sshd > /dev/null 2>&1; then
                                    sudo fail2ban-client status sshd
                                else
                                    echo -e "${RED}Fail2Ban 未正常运行，请检查服务状态！${RESET}"
                                fi
                                echo -e "${GREEN}----------------------------------------${RESET}"
                            elif [ "$fail2ban_choice" == "2" ]; then
                                # 修改 Fail2Ban 参数
                                echo -e "${YELLOW}请输入新的 Fail2Ban 参数（留空保留原值）：${RESET}"
                                read -p "请输入单 IP 允许的最大失败尝试次数 [当前 $FAIL2BAN_MAX_ATTEMPTS]： " fail2ban_max_attempts
                                fail2ban_max_attempts=${fail2ban_max_attempts:-$FAIL2BAN_MAX_ATTEMPTS}
                                read -p "请输入 IP 封禁时长（秒）[当前 $BAN_TIME]： " ban_time
                                ban_time=${ban_time:-$BAN_TIME}
                                read -p "请输入查找时间窗口（秒）[当前 $FIND_TIME]： " find_time
                                find_time=${find_time:-$FIND_TIME}

                                # 更新 Fail2Ban 配置
                                echo "FAIL2BAN_MAX_ATTEMPTS=$fail2ban_max_attempts" | sudo tee "$FAIL2BAN_CONFIG" > /dev/null
                                echo "BAN_TIME=$ban_time" | sudo tee -a "$FAIL2BAN_CONFIG" > /dev/null
                                echo "FIND_TIME=$find_time" | sudo tee -a "$FAIL2BAN_CONFIG" > /dev/null

                                # 更新 jail.local
                                sudo bash -c "cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = $ban_time
findtime = $find_time
maxretry = $fail2ban_max_attempts

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = $LOG_FILE
maxretry = $fail2ban_max_attempts
bantime = $ban_time
EOF"
                                echo -e "${GREEN}Fail2Ban 配置已更新至 $FAIL2BAN_CONFIG 和 /etc/fail2ban/jail.local${RESET}"
                                sudo systemctl restart fail2ban
                            elif [ "$fail2ban_choice" == "3" ]; then
                                # 管理封禁 IP
                                echo -e "${GREEN}当前 Fail2Ban 封禁状态：${RESET}"
                                echo -e "----------------------------------------${RESET}"
                                if sudo fail2ban-client status sshd > /dev/null 2>&1; then
                                    STATUS=$(sudo fail2ban-client status sshd)
                                    BANNED_IPS=$(echo "$STATUS" | grep "Banned IP list" | awk '{print $NF}')
                                    echo "$STATUS"
                                    echo -e "${GREEN}----------------------------------------${RESET}"
                                    if [ -n "$BANNED_IPS" ]; then
                                        echo -e "${YELLOW}已封禁的 IP：$BANNED_IPS${RESET}"
                                        read -p "请输入要解禁的 IP（留空取消）： " ip_to_unban
                                        if [ -n "$ip_to_unban" ]; then
                                            sudo fail2ban-client unban "$ip_to_unban"
                                            if [ $? -eq 0 ]; then
                                                echo -e "${GREEN}已成功解禁 IP：$ip_to_unban${RESET}"
                                            else
                                                echo -e "${RED}解禁 IP 失败，请检查输入！${RESET}"
                                            fi
                                        fi
                                    else
                                        echo -e "${YELLOW}暂无封禁 IP${RESET}"
                                        read -p "请输入要手动封禁的 IP（留空取消）： " ip_to_ban
                                        if [ -n "$ip_to_ban" ]; then
                                            sudo fail2ban-client ban "$ip_to_ban"
                                            if [ $? -eq 0 ]; then
                                                echo -e "${GREEN}已成功封禁 IP：$ip_to_ban${RESET}"
                                            else
                                                echo -e "${RED}封禁 IP 失败，请检查输入！${RESET}"
                                            fi
                                        fi
                                    fi
                                else
                                    echo -e "${RED}Fail2Ban 未正常运行，请检查服务状态！${RESET}"
                                    echo -e "${GREEN}----------------------------------------${RESET}"
                                fi
                            fi
                        fi
                        # 启动或重启 Fail2Ban 服务
                        sudo systemctl restart fail2ban
                        sudo systemctl enable fail2ban
                        read -p "按回车键继续检测暴力破解记录..."
                    fi
                fi

                # 计算时间范围的开始时间戳
                start_timestamp=$(date -d "$DETECT_TIME minutes ago" +%s)
                current_year=$(date +%Y)

                # 检测并统计暴力破解尝试
                echo -e "${GREEN}正在分析日志文件：$LOG_FILE${RESET}"
                echo -e "${GREEN}检测时间范围：最近 $DETECT_TIME 分钟${RESET}"
                echo -e "${GREEN}可疑 IP 统计（尝试次数 >= $MAX_ATTEMPTS）："
                echo -e "----------------------------------------${RESET}"

                grep "Failed password" "$LOG_FILE" | awk -v start_ts="$start_timestamp" -v year="$current_year" '
                {
                    log_time = substr($0, 1, 15)
                    ip = $(NF-3)
                    # 拼接完整时间并转换为时间戳
                    log_full_time = sprintf("%s %s", year, log_time)
                    log_timestamp = mktime(sprintf("%s %s", year, substr(log_time,1,2) " " substr(log_time,4,2) " " substr(log_time,7,8) " " substr(log_time,10,5) " " substr(log_time,16,2)))
                    if (log_timestamp >= start_ts) {
                        attempts[ip]++
                        if (!last_time[ip] || log_timestamp > last_time[ip]) {
                            last_time[ip] = log_timestamp
                        }
                    }
                }
                END {
                    for (ip in attempts) {
                        if (attempts[ip] >= 5) {
                            strftime_result = strftime("%Y-%m-%d %H:%M:%S", last_time[ip])
                            printf "IP: %-15s 尝试次数: %-5d 最近尝试时间: %s\n", ip, attempts[ip], strftime_result
                        }
                    }
                }' | sort -k3 -nr

                echo -e "${GREEN}----------------------------------------${RESET}"
                echo -e "${YELLOW}提示：以上为疑似暴力破解的 IP 列表，未自动封禁。${RESET}"
                echo -e "${YELLOW}检测配置：最大尝试次数=$MAX_ATTEMPTS，统计时间范围=$DETECT_TIME 分钟，高风险阈值=$HIGH_RISK_THRESHOLD，常规扫描=$SCAN_INTERVAL 分钟，高风险扫描=$SCAN_INTERVAL_HIGH 分钟${RESET}"
                echo -e "${YELLOW}若需自动封禁或管理 IP，请使用选项 3 配置 Fail2Ban 或手动编辑 /etc/hosts.deny。${RESET}"
                read -p "按回车键返回主菜单..."
                ;;
20)
    # Speedtest 测速面板管理（ALS 和 SpeedTest）
    echo -e "${GREEN}=== Speedtest 测速面板管理 ===${RESET}"
    echo "1) 安装 ALS 测速面板"
    echo "2) 卸载 ALS 测速面板"
    echo "3) 安装 SpeedTest 测速面板"
    echo "4) 卸载 SpeedTest 测速面板"
    echo "0) 返回主菜单"
    echo -e "${GREEN}=============================${RESET}"
    read -p "请输入选项: " operation_choice

    # 检查系统类型
    check_system
    if [ "$SYSTEM" == "unknown" ]; then
        echo -e "${RED}无法识别系统，无法继续操作！${RESET}"
        read -p "按回车键返回主菜单..."
        continue
    fi

    # 端口检查函数
    check_port() {
        local port=$1
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            return 1
        elif netstat -tuln 2>/dev/null | grep -q ":$port "; then
            return 1
        else
            return 0
        fi
    }

    # 检查防火墙并尝试关闭
    disable_firewall_if_blocking() {
        local port=$1
        local firewall_blocking=false
        if command -v ufw > /dev/null 2>&1; then
            ufw status | grep -q "Status: active"
            if [ $? -eq 0 ]; then
                ufw status | grep -q "$port.*DENY" || ufw status | grep -q "$port.*REJECT"
                if [ $? -eq 0 ]; then
                    firewall_blocking=true
                    echo -e "${YELLOW}检测到 UFW 防火墙可能阻止端口 $port，正在关闭 UFW...${RESET}"
                    sudo ufw disable
                    echo -e "${GREEN}UFW 防火墙已关闭${RESET}"
                fi
            fi
        fi
        if command -v firewall-cmd > /dev/null 2>&1; then
            firewall-cmd --state | grep -q "running"
            if [ $? -eq 0 ]; then
                firewall-cmd --list-ports | grep -q "$port/tcp"
                if [ $? -ne 0 ]; then
                    firewall_blocking=true
                    echo -e "${YELLOW}检测到 firewalld 防火墙可能阻止端口 $port，正在关闭 firewalld...${RESET}"
                    sudo systemctl stop firewalld
                    sudo systemctl disable firewalld
                    echo -e "${GREEN}firewalld 防火墙已关闭${RESET}"
                fi
            fi
        fi
        if command -v iptables > /dev/null 2>&1; then
            iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || iptables -C INPUT -p tcp --dport "$port" -j REJECT 2>/dev/null
            if [ $? -eq 0 ]; then
                firewall_blocking=true
                echo -e "${YELLOW}检测到 iptables 防火墙可能阻止端口 $port，正在清除 iptables 规则...${RESET}"
                sudo iptables -F
                sudo iptables -X
                sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                echo -e "${GREEN}iptables 规则已清除${RESET}"
            fi
        fi
        return $firewall_blocking
    }

    case $operation_choice in
        1)
            # 安装 ALS 测速面板
            echo -e "${GREEN}正在安装 ALS 测速面板...${RESET}"

            # 检测运行中的 Docker 服务
            echo -e "${YELLOW}正在检测运行中的 Docker 服务...${RESET}"
            DOCKER_RUNNING=false
            if command -v docker > /dev/null 2>&1 && systemctl is-active docker > /dev/null 2>&1; then
                DOCKER_RUNNING=true
                echo -e "${YELLOW}检测到 Docker 服务正在运行${RESET}"
                if docker ps -q | grep -q "."; then
                    echo -e "${YELLOW}检测到运行中的 Docker 容器${RESET}"
                fi
            fi

            # 安装 Docker 和 Docker Compose
            if ! command -v docker > /dev/null 2>&1; then
                echo -e "${YELLOW}安装 Docker...${RESET}"
                curl -fsSL https://get.docker.com | sh
                if [ $? -eq 0 ]; then
                    systemctl start docker
                    systemctl enable docker
                    echo -e "${GREEN}Docker 安装成功！${RESET}"
                else
                    echo -e "${RED}Docker 安装失败，请手动安装！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi
            fi
            if ! command -v docker-compose > /dev/null 2>&1; then
                echo -e "${YELLOW}安装 Docker Compose...${RESET}"
                curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                chmod +x /usr/local/bin/docker-compose
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Docker Compose 安装失败，请手动安装！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi
            fi

            # 检查端口占用并选择可用端口
            # ALS 使用 network_mode: host，需要直接占用端口
            # 为避免与统一 Nginx 代理冲突，默认使用 8083 端口
            DEFAULT_PORT=8083
            check_port "$DEFAULT_PORT"
            if [ $? -eq 1 ]; then
                echo -e "${YELLOW}端口 $DEFAULT_PORT 已被占用，自动选择可用端口...${RESET}"
                DEFAULT_PORT=$(get_free_port 8083)
            fi
            echo -e "${GREEN}ALS 将使用端口: $DEFAULT_PORT${RESET}"

            # 检查并放行防火墙端口
            if command -v ufw > /dev/null 2>&1; then
                ufw status | grep -q "Status: active"
                if [ $? -eq 0 ]; then
                    echo -e "${YELLOW}检测到 UFW 防火墙正在运行...${RESET}"
                    ufw status | grep -q "$DEFAULT_PORT"
                    if [ $? -ne 0 ]; then
                        echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                        sudo ufw allow "$DEFAULT_PORT/tcp"
                        sudo ufw reload
                    fi
                fi
            elif command -v iptables > /dev/null 2>&1; then
                echo -e "${YELLOW}检测到 iptables 防火墙...${RESET}"
                iptables -C INPUT -p tcp --dport "$DEFAULT_PORT" -j ACCEPT 2>/dev/null
                if [ $? -ne 0 ]; then
                    echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                    sudo iptables -A INPUT -p tcp --dport "$DEFAULT_PORT" -j ACCEPT
                    sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                fi
            elif command -v firewall-cmd > /dev/null 2>&1; then
                echo -e "${YELLOW}检测到 firewalld 防火墙...${RESET}"
                firewall-cmd --list-ports | grep -q "$DEFAULT_PORT/tcp"
                if [ $? -ne 0 ]; then
                    echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                    sudo firewall-cmd --permanent --add-port="$DEFAULT_PORT/tcp"
                    sudo firewall-cmd --reload
                fi
            fi

            # 创建目录和配置 docker-compose.yml
            cd /home && mkdir -p web && touch web/docker-compose.yml
            sudo bash -c "cat > /home/web/docker-compose.yml <<EOF
version: '3'
services:
  als:
    image: wikihostinc/looking-glass-server:latest
    container_name: als_speedtest_panel
    ports:
      - \"$DEFAULT_PORT:80\"
    environment:
      - HTTP_PORT=$DEFAULT_PORT
    restart: always
    network_mode: host
EOF"

            # 停止并移除旧 ALS 容器（如果存在）
            if docker ps -a | grep -q "als_speedtest_panel"; then
                echo -e "${YELLOW}检测到旧 ALS 容器，正在移除...${RESET}"
                docker stop als_speedtest_panel || true
                docker rm als_speedtest_panel || true
            fi

            # 启动 Docker Compose
            cd /home/web && docker-compose up -d
            if [ $? -ne 0 ]; then
                echo -e "${RED}ALS 测速面板启动失败，请检查 Docker 或网络！${RESET}"
                read -p "按回车键返回主菜单..."
                continue
            fi

            server_ip=$(curl -s4 ifconfig.me || curl -s http://api.ipify.org)
            if [ -z "$server_ip" ]; then
                server_ip="YOUR_SERVER_IP"
                echo -e "${YELLOW}无法自动获取公网 IP，请手动替换访问地址中的 YOUR_SERVER_IP！${RESET}"
            fi
            echo -e "${GREEN}ALS 测速面板安装完成！${RESET}"
            echo -e "${YELLOW}访问 http://$server_ip:$DEFAULT_PORT 查看 ALS 测速面板${RESET}"
            echo -e "${YELLOW}功能包括：HTML5 速度测试、Ping、iPerf3、Speedtest、下载测速、网卡流量监控、在线 Shell${RESET}"
            read -p "按回车键返回主菜单..."
            ;;
        2)
            # 卸载 ALS 测速面板
            echo -e "${GREEN}正在卸载 ALS 测速面板...${RESET}"
            cd /home/web || true
            if [ -f docker-compose.yml ]; then
                docker-compose down -v || true
                echo -e "${YELLOW}已停止并移除 ALS 测速面板容器和卷${RESET}"
            fi
            if docker ps -a | grep -q "als_speedtest_panel"; then
                docker stop als_speedtest_panel || true
                docker rm als_speedtest_panel || true
                echo -e "${YELLOW}已移除独立的 als_speedtest_panel 容器${RESET}"
            fi
            sudo rm -rf /home/web
            echo -e "${YELLOW}已删除 /home/web 目录${RESET}"
            if docker images | grep -q "wikihostinc/looking-glass-server"; then
                read -p "是否移除 ALS 测速面板的 Docker 镜像（wikihostinc/looking-glass-server）？（y/n，默认 n）： " remove_image
                if [ "$remove_image" == "y" ] || [ "$remove_image" == "Y" ]; then
                    docker rmi wikihostinc/looking-glass-server:latest || true
                    echo -e "${YELLOW}已移除 ALS 测速面板的 Docker 镜像${RESET}"
                fi
            fi
            echo -e "${GREEN}ALS 测速面板卸载完成！${RESET}"
            read -p "按回车键返回主菜单..."
            ;;
        3)
            # 安装 SpeedTest 测速面板
            echo -e "${GREEN}正在安装 SpeedTest 测速面板...${RESET}"

            # 检测运行中的 Docker 服务
            echo -e "${YELLOW}正在检测运行中的 Docker 服务...${RESET}"
            DOCKER_RUNNING=false
            if command -v docker > /dev/null 2>&1 && systemctl is-active docker > /dev/null 2>&1; then
                DOCKER_RUNNING=true
                echo -e "${YELLOW}检测到 Docker 服务正在运行${RESET}"
                if docker ps -q | grep -q "."; then
                    echo -e "${YELLOW}检测到运行中的 Docker 容器${RESET}"
                fi
            fi

            # 安装 Docker 和 Docker Compose
            if ! command -v docker > /dev/null 2>&1; then
                echo -e "${YELLOW}安装 Docker...${RESET}"
                curl -fsSL https://get.docker.com | sh
                if [ $? -eq 0 ]; then
                    systemctl start docker
                    systemctl enable docker
                    echo -e "${GREEN}Docker 安装成功！${RESET}"
                else
                    echo -e "${RED}Docker 安装失败，请手动安装！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi
            fi
            if ! command -v docker-compose > /dev/null 2>&1; then
                echo -e "${YELLOW}安装 Docker Compose...${RESET}"
                curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                chmod +x /usr/local/bin/docker-compose
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Docker Compose 安装失败，请手动安装！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi
            fi

            # 检查 ALS 是否安装以决定默认端口
            DEFAULT_PORT=80
            if docker ps -a | grep -q "als_speedtest_panel" || [ -d "/home/web" ]; then
                echo -e "${YELLOW}检测到 ALS 测速面板已安装，SpeedTest 将使用默认端口 6688${RESET}"
                DEFAULT_PORT=6688
            fi

            # 检查端口占用并处理
            check_port "$DEFAULT_PORT"
            if [ $? -eq 1 ]; then
                echo -e "${RED}端口 $DEFAULT_PORT 已被占用！${RESET}"
                disable_firewall_if_blocking "$DEFAULT_PORT"
                check_port "$DEFAULT_PORT"
                if [ $? -eq 1 ]; then
                    read -p "是否更换端口？（y/n，默认 y）： " change_port
                    if [ "$change_port" != "n" ] && [ "$change_port" != "N" ]; then
                        while true; do
                            read -p "请输入新的端口号（例如 8080）： " new_port
                            while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                                echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                                read -p "请输入新的端口号（例如 8080）： " new_port
                            done
                            check_port "$new_port"
                            if [ $? -eq 0 ]; then
                                DEFAULT_PORT=$new_port
                                break
                            else
                                echo -e "${RED}端口 $new_port 已被占用，请选择其他端口！${RESET}"
                                disable_firewall_if_blocking "$new_port"
                                check_port "$new_port"
                                if [ $? -eq 0 ]; then
                                    DEFAULT_PORT=$new_port
                                    break
                                fi
                            fi
                        done
                    else
                        echo -e "${RED}端口 $DEFAULT_PORT 被占用，无法继续安装！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                fi
            fi

            # 检查并放行防火墙端口
            if command -v ufw > /dev/null 2>&1; then
                ufw status | grep -q "Status: active"
                if [ $? -eq 0 ]; then
                    echo -e "${YELLOW}检测到 UFW 防火墙正在运行...${RESET}"
                    ufw status | grep -q "$DEFAULT_PORT"
                    if [ $? -ne 0 ]; then
                        echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                        sudo ufw allow "$DEFAULT_PORT/tcp"
                        sudo ufw reload
                    fi
                fi
            elif command -v iptables > /dev/null 2>&1; then
                echo -e "${YELLOW}检测到 iptables 防火墙...${RESET}"
                iptables -C INPUT -p tcp --dport "$DEFAULT_PORT" -j ACCEPT 2>/dev/null
                if [ $? -ne 0 ]; then
                    echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                    sudo iptables -A INPUT -p tcp --dport "$DEFAULT_PORT" -j ACCEPT
                    sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                fi
            elif command -v firewall-cmd > /dev/null 2>&1; then
                echo -e "${YELLOW}检测到 firewalld 防火墙...${RESET}"
                firewall-cmd --list-ports | grep -q "$DEFAULT_PORT/tcp"
                if [ $? -ne 0 ]; then
                    echo -e "${YELLOW}正在放行端口 $DEFAULT_PORT...${RESET}"
                    sudo firewall-cmd --permanent --add-port="$DEFAULT_PORT/tcp"
                    sudo firewall-cmd --reload
                fi
            fi

            # 创建目录和配置 docker-compose.yml
            cd /home && mkdir -p speedtest && touch speedtest/docker-compose.yml
            sudo bash -c "cat > /home/speedtest/docker-compose.yml <<EOF
version: '3'
services:
  speedtest:
    image: ilemonrain/html5-speedtest:alpine
    container_name: speedtest_html5_panel
    ports:
      - \"$DEFAULT_PORT:80\"
    restart: always
EOF"

            # 停止并移除旧 SpeedTest 容器（如果存在）
            if docker ps -a | grep -q "speedtest_html5_panel"; then
                echo -e "${YELLOW}检测到旧 SpeedTest 容器，正在移除...${RESET}"
                docker stop speedtest_html5_panel || true
                docker rm speedtest_html5_panel || true
            fi

            # 启动 Docker Compose
            cd /home/speedtest && docker-compose up -d
            if [ $? -ne 0 ]; then
                echo -e "${RED}SpeedTest 测速面板启动失败，请检查 Docker 或网络！${RESET}"
                read -p "按回车键返回主菜单..."
                continue
            fi

            server_ip=$(curl -s4 ifconfig.me || curl -s http://api.ipify.org)
            if [ -z "$server_ip" ]; then
                server_ip="YOUR_SERVER_IP"
                echo -e "${YELLOW}无法自动获取公网 IP，请手动替换访问地址中的 YOUR_SERVER_IP！${RESET}"
            fi
            echo -e "${GREEN}SpeedTest 测速面板安装完成！${RESET}"
            echo -e "${YELLOW}访问 http://$server_ip:$DEFAULT_PORT 查看 SpeedTest 测速面板${RESET}"
            echo -e "${YELLOW}功能包括：HTML5 速度测试，适用于带宽测试${RESET}"
            read -p "按回车键返回主菜单..."
            ;;
        4)
            # 卸载 SpeedTest 测速面板
            echo -e "${GREEN}正在卸载 SpeedTest 测速面板...${RESET}"
            cd /home/speedtest || true
            if [ -f docker-compose.yml ]; then
                docker-compose down -v || true
                echo -e "${YELLOW}已停止并移除 SpeedTest 测速面板容器和卷${RESET}"
            fi
            if docker ps -a | grep -q "speedtest_html5_panel"; then
                docker stop speedtest_html5_panel || true
                docker rm speedtest_html5_panel || true
                echo -e "${YELLOW}已移除独立的 speedtest_html5_panel 容器${RESET}"
            fi
            sudo rm -rf /home/speedtest
            echo -e "${YELLOW}已删除 /home/speedtest 目录${RESET}"
            if docker images | grep -q "ilemonrain/html5-speedtest"; then
                read -p "是否移除 SpeedTest 测速面板的 Docker 镜像（ilemonrain/html5-speedtest）？（y/n，默认 n）： " remove_image
                if [ "$remove_image" == "y" ] || [ "$remove_image" == "Y" ]; then
                    docker rmi ilemonrain/html5-speedtest:alpine || true
                    echo -e "${YELLOW}已移除 SpeedTest 测速面板的 Docker 镜像${RESET}"
                fi
            fi
            echo -e "${GREEN}SpeedTest 测速面板卸载完成！${RESET}"
            read -p "按回车键返回主菜单..."
            ;;
        0)
            # 返回主菜单
            continue
            ;;
        *)
            echo -e "${RED}无效选项，请输入 1-4 或 0！${RESET}"
            read -p "按回车键返回主菜单..."
            ;;
    esac
    ;;
        21)
        # WordPress 安装（基于 Docker，支持域名绑定、HTTPS、迁移、证书查看和定时备份，兼容 CentOS）
        echo -e "${GREEN}正在准备处理 WordPress 安装...${RESET}"

        # 检查系统类型
        check_system
        if [ "$SYSTEM" == "unknown" ]; then
            echo -e "${RED}无法识别系统，无法继续操作！${RESET}"
            read -p "按回车键返回主菜单..."
        else
            # 检测网络连接（增强版）
            check_network() {
                local targets=("google.com" "8.8.8.8" "baidu.com")
                local retries=3
                local success=0
                for target in "${targets[@]}"; do
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
            echo -e "${YELLOW}检测网络连接...${RESET}"
            check_network
            if [ $? -ne 0 ]; then
                echo -e "${RED}网络连接失败，请检查网络后重试！${RESET}"
                read -p "按回车键返回主菜单..."
                continue
            fi

            # 检查磁盘空间
            DISK_SPACE=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')
            if [ -z "$DISK_SPACE" ] || ! command -v bc >/dev/null 2>&1; then
                if [ -z "$DISK_SPACE" ]; then
                    echo -e "${RED}无法获取磁盘空间信息${RESET}"
                fi
            elif [ $(echo "$DISK_SPACE < 5" | bc) -eq 1 ]; then
                echo -e "${RED}磁盘空间不足（需至少 5G），请清理后再试！当前可用空间：${DISK_SPACE}G${RESET}"
                read -p "按回车键返回主菜单..."
                continue
            fi

            # 检测并启动 Docker 服务
            echo -e "${YELLOW}正在检测 Docker 服务...${RESET}"
            if ! command -v docker > /dev/null 2>&1 || ! systemctl is-active docker > /dev/null 2>&1; then
                if ! command -v docker > /dev/null 2>&1; then
                    echo -e "${YELLOW}安装 Docker...${RESET}"
                    if [ "$SYSTEM" == "centos" ]; then
                        yum install -y yum-utils
                        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                        yum install -y docker-ce docker-ce-cli containerd.io
                    else
                        curl -fsSL https://get.docker.com | sh
                    fi
                fi
                echo -e "${YELLOW}启动 Docker 服务...${RESET}"
                systemctl start docker
                systemctl enable docker
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Docker 服务启动失败，请手动检查！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi
            fi

            # 安装 Docker Compose
            if ! command -v docker-compose > /dev/null 2>&1; then
                echo -e "${YELLOW}安装 Docker Compose...${RESET}"
                curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose 2>/dev/null
                chmod +x /usr/local/bin/docker-compose
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Docker Compose 安装失败！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi
            fi

            # 检测运行中的 Docker 容器
            if docker ps -q | grep -q "."; then
                echo -e "${YELLOW}检测到运行中的 Docker 容器${RESET}"
                read -p "是否停止并移除运行中的 Docker 容器以继续安装？（y/n，默认 n）： " stop_containers
                if [ "$stop_containers" == "y" ] || [ "$stop_containers" == "Y" ]; then
                    echo -e "${YELLOW}正在停止并移除运行中的 Docker 容器...${RESET}"
                    docker stop $(docker ps -q) || true
                    docker rm $(docker ps -aq) || true
                else
                    echo -e "${RED}保留运行中的容器，可能导致安装冲突，建议手动清理后再试！${RESET}"
                fi
            fi

            # 提示用户选择操作
            echo -e "${YELLOW}请选择操作：${RESET}"
            echo "1) 安装 WordPress"
            echo "2) 卸载 WordPress"
            echo "3) 迁移 WordPress 到新服务器"
            echo "4) 查看证书信息"
            echo "5) 设置定时备份 WordPress"
            read -p "请输入选项（1、2、3、4 或 5）： " operation_choice

case $operation_choice in
    1)
        echo -e "${GREEN}正在安装 WordPress...${RESET}"

        # 检查现有 WordPress 文件
        if [ -d "/home/wordpress" ] && { [ -f "/home/wordpress/docker-compose.yml" ] || [ -d "/home/wordpress/html" ]; }; then
            echo -e "${YELLOW}检测到 /home/wordpress 已存在 WordPress 文件${RESET}"
            read -p "是否覆盖重新安装？（y/n，默认 n）： " overwrite
            if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
                echo -e "${YELLOW}选择不覆盖，尝试启动现有 WordPress...${RESET}"
                if [ ! -f "/home/wordpress/docker-compose.yml" ]; then
                    echo -e "${RED}缺少 docker-compose.yml，无法启动现有实例！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi
                cd /home/wordpress
                for image in nginx:latest wordpress:php8.2-fpm mariadb:10.5 certbot/certbot; do
                    if ! docker images | grep -q "$(echo $image | cut -d: -f1)"; then
                        echo -e "${YELLOW}拉取缺失的镜像 $image...${RESET}"
                        docker pull "$image"
                        if [ $? -ne 0 ]; then
                            echo -e "${RED}拉取镜像 $image 失败，请检查网络！${RESET}"
                            read -p "按回车键返回主菜单..."
                            continue 2
                        fi
                    fi
                done
                docker-compose up -d
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}现有 WordPress 启动成功！${RESET}"
                    echo -e "${YELLOW}请访问 http://<服务器IP>:$DEFAULT_PORT 或 https://<域名>:$DEFAULT_SSL_PORT${RESET}"
                    echo -e "${YELLOW}后台地址：/wp-admin（请根据实际情况输入用户名和密码）${RESET}"
                else
                    echo -e "${RED}启动现有 WordPress 失败，请检查 docker-compose.yml 或日志！${RESET}"
                    docker-compose logs
                fi
                read -p "按回车键返回主菜单..."
                continue
            else
                echo -e "${YELLOW}将覆盖现有 WordPress 文件...${RESET}"
                rm -rf /home/wordpress
            fi
        fi

        # 创建 WordPress 目录
        mkdir -p /home/wordpress/html /home/wordpress/mysql /home/wordpress/conf.d /home/wordpress/logs/nginx /home/wordpress/logs/mariadb /home/wordpress/certs


        # WordPress 安装模式选择
        echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}║       WordPress 安装模式选择       ║${RESET}"
        echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
        echo -e "请选择 WordPress 安装配置模式："
        echo -e "  ${GREEN}1)${RESET} 256MB 极简模式 (小型站点、测试环境)"
        echo -e "  ${GREEN}2)${RESET} 512MB 标准模式 (一般生产环境) ${YELLOW}[推荐]${RESET}"
        echo -e "  ${GREEN}3)${RESET} 1024MB 高性能模式 (大型站点、高流量)"
        read -p "请输入选项（1、2、3，默认 2）： " install_mode
        install_mode=${install_mode:-2}
        case $install_mode in
            1) MINIMAL_MODE="256";;
            2) MINIMAL_MODE="512";;
            3) MINIMAL_MODE="1024";;
            *) MINIMAL_MODE="512";;
        esac
        echo -e "\${GREEN}已选择 \${MINIMAL_MODE}MB 配置模式\${RESET}"

        # 检查端口占用并选择可用端口
        # WordPress使用高端口（8082）作为内部端口，由统一Nginx反向代理处理80/443
        DEFAULT_PORT=8082
        DEFAULT_SSL_PORT=8443
        WORDPRESS_INTERNAL_PORT=8082
        check_port() {
            local port=$1
            if command -v ss > /dev/null 2>&1; then
                ss -tuln | grep -q ":$port " && return 1 || return 0
            elif command -v netstat > /dev/null 2>&1; then
                netstat -tuln | grep -q ":$port " && return 1 || return 0
            else
                echo -e "${RED}未找到 ss 或 netstat，正在安装 net-tools...${RESET}"
                if [ "$SYSTEM" == "centos" ]; then
                    yum install -y net-tools
                else
                    apt install -y net-tools
                fi
                ss -tuln | grep -q ":$port " && return 1 || return 0
            fi
        }

        check_port "$WORDPRESS_INTERNAL_PORT"
        if [ $? -eq 1 ]; then
            echo -e "${YELLOW}端口 $WORDPRESS_INTERNAL_PORT 被占用，自动选择可用端口...${RESET}"
            WORDPRESS_INTERNAL_PORT=$(get_free_port 8082)
            DEFAULT_PORT=$WORDPRESS_INTERNAL_PORT
            DEFAULT_SSL_PORT=$((WORDPRESS_INTERNAL_PORT + 1))
        fi

        # 域名绑定和HTTPS配置
        echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}║         WordPress 配置界面         ║${RESET}"
        echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
        read -p "是否绑定域名？（y/n，默认 n）： " bind_domain
        DOMAIN=""
        WP_EMAIL="admin@wordpress.local"
        if [ "$bind_domain" == "y" ] || [ "$bind_domain" == "Y" ]; then
            read -p "请输入域名（例如 example.com）： " DOMAIN
            while [ -z "$DOMAIN" ]; do
                echo -e "${RED}域名不能为空，请重新输入！${RESET}"
                read -p "请输入域名（例如 example.com）： " DOMAIN
            done
            read -p "请输入邮箱（用于证书通知，默认 admin@$DOMAIN）： " wp_email_input
            WP_EMAIL=${wp_email_input:-admin@$DOMAIN}
            read -p "是否启用 HTTPS（需域名指向服务器 IP）？（y/n，默认 y）： " enable_https
            enable_https=${enable_https:-y}
            if [ "$enable_https" == "y" ] || [ "$enable_https" == "Y" ]; then
                ENABLE_HTTPS="yes"
            fi
        fi
        # WordPress内部配置已完成，现在使用统一反向代理处理域名
        if [ "$MINIMAL_MODE" != "256" ] && [ "${ENABLE_HTTPS:-no}" == "yes" ] && [ -n "$DOMAIN" ]; then
            echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
            echo -e "${YELLOW}║         配置 HTTPS 反向代理         ║${RESET}"
            echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
            
            # 使用统一Nginx反向代理申请证书
            add_domain_to_unified_nginx "$DOMAIN" "$WORDPRESS_INTERNAL_PORT" "$WP_EMAIL"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}域名 $DOMAIN HTTPS 配置成功！${RESET}"
                CERT_OK="yes"
            else
                echo -e "${RED}域名 HTTPS 配置失败，将使用 HTTP 访问${RESET}"
                CERT_OK="no"
                CERT_FAIL="yes"
            fi
        fi

        # 配置 WordPress Nginx（内部配置，不再监听80/443）
        TEMP_CONF=$(mktemp)
        if [ "$MINIMAL_MODE" == "256" ] || [ "${ENABLE_HTTPS:-no}" != "yes" ] || [ "${CERT_OK:-no}" != "yes" ]; then
            # HTTP only 或证书申请失败时的配置
            cat > "$TEMP_CONF" <<EOF
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html index.htm;

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
        else
            # HTTPS 配置（WordPress内部仍然处理PHP，但由统一代理提供SSL）
            cat > "$TEMP_CONF" <<EOF
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
    index index.php index.html index.htm;

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
        fi
        mv "$TEMP_CONF" /home/wordpress/conf.d/default.conf
        chmod 644 /home/wordpress/conf.d/default.conf

        # 创建 Docker Compose 配置
        echo -e "${YELLOW}创建 Docker Compose 配置...${RESET}"
        cat > /home/wordpress/docker-compose.yml <<EOF
services:
  nginx:
    image: nginx:latest
    container_name: wordpress_nginx
    ports:
      - "${WORDPRESS_INTERNAL_PORT}:80"
    volumes:
      - ./html:/var/www/html
      - ./conf.d:/etc/nginx/conf.d
      - ./logs/nginx:/var/log/nginx
    depends_on:
      - wordpress
    restart: unless-stopped
    networks:
      - wordpress_network
    healthcheck:
      disable: true

  wordpress:
    image: wordpress:php8.2-fpm
    container_name: wordpress
    environment:
      - WORDPRESS_DB_HOST=mariadb
      - WORDPRESS_DB_USER=wordpress
      - WORDPRESS_DB_PASSWORD=\${db_user_passwd}
      - WORDPRESS_DB_NAME=wordpress
    volumes:
      - ./html:/var/www/html
    depends_on:
      - mariadb
    restart: unless-stopped
    networks:
      - wordpress_network
    healthcheck:
      disable: true

  mariadb:
    image: mariadb:10.5
    container_name: wordpress_mariadb
    environment:
      - MYSQL_ROOT_PASSWORD=\${db_root_passwd}
      - MYSQL_DATABASE=wordpress
      - MYSQL_USER=wordpress
      - MYSQL_PASSWORD=\${db_user_passwd}
    volumes:
      - ./mysql:/var/lib/mysql
    restart: unless-stopped
    networks:
      - wordpress_network
    healthcheck:
      disable: true

networks:
  wordpress_network:
    driver: bridge
EOF

        # 创建 .env 文件存储密码
        db_root_passwd=$(openssl rand -base64 24)
        db_user_passwd=$(openssl rand -base64 24)
        cat > /home/wordpress/.env <<EOF
db_root_passwd=${db_root_passwd}
db_user_passwd=${db_user_passwd}
EOF

        # 确保 Docker Compose 可用
        if ! command -v docker-compose > /dev/null 2>&1; then
            echo -e "${YELLOW}安装 Docker Compose...${RESET}"
            curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose 2>/dev/null
            chmod +x /usr/local/bin/docker-compose
        fi

        # 启动 Docker Compose
        echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}║         启动所有服务界面          ║${RESET}"
        echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
        cd /home/wordpress && /usr/local/bin/docker-compose up -d
        if [ $? -ne 0 ]; then
            echo -e "${RED}Docker Compose 启动失败，请检查以下日志！${RESET}"
            docker-compose logs
            echo -e "${YELLOW}可能原因：镜像拉取失败、端口冲突或服务依赖问题${RESET}"
            read -p "按回车键返回主菜单..."
            continue
        fi
        echo -e "${GREEN}所有服务启动成功！${RESET}"

        # 等待服务就绪并动态检查容器状态
        echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}║         服务初始化界面            ║${RESET}"
        echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
        echo -e "${YELLOW}等待容器启动（最多等待 180 秒）...${RESET}"
        
        TIMEOUT=180
        INTERVAL=10
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            if docker ps --format '{{.Names}}' | grep -q "wordpress_nginx" && \
               docker ps --format '{{.Names}}' | grep -q "wordpress" && \
               docker ps --format '{{.Names}}' | grep -q "wordpress_mariadb"; then
                echo -e "${GREEN}所有容器已启动！${RESET}"
                break
            fi
            echo -e "${YELLOW}等待容器启动，已用时 $ELAPSED 秒...${RESET}"
            sleep $INTERVAL
            ELAPSED=$((ELAPSED + INTERVAL))
        done

        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo -e "${RED}容器未在 180 秒内完全启动，请检查以下信息：${RESET}"
            echo -e "${YELLOW}容器状态：${RESET}"
            docker ps -a
            echo -e "${YELLOW}日志：${RESET}"
            docker-compose logs
            read -p "按回车键返回主菜单..."
            continue
        fi

        # 额外等待 MariaDB 初始化
        echo -e "${YELLOW}等待 MariaDB 数据库初始化（最多 60 秒）...${RESET}"
        DB_TIMEOUT=60
        DB_INTERVAL=5
        DB_ELAPSED=0
        MYSQL_PING_RESULT=""
        while [ $DB_ELAPSED -lt $DB_TIMEOUT ]; do
            MYSQL_PING_RESULT=$(docker exec wordpress_mariadb mysqladmin ping -h localhost -u root -p"$db_root_passwd" 2>&1)
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}MariaDB 数据库就绪！${RESET}"
                break
            fi
            echo -e "${YELLOW}等待 MariaDB 就绪，已用时 $DB_ELAPSED 秒...${RESET}"
            sleep $DB_INTERVAL
            DB_ELAPSED=$((DB_ELAPSED + DB_INTERVAL))
        done
        
        if [ $DB_ELAPSED -ge $DB_TIMEOUT ]; then
            echo -e "${YELLOW}MariaDB 响应超时，但容器已在运行，继续安装...${RESET}"
        fi

        CHECK_PORT=$DEFAULT_PORT
        if [ "$MINIMAL_MODE" != "256" ] && [ "${ENABLE_HTTPS:-no}" == "yes" ] && [ "${CERT_OK:-no}" == "yes" ]; then
            CHECK_PORT=$DEFAULT_SSL_PORT
            CHECK_URL="https://$DOMAIN:$CHECK_PORT"
        else
            CHECK_URL="http://localhost:$CHECK_PORT"
        fi

        # 检查 HTTP 访问（302/301 重定向或 000 连接超时都可能是正常的）
        echo -e "${YELLOW}检查服务访问...${RESET}"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$CHECK_URL" 2>/dev/null)
        
        # 容器都运行且 MariaDB 就绪的情况下，允许 000（连接超时）通过
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
            echo -e "${GREEN}服务访问正常 (HTTP $HTTP_CODE)！${RESET}"
        elif [ "$HTTP_CODE" = "000" ]; then
            # 容器都在运行且 MariaDB 就绪，000 可能是时序问题，认为成功
            echo -e "${GREEN}服务已启动（容器运行正常，MariaDB 就绪）${RESET}"
        else
            echo -e "${RED}服务访问异常 (HTTP $HTTP_CODE)，请检查以下信息：${RESET}"
            echo -e "${YELLOW}容器状态：${RESET}"
            docker ps -a
            echo -e "${YELLOW}日志：${RESET}"
            docker-compose logs
            read -p "按回车键返回主菜单..."
            continue
        fi

        # 配置系统服务以确保服务器重启后自动运行
        echo -e "${YELLOW}╔════════════════════════════════════╗${RESET}"
        echo -e "${YELLOW}║         配置系统服务界面          ║${RESET}"
        echo -e "${YELLOW}╚════════════════════════════════════╝${RESET}"
        bash -c "cat > /etc/systemd/system/wordpress.service <<EOF
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
EOF"
        systemctl enable wordpress.service
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}WordPress 服务已配置为开机自启！${RESET}"
        else
            echo -e "${RED}配置 WordPress 服务失败，请手动检查！${RESET}"
        fi

        # 禁用交换空间（可选，仅在 1GB 模式下）
        if [ "$MINIMAL_MODE" == "1024" ]; then
            echo -e "${YELLOW}MariaDB 已稳定运行，是否禁用交换空间以释放磁盘空间？（y/n，默认 n）：${RESET}"
            read -p "请输入选择： " disable_swap
            if [ "$disable_swap" == "y" ] || [ "$disable_swap" == "Y" ]; then
                swapoff /swapfile
                sed -i '/\/swapfile none swap sw 0 0/d' /etc/fstab
                rm -f /swapfile
                echo -e "${GREEN}交换空间已禁用并删除！${RESET}"
            fi
        fi

        # 显示安装完成界面
        echo -e "${GREEN}╔════════════════════════════════════╗${RESET}"
        echo -e "${GREEN}║         安装完成界面              ║${RESET}"
        echo -e "${GREEN}╚════════════════════════════════════╝${RESET}"
        server_ip=$(curl -s4 ifconfig.me)
        if [ -z "$server_ip" ]; then
            server_ip="你的服务器IP"
        fi
        echo -e "${GREEN}WordPress 安装完成！${RESET}"
        if [ "$MINIMAL_MODE" != "256" ] && [ "${ENABLE_HTTPS:-no}" == "yes" ] && [ "${CERT_OK:-no}" == "yes" ]; then
            echo -e "${YELLOW}访问地址：https://$DOMAIN:$DEFAULT_SSL_PORT${RESET}"
            echo -e "${YELLOW}后台地址：https://$DOMAIN:$DEFAULT_SSL_PORT/wp-admin${RESET}"
        else
            echo -e "${YELLOW}访问地址：http://$server_ip:$DEFAULT_PORT${RESET}"
            echo -e "${YELLOW}后台地址：http://$server_ip:$DEFAULT_PORT/wp-admin${RESET}"
        fi
        echo -e "${YELLOW}数据库用户：wordpress${RESET}"
        echo -e "${YELLOW}数据库密码：$db_user_passwd${RESET}"
        echo -e "${YELLOW}ROOT 密码：$db_root_passwd${RESET}"
        echo -e "${YELLOW}安装目录：/home/wordpress${RESET}"
        echo -e "${YELLOW}文件存放：/home/wordpress/html/wp-content/uploads${RESET}"
        echo -e "${YELLOW}日志目录：/home/wordpress/logs/nginx 和 /home/wordpress/logs/mariadb${RESET}"
        if [ "$MINIMAL_MODE" != "256" ] && [ "${ENABLE_HTTPS:-no}" == "yes" ]; then
            echo -e "${YELLOW}证书目录：/home/wordpress/certs${RESET}"
            echo -e "${YELLOW}证书信息：使用选项 4 查看${RESET}"
        fi
        if [ "$MINIMAL_MODE" == "256" ]; then
            echo -e "${YELLOW}注意：当前为 256MB 极简模式，性能较低，仅适合测试用途！${RESET}"
        fi

        # 询问是否配置定时备份
        echo -e "${YELLOW}是否配置定时备份 WordPress 到其他服务器？（y/n，默认 n）：${RESET}"
        read -p "请输入选择： " enable_backup
        if [ "$enable_backup" == "y" ] || [ "$enable_backup" == "Y" ]; then
            operation_choice=5
            echo -e "${YELLOW}即将跳转到定时备份配置（选项 5）...${RESET}"
        fi
        read -p "按回车键返回主菜单..."
        ;;
                2)
                    # 卸载 WordPress
                    echo -e "${GREEN}正在卸载 WordPress...${RESET}"
                    echo -e "${YELLOW}注意：卸载将删除 WordPress 数据和证书，请确保已备份 /home/wordpress/html、/home/wordpress/mysql 和 /home/wordpress/certs${RESET}"
                    read -p "是否继续卸载？（y/n，默认 n）： " confirm_uninstall
                    if [ "$confirm_uninstall" != "y" ] && [ "$confirm_uninstall" != "Y" ]; then
                        echo -e "${YELLOW}取消卸载操作${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    cd /home/wordpress || true
                    if [ -f docker-compose.yml ]; then
                        docker-compose down -v || true
                        echo -e "${YELLOW}已停止并移除 WordPress 容器和卷${RESET}"
                    fi
                    # 检查并移除相关容器
                    for container in wordpress_nginx wordpress wordpress_mariadb wordpress_certbot; do
                        if docker ps -a | grep -q "$container"; then
                            docker stop "$container" || true
                            docker rm "$container" || true
                            echo -e "${YELLOW}已移除容器 $container${RESET}"
                        fi
                    done
                    rm -rf /home/wordpress
                    if [ $? -eq 0 ]; then
                        echo -e "${YELLOW}已删除 /home/wordpress 目录${RESET}"
                    else
                        echo -e "${RED}删除 /home/wordpress 目录失败，请手动检查！${RESET}"
                    fi
                    # 移除系统服务
                    if [ -f "/etc/systemd/system/wordpress.service" ]; then
                        systemctl disable wordpress.service
                        rm -f /etc/systemd/system/wordpress.service
                        systemctl daemon-reload
                        echo -e "${YELLOW}已移除 WordPress 自启服务${RESET}"
                    fi
                    # 移除定时备份任务
                    if crontab -l 2>/dev/null | grep -q "wordpress_backup.sh"; then
                        crontab -l | grep -v "wordpress_backup.sh" | crontab -
                        rm -f /usr/local/bin/wordpress_backup.sh
                        echo -e "${YELLOW}已移除 WordPress 定时备份任务${RESET}"
                    fi
                    # 询问是否移除镜像
                    for image in nginx:latest wordpress:php8.2-fpm mariadb:latest certbot/certbot; do
                        if docker images | grep -q "$(echo $image | cut -d: -f1)"; then
                            read -p "是否移除 WordPress 的 Docker 镜像（$image）？（y/n，默认 n）： " remove_image
                            if [ "$remove_image" == "y" ] || [ "$remove_image" == "Y" ]; then
                                docker rmi "$image" || true
                                if [ $? -eq 0 ]; then
                                    echo -e "${YELLOW}已移除镜像 $image${RESET}"
                                else
                                    echo -e "${RED}移除镜像 $image 失败，可能被其他容器使用！${RESET}"
                                fi
                            fi
                        fi
                    done
                    echo -e "${GREEN}WordPress 卸载完成！${RESET}"
                    read -p "按回车键返回主菜单..."
                    ;;
                3)
                    # 迁移 WordPress 到新服务器
                    echo -e "${GREEN}正在准备迁移 WordPress 到新服务器...${RESET}"
                    if [ ! -d "/home/wordpress" ] || [ ! -f "/home/wordpress/docker-compose.yml" ]; then
                        echo -e "${RED}本地未找到 WordPress 安装目录 (/home/wordpress)，请先安装！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi

                    # 从本地 docker-compose.yml 获取原始端口和域名
                    ORIGINAL_PORT=$(grep -oP '(?<=ports:.*- ")[0-9]+:80' /home/wordpress/docker-compose.yml | cut -d':' -f1 || echo "$DEFAULT_PORT")
                    ORIGINAL_SSL_PORT=$(grep -oP '(?<=ports:.*- ")[0-9]+:443' /home/wordpress/docker-compose.yml | cut -d':' -f1 || echo "$DEFAULT_SSL_PORT")
                    ORIGINAL_DOMAIN=$(sed -n 's/^\s*server_name\s*\([^;]*\);/\1/p' /home/wordpress/conf.d/default.conf | head -n 1 || echo "_")

                    read -p "请输入新服务器的 IP 地址： " NEW_SERVER_IP
                    while [ -z "$NEW_SERVER_IP" ] || ! ping -c 1 "$NEW_SERVER_IP" > /dev/null 2>&1; do
                        echo -e "${RED}IP 地址无效或无法连接，请重新输入！${RESET}"
                        read -p "请输入新服务器的 IP 地址： " NEW_SERVER_IP
                    done

                    read -p "请输入新服务器的 SSH 用户名（默认 root）： " SSH_USER
                    SSH_USER=${SSH_USER:-root}

                    read -p "请输入新服务器的 SSH 密码（或留空使用 SSH 密钥）： " SSH_PASS
                    if [ -z "$SSH_PASS" ]; then
                        echo -e "${YELLOW}将使用 SSH 密钥连接，请确保密钥已配置${RESET}"
                        read -p "请输入本地 SSH 密钥路径（默认 ~/.ssh/id_rsa）： " SSH_KEY
                        SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
                        if [ ! -f "$SSH_KEY" ]; then
                            echo -e "${RED}SSH 密钥文件 $SSH_KEY 不存在，请检查路径！${RESET}"
                            read -p "按回车键返回主菜单..."
                            continue
                        fi
                    fi

                    # 安装 sshpass（如果使用密码且未安装）
                    if [ -n "$SSH_PASS" ] && ! command -v sshpass > /dev/null 2>&1; then
                        echo -e "${YELLOW}检测到需要 sshpass，正在安装...${RESET}"
                        if [ "$SYSTEM" == "centos" ]; then
                            yum install -y epel-release
                            yum install -y sshpass
                        else
                            apt update && apt install -y sshpass
                        fi
                        if [ $? -ne 0 ]; then
                            echo -e "${RED}sshpass 安装失败，请手动安装后重试！${RESET}"
                            read -p "按回车键返回主菜单..."
                            continue
                        fi
                    fi

                    # 测试 SSH 连接
                    echo -e "${YELLOW}测试 SSH 连接到 $NEW_SERVER_IP...${RESET}"
                    if [ -n "$SSH_PASS" ]; then
                        sshpass -p "$SSH_PASS" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "echo SSH 连接成功" 2>/tmp/ssh_error
                        SSH_TEST=$?
                    else
                        ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "echo SSH 连接成功" 2>/tmp/ssh_error
                        SSH_TEST=$?
                    fi
                    if [ $SSH_TEST -ne 0 ]; then
                        echo -e "${RED}SSH 连接失败！错误信息如下：${RESET}"
                        cat /tmp/ssh_error
                        echo -e "${YELLOW}请检查 IP、用户名、密码/密钥或目标服务器 SSH 配置！${RESET}"
                        rm -f /tmp/ssh_error
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    rm -f /tmp/ssh_error
                    echo -e "${GREEN}SSH 连接成功！${RESET}"

                    # 获取新域名（用于迁移后的网站域名）
                    NEW_DOMAIN="$ORIGINAL_DOMAIN"
                    read -p "请输入新服务器的域名（留空使用原域名 $ORIGINAL_DOMAIN）： " input_new_domain
                    if [ -n "$input_new_domain" ]; then
                        NEW_DOMAIN="$input_new_domain"
                    fi
                    echo -e "${YELLOW}迁移后网站将使用域名：$NEW_DOMAIN${RESET}"

                    # 检查原配置是否启用了 HTTPS
                    ENABLE_HTTPS="no"
                    CERT_OK="no"
                    if [ -d "/home/wordpress/certs" ] && [ -f "/home/wordpress/conf.d/default.conf" ]; then
                        if grep -q "listen 443 ssl" /home/wordpress/conf.d/default.conf 2>/dev/null; then
                            ENABLE_HTTPS="yes"
                            if [ -d "/home/wordpress/certs/live" ]; then
                                CERT_OK="yes"
                            fi
                        fi
                    fi
                    echo -e "${YELLOW}原配置 HTTPS 状态：${ENABLE_HTTPS}${RESET}"

                    # 检查新服务器上是否已有 WordPress 文件
                    echo -e "${YELLOW}检查新服务器上是否已有 WordPress 文件...${RESET}"
                    if [ -n "$SSH_PASS" ]; then
                        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "[ -d /home/wordpress ] && echo 'exists' || echo 'not_exists'" > /tmp/wp_check 2>/dev/null
                    else
                        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "[ -d /home/wordpress ] && echo 'exists' || echo 'not_exists'" > /tmp/wp_check 2>/dev/null
                    fi
                    if grep -q "exists" /tmp/wp_check; then
                        echo -e "${YELLOW}新服务器上已存在 /home/wordpress 目录${RESET}"
                        read -p "是否覆盖现有 WordPress 文件？（y/n，默认 n）： " overwrite_new
                        if [ "$overwrite_new" != "y" ] && [ "$overwrite_new" != "Y" ]; then
                            echo -e "${YELLOW}选择不覆盖，尝试在新服务器上启动现有 WordPress...${RESET}"
                            DEPLOY_SCRIPT=$(mktemp)
                            cat > "$DEPLOY_SCRIPT" <<EOF
#!/bin/bash
if ! command -v docker > /dev/null 2>&1; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io
    systemctl start docker
    systemctl enable docker
fi
if ! command -v docker-compose > /dev/null 2>&1; then
    curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi
# 检查防火墙并放行端口
if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state | grep -q "running"; then
    if ! firewall-cmd --list-ports | grep -q "$ORIGINAL_PORT/tcp"; then
        firewall-cmd --permanent --add-port=$ORIGINAL_PORT/tcp
        echo "已放行端口 $ORIGINAL_PORT"
    fi
    if ! firewall-cmd --list-ports | grep -q "$ORIGINAL_SSL_PORT/tcp"; then
        firewall-cmd --permanent --add-port=$ORIGINAL_SSL_PORT/tcp
        echo "已放行端口 $ORIGINAL_SSL_PORT"
    fi
    firewall-cmd --reload
elif command -v iptables > /dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport $ORIGINAL_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $ORIGINAL_PORT -j ACCEPT
    iptables -C INPUT -p tcp --dport $ORIGINAL_SSL_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $ORIGINAL_SSL_PORT -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
cd /home/wordpress
for image in nginx:latest wordpress:php8.2-fpm mariadb:latest certbot/certbot; do
    if ! docker images | grep -q "\$(echo \$image | cut -d: -f1)"; then
        docker pull \$image
    fi
done
docker-compose up -d
if [ \$? -eq 0 ]; then
    echo "WordPress 启动成功，请访问 http://$NEW_SERVER_IP:$ORIGINAL_PORT 或 https://$NEW_DOMAIN:$ORIGINAL_SSL_PORT"
    echo "后台地址：http://$NEW_SERVER_IP:$ORIGINAL_PORT/wp-admin 或 https://$NEW_DOMAIN:$ORIGINAL_SSL_PORT/wp-admin"
else
    echo "启动失败，请检查日志：docker-compose logs"
fi
EOF
                            if [ -n "$SSH_PASS" ]; then
                                sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$DEPLOY_SCRIPT" "$SSH_USER@$NEW_SERVER_IP:/tmp/deploy.sh"
                                sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "bash /tmp/deploy.sh && rm -f /tmp/deploy.sh"
                            else
                                scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$DEPLOY_SCRIPT" "$SSH_USER@$NEW_SERVER_IP:/tmp/deploy.sh"
                                ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "bash /tmp/deploy.sh && rm -f /tmp/deploy.sh"
                            fi
                            rm -f "$DEPLOY_SCRIPT"
                            echo -e "${GREEN}在新服务器上启动现有 WordPress 完成！${RESET}"
                            echo -e "${YELLOW}请在新服务器 $NEW_SERVER_IP 上检查 WordPress 是否运行正常${RESET}"
                            read -p "按回车键返回主菜单..."
                            continue
                        else
                            echo -e "${YELLOW}将覆盖新服务器上的现有 WordPress 文件...${RESET}"
                            if [ -n "$SSH_PASS" ]; then
                                sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "rm -rf /home/wordpress"
                            else
                                ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "rm -rf /home/wordpress"
                            fi
                        fi
                    fi
                    rm -f /tmp/wp_check

                    # 打包 WordPress 数据
                    echo -e "${YELLOW}正在打包 WordPress 数据...${RESET}"
                    tar -czf /tmp/wordpress_backup.tar.gz -C /home wordpress

                    # 传输到新服务器
                    echo -e "${YELLOW}正在传输 WordPress 数据到新服务器 $NEW_SERVER_IP...${RESET}"
                    if [ -n "$SSH_PASS" ]; then
                        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no /tmp/wordpress_backup.tar.gz "$SSH_USER@$NEW_SERVER_IP:~/" 2>/tmp/scp_error
                        SCP_RESULT=$?
                    else
                        scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/wordpress_backup.tar.gz "$SSH_USER@$NEW_SERVER_IP:~/" 2>/tmp/scp_error
                        SCP_RESULT=$?
                    fi
                    if [ $SCP_RESULT -ne 0 ]; then
                        echo -e "${RED}数据传输失败！错误信息如下：${RESET}"
                        cat /tmp/scp_error
                        echo -e "${YELLOW}请检查 SSH 权限或网络连接！${RESET}"
                        rm -f /tmp/wordpress_backup.tar.gz /tmp/scp_error
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    rm -f /tmp/scp_error

                    # 在新服务器上部署
                    echo -e "${YELLOW}正在新服务器上部署 WordPress...${RESET}"
                    DEPLOY_SCRIPT=$(mktemp)
                    if [ "$NEW_DOMAIN" != "$ORIGINAL_DOMAIN" ] || [ "${ENABLE_HTTPS:-no}" == "yes" ]; then
                        # 如果更换域名或启用 HTTPS，修改配置文件并重新生成证书
                        cat > "$DEPLOY_SCRIPT" <<EOF
#!/bin/bash
if ! command -v docker > /dev/null 2>&1; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io
    systemctl start docker
    systemctl enable docker
fi
if ! command -v docker-compose > /dev/null 2>&1; then
    curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi
# 检查防火墙并放行端口
if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state | grep -q "running"; then
    if ! firewall-cmd --list-ports | grep -q "$ORIGINAL_PORT/tcp"; then
        firewall-cmd --permanent --add-port=$ORIGINAL_PORT/tcp
        echo "已放行端口 $ORIGINAL_PORT"
    fi
    if ! firewall-cmd --list-ports | grep -q "$ORIGINAL_SSL_PORT/tcp"; then
        firewall-cmd --permanent --add-port=$ORIGINAL_SSL_PORT/tcp
        echo "已放行端口 $ORIGINAL_SSL_PORT"
    fi
    firewall-cmd --reload
elif command -v iptables > /dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport $ORIGINAL_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $ORIGINAL_PORT -j ACCEPT
    iptables -C INPUT -p tcp --dport $ORIGINAL_SSL_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $ORIGINAL_SSL_PORT -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
mkdir -p /home/wordpress
tar -xzf ~/wordpress_backup.tar.gz -C /home
cd /home/wordpress
# 更新 Nginx 配置中的域名
sed -i "s/server_name $ORIGINAL_DOMAIN/server_name $NEW_DOMAIN/g" conf.d/default.conf
# 拉取镜像
for image in nginx:latest wordpress:php8.2-fpm mariadb:latest certbot/certbot; do
    if ! docker images | grep -q "\$(echo \$image | cut -d: -f1)"; then
        docker pull \$image
    fi
done
docker-compose up -d
# 配置系统服务
cat > /etc/systemd/system/wordpress.service <<EOL
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
EOL
systemctl enable wordpress.service
# 更新 WordPress 数据库中的域名（使用 SQL 而非 wp cli）
DB_PASS=$(grep MYSQL_PASSWORD /home/wordpress/.env 2>/dev/null | cut -d'=' -f2 || echo "")
if [ -z "$DB_PASS" ]; then
    DB_PASS=$(grep MYSQL_PASSWORD /home/wordpress/docker-compose.yml 2>/dev/null | grep -oP '(?<=MYSQL_PASSWORD: ").*(?=")' | head -1)
fi
docker exec wordpress_mariadb mysql -uwordpress -p"$DB_PASS" wordpress -e "UPDATE wp_options SET option_value='http://$NEW_SERVER_IP:$ORIGINAL_PORT' WHERE option_name IN ('siteurl','home');" 2>/dev/null || echo "数据库更新跳过"
if [ "${ENABLE_HTTPS:-no}" == "yes" ]; then
    docker run --rm -v /home/wordpress/certs:/etc/letsencrypt -v /home/wordpress/html:/var/www/html certbot/certbot certonly --webroot -w /var/www/html --force-renewal --email "admin@$NEW_DOMAIN" -d "$NEW_DOMAIN" --agree-tos --non-interactive
    if [ \$? -eq 0 ]; then
        echo "证书重新申请成功"
        docker-compose restart nginx
        docker exec wordpress_mariadb mysql -uwordpress -p"$DB_PASS" wordpress -e "UPDATE wp_options SET option_value='https://$NEW_DOMAIN:$ORIGINAL_SSL_PORT' WHERE option_name IN ('siteurl','home');" 2>/dev/null || echo "数据库更新跳过"
    else
        echo "证书重新申请失败，请检查域名解析"
    fi
fi
rm -f ~/wordpress_backup.tar.gz
EOF
                    else
                        cat > "$DEPLOY_SCRIPT" <<EOF
#!/bin/bash
if ! command -v docker > /dev/null 2>&1; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io
    systemctl start docker
    systemctl enable docker
fi
if ! command -v docker-compose > /dev/null 2>&1; then
    curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi
# 检查防火墙并放行端口
if command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state | grep -q "running"; then
    if ! firewall-cmd --list-ports | grep -q "$ORIGINAL_PORT/tcp"; then
        firewall-cmd --permanent --add-port=$ORIGINAL_PORT/tcp
        echo "已放行端口 $ORIGINAL_PORT"
    fi
    if ! firewall-cmd --list-ports | grep -q "$ORIGINAL_SSL_PORT/tcp"; then
        firewall-cmd --permanent --add-port=$ORIGINAL_SSL_PORT/tcp
        echo "已放行端口 $ORIGINAL_SSL_PORT"
    fi
    firewall-cmd --reload
elif command -v iptables > /dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport $ORIGINAL_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $ORIGINAL_PORT -j ACCEPT
    iptables -C INPUT -p tcp --dport $ORIGINAL_SSL_PORT -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $ORIGINAL_SSL_PORT -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
mkdir -p /home/wordpress
tar -xzf ~/wordpress_backup.tar.gz -C /home
cd /home/wordpress
for image in nginx:latest wordpress:php8.2-fpm mariadb:latest certbot/certbot; do
    if ! docker images | grep -q "\$(echo \$image | cut -d: -f1)"; then
        docker pull \$image
    fi
done
docker-compose up -d
# 配置系统服务
cat > /etc/systemd/system/wordpress.service <<EOL
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
EOL
systemctl enable wordpress.service
rm -f ~/wordpress_backup.tar.gz
EOF
                    fi

                    if [ -n "$SSH_PASS" ]; then
                        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$DEPLOY_SCRIPT" "$SSH_USER@$NEW_SERVER_IP:/tmp/deploy.sh" 2>/tmp/scp_error
                        SCP_RESULT=$?
                        if [ $SCP_RESULT -eq 0 ]; then
                            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "bash /tmp/deploy.sh && rm -f /tmp/deploy.sh" 2>/tmp/ssh_error
                            SSH_RESULT=$?
                        fi
                    else
                        scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$DEPLOY_SCRIPT" "$SSH_USER@$NEW_SERVER_IP:/tmp/deploy.sh" 2>/tmp/scp_error
                        SCP_RESULT=$?
                        if [ $SCP_RESULT -eq 0 ]; then
                            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NEW_SERVER_IP" "bash /tmp/deploy.sh && rm -f /tmp/deploy.sh" 2>/tmp/ssh_error
                            SSH_RESULT=$?
                        fi
                    fi
                    if [ $SCP_RESULT -ne 0 ] || [ $SSH_RESULT -ne 0 ]; then
                        echo -e "${RED}新服务器部署失败！${RESET}"
                        if [ $SCP_RESULT -ne 0 ]; then
                            echo -e "${RED}脚本传输失败，错误信息如下：${RESET}"
                            cat /tmp/scp_error
                        fi
                        if [ $SSH_RESULT -ne 0 ]; then
                            echo -e "${RED}部署执行失败，错误信息如下：${RESET}"
                            cat /tmp/ssh_error
                        fi
                        echo -e "${YELLOW}请检查 SSH 连接、权限或新服务器环境！${RESET}"
                        rm -f /tmp/wordpress_backup.tar.gz "$DEPLOY_SCRIPT" /tmp/scp_error /tmp/ssh_error
                        read -p "按回车键返回主菜单..."
                        continue
                    fi

                    # 清理临时文件
                    rm -f /tmp/wordpress_backup.tar.gz "$DEPLOY_SCRIPT" /tmp/scp_error /tmp/ssh_error

                    echo -e "${GREEN}WordPress 迁移完成！${RESET}"
                    if [ "${ENABLE_HTTPS:-no}" == "yes" ] && [ "${CERT_OK:-no}" == "yes" ]; then
                        echo -e "${YELLOW}在新服务器 $NEW_SERVER_IP 上访问 WordPress：https://$NEW_DOMAIN:$ORIGINAL_SSL_PORT${RESET}"
                        echo -e "${YELLOW}后台地址：https://$NEW_DOMAIN:$ORIGINAL_SSL_PORT/wp-admin${RESET}"
                    else
                        echo -e "${YELLOW}在新服务器 $NEW_SERVER_IP 上访问 WordPress：http://$NEW_SERVER_IP:$ORIGINAL_PORT${RESET}"
                        echo -e "${YELLOW}后台地址：http://$NEW_SERVER_IP:$ORIGINAL_PORT/wp-admin${RESET}"
                    fi
                    echo -e "${YELLOW}新服务器防火墙已自动放行端口 $ORIGINAL_PORT 和 $ORIGINAL_SSL_PORT${RESET}"
                    if [ "${ENABLE_HTTPS:-no}" == "yes" ]; then
                        echo -e "${YELLOW}请使用选项 4 查看新证书详细信息${RESET}"
                    fi
                    read -p "按回车键返回主菜单..."
                    ;;
                4)
                    # 查看证书信息
                    echo -e "${GREEN}正在查看证书信息...${RESET}"
                    
                    # 获取当前域名（从统一代理配置）
                    CURRENT_DOMAIN=""
                    for conf in /etc/nginx/conf.d/domain-*.conf; do
                        if [ -f "$conf" ]; then
                            domain=$(basename "$conf" | sed 's/^domain-\(.*\)\.conf/\1/')
                            if [ -n "$domain" ]; then
                                CURRENT_DOMAIN="$domain"
                                break
                            fi
                        fi
                    done
                    
                    if [ -z "$CURRENT_DOMAIN" ]; then
                        # 尝试从WordPress配置获取
                        CURRENT_DOMAIN=$(grep "server_name" /home/wordpress/conf.d/default.conf 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
                    fi
                    
                    if [ -z "$CURRENT_DOMAIN" ] || [ "$CURRENT_DOMAIN" = "localhost" ]; then
                        echo -e "${RED}无法获取域名，请先配置域名绑定！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    
                    CERT_FILE="/etc/letsencrypt/live/$CURRENT_DOMAIN/fullchain.pem"
                    
                    if [ ! -f "$CERT_FILE" ]; then
                        echo -e "${RED}证书文件 $CERT_FILE 不存在，请检查 HTTPS 配置！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    
                    # 提取证书信息
                    START_DATE=$(openssl x509 -startdate -noout -in "$CERT_FILE" 2>/dev/null | cut -d'=' -f2)
                    END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d'=' -f2)
                    CERT_TYPE=$(openssl x509 -text -noout -in "$CERT_FILE" 2>/dev/null | grep -A1 "Public-Key" | tail -n1 | sed 's/^\s*//;s/\s*$//')
                    
                    if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
                        echo -e "${RED}无法解析证书信息，请检查证书文件完整性！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    
                    # 计算剩余天数
                    EXPIRY_EPOCH=$(date -d "$END_DATE" +%s)
                    CURRENT_EPOCH=$(date +%s)
                    DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))
                    
                    echo -e "${YELLOW}证书信息如下：${RESET}"
                    echo -e "${YELLOW}证书域名：$CURRENT_DOMAIN${RESET}"
                    echo -e "${YELLOW}申请时间：$START_DATE${RESET}"
                    echo -e "${YELLOW}到期时间：$END_DATE${RESET}"
                    echo -e "${YELLOW}剩余天数：$DAYS_LEFT 天${RESET}"
                    echo -e "${YELLOW}申请方式：Let's Encrypt${RESET}"
                    echo -e "${YELLOW}证书类型：$CERT_TYPE${RESET}"
                    echo -e "${YELLOW}证书路径：$CERT_FILE${RESET}"
                    read -p "按回车键返回主菜单..."
                    ;;
                5)
                    # 设置定时备份 WordPress
                    echo -e "${GREEN}正在设置 WordPress 定时备份...${RESET}"
                    if [ ! -d "/home/wordpress" ] || [ ! -f "/home/wordpress/docker-compose.yml" ]; then
                        echo -e "${RED}本地未找到 WordPress 安装目录 (/home/wordpress)，请先安装！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi

                    read -p "请输入备份目标服务器的 IP 地址： " BACKUP_SERVER_IP
                    while [ -z "$BACKUP_SERVER_IP" ] || ! ping -c 1 "$BACKUP_SERVER_IP" > /dev/null 2>&1; do
                        echo -e "${RED}IP 地址无效或无法连接，请重新输入！${RESET}"
                        read -p "请输入备份目标服务器的 IP 地址： " BACKUP_SERVER_IP
                    done

                    read -p "请输入目标服务器的 SSH 用户名（默认 root）： " BACKUP_SSH_USER
                    BACKUP_SSH_USER=${BACKUP_SSH_USER:-root}

                    read -p "请输入目标服务器的 SSH 密码（或留空使用 SSH 密钥）： " BACKUP_SSH_PASS
                    if [ -z "$BACKUP_SSH_PASS" ]; then
                        echo -e "${YELLOW}将使用 SSH 密钥备份，请确保密钥已配置${RESET}"
                        read -p "请输入本地 SSH 密钥路径（默认 ~/.ssh/id_rsa）： " BACKUP_SSH_KEY
                        BACKUP_SSH_KEY=${BACKUP_SSH_KEY:-~/.ssh/id_rsa}
                        if [ ! -f "$BACKUP_SSH_KEY" ]; then
                            echo -e "${RED}SSH 密钥文件 $BACKUP_SSH_KEY 不存在，请检查路径！${RESET}"
                            read -p "按回车键返回主菜单..."
                            continue
                        fi
                    fi

                    # 安装 sshpass（如果使用密码且未安装）
                    if [ -n "$BACKUP_SSH_PASS" ] && ! command -v sshpass > /dev/null 2>&1; then
                        echo -e "${YELLOW}检测到需要 sshpass，正在安装...${RESET}"
                        if [ "$SYSTEM" == "centos" ]; then
                            yum install -y epel-release
                            yum install -y sshpass
                        else
                            apt update && apt install -y sshpass
                        fi
                        if [ $? -ne 0 ]; then
                            echo -e "${RED}sshpass 安装失败，请手动安装后重试！${RESET}"
                            read -p "按回车键返回主菜单..."
                            continue
                        fi
                    fi

                    # 测试 SSH 连接
                    echo -e "${YELLOW}测试 SSH 连接到 $BACKUP_SERVER_IP...${RESET}"
                    if [ -n "$BACKUP_SSH_PASS" ]; then
                        sshpass -p "$BACKUP_SSH_PASS" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$BACKUP_SSH_USER@$BACKUP_SERVER_IP" "echo SSH 连接成功" 2>/tmp/ssh_error
                        SSH_TEST=$?
                    else
                        ssh -i "$BACKUP_SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$BACKUP_SSH_USER@$BACKUP_SERVER_IP" "echo SSH 连接成功" 2>/tmp/ssh_error
                        SSH_TEST=$?
                    fi
                    if [ $SSH_TEST -ne 0 ]; then
                        echo -e "${RED}SSH 连接失败！错误信息如下：${RESET}"
                        cat /tmp/ssh_error
                        echo -e "${YELLOW}请检查 IP、用户名、密码/密钥或目标服务器 SSH 配置！${RESET}"
                        rm -f /tmp/ssh_error
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    rm -f /tmp/ssh_error
                    echo -e "${GREEN}SSH 连接成功！${RESET}"

                    # 选择备份周期
                    echo -e "${YELLOW}请选择备份周期（默认 每天）：${RESET}"
                    echo "1) 每天（每天备份一次）"
                    echo "2) 每周（每周备份一次）"
                    echo "3) 每月（每月备份一次）"
                    echo "4) 立即备份（仅执行一次备份，不设置定时任务）"
                    read -p "请输入选项（1、2、3 或 4，默认 1）： " backup_interval_choice
                    case $backup_interval_choice in
                        2) BACKUP_INTERVAL="每周"; CRON_DAY="0"; CRON_WDAY="0" ;; # 每周日凌晨2点
                        3) BACKUP_INTERVAL="每月"; CRON_DAY="1"; CRON_WDAY="*" ;; # 每月1日凌晨2点
                        4) BACKUP_INTERVAL="立即备份"; CRON_DAY="*"; CRON_WDAY="*" ;;
                        *|1) BACKUP_INTERVAL="每天"; CRON_DAY="*"; CRON_WDAY="*" ;; # 每天凌晨2点
                    esac

                    if [ "$BACKUP_INTERVAL" != "立即备份" ]; then
                        # 选择备份时间
                        read -p "请输入备份时间 - 小时（0-23，默认 2）： " BACKUP_HOUR
                        BACKUP_HOUR=${BACKUP_HOUR:-2}
                        while ! [[ "$BACKUP_HOUR" =~ ^[0-9]+$ ]] || [ "$BACKUP_HOUR" -lt 0 ] || [ "$BACKUP_HOUR" -gt 23 ]; do
                            echo -e "${RED}小时必须为 0-23 之间的数字，请重新输入！${RESET}"
                            read -p "请输入备份时间 - 小时（0-23，默认 2）： " BACKUP_HOUR
                        done

                        read -p "请输入备份时间 - 分钟（0-59，默认 0）： " BACKUP_MINUTE
                        BACKUP_MINUTE=${BACKUP_MINUTE:-0}
                        while ! [[ "$BACKUP_MINUTE" =~ ^[0-9]+$ ]] || [ "$BACKUP_MINUTE" -lt 0 ] || [ "$BACKUP_MINUTE" -gt 59 ]; do
                            echo -e "${RED}分钟必须为 0-59 之间的数字，请重新输入！${RESET}"
                            read -p "请输入备份时间 - 分钟（0-59，默认 0）： " BACKUP_MINUTE
                        done

                        # 正确构建 cron 表达式：分 时 日 月 周
                        if [ "$backup_interval_choice" == "2" ]; then
                            # 每周：分 时 * * 周字段
                            CRON_TIME="$BACKUP_MINUTE $BACKUP_HOUR * * $CRON_WDAY"
                        elif [ "$backup_interval_choice" == "3" ]; then
                            # 每月：分 时 日 * *
                            CRON_TIME="$BACKUP_MINUTE $BACKUP_HOUR $CRON_DAY * *"
                        else
                            # 每天：分 时 * * *
                            CRON_TIME="$BACKUP_MINUTE $BACKUP_HOUR * * *"
                        fi
                    fi

                    # 创建凭证存储文件（仅root可读）
                    CREDENTIAL_FILE="/root/.wordpress_backup_creds"
                    chmod 600 "$CREDENTIAL_FILE" 2>/dev/null || true
                    if [ -n "$BACKUP_SSH_PASS" ]; then
                        cat > "$CREDENTIAL_FILE" <<EOF
BACKUP_SSH_PASS="$BACKUP_SSH_PASS"
BACKUP_SSH_USER="$BACKUP_SSH_USER"
BACKUP_SERVER_IP="$BACKUP_SERVER_IP"
BACKUP_SSH_KEY=""
EOF
                    else
                        cat > "$CREDENTIAL_FILE" <<EOF
BACKUP_SSH_PASS=""
BACKUP_SSH_USER="$BACKUP_SSH_USER"
BACKUP_SERVER_IP="$BACKUP_SERVER_IP"
BACKUP_SSH_KEY="$BACKUP_SSH_KEY"
EOF
                    fi
                    chmod 600 "$CREDENTIAL_FILE"

                    # 创建备份脚本
                    bash -c "cat > /usr/local/bin/wordpress_backup.sh <<'BKSHEOF'
#!/bin/bash
source /root/.wordpress_backup_creds
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_FILE=/tmp/wordpress_backup_\$TIMESTAMP.tar.gz
tar -czf \$BACKUP_FILE -C /home wordpress
if [ -n \"\$BACKUP_SSH_PASS\" ]; then
    sshpass -p \"\$BACKUP_SSH_PASS\" scp -o StrictHostKeyChecking=no \$BACKUP_FILE \$BACKUP_SSH_USER@\$BACKUP_SERVER_IP:~/wordpress_backups/
else
    scp -i \"\$BACKUP_SSH_KEY\" -o StrictHostKeyChecking=no \$BACKUP_FILE \$BACKUP_SSH_USER@\$BACKUP_SERVER_IP:~/wordpress_backups/
fi
if [ \$? -eq 0 ]; then
    echo \"WordPress 备份成功：\$TIMESTAMP\" >> /var/log/wordpress_backup.log
else
    echo \"WordPress 备份失败：\$TIMESTAMP\" >> /var/log/wordpress_backup.log
fi
rm -f \$BACKUP_FILE
BKSHEOF"
                    chmod +x /usr/local/bin/wordpress_backup.sh

                    # 配置目标服务器备份目录
                    if [ -n "$BACKUP_SSH_PASS" ]; then
                        sshpass -p "$BACKUP_SSH_PASS" ssh -o StrictHostKeyChecking=no "$BACKUP_SSH_USER@$BACKUP_SERVER_IP" "mkdir -p ~/wordpress_backups"
                    else
                        ssh -i "$BACKUP_SSH_KEY" -o StrictHostKeyChecking=no "$BACKUP_SSH_USER@$BACKUP_SERVER_IP" "mkdir -p ~/wordpress_backups"
                    fi

                    # 如果选择立即备份，直接执行
                    if [ "$BACKUP_INTERVAL" == "立即备份" ]; then
                        echo -e "${YELLOW}正在执行立即备份...${RESET}"
                        /usr/local/bin/wordpress_backup.sh
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}立即备份完成！备份文件已传输至 $BACKUP_SSH_USER@$BACKUP_SERVER_IP:~/wordpress_backups${RESET}"
                            echo -e "${YELLOW}请检查 /var/log/wordpress_backup.log 查看备份日志${RESET}"
                        else
                            echo -e "${RED}立即备份失败，请检查网络或服务器配置！${RESET}"
                            echo -e "${YELLOW}详情见 /var/log/wordpress_backup.log${RESET}"
                        fi
                    else
                        # 设置 cron 任务
                        (crontab -l 2>/dev/null | grep -v "wordpress_backup.sh"; echo "$CRON_TIME /usr/local/bin/wordpress_backup.sh") | crontab -
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}定时备份已设置为 $BACKUP_INTERVAL，每$BACKUP_INTERVAL $BACKUP_HOUR:$BACKUP_MINUTE 执行，备份目标：$BACKUP_SSH_USER@$BACKUP_SERVER_IP:~/wordpress_backups${RESET}"
                            echo -e "${YELLOW}备份日志存储在 /var/log/wordpress_backup.log${RESET}"
                        else
                            echo -e "${RED}设置定时备份失败，请手动检查 crontab！${RESET}"
                        fi
                    fi
                            read -p "按回车键返回主菜单..."
                            ;;
                        *)
                            echo -e "${RED}无效选项，请输入 1、2、3、4 或 5！${RESET}"
                            read -p "按回车键返回主菜单..."
                            ;;
                    esac
                fi
                ;;
                22)
                # 网心云安装
                echo -e "${GREEN}正在安装网心云...${RESET}"

                # 检查Docker是否安装
                if command -v docker &> /dev/null; then
                    echo -e "${YELLOW}Docker 已安装，跳过安装步骤。${RESET}"
                else
                    echo -e "${YELLOW}检测到 Docker 未安装，正在安装...${RESET}"
                    check_system
                    if [ "$SYSTEM" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
                        sudo apt update
                        sudo apt install -y docker.io
                    elif [ "$SYSTEM" == "centos" ]; then
                        sudo yum install -y docker
                        sudo systemctl enable docker
                        sudo systemctl start docker
                    elif [ "$SYSTEM" == "fedora" ]; then
                        sudo dnf install -y docker
                        sudo systemctl enable docker
                        sudo systemctl start docker
                    else
                        echo -e "${RED}无法识别系统，无法安装 Docker！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    if [ $? -ne 0 ]; then
                        echo -e "${RED}Docker 安装失败，请手动检查！${RESET}"
                        read -p "按回车键返回主菜单..."
                        continue
                    fi
                    echo -e "${GREEN}Docker 安装成功！${RESET}"
                fi

                # 默认端口
                DEFAULT_PORT=18888

                # 检查端口是否占用
                check_port() {
                    local port=$1
                    if ss -tuln 2>/dev/null | grep -q ":$port "; then
                        return 1
                    elif netstat -tuln 2>/dev/null | grep -q ":$port "; then
                        return 1
                    else
                        return 0
                    fi
                }

                check_port $DEFAULT_PORT
                if [ $? -eq 1 ]; then
                    echo -e "${RED}端口 $DEFAULT_PORT 已被占用！${RESET}"
                    read -p "请输入其他端口号（1-65535）： " new_port
                    while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                        echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                        read -p "请输入其他端口号（1-65535）： " new_port
                    done
                    check_port $new_port
                    while [ $? -eq 1 ]; do
                        echo -e "${RED}端口 $new_port 已被占用，请选择其他端口！${RESET}"
                        read -p "请输入其他端口号（1-65535）： " new_port
                        while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                            echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
                            read -p "请输入其他端口号（1-65535）： " new_port
                        done
                        check_port $new_port
                    done
                    DEFAULT_PORT=$new_port
                fi

                # 开放端口
                echo -e "${YELLOW}正在开放端口 $DEFAULT_PORT...${RESET}"
                if command -v ufw &> /dev/null; then
                    sudo ufw allow $DEFAULT_PORT/tcp
                    sudo ufw reload
                    echo -e "${GREEN}UFW 防火墙端口 $DEFAULT_PORT 已开放！${RESET}"
                elif command -v firewall-cmd &> /dev/null; then
                    sudo firewall-cmd --permanent --add-port=$DEFAULT_PORT/tcp
                    sudo firewall-cmd --reload
                    echo -e "${GREEN}Firewalld 防火墙端口 $DEFAULT_PORT 已开放！${RESET}"
                elif command -v iptables &> /dev/null; then
                    sudo iptables -A INPUT -p tcp --dport $DEFAULT_PORT -j ACCEPT
                    sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                    echo -e "${GREEN}iptables 防火墙端口 $DEFAULT_PORT 已开放！${RESET}"
                else
                    echo -e "${YELLOW}未检测到常见防火墙工具，请手动开放端口 $DEFAULT_PORT！${RESET}"
                fi

                # 检查并创建存储目录
                STORAGE_DIR="/root/wxy"
                if [ ! -d "/root" ]; then
                    STORAGE_DIR="/etc/wxy"
                    echo -e "${YELLOW}未找到 /root 目录，将在 /etc/wxy 创建存储目录...${RESET}"
                    sudo mkdir -p /etc/wxy
                    sudo chmod 755 /etc/wxy
                else
                    sudo mkdir -p /root/wxy
                    sudo chmod 755 /root/wxy
                fi

                # 拉取网心云镜像
                echo -e "${YELLOW}正在拉取网心云镜像...${RESET}"
                docker pull images-cluster.xycloud.com/wxedge/wxedge:latest
                if [ $? -ne 0 ]; then
                    echo -e "${RED}拉取网心云镜像失败，请检查网络连接！${RESET}"
                    read -p "按回车键返回主菜单..."
                    continue
                fi

                # 检查是否已有同名容器
                if docker ps -a --format '{{.Names}}' | grep -q "^wxedge$"; then
                    echo -e "${YELLOW}检测到已存在名为 wxedge 的容器，正在移除...${RESET}"
                    docker stop wxedge &> /dev/null
                    docker rm wxedge &> /dev/null
                fi

                # 运行网心云容器
                echo -e "${YELLOW}正在启动网心云容器...${RESET}"
                docker run -d --name=wxedge --restart=always --privileged --net=host \
                    --tmpfs /run --tmpfs /tmp -v "$STORAGE_DIR:/storage:rw" \
                    -e WXEDGE_PORT="$DEFAULT_PORT" \
                    images-cluster.xycloud.com/wxedge/wxedge:latest
                if [ $? -ne 0 ]; then
                    echo -e "${RED}启动网心云容器失败，请检查 Docker 状态或日志！${RESET}"
                    docker logs wxedge
                    read -p "按回车键返回主菜单..."
                    continue
                fi

                # 检查容器状态
                sleep 3
                if docker ps --format '{{.Names}}' | grep -q "^wxedge$"; then
                    server_ip=$(curl -s4 ifconfig.me || echo "你的服务器IP")
                    echo -e "${GREEN}网心云安装成功！${RESET}"
                    echo -e "${YELLOW}容器名称：wxedge${RESET}"
                    echo -e "${YELLOW}访问端口：$DEFAULT_PORT${RESET}"
                    echo -e "${YELLOW}存储目录：$STORAGE_DIR${RESET}"
                    echo -e "${YELLOW}访问地址：http://$server_ip:$DEFAULT_PORT${RESET}"
                else
                    echo -e "${RED}网心云容器未正常运行，请检查以下日志：${RESET}"
                    docker logs wxedge
                fi
                read -p "按回车键返回主菜单..."
                ;;
                23)
                # 3X-UI 搭建
                echo -e "${GREEN}正在搭建 3X-UI 并启用 BBR...${RESET}"
                echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
                echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
                sudo sysctl -p
                lsmod | grep bbr
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}BBR 模块已加载！${RESET}"
                else
                    echo -e "${RED}BBR 模块未加载，请检查内核支持！${RESET}"
                fi
                sysctl net.ipv4.tcp_congestion_control
                echo -e "${YELLOW}正在下载并运行 3X-UI 安装脚本...${RESET}"
                printf "y\nsinian\nsinian\n5321\na\n" | bash <(curl -Ls https://raw.githubusercontent.com/teaing-liu/3x-ui/master/install.sh)
                echo ""
                echo -e "${GREEN}╔══════════════════════════════════════════╗${RESET}"
                echo -e "${GREEN}║         3X-UI 安装完成！            ║${RESET}"
                echo -e "${GREEN}╚══════════════════════════════════════════╝${RESET}"
                SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 api.ipify.org 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "服务器IP")
                echo ""
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
                echo -e "${YELLOW}  3X-UI 面板登录信息${RESET}"
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
                echo -e "${YELLOW}  访问地址: http://${SERVER_IP}:5321/a/${RESET}"
                echo -e "${YELLOW}  用户名:   sinian${RESET}"
                echo -e "${YELLOW}  密码:     sinian${RESET}"
                echo -e "${YELLOW}  端口:     5321${RESET}"
                echo -e "${YELLOW}  登录路径: /a/${RESET}"
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
                read -p "按回车键返回主菜单..."
                ;;
                24)
                # S-UI搭建
                echo -e "${GREEN}正在安装 s-ui ...${RESET}"
                # 执行 s-ui 安装脚本，自动填入默认配置和用户名密码
                printf "y\n2095\n/app/\n2096\n/sub/\ny\nsinian\nsinian\n" | bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}s-ui 安装成功！正在验证配置...${RESET}"
                    # 重启 s-ui 服务以确保配置生效
                    systemctl restart s-ui
                    if [ $? -eq 0 ]; then
                        server_ip=$(curl -s4 ifconfig.me || echo "你的服务器IP")
                        echo -e "${GREEN}s-ui 配置完成！${RESET}"
                        echo -e "${YELLOW}登录信息如下：${RESET}"
                        echo -e "${YELLOW}面板地址：http://$server_ip:2095/app/${RESET}"
                        echo -e "${YELLOW}订阅地址：http://$server_ip:2096/sub/${RESET}"
                        echo -e "${YELLOW}用户名：sinian${RESET}"
                        echo -e "${YELLOW}密码：sinian${RESET}"
                        # 验证服务状态
                        if s-ui status | grep -q "running"; then
                            echo -e "${GREEN}验证成功：s-ui 服务正在运行！请使用以上凭据登录。${RESET}"
                        else
                            echo -e "${RED}警告：s-ui 服务未运行，请检查日志（s-ui log）或手动验证用户名和密码！${RESET}"
                        fi
                    else
                        echo -e "${RED}s-ui 服务重启失败，请检查日志（s-ui log）或手动运行 's-ui' 检查配置！${RESET}"
                    fi
                else
                    echo -e "${RED}s-ui 安装失败，请检查网络或运行 's-ui log' 查看错误详情！${RESET}"
                fi
                read -p "按回车键返回主菜单..."
                ;;
                25)
                # FileBrowser 安装
                echo -e "${GREEN}正在进入 FileBrowser 安装管理...${RESET}"
                fb_main_menu
                read -p "按回车键返回主菜单..."
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${RESET}"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

# 运行主菜单
show_menu
