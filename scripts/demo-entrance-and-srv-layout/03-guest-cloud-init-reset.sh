#!/usr/bin/env bash
#
# 票 03 — 進入 Demo 並重套網路設定。
#
# 所有 guest 內部操作走 qemu-guest-agent：它經 virtio-serial 以 root 執行，
# 不需要網路也不需要本機密碼。本腳本不建立任何新憑證。
#
# Blocked by 票 02：Demo 必須已在 private bridge 上且已開機。
# 在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
GUEST_BACKUP="/root/pre-cloudinit-reset-${TS}"
HOST_BACKUP="$(pwd)/demo-cloudinit-backup-${TS}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# guest 內人工維護的檔案：<備份檔名>:<guest 路徑>
FILES=(
  "_root_.ssh_authorized_keys:/root/.ssh/authorized_keys"
  "_home_mobagel_.ssh_authorized_keys:${HOME_DIR}/.ssh/authorized_keys"
  "_etc_fstab:/etc/fstab"
)
# guest 內人工維護的目錄：<備份目錄名>:<guest 路徑>
DIRS=(
  "etc_netplan:/etc/netplan"
  "etc_network:/etc/network"
  "etc_cloud_cloud.cfg.d:/etc/cloud/cloud.cfg.d"
)

TOTAL_STAGES=11
banner "票 03 — Demo 進入 guest 並重套網路設定"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
readback_match "net0 bridge" "bridge=${PRIVATE_BRIDGE}(,|\$)" "$(qmcfg "$DEMO_VMID" net0)"
readback_match "ipconfig0" "ip=${DEMO_IP//./\\.}/24" "$(qmcfg "$DEMO_VMID" ipconfig0)"
readback "ciupgrade（票 02 已關閉）" "0" "$(qmcfg "$DEMO_VMID" ciupgrade)"

qm agent "$DEMO_VMID" ping >/dev/null 2>&1 ||
  abort "guest agent 沒有回應；沒有它就沒有免密碼的 root 通道"
ok "guest agent 可用"

say ""
say "重置前 guest 內部看到的位址："
say "    $(guest_global_addrs "$DEMO_VMID")"
note "Cloud-Init 的網路設定只在 first boot 套用，所以這裡預期仍是舊的。"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "備份 guest 內由人工維護的設定"
say "備份到 guest 的 ${GUEST_BACKUP}，並在 PVE host 留一份副本。"
note "掛載表特別重要：大資料卷的掛載是人工加的，不由 Cloud-Init 管理。"
gate "建立備份？"

guest_exec_or_abort "$DEMO_VMID" "
set -e
B='${GUEST_BACKUP}'
mkdir -p \"\$B\"
for f in /root/.ssh/authorized_keys ${HOME_DIR}/.ssh/authorized_keys /etc/fstab; do
  [ -f \"\$f\" ] && cp -a \"\$f\" \"\$B/\$(echo \"\$f\" | tr / _)\"
done
for d in /etc/netplan /etc/network /etc/cloud/cloud.cfg.d; do
  [ -d \"\$d\" ] && cp -a \"\$d\" \"\$B/\$(echo \"\${d#/}\" | tr / _)\"
done
dpkg-query -W -f='\${Package} \${Version}\n' | sort > \"\$B/dpkg-versions.txt\"
sha256sum \"\$B/dpkg-versions.txt\" | awk '{print \$1}' > \"\$B/dpkg-versions.sha256\"
findmnt -rno TARGET,SOURCE,FSTYPE | sort > \"\$B/mounts.txt\"
ls -1 \"\$B\"
" "guest 內備份失敗" | sed 's/^/    /'

mkdir -p "$HOST_BACKUP"
for item in "${FILES[@]}"; do
  pull_guest_file "$DEMO_VMID" "${GUEST_BACKUP}/${item%%:*}" "${HOST_BACKUP}/${item%%:*}"
done
for f in dpkg-versions.txt dpkg-versions.sha256 mounts.txt; do
  pull_guest_file "$DEMO_VMID" "${GUEST_BACKUP}/${f}" "${HOST_BACKUP}/${f}"
done
ok "PVE host 副本：${HOST_BACKUP}"
readback_match "備份的 dpkg 版本清單 sha256" '^[0-9a-f]{64}$' \
  "$(tr -d '\n' < "${HOST_BACKUP}/dpkg-versions.sha256")"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "列出 guest 有、hypervisor sshkeys 欄位沒有的金鑰"
say "Cloud-Init 會依 hypervisor 的 sshkeys 欄位重寫 authorized key 集合。"
note "沒先列出，重置後就會失去那些金鑰的存取。"

urldecode "$(qmcfg "$DEMO_VMID" sshkeys)" | ssh_key_bodies > "${WORK}/hv-keys"
cat "${HOST_BACKUP}/_root_.ssh_authorized_keys" \
    "${HOST_BACKUP}/_home_mobagel_.ssh_authorized_keys" |
  ssh_key_bodies > "${WORK}/guest-keys"

say ""
say "hypervisor sshkeys 欄位金鑰數：$(wc -l < "${WORK}/hv-keys")"
say "guest authorized_keys 金鑰數：  $(wc -l < "${WORK}/guest-keys")"

comm -23 "${WORK}/guest-keys" "${WORK}/hv-keys" > "${HOST_BACKUP}/keys-only-in-guest.txt"
if [[ -s "${HOST_BACKUP}/keys-only-in-guest.txt" ]]; then
  warn "下列金鑰只存在於 guest，重置後會被 Cloud-Init 移除："
  sed 's/^/    /' "${HOST_BACKUP}/keys-only-in-guest.txt"
  say ""
  human_action "若仍需要這些金鑰，先把它們加進 VM ${DEMO_VMID} 的 sshkeys 欄位，再重跑本腳本。"
  gate "已確認可以接受移除這些金鑰？"
else
  ok "guest 沒有 hypervisor sshkeys 欄位以外的金鑰"
fi
note "清單已寫入 ${HOST_BACKUP}/keys-only-in-guest.txt"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "Cloud-Init 狀態重置並重新開機"
say "cloud-init clean --logs → qm cloudinit update → qm reboot。"
warn "所有 Cloud-Init 模組會以 first boot 身分重跑。"
note "自動套件升級已在票 02 關閉，備份已在 stage 2 完成，這是那個代價的涵蓋方式。"
gate "執行重置並重新開機？"

guest_exec_or_abort "$DEMO_VMID" "cloud-init clean --logs" "cloud-init clean 失敗" |
  sed 's/^/    /'
ok "cloud-init 狀態已清除"
qm cloudinit update "$DEMO_VMID"
ok "Cloud-Init drive 已依 hypervisor 設定重新產生"
qm reboot "$DEMO_VMID"
ok "已送出重新開機"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "等待 Demo 回來"
say "等待 guest agent 回應（最多 10 分鐘）…"
sleep 20
wait_agent "$DEMO_VMID" 600 ||
  abort "guest agent 在 10 分鐘內沒有回應；改用 PVE console 檢查開機狀況"
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "從 guest 內部驗證位址"
note "驗證讀的是 guest 內部的實際狀態，不是把 hypervisor 的設定讀回來。"
note "Demo 跑著 Docker，docker0 與 br-* 也是 scope global，所以比對的是「有沒有」而非「等不等於」。"

readback_contains "guest 內部位址" "=${DEMO_IP}/24" "$(guest_global_addrs "$DEMO_VMID")"
guest_gw=$(guest_exec_or_abort "$DEMO_VMID" \
  "ip -4 route show default | awk '{print \$3}' | head -n1" \
  "無法從 guest 讀取 default gateway")
readback "guest 內部 default gateway" "$EDGE_PRIVATE_IP" "$(printf '%s' "$guest_gw" | tr -d '\n')"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "與備份逐項比對"
for item in "${FILES[@]}"; do
  backup_name="${item%%:*}"; live_path="${item##*:}"
  say ""
  say "$live_path"
  if guest_exec "$DEMO_VMID" "diff -u '${GUEST_BACKUP}/${backup_name}' '${live_path}'" \
       > "${WORK}/diff" 2>&1; then
    ok "與備份相同"
  else
    warn "與備份有差異："
    sed 's/^/    /' "${WORK}/diff"
    cp "${WORK}/diff" "${HOST_BACKUP}/diff-${backup_name}.txt"
    note "差異已記錄於 ${HOST_BACKUP}/diff-${backup_name}.txt"
    if [[ "$live_path" == "/etc/fstab" ]]; then
      human_action "掛載表被改寫。大資料卷的掛載必須保留；請比對後決定是否還原。"
      gate "已確認 /etc/fstab 的差異可以接受？"
    fi
  fi
done

for item in "${DIRS[@]}"; do
  backup_name="${item%%:*}"; live_path="${item##*:}"
  say ""
  say "$live_path"
  if ! guest_exec "$DEMO_VMID" "test -d '${GUEST_BACKUP}/${backup_name}'" >/dev/null; then
    note "重置前不存在，略過"
    continue
  fi
  if guest_exec "$DEMO_VMID" "diff -ru '${GUEST_BACKUP}/${backup_name}' '${live_path}'" \
       > "${WORK}/diff" 2>&1; then
    ok "與備份相同"
  else
    warn "與備份有差異（網路設定目錄預期會被 Cloud-Init 重寫）："
    sed 's/^/    /' "${WORK}/diff"
    cp "${WORK}/diff" "${HOST_BACKUP}/diff-${backup_name}.txt"
    note "差異已記錄於 ${HOST_BACKUP}/diff-${backup_name}.txt"
  fi
done

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "確認大資料卷仍掛在原本路徑且檔案可讀"
guest_exec_or_abort "$DEMO_VMID" "findmnt -rno TARGET,SOURCE,FSTYPE | sort" \
  "無法讀取掛載表" > "${WORK}/mounts-after"
if diff -u "${HOST_BACKUP}/mounts.txt" "${WORK}/mounts-after" > "${WORK}/mounts-diff"; then
  ok "掛載表與重置前相同"
else
  warn "掛載表有差異："
  sed 's/^/    /' "${WORK}/mounts-diff"
  cp "${WORK}/mounts-diff" "${HOST_BACKUP}/diff-mounts.txt"
  human_action "確認大資料卷仍掛在原本路徑；不符時停止並先修復掛載。"
  gate "掛載差異可以接受？"
fi

say ""
say "非 root 檔案系統的可讀性："
guest_exec_or_abort "$DEMO_VMID" "
for m in \$(findmnt -rno TARGET -t ext4,xfs,btrfs | grep -v '^/\$'); do
  n=\$(ls -A \"\$m\" 2>/dev/null | wc -l)
  printf '%s files=%s\n' \"\$m\" \"\$n\"
done" "無法列出檔案系統內容" | sed 's/^/    /'
gate "各掛載點的檔案都讀得到？"

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "確認未升級任何套件"
before_sha=$(tr -d '\n' < "${HOST_BACKUP}/dpkg-versions.sha256")
after_sha=$(guest_exec_or_abort "$DEMO_VMID" \
  "dpkg-query -W -f='\${Package} \${Version}\n' | sort | sha256sum | awk '{print \$1}'" \
  "無法讀取套件版本清單")
readback "dpkg 版本清單 sha256" "$before_sha" "$(printf '%s' "$after_sha" | tr -d '\n')"
ok "沒有任何套件或作業系統版本被升級"

# ── 10 ────────────────────────────────────────────────────────────────────
stage "Edge 可以連到 ${DEMO_IP}"
if qm agent "$EDGE_VMID" ping >/dev/null 2>&1; then
  if guest_exec "$EDGE_VMID" "ping -c 2 -W 2 ${DEMO_IP}" | sed 's/^/    /'; then
    ok "Edge 可以連到 ${DEMO_IP}"
  else
    abort "Edge 無法連到 ${DEMO_IP}"
  fi
else
  warn "Edge VM ${EDGE_VMID} 的 guest agent 不可用。"
  human_action "從 Edge 執行：ping -c 2 ${DEMO_IP}"
  gate "Edge 可以連到 ${DEMO_IP}？"
fi

# ── 11 ────────────────────────────────────────────────────────────────────
stage "UAT 未受影響，且未建立任何新憑證"
cipassword=$(qmcfg "$DEMO_VMID" cipassword)
[[ -z "$cipassword" ]] || abort "VM ${DEMO_VMID} 出現 cipassword；本工作不得建立任何新憑證"
ok "Demo 沒有 Cloud-Init 密碼；全程未建立新憑證"

verify_uat_entrance

finish "票 03 完成：Demo 內部持有 ${DEMO_IP}"
say "備份與比對紀錄：${HOST_BACKUP}"
say "guest 內備份：${GUEST_BACKUP}"
say "下一步：./04-inventory.sh"
