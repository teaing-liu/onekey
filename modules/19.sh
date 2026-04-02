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
# 模块 19: SSH 防暴力破解检测
# ============================================================

ssh_guard() {
    echo -e "${GREEN}正在处理 SSH 暴力破解检测与防护...${RESET}"

    local LOG_FILE="/var/log/auth.log"

    if [ -f /etc/os-release ] && grep -qi "centos\|rhel" /etc/os-release; then
        LOG_FILE="/var/log/secure"
    fi

    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}未找到 SSH 日志文件，跳过检测。${RESET}"
        return 1
    fi

    local DETECT_CONFIG="/etc/ssh_brute_force.conf"

    if [ ! -f "$DETECT_CONFIG" ]; then
        echo -e "${YELLOW}首次运行检测功能，请设置检测参数：${RESET}"
        read -p "请输入单 IP 允许的最大失败尝试次数 [默认 5]： " max_attempts
        max_attempts=${max_attempts:-5}

        echo "MAX_ATTEMPTS=$max_attempts" | sudo tee "$DETECT_CONFIG" > /dev/null
        echo -e "${GREEN}检测配置已保存${RESET}"
    else
        source "$DETECT_CONFIG"
    fi

    echo -e "${GREEN}检测时间范围：最近 24 小时${RESET}"
    echo -e "${GREEN}可疑 IP 统计（尝试次数 >= $MAX_ATTEMPTS）：${RESET}"
    echo -e "----------------------------------------${RESET}"

    grep "Failed password" "$LOG_FILE" 2>/dev/null | awk -v max=$MAX_ATTEMPTS '
    {
        ip = $(NF-3)
        attempts[ip]++
    }
    END {
        for (ip in attempts) {
            if (attempts[ip] >= max) {
                printf "IP: %-15s 尝试次数: %d\n", ip, attempts[ip]
            }
        }
    }' | sort -k3 -nr

    echo -e "----------------------------------------${RESET}"
    echo -e "${YELLOW}提示：以上为疑似暴力破解的 IP 列表，未自动封禁。${RESET}"
    echo -e "${YELLOW}若需自动封禁，建议安装配置 Fail2Ban。${RESET}"

    echo ""
    read -p "是否安装 Fail2Ban 防护？(y/n): " install_fail2ban
    if [[ "$install_fail2ban" =~ [Yy] ]]; then
        check_system
        case $SYSTEM in
            debian)
                sudo apt update && sudo apt install -y fail2ban
                ;;
            centos)
                sudo yum install -y epel-release && sudo yum install -y fail2ban
                ;;
        esac

        if command_exists fail2ban-client; then
            echo -e "${GREEN}Fail2Ban 安装成功！${RESET}"
            if has_systemctl; then
                sudo systemctl enable fail2ban
                sudo systemctl start fail2ban
            fi
            echo -e "${YELLOW}SSH 防护已启用！${RESET}"
        fi
    fi
}

ssh_guard
