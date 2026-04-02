#!/bin/bash

# ============================================================
# onekey - 服务器管理一键工具
# ============================================================

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

INSTALL_DIR="/root/new-onekey"
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURRENT_NAME="$(basename "$0")"

# 自动安装
auto_install() {
    if [ ! -d "${INSTALL_DIR}/modules" ]; then
        echo -e "${YELLOW}首次运行，正在安装...${RESET}"
        
        local clone_urls=(
            "https://github.com/sinian-liu/new-onekey.git"
            "https://gh.llkk.cc/github.com/sinian-liu/new-onekey.git"
            "https://mirror.ghproxy.com/https://github.com/sinian-liu/new-onekey.git"
        )
        
        local installed=false
        for url in "${clone_urls[@]}"; do
            echo -e "${YELLOW}尝试下载: $url${RESET}"
            if git clone --depth 1 "$url" "$INSTALL_DIR" 2>/dev/null; then
                installed=true
                break
            fi
        done
        
        if [ "$installed" = false ]; then
            echo -e "${RED}下载失败，请尝试以下方法：${RESET}"
            echo -e "${YELLOW}1. 等待网络稳定后重试${RESET}"
            echo -e "${YELLOW}2. 手动下载：${RESET}"
            echo -e "   git clone https://github.com/sinian-liu/new-onekey.git /root/new-onekey"
            echo -e "${YELLOW}3. 或使用代理加速${RESET}"
            exit 1
        fi
        
        chmod +x "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/modules/*.sh
        setup_s_command
    fi
}

# 清理损坏的 s 命令符号链接
cleanup_broken_symlinks() {
    for dir in /root/bin "$HOME/bin" /usr/local/bin; do
        local link="${dir}/s"
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            echo -e "${YELLOW}发现损坏的符号链接: $link，正在删除...${RESET}"
            rm -f "$link"
        fi
    done
}

# 设置s快捷命令
setup_s_command() {
    chmod +x /root/new-onekey/new-onekey.sh 2>/dev/null
    
    # 先清理损坏的符号链接（即使 /usr/local/bin/s 存在）
    cleanup_broken_symlinks
    
    # 检查 /usr/local/bin/s 是否已正确创建
    if [ -L /usr/local/bin/s ] && [ -f /usr/local/bin/s ]; then
        echo -e "${GREEN}快捷命令 s 已存在于 /usr/local/bin/s${RESET}"
    else
        # 优先尝试创建 /usr/local/bin/s（最可靠，/usr/local/bin 通常在 PATH 中）
        if ln -sf /root/new-onekey/new-onekey.sh /usr/local/bin/s 2>/dev/null; then
            echo -e "${GREEN}快捷命令 s 已设置到 /usr/local/bin/s${RESET}"
        else
            echo -e "${YELLOW}警告：无法创建 /usr/local/bin/s（权限不足）${RESET}"
            echo -e "${YELLOW}正在尝试创建到 ~/bin/s ...${RESET}"
            
            # 回退方案：创建 ~/bin/s
            mkdir -p "${HOME}/bin"
            if ln -sf /root/new-onekey/new-onekey.sh "${HOME}/bin/s" 2>/dev/null; then
                echo -e "${GREEN}快捷命令 s 已设置到 ~/bin/s${RESET}"
                
                # 检查 PATH 是否包含 ~/bin
                if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
                    echo -e "${YELLOW}警告：~/bin 不在当前 PATH 中${RESET}"
                    
                    # 自动修复：添加到当前 shell 的 PATH
                    export PATH="$HOME/bin:$PATH"
                    echo -e "${GREEN}已将 ~/bin 添加到当前会话的 PATH${RESET}"
                fi
            else
                echo -e "${RED}错误：无法创建符号链接 ~/bin/s${RESET}"
            fi
        fi
    fi
    
    # 添加到 /etc/profile.d/（系统级配置，SSH登录时自动加载）
    if [ ! -f /etc/profile.d/new-onekey.sh ]; then
        echo 'export PATH="/usr/local/bin:$HOME/bin:$PATH"' | sudo tee /etc/profile.d/new-onekey.sh > /dev/null
        sudo chmod +x /etc/profile.d/new-onekey.sh 2>/dev/null
        echo -e "${GREEN}已创建 /etc/profile.d/new-onekey.sh（下次SSH登录自动生效）${RESET}"
    fi
    
    echo -e "${YELLOW}（使用 s 命令启动）${RESET}"
}

# 如果当前目录不是安装目录，或者模块目录不存在，执行安装
if [ "$CURRENT_DIR" != "$INSTALL_DIR" ] || [ ! -d "${INSTALL_DIR}/modules" ]; then
    auto_install
    # 切换到安装目录重新运行
    cd "$INSTALL_DIR"
    bash "$CURRENT_NAME"
    exit 0
fi

# 以下是主脚本逻辑
MODULE_DIR="${INSTALL_DIR}/modules"

# 主菜单定义
declare -A MENU_ITEMS
MENU_ITEMS=(
    ["0"]="脚本更新"
    ["1"]="VPS一键测试"
    ["2"]="安装BBR"
    ["3"]="安装v2ray"
    ["4"]="安装无人直播云SRS"
    ["5"]="面板安装（1panel/宝塔/青龙）"
    ["6"]="系统更新"
    ["7"]="修改密码"
    ["8"]="重启服务器"
    ["9"]="永久禁用IPv6"
    ["10"]="解除禁用IPv6"
    ["11"]="时区修改为中国时区"
    ["12"]="保持SSH连接"
    ["13"]="DD重装系统"
    ["14"]="服务器文件传输"
    ["15"]="安装探针"
    ["16"]="反代NPM"
    ["17"]="安装curl和wget"
    ["18"]="Docker管理"
    ["19"]="SSH防暴力破解"
    ["20"]="Speedtest测速"
    ["21"]="WordPress安装"
    ["22"]="网心云安装"
    ["23"]="3X-UI搭建"
    ["24"]="S-UI搭建"
    ["25"]="FileBrowser网盘"
    ["26"]="智能端口与域名管理"
)

show_menu() {
    clear
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${GREEN}服务器推荐：https://my.frantech.ca/aff.php?aff=4337${RESET}"
    echo -e "${GREEN}VPS评测网站：https://www.1373737.xyz/${RESET}"
    echo -e "${GREEN}YouTube频道：https://www.youtube.com/@cyndiboy7881${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
    echo "请选择要执行的操作："
    echo ""

    for key in $(echo "${!MENU_ITEMS[@]}" | tr ' ' '\n' | sort -n); do
        printf "    ${YELLOW}%-2s${RESET}) ${YELLOW}%s${RESET}\n" "$key" "${MENU_ITEMS[$key]}"
    done

    echo ""
    echo -e "${YELLOW}=============================================${RESET}"
}

run_module() {
    local module_file="${INSTALL_DIR}/modules/${1}.sh"
    if [ ! -f "$module_file" ]; then
        echo -e "${RED}模块 ${1} 不存在${RESET}"
        return 1
    fi
    set --
    . "$module_file"
}

# 检查更新
check_update() {
    cd "$INSTALL_DIR"
    echo -e "${YELLOW}正在检查更新...${RESET}"
    
    git fetch origin main 2>/dev/null
    
    local local_commit=$(git log --oneline -1 HEAD 2>/dev/null)
    local remote_commit=$(git log --oneline -1 origin/main 2>/dev/null)
    
    if [ "$local_commit" = "$remote_commit" ]; then
        echo -e "${GREEN}已是最新版本${RESET}"
        return 0
    fi
    
    echo -e "${YELLOW}发现新版本！${RESET}"
    echo -e "${GREEN}当前版本: ${local_commit}${RESET}"
    echo -e "${YELLOW}最新版本: ${remote_commit}${RESET}"
    echo ""
    echo -e "${YELLOW}更新内容：${RESET}"
    git log --oneline HEAD..origin/main 2>/dev/null | head -5
    echo ""
    
    read -p "是否更新？(y/n，默认 n): " confirm
    confirm=${confirm:-n}
    
    if [[ "$confirm" =~ [Yy] ]]; then
        echo -e "${YELLOW}正在更新...${RESET}"
        git stash 2>/dev/null
        git pull origin main
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}更新成功！${RESET}"
        else
            echo -e "${RED}更新失败，可能是网络问题或存在冲突${RESET}"
            echo -e "${YELLOW}请稍后重试，或手动执行: cd $INSTALL_DIR && git pull${RESET}"
            git stash pop 2>/dev/null
        fi
    else
        echo -e "${YELLOW}已取消更新${RESET}"
    fi
}

# 检查并自动修复 s 命令
check_and_fix_s_command() {
    # 如果 s 命令已可用，跳过
    if command -v s &> /dev/null; then
        return 0
    fi
    
    echo -e "${YELLOW}检测到 s 命令不可用，正在自动修复...${RESET}"
    
    # 先清理损坏的符号链接
    cleanup_broken_symlinks
    
    # 检查 /usr/local/bin/s 是否存在且有效
    if [ -L /usr/local/bin/s ] && [ -f /usr/local/bin/s ]; then
        echo -e "${YELLOW}发现有效的 /usr/local/bin/s，添加到 PATH...${RESET}"
        export PATH="/usr/local/bin:$PATH"
        
        if command -v s &> /dev/null; then
            echo -e "${GREEN}s 命令已修复！${RESET}"
            return 0
        fi
    fi
    
    # 检查 ~/bin/s 是否存在且有效
    if [ -L "${HOME}/bin/s" ] && [ -f "${HOME}/bin/s" ]; then
        echo -e "${YELLOW}发现有效的 ~/bin/s，添加到 PATH...${RESET}"
        export PATH="$HOME/bin:$PATH"
        
        if command -v s &> /dev/null; then
            echo -e "${GREEN}s 命令已修复！${RESET}"
            return 0
        fi
    fi
    
    # 符号链接都不存在或无效，重新设置
    echo -e "${YELLOW}符号链接不存在或无效，重新创建...${RESET}"
    setup_s_command
    
    # 再次检查
    if command -v s &> /dev/null; then
        echo -e "${GREEN}s 命令已修复！${RESET}"
        return 0
    fi
    
    return 1
}

main() {
    # 自动检测并修复 s 命令
    check_and_fix_s_command
    
    while true; do
        show_menu
        read -p "请输入选项 (输入 'q' 退出): " option

        [ "$option" = "q" ] || [ "$option" = "Q" ] && echo -e "${GREEN}退出脚本，感谢使用！${RESET}" && echo -e "${GREEN}服务器推荐：https://my.frantech.ca/aff.php?aff=4337${RESET}" && echo -e "${GREEN}VPS评测官方网站：https://www.1373737.xyz/${RESET}" && exit 0

        # 检查选项是否有效（排除空字符串）
        if [ -z "$option" ]; then
            continue
        fi
        
        if [ ! "${MENU_ITEMS[$option]+exists}" ]; then
            echo -e "${RED}无效选项${RESET}"
            read -p "按回车键继续..."
            continue
        fi

        # 选项 0 是更新
        if [ "$option" = "0" ]; then
            check_update
            read -p "按回车键继续..."
            continue
        fi

        echo -e "${YELLOW}正在执行: ${MENU_ITEMS[$option]}...${RESET}"
        run_module "$option"
        echo ""
        read -p "按回车键返回主菜单..."
    done
}

main "$@"

# 清除 bash 命令缓存，确保 s 命令可用
hash -r 2>/dev/null
