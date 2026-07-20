#!/usr/bin/env bash
# ======================================================
# ⚡ VPS 跨境网络全天候测绘探针 (VPS-Monitor-Pro) v1.0
# ======================================================

LOG_DIR="/root/vps_monitor_data"
SPEED_CSV="${LOG_DIR}/speed_log.csv"
TCPING_CSV="${LOG_DIR}/tcping_log.csv"

# 云端配置与本地自定义配置
CONFIG_FILE="${LOG_DIR}/nodes.conf"
REGION_CONF="${LOG_DIR}/region.conf"
CUSTOM_TCP="${LOG_DIR}/custom_tcp.list"
CUSTOM_SPEED="${LOG_DIR}/custom_speed.list"
REMOTE_CONFIG_URL="https://raw.githubusercontent.com/playfulsoul/vps-monitor-pro/main/nodes.conf"

# ================= 基础环境与初始化 =================
init_env() {
    mkdir -p "$LOG_DIR"
    
    if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
        echo "🔧 正在安装必要依赖 (jq, curl, cron)..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get install -y jq curl ping cron
        elif command -v yum &> /dev/null; then
            yum install -y jq curl iputils cronie
        fi
    fi

    if ! command -v tcping &> /dev/null && [ ! -f "${LOG_DIR}/tcping" ]; then
        echo "🔧 正在初始化轻量级 TCPing 引擎..."
        curl -sL "https://github.com/cloverstd/tcping/releases/download/v0.1.1/tcping-linux-amd64" -o "${LOG_DIR}/tcping"
        chmod +x "${LOG_DIR}/tcping"
    fi

    if ! command -v speedtest &> /dev/null; then
        echo "🔧 正在安装 Ookla 官方 Speedtest CLI 工具..."
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash &> /dev/null
        apt-get install -y speedtest &> /dev/null || yum install -y speedtest &> /dev/null
    fi

    if [ ! -f "$SPEED_CSV" ]; then
        echo "测试时间,测试节点类型,目标节点ID/名称,下载速度(Mbps),上传速度(Mbps),延迟(ms),CPU负载" > "$SPEED_CSV"
    fi
    if [ ! -f "$TCPING_CSV" ]; then
        echo "测试时间,目标名称,目标IP,端口,平均延迟(ms),丢包率(%)" > "$TCPING_CSV"
    fi

    curl -sL --connect-timeout 5 "$REMOTE_CONFIG_URL" -o "${CONFIG_FILE}.tmp"
    if [ -s "${CONFIG_FILE}.tmp" ]; then
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
}

get_cpu_load() {
    uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | tr -d ' '
}

# ================= 测试引擎模块 =================
run_tcping_test() {
    local now=$(date "+%Y-%m-%d %H:%M:%S")
    local tcping_bin=$(command -v tcping || echo "${LOG_DIR}/tcping")

    # 1. 跑云端标杆 IP
    if [ -f "$CONFIG_FILE" ]; then
        jq -c '.tcping_targets[]' "$CONFIG_FILE" 2>/dev/null | while read -r item; do
            local name=$(echo "$item" | jq -r '.name')
            local ip=$(echo "$item" | jq -r '.ip')
            local port=$(echo "$item" | jq -r '.port')

            local res=$("$tcping_bin" -c 20 -i 0.1 -g "$port" "$ip" 2>/dev/null)
            local loss=$(echo "$res" | grep -o '[0-9]*%' | tr -d '%' || echo "100")
            local avg_ping=$(echo "$res" | grep -o 'avg: [0-9.]*' | awk '{print $2}' || echo "0")
            echo "\"$now\",\"$name\",\"$ip\",$port,$avg_ping,$loss" >> "$TCPING_CSV"
        done
    fi

    # 2. 跑本地自定义 IP
    if [ -f "$CUSTOM_TCP" ]; then
        while IFS=',' read -r c_name c_ip c_port; do
            local res=$("$tcping_bin" -c 20 -i 0.1 -g "$c_port" "$c_ip" 2>/dev/null)
            local loss=$(echo "$res" | grep -o '[0-9]*%' | tr -d '%' || echo "100")
            local avg_ping=$(echo "$res" | grep -o 'avg: [0-9.]*' | awk '{print $2}' || echo "0")
            echo "\"$now\",\"[自定] $c_name\",\"$c_ip\",$c_port,$avg_ping,$loss" >> "$TCPING_CSV"
        done < "$CUSTOM_TCP"
    fi
}

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

run_speed_test() {
    local now=$(date "+%Y-%m-%d %H:%M:%S")
    local cpu_load=$(get_cpu_load)
    local region=$(cat "$REGION_CONF" 2>/dev/null || echo "beijing")

    # 1. 测 VPS 本地物理极速
    local local_res=$(test_single_speed "auto")
    if [ -n "$local_res" ]; then
        IFS=',' read -r d u p name <<< "$local_res"
        echo "\"$now\",\"VPS本地极速\",\"$name\",$d,$u,$p,$cpu_load" >> "$SPEED_CSV"
    fi

    # 2. 测 1+3 框架三网
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

    # 3. 测本地自定义 Speedtest 节点
    if [ -f "$CUSTOM_SPEED" ]; then
        while IFS=',' read -r c_name c_id; do
            local c_res=$(test_single_speed "$c_id")
            if [ -n "$c_res" ]; then
                IFS=',' read -r d u p name <<< "$c_res"
                echo "\"$now\",\"[自定] $c_name\",\"$name\",$d,$u,$p,$cpu_load" >> "$SPEED_CSV"
            else
                echo "\"$now\",\"[自定] $c_name\",\"节点失效(ID:$c_id)\",0,0,0,$cpu_load" >> "$SPEED_CSV"
            fi
        done < "$CUSTOM_SPEED"
    fi
}

run_cron_task() {
    init_env
    run_tcping_test
    run_speed_test
}

# ================= 任务调度与菜单管理模块 =================
setup_cron() {
    crontab -l 2>/dev/null | grep -v "vps-monitor-pro.sh" > /tmp/cron_bak
    echo "0 1-17/2 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    echo "0 18-23 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    echo "0 0 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    crontab /tmp/cron_bak
    rm -f /tmp/cron_bak
    echo "✅ 自动化 Cron 定时任务配置完成！(白天2H/次, 晚高峰1H/次)"
}

stop_cron() {
    crontab -l 2>/dev/null | grep -v "vps-monitor-pro.sh" | crontab -
    echo "🛑 已成功停止并注销所有自动化监控任务。"
}

change_region() {
    clear
    echo "======================================================"
    echo "🎯 请选择 '1+3' 测速核心大区:"
    echo "  1. 华北/北京枢纽"
    echo "  2. 华东/上海枢纽"
    echo "  3. 华南/广州枢纽"
    echo "======================================================"
    read -p "请输入对应的操作数字 [1-3]: " rc
    case "$rc" in
        1) echo "beijing" > "$REGION_CONF"; echo "✅ 已切换至: 华北/北京枢纽" ;;
        2) echo "shanghai" > "$REGION_CONF"; echo "✅ 已切换至: 华东/上海枢纽" ;;
        3) echo "guangzhou" > "$REGION_CONF"; echo "✅ 已切换至: 华南/广州枢纽" ;;
        *) echo "❌ 输入无效，保持原有设置。" ;;
    esac
    sleep 1.5
}

manage_custom_targets() {
    clear
    local tcp_count=$(wc -l < "$CUSTOM_TCP" 2>/dev/null || echo "0")
    local spd_count=$(wc -l < "$CUSTOM_SPEED" 2>/dev/null || echo "0")
    
    echo "======================================================"
    echo "🛠️ 自定义 24 小时监控目标管理"
    echo "======================================================"
    echo "当前已挂载 - 自定义 IP: $tcp_count 个 | 自定义节点: $spd_count 个"
    echo "------------------------------------------------------"
    echo "  1. ➕ 添加自定义 TCPing 目标 (测丢包/延迟)"
    echo "  2. ➕ 添加自定义 Speedtest 节点 (测带宽, 需提供ID)"
    echo "  3. 🗑️ 清空所有自定义目标"
    echo "  0. ↩️ 返回主菜单"
    echo "======================================================"
    read -p "请选择操作 [0-3]: " cc
    case "$cc" in
        1)
            echo ""
            read -p "👉 请输入目标名称 (例: 家里宽带): " c_name
            read -p "👉 请输入目标 IP 或 域名: " c_ip
            read -p "👉 请输入测试端口 (留空默认 80): " c_port
            c_port=${c_port:-80}
            if [ -n "$c_name" ] && [ -n "$c_ip" ]; then
                echo "$c_name,$c_ip,$c_port" >> "$CUSTOM_TCP"
                echo "✅ 已成功追加 TCPing 目标: $c_name ($c_ip:$c_port)"
            else
                echo "❌ 输入为空，已取消。"
            fi
            sleep 1.5
            manage_custom_targets
            ;;
        2)
            echo ""
            read -p "👉 请输入节点名称 (例: 洛杉矶): " s_name
            read -p "👉 请输入 Speedtest Server ID: " s_id
            if [ -n "$s_name" ] && [ -n "$s_id" ]; then
                echo "$s_name,$s_id" >> "$CUSTOM_SPEED"
                echo "✅ 已成功追加测速节点: $s_name (ID: $s_id)"
            else
                echo "❌ 输入为空，已取消。"
            fi
            sleep 1.5
            manage_custom_targets
            ;;
        3)
            rm -f "$CUSTOM_TCP" "$CUSTOM_SPEED"
            echo "🧹 所有自定义目标已清空！"
            sleep 1.5
            manage_custom_targets
            ;;
        0) return ;;
        *) manage_custom_targets ;;
    esac
}

show_menu() {
    clear
    local cron_status="未运行"
    if crontab -l 2>/dev/null | grep -q "vps-monitor-pro.sh"; then
        cron_status="运行中"
    fi
    
    local tz=$(date +"%Z %z")
    local current_region=$(cat "$REGION_CONF" 2>/dev/null || echo "beijing")
    local region_name="华北/北京枢纽"
    if [ "$current_region" == "shanghai" ]; then region_name="华东/上海枢纽"; fi
    if [ "$current_region" == "guangzhou" ]; then region_name="华南/广州枢纽"; fi

    local c_total=$(($(wc -l < "$CUSTOM_TCP" 2>/dev/null || echo 0) + $(wc -l < "$CUSTOM_SPEED" 2>/dev/null || echo 0)))
    local custom_badge=""
    if [ "$c_total" -gt 0 ]; then custom_badge=" (已挂载 $c_total 个)"; fi

    echo "======================================================"
    echo "⚡ VPS 跨境网络全天候测绘探针 (VPS-Monitor-Pro) v1.0"
    echo "======================================================"
    echo "  [▶️ 监控状态: $cron_status] | [🕒 系统时区: $tz]"
    echo "======================================================"
    echo "  [ 核心控制 ]"
    echo "  1. 🚀 部署并启动全自动监控 (白天2H/次, 晚高峰1H/次)"
    echo "  2. 🛑 停止所有监控任务"
    echo ""
    echo "  [ 参数定制 ]"
    echo "  3. 🎯 测速城市设定 (当前: 1+3 模式 - $region_name)"
    echo "  4. 🛠️ 管理自定义监控目标$custom_badge"
    echo "  5. ⚙️ 修改监控执行频率 (敬请期待)"
    echo ""
    echo "  [ 数据输出 ]"
    echo "  6. 📊 立刻执行一次手动综合探测"
    echo "  7. 📉 查看最近报告 (测速 与 TCPing)"
    echo "  8. 📥 导出原始 CSV 数据 (打包至当前目录)"
    echo ""
    echo "  [ 系统维护 ]"
    echo "  9. 🧹 清理过期日志与缓存"
    echo "  0. 退出脚本"
    echo "======================================================"
    read -p "请输入对应的操作数字 [0-9]: " choice
    
    case "$choice" in
        1) init_env; setup_cron; read -p "按回车键继续..." ;;
        2) stop_cron; read -p "按回车键继续..." ;;
        3) change_region ;;
        4) manage_custom_targets ;;
        5) echo "⏳ 高级自定义频率模块开发中..."; read -p "按回车键继续..." ;;
        6) 
            echo "⌛ 正在执行综合测试，请耐心等待 (约需2-3分钟)..."
            run_cron_task
            echo "✅ 测试完成！数据已写入日志。"
            read -p "按回车键继续..."
            ;;
        7) 
            echo "=== 最近 6 条带宽测速记录 ==="
            tail -n 7 "$SPEED_CSV" 2>/dev/null | column -s, -t || echo "暂无记录"
            echo -e "\n=== 最近 9 条 TCPing 记录 ==="
            tail -n 10 "$TCPING_CSV" 2>/dev/null | column -s, -t || echo "暂无记录"
            read -p "按回车键继续..."
            ;;
        8) 
            tar -czf /root/vps_monitor_export_$(date +"%Y%m%d").tar.gz -C "$LOG_DIR" speed_log.csv tcping_log.csv 2>/dev/null
            echo "✅ 导出成功！文件已保存为 /root/vps_monitor_export_*.tar.gz"
            read -p "按回车键继续..."
            ;;
        9) 
            rm -f "$SPEED_CSV" "$TCPING_CSV"
            echo "🧹 历史测速数据已清空。"
            read -p "按回车键继续..."
            ;;
        0) exit 0 ;;
        *) echo "输入无效，请重新选择！"; sleep 1 ;;
    esac
}

if [ "$1" == "--cron" ]; then
    run_cron_task
else
    init_env
    while true; do show_menu; done
fi
