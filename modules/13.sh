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

ask_reboot() {
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

show_dd_menu() {
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

download_scripts() {
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

execute_install() {
    local choice=$1
    
    local password
    local install_cmd=""
    local is_windows=false
    local is_custom_dd=false
    local win_user="administrator"
    local win_port="3389"
    local linux_user="root"
    local linux_port="22"
    
generate_random_password() {
    tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 16
}

    case $choice in
        1)
            echo -e "${YELLOW}Ubuntu 24.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 24.04 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        2)
            echo -e "${YELLOW}Ubuntu 22.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 22.04 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        3)
            echo -e "${YELLOW}Ubuntu 20.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 20.04 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        4)
            echo -e "${YELLOW}Ubuntu 18.04${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh ubuntu 18.04 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        5)
            echo -e "${YELLOW}Debian 13${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 13 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        6)
            echo -e "${YELLOW}Debian 12${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 12 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        7)
            echo -e "${YELLOW}Debian 11${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 11 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        8)
            echo -e "${YELLOW}Debian 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh debian 10 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        9)
            echo -e "${YELLOW}CentOS Stream 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh centos 10 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        10)
            echo -e "${YELLOW}CentOS Stream 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh centos 9 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        11)
            echo -e "${YELLOW}CentOS 8 (leitbogioro)${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/InstallNET.sh -centos 8 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        12)
            echo -e "${YELLOW}CentOS 7 (leitbogioro)${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/InstallNET.sh -centos 7 --password $root_password"
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
            install_cmd="bash /tmp/reinstall.sh windows --image-name=\"Windows Server 2025\" --lang en-us --password $win_pass"
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
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh rocky 10 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        22)
            echo -e "${YELLOW}Rocky Linux 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh rocky 9 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        23)
            echo -e "${YELLOW}AlmaLinux 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh almalinux 10 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        24)
            echo -e "${YELLOW}AlmaLinux 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh almalinux 9 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        25)
            echo -e "${YELLOW}Oracle Linux 10${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh oracle 10 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        26)
            echo -e "${YELLOW}Oracle Linux 9${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh oracle 9 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        27)
            echo -e "${YELLOW}Fedora Linux 43${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh fedora 43 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        28)
            echo -e "${YELLOW}Fedora Linux 42${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh fedora 42 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        29)
            echo -e "${YELLOW}Alpine Linux 3.23${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh alpine 3.23 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        30)
            echo -e "${YELLOW}Alpine Linux 3.22${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh alpine 3.22 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        31)
            echo -e "${YELLOW}Alpine Linux 3.21${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh alpine 3.21 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        32)
            echo -e "${YELLOW}Arch Linux${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh arch --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        33)
            echo -e "${YELLOW}Kali Linux${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh kali --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        34)
            echo -e "${YELLOW}openSUSE 15.6${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh opensuse 15.6 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        35)
            echo -e "${YELLOW}openSUSE 16.0${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh opensuse 16.0 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        36)
            echo -e "${YELLOW}openEuler 24.03${RESET}"
            echo -e "用户名: ${GREEN}${linux_user}${RESET}"
            echo -e "端口: ${GREEN}${linux_port}${RESET} (SSH)"
            read -p "请输入密码 (留空随机生成): " root_password
            if [ -z "$root_password" ]; then
                root_password=$(generate_random_password)
            fi
            install_cmd="bash /tmp/reinstall.sh openeuler 24.03 --password $root_password"
            echo -e "密码: ${GREEN}${root_password}${RESET}"
            ;;
        37)
            read -p "请输入 DD 镜像直链地址: " dd_url
            if [ -z "$dd_url" ]; then
                echo -e "${RED}镜像地址不能为空${RESET}"
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
                install_cmd="bash /tmp/reinstall.sh dd --img=$dd_url --password $dd_password"
            else
                install_cmd="bash /tmp/reinstall.sh dd --img=$dd_url"
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
        echo -e "${YELLOW}即将执行: ${install_cmd}${RESET}"
        echo -e "${RED}执行后会自动重启${RESET}"
        read -p "确认执行？(y/n，默认 y): " confirm
        confirm=${confirm:-y}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}正在执行安装命令，执行后自动重启...${RESET}"
            sleep 2
            eval "$install_cmd" && reboot
        else
            echo -e "${YELLOW}已取消${RESET}"
        fi
    fi
    
    return 0
}

dd_reinstall_menu() {
    if ! is_interactive; then
        echo -e "${YELLOW}检测到非交互模式，显示 DD 重装菜单${RESET}"
        show_dd_menu
        return 0
    fi
    
    if ! download_scripts; then
        wait_for_enter
        return 1
    fi
    
    while true; do
        show_dd_menu
        read -p "请输入选项: " choice
        
        if [ -z "$choice" ]; then
            echo ""
            break
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 37 ]; then
            execute_install "$choice"
        else
            echo -e "${RED}无效选项，请输入 1-37 之间的数字或直接回车返回${RESET}"
        fi
        
        wait_for_enter
    done
}

dd_reinstall_menu
