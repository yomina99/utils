#!/bin/bash
set -e # 如果任何命令失败，则立即退出
#set -x # 取消注释以进行调试

# --- 配置 ---
DOMAIN_LIST_URL="https://raw.githubusercontent.com/yomina99/utils/refs/heads/main/domains.txt"

HOSTS_FILE="/etc/hosts"
BASE_MARKER="# Managed by update_hosts_script"
TEMP_FILE=$(mktemp)
FINAL_HOSTS_CONTENT=$(mktemp)
DOMAINS_TO_MANAGE=() # 初始化为空数组

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

# --- 依赖检查 (dig and curl/wget) ---
MISSING_DEPS=()
if ! command -v dig &> /dev/null; then MISSING_DEPS+=("dig"); fi
if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then MISSING_DEPS+=("curl/wget"); fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "错误: 缺少依赖: ${MISSING_DEPS[*]}" >&2
    # 尝试自动安装 (根据需要调整包名)
    INSTALL_PACKAGES=""
    if [[ " ${MISSING_DEPS[*]} " =~ " dig " ]]; then
        if command -v apt-get &> /dev/null; then INSTALL_PACKAGES+=" dnsutils"; \
        elif command -v yum &> /dev/null; then INSTALL_PACKAGES+=" bind-utils"; fi
    fi
     if [[ " ${MISSING_DEPS[*]} " =~ " curl/wget " ]]; then
        if command -v apt-get &> /dev/null; then INSTALL_PACKAGES+=" curl"; \
        elif command -v yum &> /dev/null; then INSTALL_PACKAGES+=" curl"; fi
    fi

    if [ -n "$INSTALL_PACKAGES" ]; then
        echo "正在尝试自动安装: $INSTALL_PACKAGES ..." >&2
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y $INSTALL_PACKAGES
        elif command -v yum &> /dev/null; then
            yum install -y $INSTALL_PACKAGES
        fi
        # 重新检查依赖
        if ! command -v dig &> /dev/null; then echo "错误: dig 安装后仍未找到。" >&2; exit 1; fi
        if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then echo "错误: curl/wget 安装后仍未找到。" >&2; exit 1; fi
    else
        echo "无法确定包管理器或所需包名。请手动安装 ${MISSING_DEPS[*]}。" >&2
        exit 1
    fi
fi

# 确定下载器
DOWNLOADER=""
if command -v curl &> /dev/null; then DOWNLOADER="curl"; elif command -v wget &> /dev/null; then DOWNLOADER="wget"; fi


# --- 函数：下载并处理域名列表 ---
# 输出 (stdout): 清理后的域名列表 (一个域名一行)
# 返回: 0 成功, 1 失败
fetch_and_process_domain_list() {
    local url="$1"
    local raw_list
    local processed_list

    echo "正在从 $url 获取域名列表..." >&2
    # 下载列表内容
    if [ "$DOWNLOADER" == "curl" ]; then
        # curl: -f fail fast, -s silent, -S show error, -L follow redirects
        raw_list=$(curl -fsSL "$url") || { echo "错误: 使用 curl 下载域名列表失败。" >&2; return 1; }
    elif [ "$DOWNLOADER" == "wget" ]; then
        # wget: -q quiet, -O - output to stdout
        raw_list=$(wget -q -O - "$url") || { echo "错误: 使用 wget 下载域名列表失败。" >&2; return 1; }
    else
         echo "错误: 未找到有效的下载器 (curl/wget)。" >&2
         return 1
    fi

    # 处理列表: 移除注释行 (# 开头) 和空行，移除行首/行尾空格
    processed_list=$(echo "$raw_list" | grep -vE '^\s*#|^\s*$' | sed 's/^[ \t]*//;s/[ \t]*$//')

    if [ -z "$processed_list" ]; then
        echo "警告: 下载的域名列表为空或只包含注释/空行。" >&2
        # 可以选择是返回成功 (空列表) 还是失败。这里返回成功，让主逻辑处理空列表。
        return 0
    fi

    # 将处理后的列表输出到 stdout
    echo "$processed_list"
    return 0
}


# --- 函数：解析单个域名并返回 hosts 条目 ---
# (这个函数保持不变)
resolve_and_format_domain() {
    # ... (代码和之前一样) ...
    local domain="$1"
    local marker_comment="${BASE_MARKER} for ${domain}"
    local ipv4_addresses
    local formatted_lines=""
    local ip

    echo "  正在查询 ${domain} 的 IPv4 地址..." >&2
    ipv4_addresses=$(dig +short "$domain" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)

    if [ -z "$ipv4_addresses" ]; then
      echo "  警告: 未能解析 ${domain} 的 IPv4 地址。" >&2
      return 1
    fi

    echo "  找到的 ${domain} 的 IPv4 地址:" >&2
    echo "$ipv4_addresses" | sed 's/^/    /' >&2

    while IFS= read -r ip; do
      if [ -n "$ip" ]; then
        formatted_lines+=$(printf "%-16s %s %s\n" "$ip" "$domain" "$marker_comment")
      fi
    done <<< "$ipv4_addresses"

    echo "$formatted_lines"
    return 0
}

# --- 主逻辑 ---
echo "开始更新 hosts 文件: ${HOSTS_FILE}" >&2

# 0. 获取域名列表
clean_domain_list=$(fetch_and_process_domain_list "$DOMAIN_LIST_URL") || {
    echo "错误: 无法获取或处理域名列表，脚本终止。" >&2
    exit 1
}

# 如果列表为空，警告并退出 (或者可以选择继续执行清理逻辑)
if [ -z "$clean_domain_list" ]; then
    echo "警告: 获取到的域名列表为空，本次不添加任何新条目，但会执行清理。" >&2
    # 如果希望列表为空时不执行任何操作，可以在这里 exit 0
fi

# 将处理后的域名列表读入数组 (需要 Bash 4+)
# mapfile -t DOMAINS_TO_MANAGE <<< "$clean_domain_list"
# 或者兼容性更好的方式：
while IFS= read -r line; do
    DOMAINS_TO_MANAGE+=("$line")
done <<< "$clean_domain_list"


# 检查数组是否为空 (以防万一)
if [ ${#DOMAINS_TO_MANAGE[@]} -eq 0 ] && [ -n "$clean_domain_list" ]; then
     echo "警告: 处理后的域名列表未能成功加载到数组中。" >&2
     # 根据需要决定是否退出
fi


# 1. 清理旧条目
echo "正在清理旧的受管理条目..." >&2
grep -vF "$BASE_MARKER" "$HOSTS_FILE" > "$FINAL_HOSTS_CONTENT" || {
    echo "注意: ${HOSTS_FILE} 为空或读取时出错，将创建新文件。" >&2
}

# 2. 解析并收集新条目 (仅当数组非空时)
echo "正在解析并添加新的域名映射 (共 ${#DOMAINS_TO_MANAGE[@]} 个域名)..." >&2
ANY_SUCCESS=false
ALL_RESOLVED_LINES=""

if [ ${#DOMAINS_TO_MANAGE[@]} -gt 0 ]; then
    for domain_to_process in "${DOMAINS_TO_MANAGE[@]}"; do
        if resolved_lines=$(resolve_and_format_domain "$domain_to_process"); then
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
    ALL_RESOLVED_LINES=$(echo "$ALL_RESOLVED_LINES" | sed '/^$/d') # 清理尾部空行
else
     echo "没有有效的域名需要处理。" >&2
fi


# 3. 写入文件 (如果需要)
if [ "$ANY_SUCCESS" = true ] && [ -n "$ALL_RESOLVED_LINES" ]; then
    echo "---" >&2
    echo "将添加以下行到 ${HOSTS_FILE}:" >&2
    echo "$ALL_RESOLVED_LINES" >&2
    echo "---" >&2
    echo "$ALL_RESOLVED_LINES" >> "$FINAL_HOSTS_CONTENT"
elif [ "$ANY_SUCCESS" = false ] && [ ${#DOMAINS_TO_MANAGE[@]} -gt 0 ]; then
     # 如果尝试处理了域名但全部失败
     echo "警告: 未能成功解析任何指定的域名。将仅执行清理操作。" >&2
fi


# 4. 比较并替换
echo "正在比较文件内容..." >&2
if ! cmp -s "$HOSTS_FILE" "$FINAL_HOSTS_CONTENT"; then
    echo "检测到更改，正在写入新配置..." >&2
    if cat "$FINAL_HOSTS_CONTENT" > "$HOSTS_FILE"; then
        chmod 644 "$HOSTS_FILE"
        echo "${HOSTS_FILE} 更新成功。" >&2
    else
        echo "错误: 写入 ${HOSTS_FILE} 失败。" >&2
        exit 1
    fi
else
    echo "${HOSTS_FILE} 无需更新。" >&2
fi

exit 0
