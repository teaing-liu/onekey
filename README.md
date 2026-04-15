# onekey - 服务器管理一键工具

## 运行命令


### 方式一：下载后运行（推荐）

```bash
wget -O /root/new-onekey.sh https://raw.githubusercontent.com/teaing-liu/new-onekey/main/new-onekey.sh && chmod +x /root/new-onekey.sh && /root/new-onekey.sh
```

### 方式二：直接运行

```bash
bash <(curl -sL https://raw.githubusercontent.com/teaing-liu/new-onekey/main/new-onekey.sh)

```

**首次运行会自动安装到 `/root/new-onekey`，并设置 `s` 命令。以后只需输入 `s` 即可运行。**

## 功能菜单

| 序号 | 功能 |
|------|------|
| 0 | 脚本更新 |
| 1 | VPS一键测试 |
| 2 | 安装BBR |
| 3 | 安装v2ray |
| 4 | 安装无人直播云SRS |
| 5 | 面板安装（1panel/宝塔/青龙） |
| 6 | 系统更新 |
| 7 | 修改密码 |
| 8 | 重启服务器 |
| 9 | 永久禁用IPv6 |
| 10 | 解除禁用IPv6 |
| 11 | 时区修改为中国时区 |
| 12 | 保持SSH连接 |
| 13 | DD重装系统 |
| 14 | 服务器文件传输 |
| 15 | 安装探针 |
| 16 | 反代NPM |
| 17 | 安装curl和wget |
| 18 | Docker管理 |
| 19 | SSH防暴力破解 |
| 20 | Speedtest测速 |
| 21 | WordPress安装 |
| 22 | 网心云安装 |
| 23 | 3X-UI搭建 |
| 24 | S-UI搭建 |
| 25 | FileBrowser网盘 |

## 使用方法

1. 运行脚本后显示主菜单
2. 输入对应序号（如 `2`）按回车执行
3. 输入 `q` 退出

## 系统要求

- Ubuntu / Debian
- CentOS / RHEL
- Fedora

## 项目结构

```
onekey/
├── new-onekey.sh          # 主入口文件
├── README.md          # 项目说明
└── modules/          # 功能模块目录
    ├── 0.sh           # 脚本更新
    ├── 1.sh           # VPS一键测试
    ├── 2.sh           # 安装BBR
    ├── 3.sh           # 安装v2ray
    ├── 4.sh           # 安装SRS
    ├── 5.sh           # 面板安装（1panel/宝塔/青龙）
    ├── 6.sh           # 系统更新
    ├── 7.sh           # 修改密码
    ├── 8.sh           # 重启服务器
    ├── 9.sh           # 禁用IPv6
    ├── 10.sh          # 解除禁用IPv6
    ├── 11.sh          # 时区修改
    ├── 12.sh          # SSH保活
    ├── 13.sh          # DD重装系统
    ├── 14.sh          # 文件传输
    ├── 15.sh          # 安装探针
    ├── 16.sh          # 反代NPM
    ├── 17.sh          # 安装curl/wget
    ├── 18.sh          # Docker管理
    ├── 19.sh          # SSH防暴力
    ├── 20.sh          # Speedtest测速
    ├── 21.sh          # WordPress
    ├── 22.sh          # 网心云
    ├── 23.sh          # 3X-UI
    ├── 24.sh          # S-UI
    ├── 25.sh          # FileBrowser
    └── common.sh       # 公共函数库
```

## 添加新功能

### 第一步：修改 new-onekey.sh

在 `MENU_ITEMS` 数组中添加新菜单项：

```bash
declare -A MENU_ITEMS
MENU_ITEMS=(
    ["0"]="脚本更新"
    ["1"]="VPS一键测试"
    # ... 其他现有功能 ...
    ["25"]="FileBrowser网盘"
    ["26"]="你的新功能名称"    # 添加这一行
)
```

### 第二步：创建模块文件

在 `modules/` 目录下创建新文件 `26.sh`：

```bash
#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 公共函数（可选，如果需要）
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu|debian) SYSTEM="debian" ;;
            centos|rhel) SYSTEM="centos" ;;
            fedora) SYSTEM="fedora" ;;
            *) SYSTEM="unknown" ;;
        esac
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

# ============================
# 新功能：你的功能名称
# ============================

new_feature_name() {
    echo -e "${GREEN}正在执行新功能...${RESET}"

    # 在这里编写你的功能代码

    # 示例：检查Docker是否安装
    if ! command_exists docker; then
        echo -e "${RED}Docker 未安装，请先安装！${RESET}"
        return 1
    fi

    echo -e "${GREEN}功能执行完成！${RESET}"
}

# 非交互模式显示菜单
if ! is_interactive; then
    echo -e "${YELLOW}检测到非交互模式，显示功能菜单${RESET}"
    echo "1) 执行功能一"
    echo "2) 执行功能二"
    echo "0) 退出"
    return 0
fi

# 交互模式主循环
while true; do
    echo -e "${GREEN}=== 新功能菜单 ===${RESET}"
    echo "1) 执行功能一"
    echo "2) 执行功能二"
    echo "0) 返回主菜单"
    read -p "请输入选项：" choice

    case $choice in
        1) echo "执行功能一..." ;;
        2) echo "执行功能二..." ;;
        0) break ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac

    wait_for_enter
done

# 关键：文件末尾必须调用主函数
new_feature_name
```

### 第三步：提交到Git

```bash
git add modules/26.sh new-onekey.sh
git commit -m "feat: 添加新功能模块"
git push
```

### 第四步：在VPS上更新

```bash
# 方法一：重新运行脚本自动更新
bash <(curl -sL https://raw.githubusercontent.com/teaing-liu/new-onekey/main/new-onekey.sh)

# 方法二：手动更新
cd /root/new-onekey
git pull

# 方法三：使用 s 命令（如果已设置别名）
s
```

## 模块开发规范

### 必须遵循的规则

1. **文件命名**：`modules/` 目录下使用数字命名，如 `26.sh`
2. **文件权限**：必须是可执行 `chmod +x modules/26.sh`
3. **主函数调用**：文件末尾必须调用主函数
4. **颜色定义**：使用标准颜色代码 `GREEN`, `RED`, `YELLOW`, `RESET`
5. **交互检测**：使用 `is_interactive()` 检测终端模式

### 推荐的公共函数

```bash
# 系统检测
check_system

# 命令是否存在
command_exists "docker"

# 获取服务器IP
get_server_ip

# 检测交互模式
is_interactive

# 等待回车
wait_for_enter
```

### 非交互模式处理

某些功能在SSH非交互模式下无法完整运行（如需要密码输入的功能）。建议：

```bash
if ! is_interactive; then
    echo -e "${YELLOW}检测到非交互模式，显示功能菜单：${RESET}"
    echo "1) 功能一"
    echo "2) 功能二"
    echo ""
    echo -e "${GREEN}请使用交互式终端运行此脚本以获得完整功能${RESET}"
    return 0
fi
```

## 常见问题

### Q: 如何测试新模块？
```bash
# 在VPS上直接运行
bash /root/new-onekey/modules/26.sh
```

### Q: 如何调试？
```bash
# 添加调试输出
set -x  # 开启调试
# 你的代码
set +x  # 关闭调试
```

### Q: 模块加载失败怎么办？
```bash
# 检查文件语法
bash -n /root/new-onekey/modules/26.sh

# 检查文件权限
ls -l /root/new-onekey/modules/26.sh
# 应该显示 -rwxr-xr-x
```
