#!/bin/bash
set -e # 如果任何命令失败，则立即退出
#set -x # 取消注释以进行调试

# --- 配置 ---
DOMAINS_TO_MANAGE=(
    "gstatic.com"
    "www.gstatic.com"
    # 在这里添加更多域名
)
HOSTS_FILE="/etc/hosts"
BASE_MARKER="# Managed by update_hosts_script"
TEMP_FILE=$(mktemp)
FINAL_HOSTS_CONTENT=$(mktemp)

# --- 清理函数 ---
cleanup() {
  rm -f "$TEMP_FILE" "$FINAL_HOSTS_CONTENT"
}
trap cleanup EXIT ERR

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 此脚本必须以 root 权限运行。" >&2
  exit 1
fi

# --- 依赖检查 ---
if ! command -v dig &> /dev/null; then
    echo "错误: 未找到 'dig' 命令。" >&2
    if command -v apt-get &> /dev/null; then
        echo "正在尝试使用 apt 安装 dnsutils..." >&2 # 输出到 stderr
        apt-get update && apt-get install -y dnsutils
    elif command -v yum &> /dev/null; then
        echo "正在尝试使用 yum 安装 bind-utils..." >&2 # 输出到 stderr
        yum install -y bind-utils
    else
        echo "无法自动安装 'dig'。请手动安装。" >&2
        exit 1
    fi
    if ! command -v dig &> /dev/null; then
       echo "错误: 安装 'dig' 后仍未找到命令。" >&2
       exit 1
    fi
fi

# --- 函数：解析单个域名并返回 hosts 条目 ---
# 输入: $1 - 域名
# 输出 (stdout): 符合 hosts 文件格式的行 (包含标记)
# 输出 (stderr): 调试/状态信息
# 返回: 0 表示成功获取IP, 1 表示失败
resolve_and_format_domain() {
    local domain="$1"
    local marker_comment="${BASE_MARKER} for ${domain}"
    local ipv4_addresses
    local formatted_lines=""
    local ip

    # 将调试信息输出到 stderr (>&2)
    echo "  正在查询 ${domain} 的 IPv4 地址..." >&2
    ipv4_addresses=$(dig +short "$domain" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)

    if [ -z "$ipv4_addresses" ]; then
      # 将警告信息输出到 stderr (>&2)
      echo "  警告: 未能解析 ${domain} 的 IPv4 地址。" >&2
      return 1 # 返回失败状态
    fi

    # 将调试信息输出到 stderr (>&2)
    echo "  找到的 ${domain} 的 IPv4 地址:" >&2
    echo "$ipv4_addresses" | sed 's/^/    /' >&2 # 缩进输出到 stderr

    while IFS= read -r ip; do
      if [ -n "$ip" ]; then
        # 使用 printf 构建要输出到 stdout 的行
        formatted_lines+=$(printf "%-16s %s %s\n" "$ip" "$domain" "$marker_comment")
      fi
    done <<< "$ipv4_addresses"

    # 仅将最终格式化的 hosts 行输出到 stdout
    echo "$formatted_lines"
    return 0 # 返回成功状态
}

# --- 主逻辑 ---
echo "开始更新 hosts 文件: ${HOSTS_FILE}" >&2 # 输出到 stderr

# 1. 清理旧条目
echo "正在清理旧的受管理条目..." >&2 # 输出到 stderr
grep -vF "$BASE_MARKER" "$HOSTS_FILE" > "$FINAL_HOSTS_CONTENT" || {
    echo "注意: ${HOSTS_FILE} 为空或读取时出错，将创建新文件。" >&2 # 输出到 stderr
}

# 2. 解析并收集新条目
echo "正在解析并添加新的域名映射..." >&2 # 输出到 stderr
ANY_SUCCESS=false
ALL_RESOLVED_LINES=""

for domain_to_process in "${DOMAINS_TO_MANAGE[@]}"; do
    # 调用函数，捕获 stdout (hosts 行)，stderr (调试信息) 会直接显示
    if resolved_lines=$(resolve_and_format_domain "$domain_to_process"); then
        # 检查捕获的内容是否非空
        if [ -n "$resolved_lines" ]; then
            ALL_RESOLVED_LINES+="${resolved_lines}"$'\n'
            ANY_SUCCESS=true
        else
             echo "  注意: 域名 ${domain_to_process} 解析成功但未返回有效 IP 地址或格式化失败。" >&2
        fi
    else
        echo "  处理域名 ${domain_to_process} 失败，跳过。" >&2
    fi
done

# 去除可能因换行符产生的尾部空行
ALL_RESOLVED_LINES=$(echo "$ALL_RESOLVED_LINES" | sed '/^$/d')

# 3. 写入文件 (如果需要)
if [ "$ANY_SUCCESS" = true ] && [ -n "$ALL_RESOLVED_LINES" ]; then
    echo "---" >&2
    echo "将添加以下行到 ${HOSTS_FILE}:" >&2
    echo "$ALL_RESOLVED_LINES" >&2 # 显示将要添加的内容到 stderr
    echo "---" >&2
    # 将所有收集到的新行追加到最终内容文件
    echo "$ALL_RESOLVED_LINES" >> "$FINAL_HOSTS_CONTENT"
elif [ "$ANY_SUCCESS" = false ]; then
     echo "警告: 未能成功解析任何指定的域名。将仅执行清理操作。" >&2
fi

# 4. 比较并替换
echo "正在比较文件内容..." >&2 # 输出到 stderr
if ! cmp -s "$HOSTS_FILE" "$FINAL_HOSTS_CONTENT"; then
    echo "检测到更改，正在写入新配置..." >&2 # 输出到 stderr
    if cat "$FINAL_HOSTS_CONTENT" > "$HOSTS_FILE"; then
        chmod 644 "$HOSTS_FILE"
        echo "${HOSTS_FILE} 更新成功。" >&2 # 输出到 stderr
    else
        echo "错误: 写入 ${HOSTS_FILE} 失败。" >&2
        exit 1
    fi
else
    echo "${HOSTS_FILE} 无需更新。" >&2 # 输出到 stderr
fi

exit 0
