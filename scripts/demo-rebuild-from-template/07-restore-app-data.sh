#!/usr/bin/env bash
#
# 票 07 — 還原保全的應用資料，並確認重開機後整台機器自己站得住。
#
# 還原是有選擇的，不是無條件照搬。舊 /srv/typeai-demo 裡混了三種東西：
#   secret（五個）      → 還原，0600，擁有者 mobagel
#   設定與文件（兩個）  → 還原，供日後參考
#   舊執行產物與 tls.*  → 不還原，留在保全副本裡
#
# tls.crt／tls.key 明確不還原：2026-09-09 就到期，而 ADR-0001 要的是永久入口。
#
# Keycloak 的 volume 還原成一個 tar 檔放著，不建立 docker volume —— 新機器上還
# 沒有 stack，憑空造一個沒人用卻被當成資料庫的 volume 只會害人。
#
# Blocked by 票 06。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

HOST_DIR=$(preserve_dir)
REPORT="${HOST_DIR}/preserve-report.md"
APP_SRC="${HOST_DIR}/app"
APP_LIST="${HOST_DIR}/app.sha256"

# expected_sha NAME — 票 01 清單裡該檔的 SHA-256（清單的路徑是 ./NAME）。
expected_sha() { awk -v k="./$1" '$2 == k { print $1 }' "$APP_LIST"; }

# guest_sha NAME — guest 上還原後的 SHA-256。
guest_sha() {
  guest_exec_or_abort "$DEMO_VMID" "sha256sum '${APP_DIR}/$1' | cut -d' ' -f1" \
    "無法計算 ${APP_DIR}/$1 的 SHA-256" | tr -d ' \r\n'
}

TOTAL_STAGES=8
banner "票 07 — 還原應用資料並重開機驗收"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "VM ${DEMO_VMID} 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"
[[ -d "$APP_SRC" && -f "$APP_LIST" ]] || abort "找不到票 01 的 ${APP_SRC}／${APP_LIST}"
[[ -f "${HOST_DIR}/${PG_VOLUME_TAR}" ]] || abort "找不到 ${HOST_DIR}/${PG_VOLUME_TAR}"
readback "repo 已在原處（票 06）" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" "test -d '${CHECKOUT_DIR}/.git' && echo yes || echo no" \
     "無法檢查 checkout" | tr -d '\r\n')"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "分類：哪些還原、哪些不還原"
say "還原（secret，0600）：${SECRET_FILES[*]}"
say "還原（設定與文件，0644）：${KEEP_FILES[*]}"
say "不還原（留在保全副本裡）：${NO_RESTORE[*]}"
say ""
note "tls.crt／tls.key 2026-09-09 到期，而 ADR-0001 要的是永久入口；日後真的要開"
note "443 端點時另外處理，不讓一張快過期的憑證混進新機器。"
for f in "${SECRET_FILES[@]}" "${KEEP_FILES[@]}"; do
  [[ -f "${APP_SRC}/${f}" ]] || abort "保全副本裡少了 ${f}"
  [[ -n "$(expected_sha "$f")" ]] || abort "票 01 的清單裡沒有 ${f} 的 SHA-256"
done
ok "七個要還原的檔案都在，且都有票 01 的 SHA-256 可比對"
gate "照這個分類還原？"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "還原 ${APP_DIR}"
guest_exec_or_abort "$DEMO_VMID" \
  "install -d -m 0750 -o mobagel -g mobagel '${APP_DIR}'" \
  "無法建立 ${APP_DIR}" >/dev/null

for f in "${SECRET_FILES[@]}"; do
  push_guest_blob "$DEMO_VMID" "${APP_SRC}/${f}" "${APP_DIR}/${f}" 0600
done
for f in "${KEEP_FILES[@]}"; do
  push_guest_blob "$DEMO_VMID" "${APP_SRC}/${f}" "${APP_DIR}/${f}" 0644
done
guest_exec_or_abort "$DEMO_VMID" "chown -R mobagel:mobagel '${APP_DIR}'" \
  "無法把 ${APP_DIR} 的擁有者改成 mobagel" >/dev/null

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "逐檔讀回"
for f in "${SECRET_FILES[@]}"; do
  readback "${f} 的權限" "600 mobagel:mobagel" \
    "$(guest_exec_or_abort "$DEMO_VMID" "stat -c '%a %U:%G' '${APP_DIR}/${f}'" \
       "讀不到 ${f}" | tr -d '\r\n')"
  readback "${f} 的 SHA-256 與票 01 相符" "$(expected_sha "$f")" "$(guest_sha "$f")"
done
for f in "${KEEP_FILES[@]}"; do
  readback "${f} 的權限" "644 mobagel:mobagel" \
    "$(guest_exec_or_abort "$DEMO_VMID" "stat -c '%a %U:%G' '${APP_DIR}/${f}'" \
       "讀不到 ${f}" | tr -d '\r\n')"
  readback "${f} 的 SHA-256 與票 01 相符" "$(expected_sha "$f")" "$(guest_sha "$f")"
done

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "不還原的東西確實沒有被帶進來"
for f in "${NO_RESTORE[@]}"; do
  readback "${f} 不在新機器上" "absent" \
    "$(guest_exec_or_abort "$DEMO_VMID" \
       "test -e '${APP_DIR}/${f}' && echo present || echo absent" \
       "無法檢查 ${f}" | tr -d '\r\n')"
done
ok "舊 log、截圖與那張快到期的憑證都留在保全副本裡"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Keycloak 的資料庫 volume"
pg_bytes=$(stat -c %s "${HOST_DIR}/${PG_VOLUME_TAR}")
pg_chunks=$(chunk_count "$pg_bytes" "$CHUNK_PUSH_BYTES") || abort "段長設定有誤"
say "${PG_VOLUME_TAR}：${pg_bytes} bytes，要分 ${pg_chunks} 段送進 guest。"
note "每段一次 qm guest exec，這條通道很窄；${pg_chunks} 段大約要跑十幾分鐘到半小時。"
note "中途失敗就整段重跑（目標檔會先清空），不會留下寫了一半的檔案。"
say ""
note "還原成一個 tar 檔放在 ${APP_DIR}，不建立 docker volume：新機器上還沒有 stack，"
note "等真的要跑 Keycloak 時再由那時候的 compose 決定怎麼掛。"
# 票 07：這一項是「可選的，且要有閘門」。答不要就跳過，封存留在保全目錄裡，
# 本票其餘部分照跑 —— 不是把整個序列停掉。
PG_RESTORED=no
if confirm "要送 Keycloak 的 volume 封存嗎？"; then
  push_guest_blob "$DEMO_VMID" "${HOST_DIR}/${PG_VOLUME_TAR}" "${APP_DIR}/${PG_VOLUME_TAR}" 0600
  guest_exec_or_abort "$DEMO_VMID" "chown mobagel:mobagel '${APP_DIR}/${PG_VOLUME_TAR}'" \
    "無法設定 ${PG_VOLUME_TAR} 的擁有者" >/dev/null
  PG_RESTORED=yes
else
  warn "跳過；封存留在 ${HOST_DIR}/${PG_VOLUME_TAR}，日後要用再送"
  note "保全產物不會被刪，所以跳過不代表失去這份資料。"
fi
readback "沒有建立任何 docker volume" "0" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker volume ls -q | wc -l" \
     "無法清點 docker volume" | tr -d ' \r\n')"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "開機自啟與重開機驗收"
qm set "$DEMO_VMID" --onboot 1 || abort "無法設定 onboot"
readback "onboot" "1" "$(qmcfg "$DEMO_VMID" onboot)"
say ""
note "重開機驗的是「整台機器自己站得起來」：位址、/srv、Docker、repo 與還原的"
note "檔案都要自己回來，不需要有人補動作。"
gate "重新開機？"
reboot_and_wait "$DEMO_VMID" 600

addrs=$(guest_global_addrs "$DEMO_VMID")
readback_contains "重開機後的位址" "${DEMO_IP}/24" "$addrs"
if has_lan_addr "$addrs"; then
  abort "重開機後出現對外網段的位址：${addrs}"
fi
readback "/srv 已掛載" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno TARGET /srv >/dev/null && echo yes || echo no" \
     "無法檢查 /srv" | tr -d '\r\n')"
readback "Docker 可用" "active" \
  "$(guest_exec_or_abort "$DEMO_VMID" "systemctl is-active docker" \
     "無法讀取 docker 狀態" | tr -d '\r\n')"
readback "repo 在原處且乾淨" "0" \
  "$(guest_exec_or_abort "$DEMO_VMID" "git -C '${CHECKOUT_DIR}' status --porcelain | wc -l" \
     "讀不到 git status" | tr -d ' \r\n')"
for f in "${SECRET_FILES[@]}"; do
  readback "${f} 權限未變" "600 mobagel:mobagel" \
    "$(guest_exec_or_abort "$DEMO_VMID" "stat -c '%a %U:%G' '${APP_DIR}/${f}'" \
       "讀不到 ${f}" | tr -d '\r\n')"
done
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "重開機後 guest agent 沒有回應"
ok "guest agent 重開機後正常回應"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "收尾"
say ""
guest_exec_or_abort "$DEMO_VMID" "ls -la '${APP_DIR}'" "無法列出 ${APP_DIR}" | sed 's/^/    /'
say ""
{
  printf '\n### 還原（票 07）\n\n'
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| 還原位置 | `%s`（0750 mobagel） |\n' "$APP_DIR"
  printf '| secret | %s 個，0600，SHA-256 與票 01 相符，值 `<redacted>` |\n' "${#SECRET_FILES[@]}"
  printf '| 設定與文件 | %s |\n' "${KEEP_FILES[*]}"
  printf '| 未還原 | %s |\n' "${NO_RESTORE[*]}"
  if [[ "$PG_RESTORED" == yes ]]; then
    printf '| Keycloak volume | `%s/%s`（tar，未建立 docker volume） |\n' "$APP_DIR" "$PG_VOLUME_TAR"
  else
    printf '| Keycloak volume | 未還原（可選項，封存留在保全目錄） |\n'
  fi
  printf '| onboot | 1 |\n'
} >> "$REPORT"
verify_uat_entrance

finish "票 07 完成：新機器重開機後自己站得住"
say "保全產物與 vzdump 封存都還在，等你明確說可以刪為止："
say "  · ${HOST_DIR}"
say "  · $(sed -n 's/^| 封存 | `\(.*\)` |$/\1/p' "$REPORT" | head -n1)"
say "下一步：票 08 是 repo 端的收尾，已隨本次變更完成，不需要在 PVE 上執行。"
