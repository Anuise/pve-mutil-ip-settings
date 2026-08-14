#!/usr/bin/env bash
#
# 票 01 — 保全舊 VM 103 上不在 repo 裡的東西。
#
# 三類：GitLab deploy key、/srv/typeai-demo 整包、Keycloak 的資料庫 volume。
# 外加一份參考資料，用來確認新機器的形狀對不對。
#
# 全程不改動應用狀態：容器不啟動、檔案不搬不刪。唯一的寫入是 guest 內的暫存
# 目錄，它隨這台機器一起消失。
#
# 產物一律留在 PVE host 的 /root/demo-preserve-<TS>/，**沒有任何一個檔案可以
# 進 repo**。報告只記檔名、大小與 SHA-256，secret 的值一律 <redacted>。
#
# Blocked by —。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
HOST_DIR="/root/demo-preserve-${TS}"
GUEST_STAGE="/root/demo-preserve-${TS}"
REPORT="${HOST_DIR}/preserve-report.md"

# preserve_tree NAME SRC_DIR ITEM… — 在 guest 內打包並逐檔算 SHA-256，取回主機、
# 驗整包 SHA-256，解開後再以 sha256sum -c 逐檔複驗。
#
# 為什麼先打包再分段取回：guest agent 那條通道是 base64 的 JSON，一個一個檔案
# 拉會拉幾百次，而且每次失敗都只說「讀不到」。打包成一個 tar，只有一件事要驗。
preserve_tree() {
  local name="$1" src="$2"; shift 2
  local items tar_guest list_guest
  items=$(printf "'%s' " "$@")
  tar_guest="${GUEST_STAGE}/${name}.tar"
  list_guest="${GUEST_STAGE}/${name}.sha256"

  guest_exec_or_abort "$DEMO_VMID" "
set -e
cd '${src}'
tar -cf '${tar_guest}' ${items}
find ${items} -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum > '${list_guest}'
" "無法在 guest 內封存 ${src}" >/dev/null

  pull_guest_blob "$DEMO_VMID" "$tar_guest" "${HOST_DIR}/${name}.tar"
  pull_guest_file "$DEMO_VMID" "$list_guest" "${HOST_DIR}/${name}.sha256"

  mkdir -p "${HOST_DIR}/${name}"
  tar -C "${HOST_DIR}/${name}" -xf "${HOST_DIR}/${name}.tar"
  ( cd "${HOST_DIR}/${name}" && sha256sum -c "${HOST_DIR}/${name}.sha256" >/dev/null ) ||
    abort "${name} 解開後的逐檔 SHA-256 與 guest 內不符"
  ok "${name}：逐檔 SHA-256 與 guest 內相符（$(wc -l < "${HOST_DIR}/${name}.sha256") 個檔案）"
}

# report_section TITLE DIR — 把某一包的檔名、大小與 SHA-256 寫進報告。值不記。
report_section() {
  local title="$1" dir="$2" bytes f sha
  {
    printf '\n### %s\n\n' "$title"
    printf '| 檔案 | bytes | SHA-256 | 值 |\n| --- | --- | --- | --- |\n'
    while read -r sha f; do
      [[ -n "$f" ]] || continue
      bytes=$(stat -c %s "${dir}/${f}" 2>/dev/null || echo '?')
      printf '| `%s` | %s | `%s` | `<redacted>` |\n' "$f" "$bytes" "$sha"
    done < "${dir}.sha256"
  } >> "$REPORT"
}

TOTAL_STAGES=7
banner "票 01 — 保全 VM ${DEMO_VMID} 上不在 repo 裡的東西"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
vm_exists "$DEMO_VMID" || abort "找不到 VM ${DEMO_VMID}"
say "本票全程不改動應用狀態：容器不啟動、檔案不搬不刪。"
note "唯一的寫入是 guest 的 ${GUEST_STAGE}（暫存），它隨這台機器一起消失。"

if [[ "$(qmstatus "$DEMO_VMID")" != "running" ]]; then
  warn "VM ${DEMO_VMID} 目前不是 running，無法經 guest agent 取出資料"
  gate "開機以取出保全資料？（票 02 會再把它停下來）"
  qm start "$DEMO_VMID"
  wait_agent "$DEMO_VMID" 600 || abort "guest agent 在 10 分鐘內沒有回應"
fi
readback "VM ${DEMO_VMID} 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "建立保全目錄"
install -d -m 0700 -o root -g root "$HOST_DIR"
readback "${HOST_DIR} 的權限" "700 root:root" "$(stat -c '%a %U:%G' "$HOST_DIR")"
guest_exec_or_abort "$DEMO_VMID" "mkdir -p '${GUEST_STAGE}' && chmod 0700 '${GUEST_STAGE}'" \
  "無法在 guest 建立暫存目錄" >/dev/null
ok "guest 暫存目錄：${GUEST_STAGE}"

printf '# Demo 保全報告 %s\n\n' "$TS" > "$REPORT"
chmod 0600 "$REPORT"
{
  printf '來源：VM %s `%s`（本報告產生後即將銷毀）\n\n' "$DEMO_VMID" "$DEMO_NAME"
  printf '**這份報告與同目錄的所有產物都不進 repo。** secret 的值一律 `<redacted>`，\n'
  printf 'agent 未讀取任何 secret 內容。\n'
} >> "$REPORT"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "GitLab deploy key"
say "${SSH_DIR} 的 ${SSH_FILES[*]}"
note "沒有它，新機器 clone 不了 repo，而重新簽發要人去 GitLab 操作（ADR-0005）。"
preserve_tree ssh "$SSH_DIR" "${SSH_FILES[@]}"

fp=$(ssh-keygen -lf "${HOST_DIR}/ssh/${DEPLOY_KEY}.pub" | awk '{print $2}')
ok "公鑰 fingerprint：${fp}"
report_section "GitLab deploy key（${SSH_DIR}）" "${HOST_DIR}/ssh"
printf '\n公鑰 fingerprint：`%s`\n' "$fp" >> "$REPORT"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "${APP_DIR} 整包"
say "手工放上去的 secret、設定與文件，沒有任何一份在 repo 裡。"
listing=$(guest_exec_or_abort "$DEMO_VMID" "ls -A '${APP_DIR}'" \
  "無法列出 ${APP_DIR}" | tr '\n' ' ')
say "guest 上的內容：${listing}"
preserve_tree app "$APP_DIR" .

for f in "${SECRET_FILES[@]}" "${KEEP_FILES[@]}"; do
  [[ -e "${HOST_DIR}/app/${f}" ]] || abort "封存裡少了 ${f}"
done
ok "$(( ${#SECRET_FILES[@]} + ${#KEEP_FILES[@]} )) 個必要的檔名都在封存裡"
report_section "${APP_DIR}" "${HOST_DIR}/app"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Keycloak 的資料庫 volume"
note "容器是 Exited，直接打包 volume 目錄即可，不需要啟動它。"
vol=$(guest_exec_or_abort "$DEMO_VMID" \
  "docker inspect -f '{{range .Mounts}}{{.Source}}{{\"\\n\"}}{{end}}' '${DEMO_PG}' | head -n1" \
  "無法讀取 ${DEMO_PG} 的 volume 位置" | tr -d '\r\n')
[[ -n "$vol" ]] || abort "${DEMO_PG} 沒有掛載任何 volume"
say "volume 目錄：${vol}"

vol_bytes=$(guest_exec_or_abort "$DEMO_VMID" "du -sb '${vol}' | cut -f1" \
  "無法量測 volume 大小" | tr -d '\r\n')
say "volume 內容 $(( vol_bytes / 1024 / 1024 )) MiB（docker system df 報 66.65 MB）"
note "tar 會比目錄本身略大（表頭與對齊），兩者不會剛好相等。"
# 差太多就是打包錯目錄，或這顆 volume 已經不是當初量到的那一顆。
if [[ "$vol_bytes" -lt 50000000 || "$vol_bytes" -gt 90000000 ]]; then
  warn "與 docker system df 報的 66.65 MB 差距過大"
  gate "確認這就是要保全的 Keycloak 資料庫 volume？"
fi

guest_exec_or_abort "$DEMO_VMID" \
  "tar -C '$(dirname "$vol")' -cf '${GUEST_STAGE}/pg-volume.tar' '$(basename "$vol")'" \
  "無法封存 ${DEMO_PG} 的 volume" >/dev/null
pull_guest_blob "$DEMO_VMID" "${GUEST_STAGE}/pg-volume.tar" "${HOST_DIR}/${PG_VOLUME_TAR}"

{
  printf '\n### Keycloak 資料庫 volume\n\n'
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| 容器 | `%s` |\n' "$DEMO_PG"
  printf '| guest 內位置 | `%s` |\n' "$vol"
  printf '| 內容大小 | %s bytes |\n' "$vol_bytes"
  printf '| 封存 | `%s` |\n' "$PG_VOLUME_TAR"
  printf '| 封存大小 | %s bytes |\n' "$(stat -c %s "${HOST_DIR}/${PG_VOLUME_TAR}")"
  printf '| 封存 SHA-256 | `%s` |\n' \
    "$(sha256sum "${HOST_DIR}/${PG_VOLUME_TAR}" | cut -d' ' -f1)"
} >> "$REPORT"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "參考資料（不是 secret，用來對照新機器的形狀）"
guest_exec_or_abort "$DEMO_VMID" "
{
  echo '## /etc/resolv.conf';       cat /etc/resolv.conf 2>/dev/null
  echo; echo '## /etc/netplan';     for f in /etc/netplan/*; do echo \"--- \$f\"; cat \"\$f\"; done 2>/dev/null
  echo; echo '## /etc/fstab';       cat /etc/fstab 2>/dev/null
  echo; echo '## /etc/docker/daemon.json'; cat /etc/docker/daemon.json 2>/dev/null
  echo; echo '## docker images';    docker images 2>/dev/null
  echo; echo '## docker ps -a';     docker ps -a 2>/dev/null
  echo; echo '## lsblk';            lsblk 2>/dev/null
  echo; echo '## lvs';              lvs 2>/dev/null
  echo; echo '## df -hT';           df -hT 2>/dev/null
} > '${GUEST_STAGE}/reference.txt' 2>&1
" "無法蒐集參考資料" >/dev/null
pull_guest_file "$DEMO_VMID" "${GUEST_STAGE}/reference.txt" "${HOST_DIR}/reference.txt"

# fstab 可能帶 CIFS 憑證、daemon.json 可能帶 registry 認證。
redact_secrets < "${HOST_DIR}/reference.txt" > "${HOST_DIR}/reference.redacted.txt"
mv -f "${HOST_DIR}/reference.redacted.txt" "${HOST_DIR}/reference.txt"

for want in resolv.conf netplan fstab daemon.json 'docker images' lsblk; do
  grep -q "$want" "${HOST_DIR}/reference.txt" || abort "參考資料缺少 ${want}"
done
ok "參考資料六項都在（票 04 的 nameserver 由此取得）"

ns=$(sed -n 's/^nameserver[[:space:]]\+//p' "${HOST_DIR}/reference.txt" | head -n1)
say "resolv.conf 的第一個 nameserver：${ns:-（未取得）}"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "報告與人工確認"
chmod -R go-rwx "$HOST_DIR"
say ""
say "保全目錄：${HOST_DIR}"
guest_exec "$DEMO_VMID" "ls -la '${GUEST_STAGE}'" | sed 's/^/    /' || true
say ""
ls -la "$HOST_DIR" | sed 's/^/    /'
say ""
human_action "打開 ${REPORT}，確認裡面沒有任何 secret 的值（只該有檔名、大小與 SHA-256）。"
gate "報告確認過，不含任何 secret 值？"

finish "票 01 完成：保全產物在 ${HOST_DIR}"
say "這個目錄與其中所有檔案都不進 repo。"
say "下一步：PRESERVE_DIR=${HOST_DIR} ./02-full-backup.sh"
