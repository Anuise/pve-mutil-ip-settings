#!/usr/bin/env bash
#
# 票 04 — 從範本 109 複製新的 103，並在第一次開機之前設定完成。
#
# 順序不能調換。範本預設 net0 bridge=vmbr0、ipconfig0: ip=dhcp；以那個設定開機，
# 新機器會拿到對外側的位址並出現在 10.1.2.x 上，而 Edge 的對外側就是 10.1.2.57，
# 衝突會打斷 UAT 的 8081。所以是複製 → 改設定 → 讀回確認 → 才開機，
# 開機本身屬於票 05。
#
# Blocked by 票 03。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

HOST_DIR=$(preserve_dir)
REPORT="${HOST_DIR}/preserve-report.md"
REFERENCE="${HOST_DIR}/reference.txt"

TOTAL_STAGES=7
banner "票 04 — 從範本 ${TEMPLATE_VMID} 複製 VM ${DEMO_VMID}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
! vm_exists "$DEMO_VMID" || abort "VMID ${DEMO_VMID} 已被佔用；票 03 沒有跑完"
vm_exists "$TEMPLATE_VMID" || abort "找不到範本 VM ${TEMPLATE_VMID}"
readback "範本 ${TEMPLATE_VMID} 是 template" "1" "$(qmcfg "$TEMPLATE_VMID" template)"
readback "範本名稱" "$TEMPLATE_NAME" "$(qmcfg "$TEMPLATE_VMID" name)"
require_pool_free "$DISK_STORAGE"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "範本現況"
qm config "$TEMPLATE_VMID" | grep -E '^(cores|memory|cpu|machine|ostype|net0|ipconfig0|ciuser|scsi|efidisk|agent)' |
  sed 's/^/    /'
say ""
note "cipassword 不設，ciuser 與共用 ci-template key 沿用，不新增任何憑證。"

# nameserver 取自票 01 抄回的參考資料。systemd-resolved 的 127.0.0.53 不能用 ——
# 那是舊機器自己的 stub，新機器上沒有對應的上游設定。
ns=$(sed -n 's/^nameserver[[:space:]]\+//p' "$REFERENCE" 2>/dev/null | grep -v '^127\.' | head -n1 || true)
[[ -n "$ns" ]] || ns=$(grep -A3 'nameservers' "$REFERENCE" 2>/dev/null |
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -n1 || true)
if [[ -z "$ns" ]]; then
  warn "票 01 的參考資料裡讀不到可用的上游 DNS"
  human_action "請輸入新機器要用的 nameserver（沒有它就開機，guest 解不到 ${REPO_HOST}）："
  printf '  nameserver：'
  read -r ns || true
fi
[[ -n "$ns" ]] || abort "沒有 nameserver，不繼續"
ok "nameserver 採用 ${ns}"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "完整複製"
say "qm clone ${TEMPLATE_VMID} ${DEMO_VMID} --full --name ${DEMO_NAME}"
note "完整複製，不用 linked clone：新機器不依賴範本 ${TEMPLATE_VMID} 的存續。"
note "100G + 200G 要實際複製，視儲存池速度可能要跑十幾分鐘。"
note "反向動作：qm destroy ${DEMO_VMID}（此時新機器還沒開過機，也還沒有資料）。"
gate "開始複製？"

qm clone "$TEMPLATE_VMID" "$DEMO_VMID" --full --name "$DEMO_NAME" ||
  abort "qm clone 失敗"
ok "複製完成"
readback "範本 ${TEMPLATE_VMID} 仍是 template（未被改動）" "1" \
  "$(qmcfg "$TEMPLATE_VMID" template)"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "開機前的設定"
net0=$(qmcfg "$DEMO_VMID" net0)
say "clone 產生的 net0：${net0}"
new_net0=$(net0_bridge_set "$net0" "$PRIVATE_BRIDGE") ||
  abort "net0 裡沒有 bridge= 欄位，無法改寫：${net0}"
say "改為：${new_net0}（MAC 沿用 clone 產生的）"
say ""

qm set "$DEMO_VMID" \
  --net0 "$new_net0" \
  --ipconfig0 "ip=${DEMO_IP}/24,gw=${EDGE_PRIVATE_IP}" \
  --nameserver "$ns" \
  --memory "$DEMO_MEMORY" \
  --cores "$DEMO_CORES" \
  --onboot 0 || abort "qm set 失敗"

# guest agent 是票 05–07 唯一的通道。範本沒開的話，開機後什麼都讀不到。
if [[ "$(qmcfg "$DEMO_VMID" agent)" == "" ]]; then
  warn "範本沒有啟用 QEMU guest agent；票 05 之後全靠它，這裡補上"
  qm set "$DEMO_VMID" --agent 1 || abort "無法啟用 guest agent"
fi

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "讀回設定"
readback_match "net0 的橋接" "bridge=${PRIVATE_BRIDGE}(,|$)" "$(qmcfg "$DEMO_VMID" net0)"
readback "ipconfig0" "ip=${DEMO_IP}/24,gw=${EDGE_PRIVATE_IP}" "$(qmcfg "$DEMO_VMID" ipconfig0)"
readback "nameserver" "$ns" "$(qmcfg "$DEMO_VMID" nameserver)"
readback "memory" "$DEMO_MEMORY" "$(qmcfg "$DEMO_VMID" memory)"
readback "cores" "$DEMO_CORES" "$(qmcfg "$DEMO_VMID" cores)"
readback "onboot" "0" "$(qmcfg "$DEMO_VMID" onboot)"
readback "name" "$DEMO_NAME" "$(qmcfg "$DEMO_VMID" name)"
readback "ciuser（沿用範本）" "mobagel" "$(qmcfg "$DEMO_VMID" ciuser)"
readback "cipassword（不設）" "" "$(qmcfg "$DEMO_VMID" cipassword)"
readback_match "guest agent 已啟用" "^1" "$(qmcfg "$DEMO_VMID" agent)"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "磁碟"
disks=$(qm config "$DEMO_VMID" | grep -E '^(scsi|ide|sata|virtio|efidisk|tpmstate)[0-9]+:')
printf '%s\n' "$disks" | sed 's/^/    /'
say ""
readback "磁碟數量（efidisk0 + scsi0 + scsi11 + cloudinit）" "4" \
  "$(printf '%s\n' "$disks" | wc -l | tr -d ' ')"
readback_match "scsi0 為 100G" "size=100G" "$(qmcfg "$DEMO_VMID" scsi0)"
readback_match "scsi11 為 200G" "size=200G" "$(qmcfg "$DEMO_VMID" scsi11)"
readback_match "scsi2 為 cloudinit" "cloudinit" "$(qmcfg "$DEMO_VMID" scsi2)"
ok "沒有多餘的磁碟（舊機器那顆從未使用的 500G 不帶過來）"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "仍未開機"
readback "VM ${DEMO_VMID} 電源狀態" "stopped" "$(qmstatus "$DEMO_VMID")"
note "開機是票 05 的事。以現在的設定開機才是安全的：網卡在 ${PRIVATE_BRIDGE}，"
note "位址是靜態 ${DEMO_IP}，不會出現在對外網段上。"
{
  printf '\n### 新機器（票 04）\n\n'
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| 來源範本 | %s `%s` |\n' "$TEMPLATE_VMID" "$TEMPLATE_NAME"
  printf '| net0 | `%s` |\n' "$(qmcfg "$DEMO_VMID" net0)"
  printf '| ipconfig0 | `%s` |\n' "$(qmcfg "$DEMO_VMID" ipconfig0)"
  printf '| nameserver | `%s` |\n' "$ns"
  printf '| memory / cores | %s / %s |\n' "$DEMO_MEMORY" "$DEMO_CORES"
} >> "$REPORT"
say ""
verify_uat_entrance

finish "票 04 完成：新的 VM ${DEMO_VMID} 已就緒，尚未開機"
say "下一步：PRESERVE_DIR=${HOST_DIR} ./05-first-boot.sh"
