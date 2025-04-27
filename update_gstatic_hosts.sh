#!/bin/bash
set -e # 如果任何命令失败，则立即退出

# --- 配置 ---
DOMAIN_TO_MAP="gstatic.com"
HOSTS_FILE="/etc/hosts"
MARKER="# Managed by update_gstatic_hosts for ${DOMAIN_TO_MAP}" # 用于识别脚本管理的行
TEMP_FILE=$(mktemp)

# --- 清理函数 ---
# 确保临时文件在脚本退出时被删除
cleanup() {
  rm -f "$TEMP_FILE"
}
trap cleanup EXIT

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 此脚本必须以 root 权限运行。" >&2
  exit 1
fi

# --- 依赖检查 ---
if ! command -v dig &> /dev/null; then
    echo "错误: 未找到 'dig' 命令。" >&2
    echo "正在安装 dnsutils (Debian/Ubuntu) 或 bind-utils (CentOS/Fedora/RHEL)。" >&2
    apt update && apt install -y dnsutils
    exit 1
fi

# --- 获取 IPv4 地址 ---
echo "正在查询 ${DOMAIN_TO_MAP} 的 IPv4 地址..."
# 使用 dig 获取 A 记录，并过滤确保是有效的 IPv4 地址
IPV4_ADDRESSES=$(dig +short "$DOMAIN_TO_MAP" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u) # sort -u 去重

if [ -z "$IPV4_ADDRESSES" ]; then
  echo "错误: 未能解析 ${DOMAIN_TO_MAP} 的 IPv4 地址，或 'dig' 命令失败。" >&2
  # 决定是否在失败时移除旧条目。这里选择不移除，直接退出。
  exit 1
fi

echo "找到的 IPv4 地址:"
echo "$IPV4_ADDRESSES"
echo "---"

# --- 更新 /etc/hosts ---
echo "正在更新 ${HOSTS_FILE}..."

# 1. 从原始 hosts 文件复制不包含我们标记的行到临时文件
#    这样可以移除上次脚本添加的所有关于 gstatic.com 的条目
grep -vF "$MARKER" "$HOSTS_FILE" > "$TEMP_FILE" || true # 即使没有匹配也继续

# 2. 将新的映射行（带有标记）追加到临时文件
#    一个域名可能解析到多个IP，为每个IP都添加一条记录
ADDED_NEW_LINES=false
while IFS= read -r IP; do
  if [ -n "$IP" ]; then # 确保IP不是空行
    printf "%-16s %s %s\n" "$IP" "$DOMAIN_TO_MAP" "$MARKER" >> "$TEMP_FILE"
    ADDED_NEW_LINES=true
  fi
done <<< "$IPV4_ADDRESSES" # 使用 Here String 将多行 IP 输入循环

# 3. 检查临时文件是否与原文件不同，如果不同则替换
#    使用 cmp -s 安静地比较文件
if ! cmp -s "$HOSTS_FILE" "$TEMP_FILE" || [ "$ADDED_NEW_LINES" = false ]; then
    # 如果文件不同，或者本次未能成功获取IP（导致没有添加新行，需要确保旧行被移除）
    echo "检测到更改或需要清理旧条目，正在写入新配置..."
    # 可选：创建时间戳备份
    # cp "$HOSTS_FILE" "$HOSTS_FILE.bak_$(date +%s)"

    # 使用 mv 替换原文件
    if mv "$TEMP_FILE" "$HOSTS_FILE"; then
        # 确保文件权限正确（通常是 644）
        chmod 644 "$HOSTS_FILE"
        echo "${HOSTS_FILE} 更新成功。"
        # 清空 TEMP_FILE 变量，防止 trap 尝试删除已移动的文件
        TEMP_FILE=""
    else
        echo "错误: 移动临时文件到 ${HOSTS_FILE} 失败。请检查权限。" >&2
        # 让 trap 清理未移动的临时文件
        exit 1
    fi
else
    echo "${HOSTS_FILE} 无需更新。"
    # 让 trap 清理未更改的临时文件
fi

exit 0
