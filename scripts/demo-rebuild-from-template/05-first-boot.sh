#!/usr/bin/env bash
#
# 票 05 — 第一次開機，並把新機器的形狀讀出來。
#
# 不假設範本的名字（ub-26-4-srv-docker）就代表 /srv 與 Docker 已經是我們要的
# 形狀。上一輪的教訓正是這個：票 06 通過了驗收，卻沒發現 image layer 根本不在
# data-root 底下，因為沒有人去讀 storage driver。這一票把事實寫下來。
#
# Blocked by 票 04。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

HOST_DIR=$(preserve_dir)
TEST_IMAGE="hello-world"

# 形狀報告不放進保全目錄：spec 說那個目錄裡「沒有任何一個檔案可以進 repo」，
# 而這一份是要能進 repo 的。每一段讀回都先過 redact_secrets —— daemon.json 可能
# 帶 registry 認證，fstab 可能帶 CIFS 憑證，「這份沒有 secret」不能只是宣稱。
SHAPE="/root/demo-rebuild-shape-$(date +%Y%m%d-%H%M%S).md"

# read_guest TITLE CMD — 讀回、印出、寫進報告。
read_guest() {
  local out
  out=$(guest_exec_or_abort "$DEMO_VMID" "$2" "無法讀取：$1" | redact_secrets)
  { printf '\n## %s\n\n```\n' "$1"; printf '%s\n' "$out"; printf '```\n'; } >> "$SHAPE"
  say ""; say "$1"; printf '%s\n' "$out" | sed 's/^/    /'
}

TOTAL_STAGES=8
banner "票 05 — 第一次開機並讀出新機器的形狀"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "開機前的停止條款複查"
need_pve
vm_exists "$DEMO_VMID" || abort "找不到 VM ${DEMO_VMID}；票 04 沒跑完"
readback_match "net0 的橋接" "bridge=${PRIVATE_BRIDGE}(,|$)" "$(qmcfg "$DEMO_VMID" net0)"
readback "ipconfig0" "ip=${DEMO_IP}/24,gw=${EDGE_PRIVATE_IP}" "$(qmcfg "$DEMO_VMID" ipconfig0)"
note "spec 的停止條款：這兩項只要不符就不准開機。"

printf '# 新機器形狀 —— VM %s（票 05）\n\n產生時間：%s\n' \
  "$DEMO_VMID" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$SHAPE"
printf '\n每一段讀回都已過 redact_secrets。放進 repo 的 docs/reports/ 之前請自己看一遍。\n' >> "$SHAPE"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "開機"
say "第一次開機。Cloud-Init 會套用靜態位址與共用的 ci-template key。"
gate "開機？"
qm start "$DEMO_VMID" || abort "qm start 失敗"
wait_agent "$DEMO_VMID" 600 ||
  abort "guest agent 在 10 分鐘內沒有回應；用 PVE console 看開機到哪裡"
readback "VM ${DEMO_VMID} 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
read_guest "guest agent" "systemctl is-active qemu-guest-agent; qemu-ga --version 2>/dev/null | head -n1"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "網路"
addrs=$(guest_global_addrs "$DEMO_VMID")
readback_contains "guest 內的位址" "${DEMO_IP}/24" "$addrs"
if has_lan_addr "$addrs"; then
  warn "guest 內出現對外網段（${EXTERNAL_NET_PREFIX}.x）的位址：${addrs}"
  abort "新機器接到對外側了；關機並修正 net0 後重跑票 05"
fi
ok "沒有任何 ${EXTERNAL_NET_PREFIX}.x 位址"
read_guest "ip -4 -o addr" "ip -4 -o addr show scope global"
read_guest "ip route" "ip route"
read_guest "/etc/netplan" "for f in /etc/netplan/*; do echo \"--- \$f\"; cat \"\$f\"; done"
readback_match "預設路由" "default via ${EDGE_PRIVATE_IP}" \
  "$(guest_exec_or_abort "$DEMO_VMID" "ip route | grep '^default'" "讀不到預設路由" | tr -d '\r\n')"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "檔案系統"
srv_src=$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE /srv" \
  "/srv 不是獨立的掛載點" | tr -d '\r\n')
[[ -n "$srv_src" ]] || abort "/srv 不是獨立檔案系統"
ok "/srv 由 ${srv_src} 提供"
read_guest "lsblk" "lsblk"
read_guest "findmnt /srv" "findmnt /srv"
read_guest "df -hT" "df -hT"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Docker 的實際落點"
note "不預設 data-root 在哪。讀出來寫下來 —— 上一輪就是漏了這一步。"
root_dir=$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.DockerRootDir}}'" \
  "無法讀取 Docker Root Dir" | tr -d '\r\n')
driver=$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.Driver}}'" \
  "無法讀取 Storage Driver" | tr -d '\r\n')
version=$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.ServerVersion}}'" \
  "無法讀取 Server Version" | tr -d '\r\n')
say "Docker Root Dir：${root_dir}"
say "Storage Driver ：${driver}"
say "Server Version ：${version}"
{
  printf '\n## Docker\n\n| 項目 | 值 |\n| --- | --- |\n'
  printf '| Docker Root Dir | `%s` |\n' "$root_dir"
  printf '| Storage Driver | `%s` |\n' "$driver"
  printf '| Server Version | `%s` |\n' "$version"
  printf '| /srv 來源裝置 | `%s` |\n' "$srv_src"
} >> "$SHAPE"

read_guest "image 實際落在哪裡" "
  echo \"data-root: ${root_dir}\"
  du -sh '${root_dir}' 2>/dev/null
  du -sh '${root_dir}/${driver}' 2>/dev/null || echo '(沒有 ${driver} 子目錄)'
  du -sh /var/lib/containerd 2>/dev/null
  df -hT --output=source,target,size,used \"\$(findmnt -rno SOURCE -T '${root_dir}')\" 2>/dev/null || true"
read_guest "/etc/docker/daemon.json" "cat /etc/docker/daemon.json 2>/dev/null || echo '(沒有這個檔案)'"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "對外通路"
read_guest "DNS 與連通性" "
  getent hosts '${REPO_HOST}' || echo 'DNS 解不到 ${REPO_HOST}'
  ping -c2 -W3 '${EDGE_PRIVATE_IP}' | tail -n2
  ping -c2 -W3 8.8.8.8 | tail -n2"
getent_out=$(guest_exec_or_abort "$DEMO_VMID" "getent hosts '${REPO_HOST}' | head -n1" \
  "DNS 解不到 ${REPO_HOST}（票 04 的 nameserver 設錯了？）" | tr -d '\r\n')
[[ -n "$getent_out" ]] || abort "DNS 解不到 ${REPO_HOST}"
ok "DNS 解得到 ${REPO_HOST}：${getent_out}"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "Docker 可用性（用實際動作證明）"
note "不看 docker info 的結束碼就當作可用：pull 一個小 image、跑一個用後即刪的"
note "容器、再刪掉它。"
GUEST_EXEC_TIMEOUT=600
guest_retry_or_abort "$DEMO_VMID" "docker pull '${TEST_IMAGE}'" \
  "docker pull 失敗（對外通路或 registry 不通）" | tail -n3 | sed 's/^/    /'
out=$(guest_retry_or_abort "$DEMO_VMID" "docker run --rm '${TEST_IMAGE}'" \
  "docker run 失敗")
printf '%s\n' "$out" | head -n5 | sed 's/^/    /'
readback "用後即刪的容器沒有留下來" "0" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker ps -aq | wc -l" "無法清點容器" | tr -d ' \r\n')"
guest_retry_or_abort "$DEMO_VMID" "docker image rm '${TEST_IMAGE}'" \
  "無法移除測試 image" >/dev/null
readback "測試 image 已移除" "0" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker images -q | wc -l" "無法清點 image" | tr -d ' \r\n')"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "收尾"
readback "onboot 仍為 0（票 07 驗收過才開自啟）" "0" "$(qmcfg "$DEMO_VMID" onboot)"
ok "新機器形狀已寫進 ${SHAPE}"
say ""
verify_uat_entrance

finish "票 05 完成：新機器已開機，形狀已記錄"
say "形狀報告（已過 redact_secrets，看過一遍即可放進 repo 的 docs/reports/）：${SHAPE}"
say "下一步：PRESERVE_DIR=${HOST_DIR} ./06-restore-key-and-clone.sh"
