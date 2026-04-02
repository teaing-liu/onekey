#!/bin/bash
is_interactive() {
    if [ -t 0 ] && [ -t 1 ]; then
        return 0
    fi
    return 1
}

# ============================================
# FileBrowser 一键部署脚本 - 最终安全版
# 支持 Ubuntu/Debian/CentOS/RHEL
# 默认共享目录为 /opt/filebrowser/shared（安全隔离）
# 完全卸载仅删除 FileBrowser 相关数据，不影响系统文件
# 新增功能：自动证书申请助手（释放 80 端口后执行用户命令，完成后自动恢复）
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

has_systemctl() { command -v systemctl &> /dev/null; }

# 全局变量
FB_CONTAINER_NAME="filebrowser"
FB_DATA_DIR="/opt/filebrowser"
FB_SHARE_DIR="$FB_DATA_DIR/shared"
FB_DB_FILE="$FB_DATA_DIR/database.db"
FB_CONFIG_FILE="$FB_DATA_DIR/config.json"
FB_PORT=8080
FB_IMAGE="filebrowser/filebrowser:latest"

# 日志函数
info() {
    echo -e "${GREEN}[信息]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[警告]${NC} $1" >&2
}

error() {
    echo -e "${RED}[错误]${NC} $1" >&2
    return 1
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        error "无法检测操作系统"
    fi

    case $OS in
        ubuntu|debian)
            PKG_MANAGER="apt"
            INSTALL_CMD="apt install -y"
            UPDATE_CMD="apt update"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            fi
            INSTALL_CMD="$PKG_MANAGER install -y"
            UPDATE_CMD="$PKG_MANAGER update -y"
            if ! rpm -q epel-release >/dev/null 2>&1; then
                $INSTALL_CMD epel-release
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            INSTALL_CMD="dnf install -y"
            UPDATE_CMD="dnf update -y"
            ;;
        *)
            error "不支持的操作系统: $OS"
            ;;
    esac
}

# 修复 dpkg 中断
fix_dpkg() {
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        info "检查 dpkg 状态..."
        if dpkg --audit >/dev/null 2>&1; then
            info "发现 dpkg 中断，正在修复..."
            dpkg --configure -a
            if ! dpkg --audit >/dev/null 2>&1; then
                apt --fix-broken install -y
            fi
        fi
    fi
}

# 检查网络连通性
check_network() {
    info "检查网络连通性..."
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        info "网络连接正常"
    else
        warn "网络连接可能有问题，但继续执行..."
    fi
}

# 安装 Docker
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "Docker 已安装"
        return
    fi
    info "正在安装 Docker..."
    case $PKG_MANAGER in
        apt)
            $UPDATE_CMD
            $INSTALL_CMD apt-transport-https ca-certificates curl software-properties-common
            curl -fsSL https://download.docker.com/linux/$OS/gpg | apt-key add -
            add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" -y
            $UPDATE_CMD
            $INSTALL_CMD docker-ce
            ;;
        yum|dnf)
            $INSTALL_CMD yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $INSTALL_CMD docker-ce docker-ce-cli containerd.io
            ;;
        *)
            error "无法自动安装 Docker，请手动安装"
            ;;
    esac
    if has_systemctl; then
        systemctl enable --now docker
    fi
    info "Docker 安装完成"
}

# 安装依赖
install_deps() {
    info "检查系统依赖..."
    local missing_deps=()
    for cmd in curl nginx; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing_deps+=($cmd)
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        info "安装缺失的依赖: ${missing_deps[@]}"
        $UPDATE_CMD
        $INSTALL_CMD ${missing_deps[@]}
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        info "安装 Certbot..."
        case $PKG_MANAGER in
            apt)
                $INSTALL_CMD certbot python3-certbot-nginx
                ;;
            yum|dnf)
                $INSTALL_CMD certbot python3-certbot-nginx
                if [ "$PKG_MANAGER" = "yum" ] && ! command -v certbot >/dev/null 2>&1; then
                    $INSTALL_CMD epel-release
                    $INSTALL_CMD certbot python3-certbot-nginx
                fi
                ;;
        esac
        if has_systemctl; then
            systemctl enable --now certbot.timer 2>/dev/null || true
        fi
    fi

    if ! command -v netstat >/dev/null 2>&1; then
        $INSTALL_CMD net-tools
    fi

    info "依赖检查完成"
}

# 检查端口是否可用
check_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
        return 1
    elif ss -tuln 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# 自动选择可用端口
auto_select_port() {
    local start_port=$1
    local port=$start_port
    while ! check_port $port; do
        warn "端口 $port 已被占用，自动选择新端口..."
        port=$((port + 1))
        if [ $port -gt 65535 ]; then
            error "无法找到可用端口"
        fi
    done
    echo "$port"
}

# 创建目录
prepare_dirs() {
    mkdir -p "$FB_DATA_DIR"
    mkdir -p "$FB_SHARE_DIR"
    chown -R 1000:1000 "$FB_DATA_DIR"
    chmod 755 "$FB_DATA_DIR"
    chmod 755 "$FB_SHARE_DIR"
}

# 启动 FileBrowser
start_filebrowser() {
    info "启动 FileBrowser 容器..."
    docker run -d \
        --name=$FB_CONTAINER_NAME \
        --restart=unless-stopped \
        -v $FB_DATA_DIR:/data \
        -v $FB_SHARE_DIR:/srv \
        -p $FB_PORT:80 \
        -u 1000:1000 \
        $FB_IMAGE \
        -r /srv \
        -d /data/database.db \
        -c /data/config.json \
        --address=0.0.0.0 \
        --port=80
    sleep 5
    if docker ps | grep -q $FB_CONTAINER_NAME; then
        info "FileBrowser 容器启动成功"
        local password=$(docker logs $FB_CONTAINER_NAME 2>&1 | grep -o 'password: [^ ]\+' | cut -d' ' -f2 | head -1)
        if [ -n "$password" ]; then
            info "初始管理员密码: $password"
            echo "$password" > $FB_DATA_DIR/admin_password.txt
        fi
    else
        error "FileBrowser 容器启动失败，请检查日志: docker logs $FB_CONTAINER_NAME"
    fi
}

# 配置 Nginx HTTP
configure_nginx_http() {
    local domain=$1
    
    # 检查80端口是否可用
    if ! check_port 80; then
        warn "端口 80 被占用，尝试自动释放..."
        # 尝试停止Nginx
        if has_systemctl && systemctl is-active --quiet nginx; then
            info "停止 Nginx 以释放 80 端口..."
            systemctl stop nginx
            sleep 2
        fi
        # 再次检查
        if ! check_port 80; then
            error "无法释放 80 端口，请先停止占用 80 端口的服务"
        fi
    fi
    
    local nginx_conf="/etc/nginx/sites-available/$domain"
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > $nginx_conf <<EOF
server {
    listen 80;
    server_name $domain;
    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:$FB_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
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
    ln -sf $nginx_conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    if has_systemctl; then
        systemctl reload nginx
    fi
    info "Nginx HTTP 配置完成 (反代到端口 $FB_PORT)"
}

# 配置 SSL
configure_ssl() {
    local domain=$1
    info "正在为 $domain 申请 SSL 证书..."
    certbot --nginx -d $domain --non-interactive --agree-tos --email "admin@$domain" --redirect
    local ssl_conf="/etc/nginx/sites-available/$domain"
    if ! grep -q "client_max_body_size" "$ssl_conf"; then
        sed -i '/listen 443 ssl;/a \    client_max_body_size 0;' "$ssl_conf"
        nginx -t
        if has_systemctl; then
            systemctl reload nginx
        fi
    fi
    info "SSL 证书配置完成"
    info "证书自动续签已启用"
}

# 获取公网 IP
get_public_ip() {
    local ipv4=$(curl -4 -s ifconfig.me 2>/dev/null)
    if [ -n "$ipv4" ] && [[ "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
    else
        local ipv6=$(curl -6 -s ifconfig.me 2>/dev/null)
        echo "${ipv6:-127.0.0.1}"
    fi
}

# 检查域名解析
check_dns() {
    local domain=$1
    info "检查域名解析..."
    if ! nslookup $domain >/dev/null 2>&1; then
        warn "域名 $domain 解析失败"
        read -p "是否继续？(y/N): " choice
        [[ "$choice" != "y" && "$choice" != "Y" ]] && exit 1
    else
        info "域名解析正常"
    fi
}

# 创建快捷命令
create_shortcuts() {
    local manager_script="/usr/local/bin/filebrowser-manager"
    local script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ -f "$script_path" ]; then
        cp "$script_path" "$manager_script"
        chmod +x "$manager_script"
        info "管理菜单命令已创建: filebrowser-manager"
    fi

    local quick_script="/usr/local/bin/filebrowser"
    cat > $quick_script <<'EOF'
#!/bin/bash
CONTAINER_NAME="filebrowser"
ACCESS_URL=""
if [ -d "/etc/nginx/sites-enabled" ]; then
    SERVER_NAME=$(grep -h "server_name" /etc/nginx/sites-enabled/* 2>/dev/null | grep -v "#" | awk '{print $2}' | sed 's/;//' | head -1)
    if [ -n "$SERVER_NAME" ]; then
        if grep -q "listen 443" /etc/nginx/sites-enabled/* 2>/dev/null; then
            ACCESS_URL="https://$SERVER_NAME"
        else
            ACCESS_URL="http://$SERVER_NAME"
        fi
    fi
if [ -z "$ACCESS_URL" ]; then
    IP=$(curl -4 -s ifconfig.me 2>/dev/null)
    if [ -z "$IP" ]; then
        IP=$(curl -6 -s ifconfig.me 2>/dev/null)
    fi
    ACCESS_URL="http://${IP:-127.0.0.1}:8080"

if ! command -v docker >/dev/null 2>&1; then
    echo "错误: Docker 未安装，请先运行安装脚本。"
    exit 1

if ! docker ps -a | grep -q $CONTAINER_NAME; then
    echo "FileBrowser 容器不存在，请先运行 filebrowser-manager 进行安装。"
    exit 1

if docker ps | grep -q $CONTAINER_NAME; then
    echo "FileBrowser 已在运行中。"
    echo "访问地址: $ACCESS_URL"
    echo "用户名: admin"
    if [ -f "/opt/filebrowser/admin_password.txt" ]; then
        echo "初始密码: $(cat /opt/filebrowser/admin_password.txt) (如果未修改)"
    else
        echo "密码: 请查看容器日志 docker logs $CONTAINER_NAME | grep password"
    fi
else
    echo "启动 FileBrowser 容器..."
    docker start $CONTAINER_NAME
    echo "已启动，访问地址: $ACCESS_URL"
    echo "用户名: admin"
    if [ -f "/opt/filebrowser/admin_password.txt" ]; then
        echo "初始密码: $(cat /opt/filebrowser/admin_password.txt) (如果未修改)"
    else
        echo "密码: 请查看容器日志 docker logs $CONTAINER_NAME | grep password"
    fi
EOF
    chmod +x $quick_script
    info "快捷命令已创建: filebrowser"
}

# 重置密码
reset_password() {
    if ! docker ps | grep -q $FB_CONTAINER_NAME; then
        error "FileBrowser 容器未运行，请先启动容器"
    fi
    read -p "请输入新密码: " newpass
    if [ -z "$newpass" ]; then
        error "密码不能为空"
    fi
    info "正在重置密码..."
    if docker exec -t $FB_CONTAINER_NAME timeout 30 filebrowser -d /data/database.db users update admin -p "$newpass" 2>&1; then
        info "密码已更新"
    else
        error "重置密码失败，请检查容器日志或稍后重试"
    fi
}

# 释放 80 端口
release_port_80() {
    if ! has_systemctl || ! systemctl is-active --quiet nginx; then
        warn "Nginx 未运行，无需释放"
        return
    fi
    info "停止 Nginx 服务以释放 80 端口..."
    systemctl stop nginx
    info "Nginx 已停止，80 端口已释放"
    info "现在可以使用其他工具申请证书"
    read -p "申请完成后，按回车键恢复 Nginx 服务..." 
    info "启动 Nginx 服务..."
    if has_systemctl; then
        systemctl start nginx
        info "Nginx 已恢复"
    fi
}

# 自动证书助手
auto_cert_helper() {
    info "自动证书申请助手：将释放 80 端口，执行您的证书申请命令，完成后自动恢复 Nginx。"
    echo "请提供完整的证书申请命令（例如：acme.sh --issue --standalone -d example.com）"
    read -p "请输入命令: " cert_cmd
    if [ -z "$cert_cmd" ]; then
        error "命令不能为空"
    fi

    local nginx_was_running=false
    if has_systemctl && systemctl is-active --quiet nginx; then
        nginx_was_running=true
        info "停止 Nginx 以释放 80 端口..."
        systemctl stop nginx
        sleep 2
    else
        warn "Nginx 未运行，可能 80 端口已被其他程序占用？"
        read -p "是否继续执行命令？(y/N): " cont
        [[ "$cont" != "y" && "$cont" != "Y" ]] && return
    fi

    info "开始执行证书申请命令..."
    eval "$cert_cmd"
    local ret=$?

    if [ "$nginx_was_running" = true ]; then
        info "恢复 Nginx 服务..."
        if has_systemctl; then
            systemctl start nginx
            if systemctl is-active --quiet nginx; then
                info "Nginx 已恢复"
            else
                warn "Nginx 启动失败，请手动检查"
            fi
        fi
    fi

    if [ $ret -eq 0 ]; then
        info "证书申请命令执行成功！"
    else
        warn "证书申请命令执行失败，请检查错误输出"
    fi
}

# 安装主流程
install_filebrowser() {
    echo "=========================================="
    echo "FileBrowser 一键部署安装流程"
    echo "=========================================="
    check_network
    detect_os
    fix_dpkg
    install_docker
    install_deps

    local mode=""
    local domain=""
    
    if [ -t 0 ] && [ -t 1 ]; then
        echo "请选择安装类型："
        echo "1) 域名模式 (带SSL证书)"
        echo "2) IP模式 (仅HTTP访问)"
        read -p "请选择 (1 或 2): " mode
        
        case $mode in
            1)
                read -p "请输入你的域名 (例如: file.example.com): " domain
                if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    warn "域名格式可能不正确，继续？(y/N): "
                    read choice
                    [[ "$choice" != "y" && "$choice" != "Y" ]] && exit 1
                fi
                info "使用域名: $domain"
                check_dns $domain
                ;;
            2)
                local public_ip=$(get_public_ip)
                info "使用 IP 模式，将直接通过 http://$public_ip:$FB_PORT 访问"
                ;;
            *)
                error "无效选项"
                ;;
        esac
    else
        info "非交互模式，自动选择 IP模式安装"
        mode=2
        local public_ip=$(get_public_ip)
        info "使用 IP 模式，将直接通过 http://$public_ip:$FB_PORT 访问"
    fi

    FB_PORT=$(auto_select_port $FB_PORT)
    info "使用端口: $FB_PORT"

    info "拉取 FileBrowser 镜像..."
    docker pull $FB_IMAGE

    prepare_dirs
    start_filebrowser

    if [ -n "$domain" ]; then
        configure_nginx_http $domain
        configure_ssl $domain
        info "安装完成！访问地址: https://$domain"
    else
        info "安装完成！访问地址: http://$(get_public_ip):$FB_PORT"
    fi

    if [ -f "$FB_DATA_DIR/admin_password.txt" ]; then
        password=$(cat "$FB_DATA_DIR/admin_password.txt")
        info "默认用户名: admin"
        info "初始密码: $password"
    else
        password=$(docker logs $FB_CONTAINER_NAME 2>&1 | grep -o 'password: [^ ]\+' | cut -d' ' -f2 | head -1)
        if [ -n "$password" ]; then
            info "默认用户名: admin"
            info "初始密码: $password"
            echo "$password" > "$FB_DATA_DIR/admin_password.txt"
        else
            info "默认用户名: admin"
            info "初始密码: 请查看容器日志"
        fi
    fi
    info "首次登录后请立即修改密码"
    info "上传的文件将保存在: $FB_SHARE_DIR"

    create_shortcuts
    info "现在你可以直接输入以下命令："
    info "  filebrowser          - 启动/查看 FileBrowser 状态"
    info "  filebrowser-manager  - 进入管理菜单"
}

# 完全卸载
uninstall_full() {
    read -p "确定要完全卸载 FileBrowser 吗？这将删除所有数据 (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi

    info "注意：上传的文件保存在 $FB_SHARE_DIR"
    read -p "是否同时删除所有上传的文件？(y/N): " del_files
    if [[ "$del_files" == "y" || "$del_files" == "Y" ]]; then
        info "再次确认，删除所有上传的文件？(y/N): "
        read confirm2
        if [[ "$confirm2" == "y" || "$confirm2" == "Y" ]]; then
            info "正在删除上传的文件..."
            rm -rf "$FB_SHARE_DIR"/*
            rm -rf "$FB_SHARE_DIR"/.[!.]* 2>/dev/null || true
            info "上传文件已删除"
        else
            info "保留上传文件"
        fi
    else
        info "保留上传文件"
    fi

    info "停止并删除 FileBrowser 容器..."
    docker stop $FB_CONTAINER_NAME 2>/dev/null || true
    docker rm $FB_CONTAINER_NAME 2>/dev/null || true
    info "删除 FileBrowser 数据目录..."
    rm -rf $FB_DATA_DIR

    for file in /etc/nginx/sites-enabled/*; do
        if [ -f "$file" ] && grep -q "proxy_pass.*$FB_PORT" "$file" 2>/dev/null; then
            rm -f "$file"
            rm -f "/etc/nginx/sites-enabled/$(basename $file)"
        fi
    done
    if has_systemctl; then
        systemctl reload nginx 2>/dev/null || true
    fi
    rm -f /usr/local/bin/filebrowser /usr/local/bin/filebrowser-manager

    info "FileBrowser 已完全卸载"
}

# 卸载保留数据
uninstall_keep_data() {
    read -p "确定要卸载 FileBrowser（保留数据）吗？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi
    info "停止并删除 FileBrowser 容器..."
    docker stop $FB_CONTAINER_NAME 2>/dev/null || true
    docker rm $FB_CONTAINER_NAME 2>/dev/null || true
    info "数据目录保留在 $FB_DATA_DIR"
    info "上传的文件保留在 $FB_SHARE_DIR"
    info "卸载完成（数据已保留）"
    rm -f /usr/local/bin/filebrowser /usr/local/bin/filebrowser-manager
}

# 查看状态
show_status() {
    if docker ps -a | grep -q $FB_CONTAINER_NAME; then
        echo "FileBrowser 容器状态:"
        docker ps -a --filter name=$FB_CONTAINER_NAME --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        if docker ps | grep -q $FB_CONTAINER_NAME; then
            echo "容器正在运行"
        else
            echo "容器已停止"
        fi
    else
        echo "FileBrowser 容器不存在"
    fi
    if grep -r "proxy_pass.*$FB_PORT" /etc/nginx/sites-enabled/ 2>/dev/null | grep -q .; then
        echo "Nginx 反向代理已配置"
    else
        echo "未检测到 Nginx 反向代理配置"
    fi
}

# 查看数据位置
show_data_location() {
    echo "FileBrowser 数据目录: $FB_DATA_DIR"
    echo "数据库文件: $FB_DB_FILE"
    echo "配置文件: $FB_CONFIG_FILE"
    if [ -f "$FB_DATA_DIR/admin_password.txt" ]; then
        echo "初始密码文件: $FB_DATA_DIR/admin_password.txt"
    fi
    echo "上传的文件存储位置: $FB_SHARE_DIR"
}

# 查看日志
show_logs() {
    if docker ps -a | grep -q $FB_CONTAINER_NAME; then
        docker logs $FB_CONTAINER_NAME --tail 50
    else
        echo "FileBrowser 容器不存在"
    fi
}

# 重启服务
restart_service() {
    if docker ps -a | grep -q $FB_CONTAINER_NAME; then
        docker restart $FB_CONTAINER_NAME
        info "FileBrowser 容器已重启"
        if has_systemctl; then
            systemctl reload nginx 2>/dev/null || true
        fi
    else
        error "FileBrowser 容器不存在"
    fi
}

# 查看当前密码
show_current_password() {
    if [ -f "$FB_DATA_DIR/admin_password.txt" ]; then
        echo "初始密码（如果未修改）: $(cat $FB_DATA_DIR/admin_password.txt)"
        echo "如果密码已被修改，请使用菜单选项7重置密码。"
    else
        echo "未找到初始密码文件。"
    fi
    echo "当前密码也可从容器日志查看: docker logs $FB_CONTAINER_NAME | grep password"
}

# 主菜单
main_menu() {
    local choice="${1:-}"
    
    if [ -n "$choice" ]; then
        case $choice in
            1) install_filebrowser ;;
            2) uninstall_full ;;
            3) uninstall_keep_data ;;
            4) show_status ;;
            5) show_data_location ;;
            6) show_logs ;;
            7) reset_password ;;
            8) restart_service ;;
            9) show_current_password ;;
            10) release_port_80 ;;
            11) auto_cert_helper ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新选择" ;;
        esac
        return 0
    fi
    
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
        echo "0) 退出"
        echo "=========================================="
        read -p "请选择操作 [0-11]: " choice
        
        case $choice in
            1) install_filebrowser ;;
            2) uninstall_full ;;
            3) uninstall_keep_data ;;
            4) show_status ;;
            5) show_data_location ;;
            6) show_logs ;;
            7) reset_password ;;
            8) restart_service ;;
            9) show_current_password ;;
            10) release_port_80 ;;
            11) auto_cert_helper ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新选择" ;;
        esac
        
        echo -e "${YELLOW}按回车键返回子菜单...${RESET}"
        if [ -t 0 ]; then read -p "" </dev/null || true; fi
    done
}

main_menu "$@"
