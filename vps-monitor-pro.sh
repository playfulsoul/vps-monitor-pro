#!/usr/bin/env bash
# ======================================================
# ⚡ VPS 跨境网络全天候测绘探针 (VPS-Monitor-Pro) v1.0.3
# ======================================================

LOG_DIR="/root/vps_monitor_data"
SPEED_CSV="${LOG_DIR}/speed_log.csv"
TCPING_CSV="${LOG_DIR}/tcping_log.csv"
CONFIG_FILE="${LOG_DIR}/nodes.conf"
REGION_CONF="${LOG_DIR}/region.conf"
FREQ_CONF="${LOG_DIR}/freq.conf"
END_TIME_CONF="${LOG_DIR}/end_time.conf"
CUSTOM_TCP="${LOG_DIR}/custom_tcp.list"
CUSTOM_SPEED="${LOG_DIR}/custom_speed.list"
REMOTE_CONFIG_URL="https://raw.githubusercontent.com/playfulsoul/vps-monitor-pro/main/nodes.conf"

init_env() {
    mkdir -p "$LOG_DIR"
    
    # ⚠️ 核心修复：强制对齐北京时间 (Asia/Shanghai)
    if command -v timedatectl &> /dev/null; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null
    fi

    if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
        echo "🔧 正在安装必要依赖 (jq, curl, cron)..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get install -y jq curl ping cron tzdata
        elif command -v yum &> /dev/null; then
            yum install -y jq curl iputils cronie tzdata
        fi
    fi
    if ! command -v tcping &> /dev/null && [ ! -f "${LOG_DIR}/tcping" ]; then
        curl -sL "https://github.com/cloverstd/tcping/releases/download/v0.1.1/tcping-linux-amd64" -o "${LOG_DIR}/tcping"
        chmod +x "${LOG_DIR}/tcping"
    fi
    if ! command -v speedtest &> /dev/null; then
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
    if [ -s "${CONFIG_FILE}.tmp" ]; then mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"; fi
}

get_cpu_load() {
    uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | tr -d ' '
}

run_tcping_test() {
    local now=$(date "+%Y-%m-%d %H:%M:%S")
    local tcping_bin=$(command -v tcping || echo "${LOG_DIR}/tcping")

    if [ -f "$CONFIG_FILE" ]; then
        jq -c '.tcping_targets[]' "$CONFIG_FILE" 2>/dev/null | while read -r item; do
            local name=$(echo "$item" | jq -r '.name')
            local ip=$(echo "$item" | jq -r '.ip')
            local port=$(echo "$item" | jq -r '.port')

            local res=$("$tcping_bin" -c 20 -i 0.1 "$ip" "$port" 2>/dev/null)
            local loss=$(echo "$res" | grep 'packet loss' | awk -F'%' '{print $1}' | awk '{print $NF}')
            local avg_ping=$(echo "$res" | grep 'min/avg/max' | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | tr -d ' ')
            
            [ -z "$loss" ] && loss="100"
            [ -z "$avg_ping" ] && avg_ping="0"
            echo "\"$now\",\"$name\",\"$ip\",$port,$avg_ping,$loss" >> "$TCPING_CSV"
        done
    fi

    if [ -f "$CUSTOM_TCP" ]; then
        while IFS=',' read -r c_name c_ip c_port; do
            local res=$("$tcping_bin" -c 20 -i 0.1 "$c_ip" "$c_port" 2>/dev/null)
            local loss=$(echo "$res" | grep 'packet loss' | awk -F'%' '{print $1}' | awk '{print $NF}')
            local avg_ping=$(echo "$res" | grep 'min/avg/max' | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | tr -d ' ')
            [ -z "$loss" ] && loss="100"
            [ -z "$avg_ping" ] && avg_ping="0"
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

    local local_res=$(test_single_speed "auto")
    if [ -n "$local_res" ]; then
        IFS=',' read -r d u p name <<< "$local_res"
        echo "\"$now\",\"VPS本地极速\",\"$name\",$d,$u,$p,$cpu_load" >> "$SPEED_CSV"
    fi

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
    if [ -f "$END_TIME_CONF" ]; then
        local end_ts=$(cat "$END_TIME_CONF")
        if [ "$end_ts" -gt 0 ]; then
            local now_ts=$(date +%s)
            if [ "$now_ts" -ge "$end_ts" ]; then
                stop_cron > /dev/null
                tar -czf /root/vps_monitor_AutoExport_$(date +"%Y%m%d").tar.gz -C "$LOG_DIR" speed_log.csv tcping_log.csv 2>/dev/null
                rm -f "$END_TIME_CONF"
                exit 0
            fi
        fi
    fi
    run_tcping_test
    run_speed_test
}

setup_cron() {
    local freq=$(cat "$FREQ_CONF" 2>/dev/null || echo "1")
    crontab -l 2>/dev/null | grep -v "vps-monitor-pro.sh" > /tmp/cron_bak
    
    if [ "$freq" == "2" ]; then
        echo "0 * * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    elif [ "$freq" == "3" ]; then
        echo "0 */4 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    else
        echo "0 1-17/2 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
        echo "0 18-23 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
        echo "0 0 * * * /bin/bash $(readlink -f "$0") --cron >/dev/null 2>&1" >> /tmp/cron_bak
    fi
    crontab /tmp/cron_bak
    rm -f /tmp/cron_bak
}

stop_cron() {
    crontab -l 2>/dev/null | grep -v "vps-monitor-pro.sh" | crontab -
    echo "🛑 已成功停止并注销后台监控任务。"
}

wizard_setup() {
    clear
    echo "======================================================"
    echo "🚀 VPS-Monitor-Pro | 自动化监控部署向导"
    echo "======================================================"
    
    echo "[1/3] 请选择 '1+3' 核心测速大区:"
    echo "  1. 华北/北京枢纽"
    echo "  2. 华东/上海枢纽"
    echo "  3. 华南/广州枢纽"
    read -p "请输入对应的操作数字 [1-3] (默认1): " rc
    case "${rc:-1}" in
        2) echo "shanghai" > "$REGION_CONF"; echo "✅ 已设定: 华东/上海枢纽" ;;
        3) echo "guangzhou" > "$REGION_CONF"; echo "✅ 已设定: 华南/广州枢纽" ;;
        *) echo "beijing" > "$REGION_CONF"; echo "✅ 已设定: 华北/北京枢纽" ;;
    esac
    echo "------------------------------------------------------"

    echo "[2/3] 请选择自动化监控频率 (已自动对齐北京时间):"
    echo "  1. 🌟 智能黄金频率 (白天2H/次, 晚高峰18-23点1H/次)"
    echo "  2. 🔥 极限高频模式 (全天 24 小时，每 1 小时/次)"
    echo "  3. ☕ 佛系低频模式 (全天 24 小时，每 4 小时/次)"
    read -p "请输入对应的操作数字 [1-3] (默认1): " fc
    case "${fc:-1}" in
        2|3) echo "$fc" > "$FREQ_CONF" ;;
        *) echo "1" > "$FREQ_CONF" ;;
    esac
    echo "✅ 频率已设定。"
    echo "------------------------------------------------------"

    echo "[3/3] 请设置监控持续周期:"
    echo "  👉 输入具体的数字 (如 3)，代表连续监控 3 天后自动停止并打包数据。"
    echo "  👉 输入 0，代表【持续监测】，直到你手动关闭它。"
    read -p "请输入天数 (默认0): " days
    days=${days:-0}
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then days=0; fi
    
    if [ "$days" -eq 0 ]; then
        echo "0" > "$END_TIME_CONF"
        echo "✅ 已设定为: 持续监测 (需手动停止)"
    else
        local end_ts=$(($(date +%s) + days * 86400))
        echo "$end_ts" > "$END_TIME_CONF"
        echo "✅ 已设定为: 连续监控 $days 天后自动停止并打包"
    fi
    echo "======================================================"
    echo "⚙️ 正在向系统调度器写入任务..."
    init_env
    setup_cron
    echo "🎉 部署全部完成！任务将在后台默默运行。"
    read -p "按回车键返回主菜单..."
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
                echo "✅ 已成功追加 TCPing 目标: $c_name"
            fi
            sleep 1; manage_custom_targets ;;
        2)
            echo ""
            read -p "👉 请输入节点名称 (例: 洛杉矶): " s_name
            read -p "👉 请输入 Speedtest Server ID: " s_id
            if [ -n "$s_name" ] && [ -n "$s_id" ]; then
                echo "$s_name,$s_id" >> "$CUSTOM_SPEED"
                echo "✅ 已成功追加测速节点: $s_name"
            fi
            sleep 1; manage_custom_targets ;;
        3) rm -f "$CUSTOM_TCP" "$CUSTOM_SPEED"; echo "🧹 已清空！"; sleep 1; manage_custom_targets ;;
        0) return ;;
        *) manage_custom_targets ;;
    esac
}

show_menu() {
    clear
    local cron_status="未运行"
    if crontab -l 2>/dev/null | grep -q "vps-monitor-pro.sh"; then cron_status="运行中"; fi
    
    local current_region=$(cat "$REGION_CONF" 2>/dev/null || echo "beijing")
    local region_name="华北/北京"
    if [ "$current_region" == "shanghai" ]; then region_name="华东/上海"; fi
    if [ "$current_region" == "guangzhou" ]; then region_name="华南/广州"; fi

    local freq_str="未部署"
    local f_val=$(cat "$FREQ_CONF" 2>/dev/null || echo "1")
    if [ "$f_val" == "2" ]; then freq_str="极限高频"; elif [ "$f_val" == "3" ]; then freq_str="佛系低频"; else freq_str="智能推荐"; fi

    local dur_str="未部署"
    local e_val=$(cat "$END_TIME_CONF" 2>/dev/null || echo "-1")
    if [ "$e_val" == "0" ]; then 
        dur_str="持续监测 (需手动停止)"
    elif [ "$e_val" -gt 0 ]; then
        dur_str="至 $(date -d @"$e_val" "+%Y-%m-%d %H:%M" 2>/dev/null || date -r "$e_val" "+%Y-%m-%d %H:%M" 2>/dev/null) (北京时间) 自动停止"
    fi

    # 动态抓取当前系统时区确认
    local tz=$(date +"%Z %z")

    echo "======================================================"
    echo "⚡ VPS 跨境网络全天候测绘探针 (VPS-Monitor-Pro) v1.0.3"
    echo "======================================================"
    echo "  [▶️ 状态: $cron_status] | [⏱️ 频率: $freq_str] | [🎯 区域: $region_name]"
    echo "  [⏳ 周期: $dur_str]"
    echo "  [🕒 系统当前时区已被强制校准为: $tz]"
    echo "======================================================"
    echo "  1. 🚀 向导式部署与启动监控任务"
    echo "  2. 🛑 手动停止所有后台监控"
    echo "  3. 🛠️ 管理自定义目标 (追加 IP / 节点)"
    echo "------------------------------------------------------"
    echo "  4. 📊 立即手动触发一次完整探测"
    echo "  5. 📉 查看最新测试报告 (在终端预览)"
    echo "  6. 📥 导出原始数据包 (打包至 /root 目录)"
    echo "------------------------------------------------------"
    echo "  9. 🧹 清理测试缓存与历史数据"
    echo "  0. 退出脚本"
    echo "======================================================"
    read -p "请输入对应的操作数字 [0-9]: " choice
    
    case "$choice" in
        1) wizard_setup ;;
        2) stop_cron; rm -f "$END_TIME_CONF" "$FREQ_CONF"; read -p "按回车键继续..." ;;
        3) manage_custom_targets ;;
        4) echo "⌛ 正在执行综合探测 (约需2-3分钟)..."; run_cron_task; echo "✅ 完成！"; read -p "按回车键继续..." ;;
        5) 
            echo "=== 最近 6 条带宽测速记录 ==="
            tail -n 7 "$SPEED_CSV" 2>/dev/null | column -s, -t || echo "暂无记录"
            echo -e "\n=== 最近 9 条 TCPing 记录 ==="
            tail -n 10 "$TCPING_CSV" 2>/dev/null | column -s, -t || echo "暂无记录"
            read -p "按回车键继续..." ;;
        6) tar -czf /root/vps_monitor_export_$(date +"%Y%m%d").tar.gz -C "$LOG_DIR" speed_log.csv tcping_log.csv 2>/dev/null; echo "✅ 导出成功！"; read -p "按回车键继续..." ;;
        9) rm -f "$SPEED_CSV" "$TCPING_CSV"; echo "🧹 历史数据已清空。"; read -p "按回车键继续..." ;;
        0) exit 0 ;;
        *) echo "输入无效！"; sleep 1 ;;
    esac
}

# 若首次直接运行菜单，确保时区已经被校准一次
if [ "$1" == "--cron" ]; then 
    run_cron_task
else 
    init_env > /dev/null 2>&1
    while true; do show_menu; done
fi
