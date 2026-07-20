#!/usr/bin/env bash
# ======================================================
# ⚡ VPS 跨境网络全天候测绘探针 (VPS-Monitor-Pro) v1.0
# ======================================================

LOG_DIR="/root/vps_monitor_data"
SPEED_CSV="${LOG_DIR}/speed_log.csv"
TCPING_CSV="${LOG_DIR}/tcping_log.csv"
CONFIG_FILE="${LOG_DIR}/nodes.conf"
# 已经更正为全新的项目仓库地址
REMOTE_CONFIG_URL="https://raw.githubusercontent.com/playfulsoul/vps-monitor-pro/main/nodes.conf"

# 初始化环境与目录
init_env() {
    mkdir -p "$LOG_DIR"
    
    # 自动安装基础软件依赖
    if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
        echo "🔧 正在安装必要依赖 (jq, curl)..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get install -y jq curl ping cron
        elif command -v yum &> /dev/null; then
            yum install -y jq curl iputils cronie
        fi
    fi

    # 自动下载或配置轻量级 tcping
    if ! command -v tcping &> /dev/null && [ ! -f "${LOG_DIR}/tcping" ]; then
        echo "🔧 正在初始化轻量级 TCPing 引擎..."
        curl -sL "https://github.com/cloverstd/tcping/releases/download/v0.1.1/tcping-linux-amd64" -o "${LOG_DIR}/tcping"
        chmod +x "${LOG_DIR}/tcping"
    fi

    # 自动安装 Ookla Speedtest CLI
    if ! command -v speedtest &> /dev/null; then
        echo "🔧 正在安装 Ookla 官方 Speedtest CLI 工具..."
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash &> /dev/null
        apt-get install -y speedtest &> /dev/null || yum install -y speedtest &> /dev/null
    fi

    # 初始化 CSV 表头
    if [ ! -f "$SPEED_CSV" ]; then
        echo "测试时间,测试节点类型,目标节点ID/名称,下载速度(Mbps),上传速度(Mbps),延迟(ms),CPU负载" > "$SPEED_CSV"
    fi
    if [ ! -f "$TCPING_CSV" ]; then
        echo "测试时间,目标名称,目标IP,端口,平均延迟(ms),丢包率(%)" > "$TCPING_CSV"
    fi

    # 同步云端最新节点配置 (失败则回退至本地缓存)
    curl -sL --connect-timeout 5 "$REMOTE_CONFIG_URL" -o "${CONFIG_FILE}.tmp"
    if [ -s "${CONFIG_FILE}.tmp" ]; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
}

# 抓取 CPU 负载
get_cpu_load() {
    uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | tr -d ' '
}

# 执行 TCPing 测试逻辑
run_tcping_test() {
    local now=$(date "+%Y-%m-%d %H:%M:%S")
    local tcping_bin=$(command -v tcping || echo "${LOG_DIR}/tcping")

    if [ ! -f "$CONFIG_FILE" ]; then return; fi

    jq -c '.tcping_targets[]' "$CONFIG_FILE" 2>/dev/null | while read -r item; do
        local name=$(echo "$item" | jq -r '.name')
        local ip=$(echo "$item" | jq -r '.ip')
        local port=$(echo "$item" | jq -r '.port')

        # 使用 tcping 发送 20 个探测包
        local res=$("$tcping_bin" -c 20 -i 0.1 -g "$port" "$ip" 2>/dev/null)
        local loss=$(echo "$res" | grep -o '[0-9]*%' | tr -d '%' || echo "100")
        local avg_ping=$(echo "$res" | grep -o 'avg: [0-9.]*' | awk '{print $2}' || echo "0")

        echo "\"$now\",\"$name\",\"$ip\",$port,$avg_ping,$loss" >> "$TCPING_CSV"
    done
}

# 带有容错降级的单节点测速函数
test_single_speed() {
    local node_id=$1
    local res=""
    if [ "$node_id" == "auto" ]; then
        res=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)
    else
        res=$(speedtest --accept-license --accept-gdpr --server-id="$node_id" -f json 2>/dev/null)
    fi

    if [ -n "$res" ] && ! echo "$res" | grep -q "error"; then
        local down=$(echo "$res" | jq '(.download.bandwidth * 8) / 1000000' | xargs printf "%.2f")
        local up=$(echo "$res" | jq '(.upload.bandwidth * 8) / 1000000' | xargs printf "%.2f")
        local ping=$(echo "$res" | jq '.ping.latency' | xargs printf "%.2f")
        local server_name=$(echo "$res" | jq -r '.server.name + "-" + .server.location')
        echo "$down,$up,$ping,$server_name"
        return 0
    fi
    return 1
}

# 执行“1+3”标准测速模型
run_speed_test() {
    local now=$(date "+%Y-%m-%d %H:%M:%S")
    local cpu_load=$(get_cpu_load)
    local region="beijing" # 默认采用北京/华北枢纽

    # 1. 测 VPS 本地物理极速
    local local_res=$(test_single_speed "auto")
    if [ -n "$local_res" ]; then
        IFS=',' read -r d u p name <<< "$local_res"
        echo "\"$now\",\"VPS本地极速\",\"$name\",$d,$u,$p,$cpu_load" >> "$SPEED_CSV"
    fi

    # 2. 依次测试中国三网 (带着主备容错轮询)
    for isp in telecom unicom mobile; do
        local node_pool=$(jq -r ".speedtest_nodes.${region}.${isp}[]" "$CONFIG_FILE" 2>/dev/null)
        local success=0
        for node_id in $node_pool; do
            local isp_res=$(test_single_speed "$node_id")
            if [ -n "$isp_res" ]; then
                IFS=',' read -r d u p name <<< "$isp_res"
                echo "\"$now\",\"${region}-${isp}\",\"$name\",$d,$u,$p,$cpu_load" >> "$SPEED_CSV"
                success=1
                break
            fi
        done
        if [ $success -eq 0 ]; then
            echo "\"$now\",\"${region}-${isp}\",\"节点响应失败\",0,0,0,$cpu_load" >> "$SPEED_CSV"
        fi
    done
}

# 自动化执行入口（供 Cron 调用）
run_cron_task() {
    init_env
    run_tcping_test
    run_speed_test
}

# 设置与更新 Cron 规则 (白天2H/次，晚高峰19-24点1H/次)
setup_cron() {
    crontab -l 2>/dev/null | grep -v "vps-monitor-pro.sh" > /tmp/cron_bak
    echo "0 1-17/2 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    echo "0 18-23 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    echo "0 0 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    crontab /tmp/cron_bak
    rm -f /tmp/cron_bak
    echo "✅ 自动化 Cron 定时任务配置完成！"
    echo "   📅 白天时段 (01:00-17:00): 每 2 小时测一次"
    echo "   🔥 晚高峰期 (18:00-24:00): 每 1 小时测一次"
}

# 停止并清理 Cron 任务
stop_cron() {
    crontab -l 2>/dev/null | grep -v "vps-monitor-pro.sh" | crontab -
    echo "🛑 已成功停止并注销所有自动化监控任务。"
}

# 交互菜单界面
show_menu() {
    clear
    echo "======================================================"
    echo "⚡ VPS 跨境网络全天候测绘探针 (VPS-Monitor-Pro) v1.0"
    echo "======================================================"
    echo "  1. 🚀 部署并开启全自动监控 (白天2H/次, 晚高峰1H/次)"
    echo "  2. 🛑 停止所有监控任务"
    echo "------------------------------------------------------"
    echo "  3. 📊 立刻手动执行一次完整综合测试"
    echo "  4. 📈 查看最新 5 条带宽测速报告"
    echo "  5. 📉 查看最新 5 条 TCPing 延迟丢包报告"
    echo "------------------------------------------------------"
    echo "  0. 退出脚本"
    echo "======================================================"
    read -p "请输入对应的操作数字 [0-5]: " choice
    case "$choice" in
        1) init_env; setup_cron; read -p "按回车键继续..." ;;
        2) stop_cron; read -p "按回车键继续..." ;;
        3) 
            echo "⌛ 正在执行综合测试，请稍候..."
            run_cron_task
            echo "✅ 测试完成！数据已写入日志。"
            read -p "按回车键继续..."
            ;;
        4) 
            echo "=== 最近 5 条带宽测速记录 ==="
            tail -n 6 "$SPEED_CSV" 2>/dev/null || echo "暂无记录"
            read -p "按回车键继续..."
            ;;
        5) 
            echo "=== 最近 5 条 TCPing 记录 ==="
            tail -n 10 "$TCPING_CSV" 2>/dev/null || echo "暂无记录"
            read -p "按回车键继续..."
            ;;
        0) exit 0 ;;
        *) echo "输入无效，请重新选择！"; sleep 1; show_menu ;;
    esac
}

# 命令行参数解析（判断是否由 Cron 触发）
if [ "$1" == "--cron" ]; then
    run_cron_task
else
    init_env
    while true; do show_menu; done
fi
