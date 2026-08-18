#!/usr/bin/env bash
#
# 票 03 — 第一次開機，並把新機器的形狀讀出來。
#
# 不假設範本的名字（ub-26-4-srv-docker）就代表 /srv 與 Docker 已經是我們要的形狀。
# 上一輪的教訓正是這個（ADR-0004）：驗收通過了，卻沒發現 image layer 根本不在
# data-root 底下，因為沒有人去讀 storage driver。這一票把事實寫下來。
#
# Blocked by 票 02。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TEST_IMAGE="hello-world"
DNS_PROBE_HOST="registry-1.docker.io"

TOTAL_STAGES=8
banner "票 03 — 第一次開機並讀出 ${CIB_NAME} 的形狀"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "開機前的停止條款複查"
need_pve
init_report
vm_exists "$CIB_VMID" || abort "找不到 VM ${CIB_VMID}；票 02 沒跑完"
readback "name" "$CIB_NAME" "$(qmcfg "$CIB_VMID" name)"
readback_match "net0 的橋接" "bridge=${PRIVATE_BRIDGE}(,|$)" "$(qmcfg "$CIB_VMID" net0)"
readback "ipconfig0" "ip=${CIB_IP}/24,gw=${EDGE_PRIVATE_IP}" "$(qmcfg "$CIB_VMID" ipconfig0)"
note "spec 的停止條款：這兩項只要不符就不准開機。"
report_section "形狀（票 03）"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "開機"
say "第一次開機。Cloud-Init 會套用靜態位址與共用的 ci-template key。"
gate "開機？"
qm start "$CIB_VMID" || abort "qm start 失敗"
wait_agent "$CIB_VMID" 600 ||
  abort "guest agent 在 10 分鐘內沒有回應；用 PVE console 看開機到哪裡"
readback "VM ${CIB_VMID} 電源狀態" "running" "$(qmstatus "$CIB_VMID")"
read_guest "guest agent" \
  "systemctl is-active qemu-guest-agent; qemu-ga --version 2>/dev/null | head -n1"
read_guest "hostname 與 OS" "hostnamectl 2>/dev/null | head -n6"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "網路"
addrs=$(guest_global_addrs "$CIB_VMID")
readback_contains "guest 內的位址" "${CIB_IP}/24" "$addrs"
if has_lan_addr "$addrs"; then
  warn "guest 內出現對外網段（${EXTERNAL_NET_PREFIX}.x）的位址：${addrs}"
  abort "新機器接到對外側了；關機並修正 net0 後重跑票 03"
fi
ok "沒有任何 ${EXTERNAL_NET_PREFIX}.x 位址"
read_guest "ip -4 -o addr" "ip -4 -o addr show scope global"
read_guest "ip route" "ip route"
read_guest "/etc/netplan" "for f in /etc/netplan/*; do echo \"--- \$f\"; cat \"\$f\"; done"
readback_match "預設路由" "default via ${EDGE_PRIVATE_IP}" \
  "$(guest_exec_or_abort "$CIB_VMID" "ip route | grep '^default'" "讀不到預設路由" |
     tr -d '\r\n')"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "檔案系統"
srv_src=$(guest_exec_or_abort "$CIB_VMID" "findmnt -rno SOURCE /srv" \
  "/srv 不是獨立的掛載點" | tr -d '\r\n')
[[ -n "$srv_src" ]] || abort "/srv 不是獨立檔案系統"
ok "/srv 由 ${srv_src} 提供"
read_guest "lsblk" "lsblk"
read_guest "findmnt /srv" "findmnt /srv"
read_guest "df -hT" "df -hT"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Docker 的實際落點"
note "不預設 data-root 在哪。讀出來寫下來 —— 上一輪就是漏了這一步。"
root_dir=$(guest_exec_or_abort "$CIB_VMID" "docker info --format '{{.DockerRootDir}}'" \
  "無法讀取 Docker Root Dir" | tr -d '\r\n')
driver=$(guest_exec_or_abort "$CIB_VMID" "docker info --format '{{.Driver}}'" \
  "無法讀取 Storage Driver" | tr -d '\r\n')
version=$(guest_exec_or_abort "$CIB_VMID" "docker info --format '{{.ServerVersion}}'" \
  "無法讀取 Server Version" | tr -d '\r\n')
say "Docker Root Dir：${root_dir}"
say "Storage Driver ：${driver}"
say "Server Version ：${version}"
{
  printf '\n### Docker\n\n| 項目 | 值 |\n| --- | --- |\n'
  printf '| Docker Root Dir | `%s` |\n' "$root_dir"
  printf '| Storage Driver | `%s` |\n' "$driver"
  printf '| Server Version | `%s` |\n' "$version"
  printf '| /srv 來源裝置 | `%s` |\n' "$srv_src"
} >> "$REPORT"
# 不預設 driver 會在 data-root 底下建同名子目錄 —— Docker 29 的 overlayfs 沒有，
# 實際是 image／rootfs／containers／volumes。逐層列出來，不問只有舊版才成立的問題。
# df 不能同時吃 -T 與 --output（互斥），fstype 走 --output。舊寫法的錯誤被
# 2>/dev/null 吃掉，於是「落在哪個裝置」一直是空的 —— 那正是 ADR-0004 的教訓本身，
# 所以這一行不再加 || true：讀不到就要停下來，不要靜靜地留白。
read_guest "image 實際落在哪裡" "
  echo \"data-root: ${root_dir}\"
  du -sh '${root_dir}' 2>/dev/null
  echo '--- data-root 底下逐層 ---'
  du -sh '${root_dir}'/* 2>/dev/null
  du -sh /var/lib/containerd 2>/dev/null
  echo '--- data-root 落在哪個裝置 ---'
  df -h --output=source,fstype,size,used,avail,target \"\$(findmnt -rno SOURCE -T '${root_dir}')\""
read_guest "/etc/docker/daemon.json" \
  "cat /etc/docker/daemon.json 2>/dev/null || echo '(沒有這個檔案)'"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "既有 listener 與 guest 自己的防火牆"
note "票 04 要在 ${CIB_SERVICE_PORT} 上起臨時 listener。先確認那個 port 沒被佔用，"
note "也沒有被 guest 自己的防火牆擋掉 —— 不然票 04 會查不出是哪一層不通。"
listeners=$(guest_exec_or_abort "$CIB_VMID" "ss -ltn" "無法讀取 listener")
printf '%s\n' "$listeners" | sed 's/^/    /'
{ printf '\n### ss -ltn\n\n```\n'; printf '%s\n' "$listeners"; printf '```\n'; } >> "$REPORT"
if printf '%s\n' "$listeners" | ss_reachable_listener "$CIB_SERVICE_PORT"; then
  abort "${CIB_SERVICE_PORT} 已經有人在聽；票 04 的臨時 listener 會起不來"
fi
ok "${CIB_SERVICE_PORT} 目前沒有 listener"
read_guest "guest 內的防火牆" "
  ufw status 2>/dev/null || echo '(沒有 ufw)'
  nft list ruleset 2>/dev/null | head -n30 || echo '(沒有 nftables 規則)'
  iptables -S 2>/dev/null | head -n20 || true"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "對外通路與 Docker 可用性（用實際動作證明）"
read_guest "DNS 與連通性" "
  getent hosts '${DNS_PROBE_HOST}' || echo 'DNS 解不到 ${DNS_PROBE_HOST}'
  ping -c2 -W3 '${EDGE_PRIVATE_IP}' | tail -n2
  ping -c2 -W3 8.8.8.8 | tail -n2"
getent_out=$(guest_exec_or_abort "$CIB_VMID" "getent hosts '${DNS_PROBE_HOST}' | head -n1" \
  "DNS 解不到 ${DNS_PROBE_HOST}（票 02 的 nameserver 設錯了？）" | tr -d '\r\n')
[[ -n "$getent_out" ]] || abort "DNS 解不到 ${DNS_PROBE_HOST}"
ok "DNS 解得到 ${DNS_PROBE_HOST}：${getent_out}"

note "不看 docker info 的結束碼就當作可用：pull 一個小 image、跑一個用後即刪的容器、"
note "再刪掉它。"
GUEST_EXEC_TIMEOUT=600
guest_retry_or_abort "$CIB_VMID" "docker pull '${TEST_IMAGE}'" \
  "docker pull 失敗（對外通路或 registry 不通）" | tail -n3 | sed 's/^/    /'
guest_retry_or_abort "$CIB_VMID" "docker run --rm '${TEST_IMAGE}'" "docker run 失敗" |
  head -n5 | sed 's/^/    /'
readback "用後即刪的容器沒有留下來" "0" \
  "$(guest_exec_or_abort "$CIB_VMID" "docker ps -aq | wc -l" "無法清點容器" | tr -d ' \r\n')"
guest_retry_or_abort "$CIB_VMID" "docker image rm '${TEST_IMAGE}'" \
  "無法移除測試 image" >/dev/null
readback "測試 image 已移除" "0" \
  "$(guest_exec_or_abort "$CIB_VMID" "docker images -q | wc -l" "無法清點 image" | tr -d ' \r\n')"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "收尾"
readback "onboot 仍為 0（要不要自啟等票 04 驗收過再決定）" "0" "$(qmcfg "$CIB_VMID" onboot)"
say ""
verify_uat_entrance

finish "票 03 完成：${CIB_NAME} 已開機，形狀已記錄"
say "紀錄（已過 redact_secrets，看過一遍即可放進 repo 的 docs/reports/）：${REPORT}"
say "下一步：./04-publish-entrance-port-8082.sh"
