#!/usr/bin/env bash
#
# 票 02 — 從範本 109 複製 VM 103，命名 cib-ai-platform，並在第一次開機之前設定完成。
#
# 順序不能調換。範本預設 net0 bridge=vmbr0、ipconfig0: ip=dhcp；以那個設定開機，
# 新機器會拿到對外側的位址並出現在 10.1.2.x 上，而 Edge 的對外側就是 10.1.2.57，
# 衝突會打斷 UAT 的 8081。所以是複製 → 改設定 → 讀回確認 → 才開機，
# 開機本身屬於票 03。
#
# Blocked by 票 01。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TOTAL_STAGES=7
banner "票 02 — 從範本 ${TEMPLATE_VMID} 複製 VM ${CIB_VMID} ${CIB_NAME}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
init_report
! vm_exists "$CIB_VMID" || abort "VMID ${CIB_VMID} 已被佔用；票 01 沒有跑完"
vm_exists "$TEMPLATE_VMID" || abort "找不到範本 VM ${TEMPLATE_VMID}"
readback "範本 ${TEMPLATE_VMID} 是 template" "1" "$(qmcfg "$TEMPLATE_VMID" template)"
readback "範本名稱" "$TEMPLATE_NAME" "$(qmcfg "$TEMPLATE_VMID" name)"
require_pool_free "$DISK_STORAGE"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "範本現況與 nameserver"
qm config "$TEMPLATE_VMID" |
  grep -E '^(cores|memory|cpu|machine|ostype|net0|ipconfig0|ciuser|scsi|efidisk|agent)' |
  sed 's/^/    /'
say ""
note "cipassword 不設，ciuser 與共用 ci-template key 沿用，不新增任何憑證。"
say ""

# nameserver 從 UAT（VM 105）讀：舊 103 的 /etc/resolv.conf 隨票 01 消失了，而 UAT
# 掛在同一個私有 bridge、走同一個 Edge 出去，上游 DNS 必然相同。
# 127.0.0.53 是 systemd-resolved 的 stub，不能用 —— 新機器上沒有對應的上游設定。
ns=""
if qm agent "$UAT_VMID" ping >/dev/null 2>&1; then
  ns=$(guest_exec "$UAT_VMID" "
      cat /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null |
        sed -n 's/^nameserver[[:space:]]\+//p'
      grep -rhoE '([0-9]{1,3}\.){3}[0-9]{1,3}' /etc/netplan/ 2>/dev/null" |
    grep -vE '^127\.' | head -n1 | tr -d ' \r\n' || true)
  [[ -n "$ns" ]] && ok "從 UAT（VM ${UAT_VMID}）讀到上游 DNS ${ns}"
else
  warn "UAT 的 guest agent 沒有回應，讀不到它的 DNS 設定"
fi
if [[ -z "$ns" ]]; then
  human_action "請輸入新機器要用的 nameserver（不能是 127.x 的 stub）："
  printf '  nameserver：'
  read -r ns || true
  ns=$(printf '%s' "$ns" | tr -d ' \r\n')
fi
[[ -n "$ns" ]] || abort "沒有 nameserver，不繼續"
[[ "$ns" != 127.* ]] || abort "${ns} 是 loopback stub，新機器上沒有對應的上游設定"
ok "nameserver 採用 ${ns}"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "完整複製"
say "qm clone ${TEMPLATE_VMID} ${CIB_VMID} --full --name ${CIB_NAME}"
note "完整複製，不用 linked clone：新機器不依賴範本 ${TEMPLATE_VMID} 的存續。"
note "100G + 200G 要實際複製，視儲存池速度可能要跑十幾分鐘。"
note "反向動作：qm destroy ${CIB_VMID}（此時新機器還沒開過機，也還沒有資料）。"
gate "開始複製？"

qm clone "$TEMPLATE_VMID" "$CIB_VMID" --full --name "$CIB_NAME" || abort "qm clone 失敗"
ok "複製完成"
readback "範本 ${TEMPLATE_VMID} 仍是 template（未被改動）" "1" \
  "$(qmcfg "$TEMPLATE_VMID" template)"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "開機前的設定"
net0=$(qmcfg "$CIB_VMID" net0)
say "clone 產生的 net0：${net0}"
new_net0=$(net0_bridge_set "$net0" "$PRIVATE_BRIDGE") ||
  abort "net0 裡沒有 bridge= 欄位，無法改寫：${net0}"
say "改為：${new_net0}（MAC 沿用 clone 產生的）"
say ""

qm set "$CIB_VMID" \
  --net0 "$new_net0" \
  --ipconfig0 "ip=${CIB_IP}/24,gw=${EDGE_PRIVATE_IP}" \
  --nameserver "$ns" \
  --memory "$CIB_MEMORY" \
  --cores "$CIB_CORES" \
  --onboot 0 || abort "qm set 失敗"

# guest agent 是票 03、04 唯一的通道。範本沒開的話，開機後什麼都讀不到。
if [[ "$(qmcfg "$CIB_VMID" agent)" == "" ]]; then
  warn "範本沒有啟用 QEMU guest agent；票 03 之後全靠它，這裡補上"
  qm set "$CIB_VMID" --agent 1 || abort "無法啟用 guest agent"
fi

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "讀回設定"
readback "name" "$CIB_NAME" "$(qmcfg "$CIB_VMID" name)"
readback_match "net0 的橋接" "bridge=${PRIVATE_BRIDGE}(,|$)" "$(qmcfg "$CIB_VMID" net0)"
readback "ipconfig0" "ip=${CIB_IP}/24,gw=${EDGE_PRIVATE_IP}" "$(qmcfg "$CIB_VMID" ipconfig0)"
readback "nameserver" "$ns" "$(qmcfg "$CIB_VMID" nameserver)"
readback "memory" "$CIB_MEMORY" "$(qmcfg "$CIB_VMID" memory)"
readback "cores" "$CIB_CORES" "$(qmcfg "$CIB_VMID" cores)"
readback "onboot" "0" "$(qmcfg "$CIB_VMID" onboot)"
readback "ciuser（沿用範本）" "mobagel" "$(qmcfg "$CIB_VMID" ciuser)"
readback "cipassword（不設）" "" "$(qmcfg "$CIB_VMID" cipassword)"
readback_match "guest agent 已啟用" "^1" "$(qmcfg "$CIB_VMID" agent)"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "磁碟"
# ide2: none,media=cdrom 是範本帶過來的空托盤 —— 沒有後端儲存，不是磁碟，不能算進數量。
# cloudinit 那顆雖然也標 media=cdrom，但有 storage，不會被 none 這個條件濾掉。
disks=$(qm config "$CIB_VMID" |
  grep -E '^(scsi|ide|sata|virtio|efidisk|tpmstate)[0-9]+:' |
  grep -vE ': none(,|$)')
printf '%s\n' "$disks" | sed 's/^/    /'
say ""
readback "磁碟數量（efidisk0 + scsi0 + scsi1 + cloudinit）" "4" \
  "$(printf '%s\n' "$disks" | wc -l | tr -d ' ')"
readback_match "scsi0 為 100G" "size=100G" "$(qmcfg "$CIB_VMID" scsi0)"
readback_match "scsi1 為 200G" "size=200G" "$(qmcfg "$CIB_VMID" scsi1)"
readback_match "scsi2 為 cloudinit" "cloudinit" "$(qmcfg "$CIB_VMID" scsi2)"
ok "沒有多餘的磁碟（舊機器那顆從未使用的 500G 不帶過來）"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "仍未開機"
readback "VM ${CIB_VMID} 電源狀態" "stopped" "$(qmstatus "$CIB_VMID")"
note "開機是票 03 的事。以現在的設定開機才是安全的：網卡在 ${PRIVATE_BRIDGE}，"
note "位址是靜態 ${CIB_IP}，不會出現在對外網段上。"
report_section "新機器（票 02）"
{
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| 來源範本 | %s `%s` |\n' "$TEMPLATE_VMID" "$TEMPLATE_NAME"
  printf '| 名稱 | `%s` |\n' "$CIB_NAME"
  printf '| net0 | `%s` |\n' "$(qmcfg "$CIB_VMID" net0)"
  printf '| ipconfig0 | `%s` |\n' "$(qmcfg "$CIB_VMID" ipconfig0)"
  printf '| nameserver | `%s` |\n' "$ns"
  printf '| memory / cores | %s / %s |\n' "$CIB_MEMORY" "$CIB_CORES"
} >> "$REPORT"
say ""
verify_uat_entrance

finish "票 02 完成：VM ${CIB_VMID} ${CIB_NAME} 已就緒，尚未開機"
say "下一步：./03-first-boot.sh"
