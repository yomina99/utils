#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- 配置 ---
# GitHub Raw URL of the main logic script
# !!! 请将下面的 URL 替换为你脚本在 GitHub 上的实际 Raw 链接 !!!
# 示例 URL，你需要改成你自己的仓库和路径
SOURCE_SCRIPT_URL="https://raw.githubusercontent.com/yomina99/utils/refs/heads/main/update_gstatic_hosts.sh"

# 目标脚本安装路径
INSTALL_SCRIPT_PATH="/usr/local/sbin/update_gstatic_hosts.sh"
# systemd service 名称
SERVICE_NAME="update-hosts"
# systemd 单元文件路径
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 此安装脚本必须以 root 权限运行。" >&2
  exit 1
fi

# --- 依赖检查 (添加 curl 或 wget) ---
DOWNLOADER=""
if command -v curl &> /dev/null; then
    DOWNLOADER="curl"
elif command -v wget &> /dev/null; then
    DOWNLOADER="wget"
else
    echo "错误: 需要 'curl' 或 'wget' 命令来下载脚本。" >&2
    # 尝试自动安装 curl
    if command -v apt-get &> /dev/null; then
        echo "正在尝试使用 apt 安装 curl..." >&2
        apt-get update && apt-get install -y curl
        DOWNLOADER="curl"
    elif command -v yum &> /dev/null; then
        echo "正在尝试使用 yum 安装 curl..." >&2
        yum install -y curl
        DOWNLOADER="curl"
    fi
    # 再次检查
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo "错误: 自动安装失败。请手动安装 'curl' 或 'wget'。" >&2
        exit 1
    fi
    # 确定下载器
     if [ -z "$DOWNLOADER" ]; then # 如果安装后 wget 可用但 curl 失败
         if command -v wget &> /dev/null; then DOWNLOADER="wget"; fi
     fi
fi
echo "将使用 '$DOWNLOADER' 下载脚本。" >&2


echo "开始安装 hosts 更新服务..."

# --- 1. 下载并安装主脚本 ---
echo "正在从 $SOURCE_SCRIPT_URL 下载脚本到 $INSTALL_SCRIPT_PATH ..."

# 创建目标目录以防万一
mkdir -p "$(dirname "$INSTALL_SCRIPT_PATH")"

# 使用选择的下载器下载文件
DOWNLOAD_SUCCESS=false
if [ "$DOWNLOADER" == "curl" ]; then
    # curl: -f fail fast, -s silent, -S show error, -L follow redirects, -o output file
    if curl -fsSL -o "$INSTALL_SCRIPT_PATH" "$SOURCE_SCRIPT_URL"; then
        DOWNLOAD_SUCCESS=true
    fi
elif [ "$DOWNLOADER" == "wget" ]; then
    # wget: -q quiet, -O output file
    if wget -q -O "$INSTALL_SCRIPT_PATH" "$SOURCE_SCRIPT_URL"; then
        DOWNLOAD_SUCCESS=true
    fi
fi

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "错误: 下载脚本失败。请检查 URL 或网络连接。" >&2
    # 清理可能下载了一部分的文件
    rm -f "$INSTALL_SCRIPT_PATH"
    exit 1
fi

# 设置执行权限
chmod +x "$INSTALL_SCRIPT_PATH"
# 验证一下脚本是否真的有内容 (简单的非空检查)
if [ ! -s "$INSTALL_SCRIPT_PATH" ]; then
    echo "错误: 下载的脚本为空文件。" >&2
    rm -f "$INSTALL_SCRIPT_PATH"
    exit 1
fi
echo "脚本下载并安装成功。"

# --- 2. 创建 systemd service 文件 ---
# (这部分和之前一样，确保 ExecStart 指向 $INSTALL_SCRIPT_PATH)
echo "正在创建 systemd service 文件: $SERVICE_FILE ..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Update /etc/hosts with IPs for specified domains
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_SCRIPT_PATH
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
if [ ! -f "$SERVICE_FILE" ]; then echo "错误: 创建 service 文件失败。" >&2; exit 1; fi
chmod 644 "$SERVICE_FILE"
echo "Service 文件创建成功。"

# --- 3. 创建 systemd timer 文件 ---
# (这部分和之前一样)
echo "正在创建 systemd timer 文件: $TIMER_FILE ..."
cat << EOF > "$TIMER_FILE"
[Unit]
Description=Run ${SERVICE_NAME}.service every 5 minutes
Requires=${SERVICE_NAME}.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=${SERVICE_NAME}.service
Persistent=true

[Install]
WantedBy=timers.target
EOF
if [ ! -f "$TIMER_FILE" ]; then echo "错误: 创建 timer 文件失败。" >&2; rm -f "$SERVICE_FILE"; exit 1; fi
chmod 644 "$TIMER_FILE"
echo "Timer 文件创建成功。"

# --- 4. 重载 systemd 配置 ---
echo "正在重新加载 systemd 配置..."
systemctl daemon-reload

# --- 5. 启用并启动 timer ---
echo "正在启用并启动 timer..."
systemctl enable "${SERVICE_NAME}.timer"
systemctl start "${SERVICE_NAME}.timer"

# --- 6. 检查状态 ---
echo "---"
echo "安装完成！"
echo "Timer 状态:"
systemctl status "${SERVICE_NAME}.timer" --no-pager
echo "---"
echo "你可以使用以下命令查看服务日志:"
echo "journalctl -u ${SERVICE_NAME}.service -f"
echo "---"

exit 0
