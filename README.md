# ⚡ VPS-Monitor-Pro | 全天候跨境网络监控测绘探针

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Cron](https://img.shields.io/badge/Automation-Cron-007ACC?style=for-the-badge)
![Open Source](https://img.shields.io/badge/Open_Source-Success?style=for-the-badge)

**VPS-Monitor-Pro** 是一款专为硬核网络评测与 VPS 玩家打造的轻量级、全自动 Shell 监控探针。通过创新的 **“1+3” 测速模型** 与 **高可用云端节点池**，精准捕获 VPS 跨境网络在晚高峰时段的真实带宽衰减与丢包波动，让一切“虚假宣传”与“母鸡超售”无所遁形。

👉 **项目地址**: [https://github.com/playfulsoul/vps-monitor-pro](https://github.com/playfulsoul/vps-monitor-pro)

---

## ✨ 核心硬核特性

*   **📈 首创 "1+3" 测速模型**
    摒弃传统的单点测速。每次触发监控，将依次测绘：`VPS 本地物理极速` + `国内目标城市（电信）` + `国内目标城市（联通）` + `国内目标城市（移动）`。一眼看穿母鸡网卡上限与回国线路的偏科情况。
*   **🔥 晚高峰智能雷达 (动态 Cron)**
    无需手动熬夜蹲点。脚本采用智能动态频率：白天（01:00-17:00）每 2 小时测绘一次，**晚高峰（18:00-24:00）自动提频至每 1 小时一次**，精准抓取拥堵断流瞬间。
*   **☁️ 云端主备节点池 (高可用防失效)**
    彻底解决 Speedtest 节点频繁下线导致的“数据断档”。测试引擎与 `nodes.conf` 配置文件分离，每次测速前动态拉取 GitHub 云端最新配置。遇到死节点自动无缝切换备用节点。
*   **🛡️ 并发 TCPing 防火墙穿透**
    拒绝容易被 QoS 降权或拦截的传统 ICMP Ping。内置极轻量级 `tcping` 引擎，并发向国内北上广 9 大核心枢纽发送 TCP 数据包，真实还原应用层协议的极速连通性与丢包率。
*   **📊 结构化 CSV 报表输出**
    纯净的数据档案管理，测速与延迟数据分离记录。附带当时的 `CPU 负载 (Load Average)`，方便后期导入 Excel 一键生成 24 小时性能折线图，评测数据信服力拉满。

---

## 🚀 极速部署指南

无需繁琐的依赖配置，只需通过 SSH 登录你的 VPS（支持 Ubuntu / Debian / CentOS 等主流系统），直接粘贴并执行以下命令：

```bash
bash <(curl -sL https://raw.githubusercontent.com/playfulsoul/vps-monitor-pro/main/vps-monitor-pro.sh
