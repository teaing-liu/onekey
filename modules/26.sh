#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

check_port() {
    local port=$1
    ss -tulnp 2>/dev/null | grep -q ":${port} " && return 1
    return 0
}

get_service_by_port() {
    local port=$1
    grep -E "^ *$port/" /etc/services 2>/dev/null | head -1 | awk '{print $1}' || echo "未知"
}

get_container_by_port() {
    local port=$1
    if ! command -v docker &>/dev/null; then
        echo "-"
        return
    fi
    local containers=$(docker ps --format "{{.Names}}" 2>/dev/null)
    for name in $containers; do
        local p=$(docker port "$name" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+:(\d+) -> \d+' | cut -d: -f2 | head -1)
        if [ "$p" = "$port" ]; then
            echo "$name"
            return
        fi
    done
    echo "-"
}

show_all_ports() {
    echo -e "${GREEN}=== 端口占用情况 ===${RESET}"
    
    local count=$(ss -tuln 2>/dev/null | grep -c LISTEN)
    echo -e "${YELLOW}共占用 $count 个端口${RESET}"
    echo ""
    
    printf "%-8s %-8s %-20s %-25s\n" "端口" "协议" "服务" "容器/Docker"
    printf "%-8s %-8s %-20s %-25s\n" "--------" "--------" "--------------------" "-------------------------"
    
    ss -tuln 2>/dev/null | grep LISTEN | awk '{print $5,$1}' | sort -u -k1,1 -t: | while read addr proto; do
        port="${addr##*:}"
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            local service=$(get_service_by_port $port)
            local container=$(get_container_by_port $port)
            printf "%-8s %-8s %-20s %-25s\n" "$port" "$proto" "$service" "$container"
        fi
    done | sort -t' ' -k1 -n
}

show_all_services() {
    echo -e "${GREEN}=== 服务状态列表 ===${RESET}"
    
    local docker_count=0
    local sys_count=0
    
    if command -v docker &>/dev/null; then
        docker_count=$(docker ps -a 2>/dev/null | wc -l)
        docker_count=$((docker_count - 1))
    fi
    
    if command -v systemctl &>/dev/null; then
        sys_count=$(systemctl list-unit-files --type=service 2>/dev/null | grep -c "\.service" || echo 0)
    fi
    
    echo -e "${YELLOW}Docker容器: $docker_count 个 | 系统服务: $sys_count 个${RESET}"
    echo ""
    
    printf "%-30s %-10s %-12s %-10s\n" "服务名称" "类型" "端口" "状态"
    printf "%-30s %-10s %-12s %-10s\n" "------------------------------" "----------" "------------" "----------"
    
    if command -v docker &>/dev/null; then
        local containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null)
        for name in $containers; do
            local status=$(docker inspect --format '{{.State.Status}}' $name 2>/dev/null)
            local port=$(docker port $name 2>/dev/null | grep -oP '\d+$' | head -1)
            [ "$status" == "running" ] && s="运行中" || s="已停止"
            [ -z "$port" ] && port="-"
            printf "%-30s %-10s %-12s %-10s\n" "$name" "Docker" "$port" "$s"
        done
    fi
    
    if command -v systemctl &>/dev/null; then
        for svc in sshd nginx mysql redis docker systemd-journald cron rsyslog; do
            if systemctl list-unit-files --type=service 2>/dev/null | grep -q "$svc.service"; then
                local s=$(systemctl is-active $svc 2>/dev/null)
                [ "$s" == "active" ] && s="运行中" || s="已停止"
                printf "%-30s %-10s %-12s %-10s\n" "$svc" "系统" "-" "$s"
            fi
        done
    fi
}

smart_port() {
    local desired=${1:-8000}
    local port=$desired
    
    while [ $port -le 65535 ]; do
        if check_port $port; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    
    echo "无可用端口"
    return 1
}

show_available_ports() {
    echo -e "${GREEN}=== 可用端口推荐 ===${RESET}"
    echo ""
    
    printf "%-10s %-25s %-10s\n" "端口" "用途" "状态"
    printf "%-10s %-25s %-10s\n" "----------" "-------------------------" "----------"
    
    local ranges=(
        "80:Web服务"
        "443:HTTPS"
        "8080:Web应用"
        "8443:备用HTTPS"
        "3000:Node.js开发"
        "5000:Python/Flask"
        "8000:Django/通用"
        "8888:jupyter/测试"
        "9090:Prometheus"
        "27017:MongoDB"
    )
    
    for entry in "${ranges[@]}"; do
        port="${entry%%:*}"
        desc="${entry##*:}"
        if check_port $port 2>/dev/null; then
            printf "%-10s %-25s %-10s\n" "$port" "$desc" "$(echo -e "${GREEN}可用${RESET}")"
        else
            printf "%-10s %-25s %-10s\n" "$port" "$desc" "$(echo -e "${RED}已占用${RESET}")"
        fi
    done
    
    echo ""
    echo "常用端口范围:"
    echo "  8000-8999: Web服务"
    echo "  3000-3999: 开发服务器"
    echo "  5000-5999: API服务"
}

smart_domain() {
    local d=$1
    [ -z "$d" ] && echo "请输入域名" && return 1
    dip=$(dig +short $d A 2>/dev/null | head -1)
    [ -z "$dip" ] && dip=$(nslookup $d 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)
    [ -z "$dip" ] && echo "DNS解析失败" && return 1
    sip=$(curl -s4 ifconfig.me 2>/dev/null)
    [ -z "$sip" ] && sip="无法获取"
    echo "域名: $d"
    echo "解析IP: $dip"
    echo "服务器IP: $sip"
    [ "$dip" == "$sip" ] && echo "状态: 验证通过" || echo "状态: IP不匹配"
}

smart_proxy() {
    local domain=$1 service=$2 port=$3
    
    if ! command -v nginx &>/dev/null; then
        echo -e "${RED}nginx未安装${RESET}"
        return 1
    fi
    
    [ -z "$domain" ] || [ -z "$service" ] || [ -z "$port" ] && echo "参数不完整" && return 1
    [[ "$port" =~ ^[0-9]+$ ]] || echo -e "${RED}无效端口号: $port${RESET}" && return 1
    
    echo -e "${GREEN}配置反向代理: $domain -> localhost:$port ($service)${RESET}"
    
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    
    local conf_file="/etc/nginx/sites-available/${domain}"
    
    cat > "$conf_file" << EOF
server {
    listen 80;
    server_name $domain;
    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

    ln -sf "$conf_file" /etc/nginx/sites-enabled/"$domain" 2>/dev/null
    
    systemctl enable nginx 2>/dev/null
    systemctl start nginx 2>/dev/null
    
    sleep 1
    
    if ss -tulnp 2>/dev/null | grep -q ":80 "; then
        echo -e "${GREEN}✓ 反向代理配置成功${RESET}"
        echo -e "${GREEN}✓ 域名: http://$domain${RESET}"
        echo -e "${GREEN}✓ 指向: localhost:$port ($service)${RESET}"
        echo -e "${YELLOW}提示: 访问 http://$domain${RESET}"
        return 0
    fi
    
    echo -e "${RED}× nginx配置失败${RESET}"
    rm -f "$conf_file" /etc/nginx/sites-enabled/"$domain"
    return 1
}

smart_port_menu() {
    while true; do
        clear
        echo -e "${GREEN}======================================${RESET}"
        echo -e "${GREEN}     智能端口与域名管理${RESET}"
        echo -e "${GREEN}======================================${RESET}"
        echo ""
        echo -e "  ${YELLOW}1)${RESET} 查看占用端口"
        echo -e "  ${YELLOW}2)${RESET} 智能分配端口"
        echo -e "  ${YELLOW}3)${RESET} 验证域名解析"
        echo -e "  ${YELLOW}4)${RESET} 配置反向代理"
        echo -e "  ${YELLOW}5)${RESET} 服务状态列表"
        echo -e "  ${YELLOW}6)${RESET} 服务启停管理"
        echo -e "  ${YELLOW}7)${RESET} 已配置域名列表"
        echo ""
        echo -e "  ${RED}0)${RESET} 返回主菜单"
        echo ""
        read -p "请输入选项: " choice || choice=""
        
        case "$choice" in
            "") ;;
            1)
                echo ""
                show_all_ports
                ;;
            2)
                echo ""
                show_available_ports
                echo ""
                read -p "输入期望端口(回车自动从8000开始搜索): " desired
                result=$(smart_port "$desired" 2>/dev/null)
                if [ -n "$result" ] && [ "$result" != "无可用端口" ]; then
                    echo ""
                    echo -e "${GREEN}✓ 推荐使用端口: $result${RESET}"
                    echo ""
                    echo "此端口已验证可用，可用于配置服务"
                else
                    echo -e "${RED}× 未能找到可用端口${RESET}"
                fi
                ;;
            3)
                echo ""
                read -p "输入域名: " domain
                if [ -n "$domain" ]; then
                    smart_domain "$domain" 2>/dev/null
                else
                    echo "域名不能为空"
                fi
                ;;
            4)
                echo ""
                configure_proxy_menu
                ;;
            5)
                echo ""
                show_all_services
                ;;
            6)
                service_control_menu
                ;;
            7)
                echo ""
                list_configured_domains
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项"
                ;;
        esac
        
        echo ""
        read -p "按回车键继续..." dummy
    done
}

configure_proxy_menu() {
    echo -e "${GREEN}=== 配置反向代理 ===${RESET}"
    echo ""
    
    if ! command -v docker &>/dev/null && ! command -v nginx &>/dev/null; then
        echo -e "${RED}Docker和nginx都未安装${RESET}"
        return
    fi
    
    echo -e "${YELLOW}请选择要反代的服务:${RESET}"
    echo ""
    
    declare -a service_list
    declare -a port_list
    
    local idx=1
    local seen_ports=""
    
    while read line; do
        local addr=$(echo "$line" | awk '{print $5}')
        local port="${addr##*:}"
        
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            continue
        fi
        
        if [[ "$seen_ports" =~ ",$port," ]]; then
            continue
        fi
        seen_ports="${seen_ports}${port},"
        
        if [ "$port" = "22" ] || [ "$port" = "53" ] || [ "$port" = "5321" ]; then
            continue
        fi
        
        local name=""
        
        case "$port" in
            62789) name="x-ui-API" ;;
            6688) name="speedtest" ;;
            6379) name="redis" ;;
            8080) name="dujiaonext-api" ;;
            8081) name="dujiaonext-user" ;;
            8082) name="dujiaonext-admin" ;;
            18888) name="wxedge" ;;
            1935) name="SRS-RTMP" ;;
            1985) name="SRS-HTTP" ;;
            2022) name="SRS-管理" ;;
            9000) name="服务-9000" ;;
            9999) name="wxedge-9999" ;;
            5201) name="speedtest-server" ;;
            11111) name="x-ui-metrics" ;;
            *) name="端口$port" ;;
        esac
        
        if [ "$port" -gt 1000 ]; then
            echo -e "  ${GREEN}[$idx]${RESET} $name (端口: $port)"
            service_list+=("$name")
            port_list+=("$port")
            idx=$((idx + 1))
        fi
    done < <(ss -tuln 2>/dev/null | grep LISTEN)
    
    if [ ${#service_list[@]} -eq 0 ]; then
        echo -e "${RED}没有检测到可用的服务${RESET}"
        return
    fi
    
    echo ""
    read -p "选择服务编号: " sel
    
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#service_list[@]} ]; then
        echo -e "${RED}无效选择${RESET}"
        return
    fi
    
    local selected_idx=$((sel - 1))
    local service="${service_list[$selected_idx]}"
    local port="${port_list[$selected_idx]}"
    
    echo ""
    read -p "输入域名: " domain
    
    if [ -z "$domain" ]; then
        echo -e "${RED}域名不能为空${RESET}"
        return
    fi
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效端口号: $port${RESET}"
        return
    fi
    
    echo ""
    echo "配置: $domain -> $service (端口: $port)"
    echo ""
    smart_proxy "$domain" "$service" "$port"
}

list_configured_domains() {
    echo -e "${GREEN}=== 已配置的反向代理域名 ===${RESET}"
    echo ""
    
    get_service_display_name() {
        local port=$1
        case "$port" in
            6688) echo "speedtest" ;;
            6379) echo "redis" ;;
            8080) echo "dujiaonext-api" ;;
            8081) echo "dujiaonext-user" ;;
            8082) echo "dujiaonext-admin" ;;
            18888) echo "wxedge" ;;
            1935) echo "SRS-RTMP" ;;
            1985) echo "SRS-HTTP" ;;
            2022) echo "SRS-管理" ;;
            9000) echo "服务-9000" ;;
            9999) echo "wxedge-9999" ;;
            5201) echo "speedtest-server" ;;
            62789) echo "x-ui-API" ;;
            11111) echo "x-ui-metrics" ;;
            10443) echo "nginx-HTTPS" ;;
            *) echo "端口-$port" ;;
        esac
    }
    
    local count=0
    printf "%-30s %-10s %-25s %-10s\n" "域名" "端口" "目标服务" "证书状态"
    printf "%-30s %-10s %-25s %-10s\n" "------------------------------" "----------" "-------------------------" "----------"
    
    for conf_file in /etc/nginx/sites-available/*; do
        if [ -f "$conf_file" ]; then
            local domain=$(basename "$conf_file")
            if [[ "$domain" == *"."* ]]; then
                local listen_port=$(grep -oP 'listen \K\d+' "$conf_file" | head -1)
                local upstream_port=$(grep -oP 'proxy_pass http://127\.0\.0\.1:\K\d+' "$conf_file" | head -1)
                local service_name=$(get_service_display_name "$upstream_port")
                local ssl_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
                local cert_status="无证书"
                if [ -f "$ssl_cert" ]; then
                    cert_status="有效"
                fi
                printf "%-30s %-10s %-25s %-10s\n" "$domain" "$listen_port" "$service_name" "$cert_status"
                count=$((count + 1))
            fi
        fi
    done
    
    echo ""
    if [ $count -gt 0 ]; then
        echo -e "${YELLOW}共配置了 $count 个反向代理域名${RESET}"
        echo ""
        echo -e "${YELLOW}提示: ${RESET}访问方式:"
        echo "  - HTTP: http://域名 (会自动跳转到HTTPS)"
        echo "  - HTTPS: https://域名:10443"
    else
        echo -e "${YELLOW}暂无配置的反向代理域名${RESET}"
    fi
}

service_control_menu() {
    while true; do
        clear
        echo -e "${GREEN}======================================${RESET}"
        echo -e "${GREEN}     服务启停管理${RESET}"
        echo -e "${GREEN}======================================${RESET}"
        echo ""
        
        echo -e "${YELLOW}【Docker 容器】${RESET}"
        
        declare -a docker_names
        declare -a docker_types
        local idx=1
        
        if command -v docker &>/dev/null; then
            local containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null)
            if [ -n "$containers" ]; then
                for name in $containers; do
                    local status=$(docker inspect --format '{{.State.Status}}' $name 2>/dev/null)
                    local port=$(docker port $name 2>/dev/null | grep -oP '\d+$' | head -1)
                    [ -z "$port" ] && port="-"
                    
                    if [ "$status" == "running" ]; then
                        echo -e "  ${GREEN}[$idx]${RESET} $name (运行中, 端口:$port) - Docker"
                    else
                        echo -e "  ${RED}[$idx]${RESET} $name (已停止, 端口:$port) - Docker"
                    fi
                    docker_names+=("$name")
                    docker_types+=("Docker")
                    idx=$((idx + 1))
                done
            fi
        fi
        
        local docker_count=$((idx - 1))
        
        echo ""
        echo -e "${YELLOW}【系统服务】${RESET}"
        
        if ! command -v systemctl &>/dev/null; then
            echo -e "${YELLOW}systemctl 不可用，跳过系统服务${RESET}"
        else
            declare -a sys_names
            declare -a sys_types
            local sidx=$((docker_count + 1))
            
            for svc in sshd nginx mysql redis docker systemd-journald cron rsyslog; do
                if systemctl list-unit-files --type=service 2>/dev/null | grep -q "$svc.service"; then
                    local status=$(systemctl is-active $svc 2>/dev/null)
                    if [ "$status" == "active" ]; then
                        echo -e "  ${GREEN}[$sidx]${RESET} $svc (运行中) - 系统服务"
                    else
                        echo -e "  ${RED}[$sidx]${RESET} $svc (已停止) - 系统服务"
                    fi
                    sys_names+=("$svc")
                    sys_types+=("系统")
                    sidx=$((sidx + 1))
                fi
            done
        fi
        
        echo ""
        echo -e "${YELLOW}0)${RESET} 返回"
        echo ""
        read -p "选择要操作的服务编号: " sel
        
        [ "$sel" = "0" ] && return
        
        if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}请输入数字${RESET}"
            continue
        fi
        
        svc_name=""
        svc_type=""
        
        if [ "$sel" -ge 1 ] && [ "$sel" -le "$docker_count" ]; then
            svc_idx=$((sel - 1))
            svc_name="${docker_names[$svc_idx]}"
            svc_type="${docker_types[$svc_idx]}"
        elif [ "$sel" -gt "$docker_count" ] && [ "$sel" -le $((docker_count + ${#sys_names[@]})) ]; then
            sys_idx=$((sel - docker_count - 1))
            svc_name="${sys_names[$sys_idx]}"
            svc_type="${sys_types[$sys_idx]}"
        fi
        
        if [ -z "$svc_name" ]; then
            echo -e "${RED}无效选择${RESET}"
            continue
        fi
        
        echo ""
        echo "已选择: $svc_name (类型: $svc_type)"
        echo -e "${YELLOW}1)${RESET} 启动服务"
        echo -e "${YELLOW}2)${RESET} 停止服务"
        echo -e "${YELLOW}0)${RESET} 返回"
        read -p "选择操作: " action
        
        case "$action" in
            1)
                echo "正在启动 $svc_name ..."
                if [ "$svc_type" = "Docker" ]; then
                    docker start "$svc_name" 2>&1 && echo -e "${GREEN}✓ 容器已启动${RESET}" || echo -e "${RED}× 启动失败${RESET}"
                else
                    systemctl start "$svc_name" 2>&1 && echo -e "${GREEN}✓ 服务已启动${RESET}" || echo -e "${RED}× 启动失败${RESET}"
                fi
                ;;
            2)
                echo "正在停止 $svc_name ..."
                if [ "$svc_type" = "Docker" ]; then
                    docker stop "$svc_name" 2>&1 && echo -e "${GREEN}✓ 容器已停止${RESET}" || echo -e "${RED}× 停止失败${RESET}"
                else
                    systemctl stop "$svc_name" 2>&1 && echo -e "${GREEN}✓ 服务已停止${RESET}" || echo -e "${RED}× 停止失败${RESET}"
                fi
                ;;
            0)
                continue
                ;;
            *)
                echo "无效操作"
                ;;
        esac
    done
}

smart_port_menu
