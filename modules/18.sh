#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

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

check_docker_status() {
    if ! command -v docker &> /dev/null && ! snap list 2>/dev/null | grep -q docker; then
        echo -e "${RED}Docker 未安装，请先安装！${RESET}"
        return 1
    fi
    return 0
}

# Docker 管理主函数
docker_management() {
    install_docker() {
        echo -e "${GREEN}正在安装 Docker 环境...${RESET}"
        
        local os_id=""
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            os_id=$ID
        fi
        
        check_system
        if [ "$os_id" == "ubuntu" ] || [ "$SYSTEM" == "debian" ]; then
            sudo apt update -y && sudo apt install -y curl ca-certificates gnupg lsb-release
            sudo mkdir -p /etc/apt/keyrings
            local docker_repo="debian"
            if [ "$os_id" == "ubuntu" ]; then
                docker_repo="ubuntu"
            fi
            curl -fsSL https://download.docker.com/linux/${docker_repo}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_repo} \
            $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt update -y
            sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        elif [ "$SYSTEM" == "centos" ]; then
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        else
            echo -e "${RED}不支持的系统类型，无法安装 Docker！${RESET}"
            return 1
        fi

        if has_systemctl; then
            sudo systemctl start docker
            sudo systemctl enable docker
        fi

        if ! command -v docker &> /dev/null; then
            echo -e "${RED}Docker 安装失败，请手动检查！${RESET}"
            return 1
        fi

        echo -e "${GREEN}Docker 和 Docker Compose 安装成功！${RESET}"
    }

    uninstall_docker() {
        echo -e "${RED}你确定要彻底卸载 Docker 和 Docker Compose 吗？此操作不可恢复！${RESET}"
        read -p "请输入 y 确认，其他任意键取消: " confirm
        if [[ "$confirm" != "y" ]]; then
            echo -e "${YELLOW}已取消卸载操作，返回上一级菜单。${RESET}"
            return
        fi

        if ! check_docker_status; then return; fi

        local running_containers=$(docker ps -q)
        if [ -n "$running_containers" ]; then
            echo -e "${YELLOW}发现运行中的容器：${RESET}"
            docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Names}}" | sed 's/CONTAINER ID/容器ID/; s/IMAGE/镜像名称/; s/NAMES/容器名称/'
            read -p "是否停止并删除所有容器？(y/n，默认 n): " stop_choice
            stop_choice=${stop_choice:-n}
            if [[ $stop_choice =~ [Yy] ]]; then
                echo -e "${YELLOW}正在停止并移除运行中的 Docker 容器...${RESET}"
                docker stop $(docker ps -aq) 2>/dev/null
                docker rm $(docker ps -aq) 2>/dev/null
            fi
        fi

        read -p "是否删除所有 Docker 镜像？(y/n，默认 n): " delete_images
        delete_images=${delete_images:-n}
        if [[ $delete_images =~ [Yy] ]]; then
            echo -e "${YELLOW}正在删除所有 Docker 镜像...${RESET}"
            docker rmi $(docker images -q) 2>/dev/null
        fi

        echo -e "${YELLOW}正在停止并禁用 Docker 服务...${RESET}"
        if has_systemctl; then
            sudo systemctl stop docker 2>/dev/null
            sudo systemctl disable docker 2>/dev/null
            sudo systemctl daemon-reload 2>/dev/null
        fi

        echo -e "${YELLOW}正在删除 Docker 和 Compose 二进制文件...${RESET}"
        sudo rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-init /usr/bin/docker-proxy

        echo -e "${YELLOW}正在删除 Docker 相关目录和文件...${RESET}"
        sudo rm -rf /var/lib/docker /etc/docker /var/run/docker.sock ~/.docker

        echo -e "${YELLOW}正在删除 Docker 服务文件...${RESET}"
        sudo rm -f /etc/systemd/system/docker.service
        sudo rm -f /etc/systemd/system/docker.socket
        if has_systemctl; then
            sudo systemctl daemon-reload 2>/dev/null
        fi

        if grep -q docker /etc/group; then
            sudo groupdel docker
        fi

        echo -e "${YELLOW}正在卸载 Docker 包...${RESET}"
        sudo apt purge -y docker.io docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-ce-rootless-extras docker-compose-plugin 2>/dev/null
        sudo apt autoremove -y 2>/dev/null
        sudo yum remove -y docker docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null

        echo -e "${GREEN}Docker 和 Docker Compose 已彻底卸载完成！${RESET}"
    }

    configure_mirror() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}当前镜像加速配置：${RESET}"
        if [ -f /etc/docker/daemon.json ]; then
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
                sudo tee /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["$mirror_url"]
}
EOF
                if has_systemctl; then
                    sudo systemctl restart docker
                fi
                echo -e "${GREEN}镜像加速配置已更新！当前使用的镜像加速地址：$mirror_url${RESET}"
                ;;
            2)
                if [ -f /etc/docker/daemon.json ]; then
                    sudo rm /etc/docker/daemon.json
                    if has_systemctl; then
                        sudo systemctl restart docker
                    fi
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
                sudo tee /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["$mirror_url"]
}
EOF
                if has_systemctl; then
                    sudo systemctl restart docker
                fi
                echo -e "${GREEN}镜像加速配置已更新！当前使用的镜像加速地址：$mirror_url${RESET}"
                ;;
            *)
                echo -e "${RED}无效选项！${RESET}"
                ;;
        esac
    }

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
        else
            echo -e "${RED}容器启动失败！${RESET}"
        fi
    }

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

    manage_images() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}====== 已安装镜像 ======${RESET}"
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" | sed 's/REPOSITORY/仓库名称/; s/TAG/标签/; s/IMAGE ID/镜像ID/; s/SIZE/大小/'
        echo -e "${YELLOW}========================${RESET}"
    }

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

    delete_image() {
        if ! check_docker_status; then return; fi

        echo -e "${YELLOW}已安装镜像列表：${RESET}"
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" | sed 's/REPOSITORY/仓库名称/; s/TAG/标签/; s/IMAGE ID/镜像ID/; s/SIZE/大小/'
        read -p "请输入要删除的镜像ID： " image_id
        local running_containers=$(docker ps -q --filter "ancestor=$image_id")
        if [ -n "$running_containers" ]; then
            echo -e "${YELLOW}发现使用该镜像的容器，正在停止并删除...${RESET}"
            docker stop $running_containers 2>/dev/null
            docker rm $running_containers 2>/dev/null
        fi
        if docker rmi "$image_id" &> /dev/null; then
            echo -e "${GREEN}镜像删除成功！${RESET}"
        else
            echo -e "${RED}镜像删除失败！${RESET}"
        fi
    }

    install_sun_panel() {
        echo -e "${GREEN}正在安装 sun-panel...${RESET}"

        local sun_port
        read -p "请输入要使用的端口号（默认 3002）： " sun_port
        sun_port=${sun_port:-3002}

        if ! [[ "$sun_port" =~ ^[0-9]+$ ]] || [ "$sun_port" -lt 1 ] || [ "$sun_port" -gt 65535 ]; then
            echo -e "${RED}无效端口，请输入 1-65535 之间的数字！${RESET}"
            return
        fi

        if ss -tuln | grep -q ":${sun_port} "; then
            echo -e "${RED}端口 ${sun_port} 已被占用，请选择其他端口！${RESET}"
            return
        fi

        open_firewall_port $sun_port

        docker pull hslr/sun-panel:latest
        docker run -d \
            --name sun-panel \
            --restart always \
            -p ${sun_port}:3002 \
            -v /home/sun-panel/data:/app/data \
            -v /home/sun-panel/config:/app/config \
            -e SUNPANEL_ADMIN_USER="admin@sun.cc" \
            -e SUNPANEL_ADMIN_PASS="12345678" \
            hslr/sun-panel:latest

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

    install_image_container() {
        if ! check_docker_status; then return; fi

        read -p "请输入镜像名称（示例：nginx:latest）： " image_name
        if [[ -z "$image_name" ]]; then
            echo -e "${RED}镜像名称不能为空！${RESET}"
            return
        fi

        echo -e "${GREEN}正在拉取镜像 ${image_name}...${RESET}"
        if ! docker pull "$image_name"; then
            echo -e "${RED}镜像拉取失败！${RESET}"
            return
        fi

        local DEFAULT_PORT=8080
        read -p "请输入要映射的端口（默认 ${DEFAULT_PORT}）： " container_port
        container_port=${container_port:-$DEFAULT_PORT}

        if ! [[ "$container_port" =~ ^[0-9]+$ ]] || [ "$container_port" -lt 1 ] || [ "$container_port" -gt 65535 ]; then
            echo -e "${RED}无效端口！${RESET}"
            return
        fi

        if ss -tuln | grep -q ":${container_port} "; then
            echo -e "${RED}端口 ${container_port} 已被占用！${RESET}"
            return
        fi

        open_firewall_port $container_port

        local container_name="$(echo "$image_name" | tr '/:' '_')_$$"
        echo -e "${GREEN}正在启动容器...${RESET}"
        docker run -d \
            --name "$container_name" \
            --restart unless-stopped \
            -p ${container_port}:80 \
            "$image_name"

        if [ $? -eq 0 ]; then
            server_ip=$(get_server_ip)
            echo -e "${GREEN}容器安装成功！${RESET}"
            echo -e "${YELLOW}访问地址：http://${server_ip}:${container_port}${RESET}"
        else
            echo -e "${RED}容器启动失败！${RESET}"
        fi
    }

    update_image_restart() {
        if ! check_docker_status; then return; fi

        read -p "请输入要更新的镜像名称（例如：nginx:latest）：" image_name
        if [[ -z "$image_name" ]]; then
            echo -e "${RED}镜像名称不能为空！${RESET}"
            return
        fi

        echo -e "${GREEN}正在更新镜像：${image_name}...${RESET}"
        if ! docker pull "$image_name"; then
            echo -e "${RED}镜像更新失败！${RESET}"
            return
        fi

        container_ids=$(docker ps -a --filter "ancestor=$image_name" --format "{{.ID}}")
        if [ -z "$container_ids" ]; then
            echo -e "${YELLOW}没有找到使用该镜像的容器${RESET}"
            return
        fi

        echo -e "${YELLOW}正在重启以下容器：${RESET}"
        docker ps -a --filter "ancestor=$image_name" --format "table {{.ID}}\t{{.Names}}\t{{.Image}}"
        for cid in $container_ids; do
            echo -n "重启容器 $cid ... "
            docker restart "$cid" && echo "成功" || echo "失败"
        done
    }

    batch_operations() {
        if ! check_docker_status; then return; fi

        echo -e "${GREEN}=== 批量操作容器 ===${RESET}"
        echo "1) 启动所有容器"
        echo "2) 停止所有容器"
        echo "3) 重启所有容器"
        echo "4) 删除已停止的容器"
        read -p "请输入选项：" batch_choice

        case $batch_choice in
            1)
                echo -e "${YELLOW}正在启动所有容器...${RESET}"
                docker start $(docker ps -aq)
                echo -e "${GREEN}所有容器已启动！${RESET}"
                ;;
            2)
                echo -e "${YELLOW}正在停止所有容器...${RESET}"
                docker stop $(docker ps -q)
                echo -e "${GREEN}所有容器已停止！${RESET}"
                ;;
            3)
                echo -e "${YELLOW}正在重启所有容器...${RESET}"
                docker restart $(docker ps -aq)
                echo -e "${GREEN}所有容器已重启！${RESET}"
                ;;
            4)
                echo -e "${YELLOW}正在删除已停止的容器...${RESET}"
                docker rm $(docker ps -aq)
                echo -e "${GREEN}已停止的容器已删除！${RESET}"
                ;;
            *)
                echo -e "${RED}无效选项！${RESET}"
                ;;
        esac
    }

    install_portainer() {
        if ! check_docker_status; then return; fi

        local DEFAULT_PORT=9000

        if ss -tuln | grep -q ":${DEFAULT_PORT} "; then
            echo -e "${RED}端口 $DEFAULT_PORT 已被占用！${RESET}"
            read -p "请输入其他端口号（1-65535）： " new_port
            while ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; do
                echo -e "${RED}无效端口！${RESET}"
                read -p "请输入其他端口号（1-65535）： " new_port
            done
            DEFAULT_PORT=$new_port
        fi

        open_firewall_port $DEFAULT_PORT

        echo -e "${YELLOW}正在拉取 Portainer 镜像...${RESET}"
        if ! docker pull 6053537/portainer-ce; then
            echo -e "${RED}拉取 Portainer 镜像失败！${RESET}"
            return
        fi

        if docker ps -a --format '{{.Names}}' | grep -q "^portainer$"; then
            echo -e "${YELLOW}检测到已存在名为 portainer 的容器，正在移除...${RESET}"
            docker stop portainer &> /dev/null
            docker rm portainer &> /dev/null
        fi

        echo -e "${YELLOW}正在启动 Portainer 容器...${RESET}"
        if ! docker run -d --restart=always --name="portainer" -p $DEFAULT_PORT:9000 -v /var/run/docker.sock:/var/run/docker.sock 6053537/portainer-ce; then
            echo -e "${RED}启动 Portainer 容器失败！${RESET}"
            return
        fi

        sleep 3
        if docker ps --format '{{.Names}}' | grep -q "^portainer$"; then
            server_ip=$(curl -s4 ifconfig.me || echo "你的服务器IP")
            echo -e "${GREEN}Portainer 安装成功！${RESET}"
            echo -e "${YELLOW}访问地址：http://$server_ip:$DEFAULT_PORT${RESET}"
            echo -e "${YELLOW}首次登录需设置管理员密码！${RESET}"
        else
            echo -e "${RED}Portainer 容器未正常运行，请检查日志！${RESET}"
            docker logs portainer
        fi
    }

    if ! is_interactive; then
        echo -e "${YELLOW}检测到非交互模式，显示 Docker 管理菜单${RESET}"
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
        echo "13) 安装 Portainer"
        echo "0) 退出"
        return 0
    fi

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
        echo "13) 安装 Portainer"
        echo "0) 返回主菜单"
        read -p "请输入选项：" docker_choice

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

        wait_for_enter
    done
}

docker_management
