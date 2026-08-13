#!/usr/bin/env bash
#
# 票 02 — Demo（VM 103）轉為 private guest 並安全首次開機。
#
# 順序不可調換：確認無快照 → 停機快照 → 關閉自動升級 → 網卡移到 private
# bridge → Cloud-Init 位址 → 記憶體／ballooning → 最後才第一次開機。
#
# 網卡先移、之後才開機是本腳本的關鍵安全性質：private bridge 沒有實體
# bridge port，所以即使 guest 內部殘留 10.1.2.57，該位址也碰不到 Edge 的
# 對外側，不會打斷 UAT 的 8081。
#
# 在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

SNAPSHOT_NAME="pre-demo-entrance-$(date +%Y%m%d)"

TOTAL_STAGES=10
banner "票 02 — Demo 轉為 private guest 並安全首次開機"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
qm config "$DEMO_VMID" >/dev/null 2>&1 || abort "找不到 VM ${DEMO_VMID}"
readback "VM ${DEMO_VMID} 名稱" "$DEMO_NAME" "$(qmcfg "$DEMO_VMID" name)"

demo_status=$(qmstatus "$DEMO_VMID")
if [[ "$demo_status" != "stopped" ]]; then
  warn "Demo 目前是 ${demo_status}。"
  human_action "先把 Demo 關機（qm shutdown ${DEMO_VMID}），再重跑本腳本。"
  abort "快照必須在停機狀態建立，才不會含記憶體映像"
fi
ok "Demo 為停機狀態"

readback "Edge VM ${EDGE_VMID} 電源狀態" "running" "$(qmstatus "$EDGE_VMID")"
readback "UAT VM ${UAT_VMID} 電源狀態" "running" "$(qmstatus "$UAT_VMID")"

# private bridge 必須存在、沒有實體 bridge port、PVE host 沒有 IP。
ip link show "$PRIVATE_BRIDGE" >/dev/null 2>&1 || abort "找不到 ${PRIVATE_BRIDGE}"
bridge_ports=$(sed -n "/^iface ${PRIVATE_BRIDGE} /,/^\$/p" /etc/network/interfaces |
  sed -n 's/^[[:space:]]*bridge-ports[[:space:]]*//p')
readback "${PRIVATE_BRIDGE} bridge-ports" "none" "${bridge_ports:-<unset>}"
host_ip_on_bridge=$(ip -4 -o addr show "$PRIVATE_BRIDGE" | wc -l)
readback "PVE host 在 ${PRIVATE_BRIDGE} 上的 IP 數" "0" "$host_ip_on_bridge"

# ciupgrade 需要 PVE 8.2 以上。這只是提早示警；決定性的檢查是 stage 4 實際執行
# qm set --ciupgrade 0 後的讀回。空清單代表問不到，不能當成「不支援」。
set_options=$(qm_set_options)
if [[ -z "$set_options" ]]; then
  warn "無法從 qm 的說明取得選項清單，略過這項預檢。"
  pveversion 2>&1 | sed 's/^/    PVE: /'
  note "stage 4 會實際設定 ciupgrade 並讀回，那才是決定性的檢查。"
elif ! printf '%s\n' "$set_options" | grep -qx ciupgrade; then
  warn "qm set 的選項清單中沒有 ciupgrade。診斷資訊："
  pveversion 2>&1 | sed 's/^/    PVE: /'
  say "    共讀到 $(printf '%s\n' "$set_options" | wc -l) 個選項，其中與 ci 相關的："
  printf '%s\n' "$set_options" | grep '^ci' | sed 's/^/      /' ||
    say "      （沒有任何 ci* 選項）"
  abort "此 PVE 版本的 qm set 沒有 ciupgrade；需 PVE 8.2 以上，否則無法在重置前關閉自動升級"
else
  ok "qm set 支援 ciupgrade"
fi

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "確認 Demo 目前沒有任何快照"
existing=$(list_snapshots "$DEMO_VMID")
if [[ -n "$existing" ]]; then
  warn "已存在快照：${existing}"
  human_action "spec 記載 Demo 沒有任何快照。實際狀態不同，請先確認這些快照的來源與是否可用，再決定回復點。"
  abort "既有快照與預期狀態不符"
fi
ok "Demo 沒有任何快照，接下來建立的就是整項工作唯一的回復點"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "建立停機狀態快照"
say "快照名稱：${SNAPSHOT_NAME}"
note "Demo 是停機狀態，所以快照不含記憶體映像。這是整項工作唯一的回復點。"
gate "建立快照？"

qm snapshot "$DEMO_VMID" "$SNAPSHOT_NAME" \
  --description "Demo entrance port 8082 與 /srv 重整前的回復點（停機狀態，無記憶體映像）"

readback "快照清單" "$SNAPSHOT_NAME" "$(list_snapshots "$DEMO_VMID")"
readback "建立快照時的電源狀態" "stopped" "$(qmstatus "$DEMO_VMID")"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "關閉自動套件升級"
say "Demo 目前沒有 ciupgrade 設定，hypervisor 預設會開啟它。"
note "票 03 的 Cloud-Init 重置會讓所有模組以 first boot 身分重跑；先關掉它，"
note "才不會在一台跑著實際 Docker workload 的機器上觸發未經要求的升級。"
gate "設定 ciupgrade=0？"

qm set "$DEMO_VMID" --ciupgrade 0
readback "ciupgrade" "0" "$(qmcfg "$DEMO_VMID" ciupgrade)"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "網卡移到 private bridge"
cur_net0=$(qmcfg "$DEMO_VMID" net0)
[[ -n "$cur_net0" ]] || abort "VM ${DEMO_VMID} 沒有 net0"
[[ "$cur_net0" == *bridge=* ]] || abort "net0 沒有 bridge= 欄位，無法安全改寫：${cur_net0}"

cur_mac=$(net0_mac "$cur_net0")
[[ -n "$cur_mac" ]] || abort "無法從 net0 取出 MAC address：${cur_net0}"
new_net0=$(net0_bridge_set "$cur_net0" "$PRIVATE_BRIDGE")

say "目前：${cur_net0}"
say "改為：${new_net0}"
note "只改 bridge，model、MAC 與其他旗標原樣保留。"
gate "把 net0 移到 ${PRIVATE_BRIDGE}？"

qm set "$DEMO_VMID" --net0 "$new_net0"
after_net0=$(qmcfg "$DEMO_VMID" net0)
readback_match "net0 bridge" "bridge=${PRIVATE_BRIDGE}(,|\$)" "$after_net0"
readback "net0 MAC" "$cur_mac" "$(net0_mac "$after_net0")"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Cloud-Init 位址改為 ${DEMO_IP}"
say "目前 ipconfig0：$(qmcfg "$DEMO_VMID" ipconfig0)"
say "改為：ip=${DEMO_IP}/24,gw=${EDGE_PRIVATE_IP}"
note "${DEMO_IP} 已確認未被使用：private bridge 上目前只有 Edge 與 UAT。"
note "guest 內部此時仍是舊設定；那由票 03 的 Cloud-Init 重置處理。"
gate "設定 ipconfig0？"

qm set "$DEMO_VMID" --ipconfig0 "ip=${DEMO_IP}/24,gw=${EDGE_PRIVATE_IP}"
after_ipconfig=$(qmcfg "$DEMO_VMID" ipconfig0)
readback_match "ipconfig0 位址" "ip=${DEMO_IP//./\\.}/24(,|\$)" "$after_ipconfig"
readback_match "ipconfig0 gateway" "gw=${EDGE_PRIVATE_IP//./\\.}(,|\$)" "$after_ipconfig"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "記憶體 64 GiB、停用 ballooning"
readback "cores（必須已是 ${DEMO_CORES}，本腳本不變更）" "$DEMO_CORES" "$(qmcfg "$DEMO_VMID" cores)"
say "目前 memory=$(qmcfg "$DEMO_VMID" memory) balloon=$(qmcfg "$DEMO_VMID" balloon)"
say "改為 memory=${DEMO_MEMORY} balloon=0"
gate "設定記憶體與 ballooning？"

qm set "$DEMO_VMID" --memory "$DEMO_MEMORY" --balloon 0
readback "memory" "$DEMO_MEMORY" "$(qmcfg "$DEMO_VMID" memory)"
readback "balloon" "0" "$(qmcfg "$DEMO_VMID" balloon)"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "確認未開啟開機自啟"
onboot=$(qmcfg "$DEMO_VMID" onboot)
if [[ -n "$onboot" && "$onboot" != "0" ]]; then
  abort "onboot=${onboot}；開機自啟必須等票 09 驗收通過後才開啟"
fi
ok "onboot 未開啟（目前值：${onboot:-<unset>}）"

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "第一次開機"
say "上述變更全部完成且已讀回確認，現在才第一次開機。"
note "網卡已在 ${PRIVATE_BRIDGE}，該 bridge 沒有實體 bridge port，"
note "所以 guest 內部殘留的位址不會出現在 Edge 的對外側。"
gate "啟動 Demo？"

qm start "$DEMO_VMID"
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"

say "等待 guest agent 回應（最多 5 分鐘）…"
wait_agent "$DEMO_VMID" 300 ||
  abort "guest agent 在 5 分鐘內沒有回應；改用 PVE console 檢查 Demo 是否正常開機"

# ── 10 ────────────────────────────────────────────────────────────────────
stage "開機後驗證"
verify_uat_entrance

say ""
say "guest 內部目前看到的位址（預期仍是舊設定，票 03 才會重套）："
say "    $(guest_global_addrs "$DEMO_VMID")"

finish "票 02 完成：Demo 已是 private guest 且已安全開機"
say "回復點：快照 ${SNAPSHOT_NAME}（qm rollback ${DEMO_VMID} ${SNAPSHOT_NAME}）"
say "開機自啟仍為關閉，等票 09 驗收通過再開。"
say "下一步：./03-guest-cloud-init-reset.sh"
