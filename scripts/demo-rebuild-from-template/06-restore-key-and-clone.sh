#!/usr/bin/env bash
#
# 票 06 — 還原 deploy key，把 repo clone 進 /srv。
#
# 這是整個重建的目的（ADR-0005）。金鑰是 secret：只經 guest agent 通道送進去，
# 內容不寫進任何報告、不進 repo，報告只記檔名與 fingerprint。
#
# clone 用 mobagel 身分做，不是 root —— 用 root clone 會留下一整棵 root 擁有的
# 檔案，之後每個 git 指令都要處理 dubious ownership（舊機器上就是這樣）。
#
# Blocked by 票 05。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

HOST_DIR=$(preserve_dir)
REPORT="${HOST_DIR}/preserve-report.md"

TOTAL_STAGES=7
banner "票 06 — 還原 deploy key 並 clone repo 到 ${CHECKOUT_DIR}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "VM ${DEMO_VMID} 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"
[[ -d "${HOST_DIR}/ssh" ]] || abort "找不到票 01 保全的 ${HOST_DIR}/ssh"
for f in "${SSH_FILES[@]}"; do
  [[ -f "${HOST_DIR}/ssh/${f}" ]] || abort "保全副本裡少了 ${f}"
done
ok "三個金鑰檔都在保全副本裡"

FP_RECORDED=$(sed -n 's/^公鑰 fingerprint：`\(.*\)`$/\1/p' "$REPORT" | head -n1)
[[ -n "$FP_RECORDED" ]] || abort "報告裡沒有票 01 記錄的 fingerprint"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "送金鑰進 guest"
note "私鑰 0600、公鑰 0644、~/.ssh 0700，擁有者都是 mobagel。"
guest_exec_or_abort "$DEMO_VMID" \
  "install -d -m 0700 -o mobagel -g mobagel '${SSH_DIR}'" \
  "無法建立 ${SSH_DIR}" >/dev/null

push_guest_blob "$DEMO_VMID" "${HOST_DIR}/ssh/${DEPLOY_KEY}" "${SSH_DIR}/${DEPLOY_KEY}" 0600
push_guest_blob "$DEMO_VMID" "${HOST_DIR}/ssh/${DEPLOY_KEY}.pub" "${SSH_DIR}/${DEPLOY_KEY}.pub" 0644
push_guest_blob "$DEMO_VMID" "${HOST_DIR}/ssh/known_hosts" "${SSH_DIR}/known_hosts" 0644

# 金鑰檔名不是預設的，沒有這份 config 就得每次 -i 指定。IdentitiesOnly 避免
# agent 裡其他金鑰先被試、被 GitLab 記成失敗嘗試。
printf 'Host %s\n    IdentityFile %s/%s\n    IdentitiesOnly yes\n' \
  "$REPO_HOST" "$SSH_DIR" "$DEPLOY_KEY" |
  guest_put_file "$DEMO_VMID" "${SSH_DIR}/config" 0600

guest_exec_or_abort "$DEMO_VMID" "chown -R mobagel:mobagel '${SSH_DIR}'" \
  "無法把 ${SSH_DIR} 的擁有者改成 mobagel" >/dev/null

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "讀回權限與 fingerprint"
readback "${SSH_DIR}" "700 mobagel:mobagel" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c '%a %U:%G' '${SSH_DIR}'" "讀不到 ${SSH_DIR}" | tr -d '\r\n')"
readback "私鑰" "600 mobagel:mobagel" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c '%a %U:%G' '${SSH_DIR}/${DEPLOY_KEY}'" "讀不到私鑰" | tr -d '\r\n')"
readback "公鑰" "644 mobagel:mobagel" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c '%a %U:%G' '${SSH_DIR}/${DEPLOY_KEY}.pub'" "讀不到公鑰" | tr -d '\r\n')"
readback "known_hosts" "644 mobagel:mobagel" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c '%a %U:%G' '${SSH_DIR}/known_hosts'" "讀不到 known_hosts" | tr -d '\r\n')"
readback "公鑰 fingerprint 與票 01 記錄相符" "$FP_RECORDED" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "ssh-keygen -lf '${SSH_DIR}/${DEPLOY_KEY}.pub' | awk '{print \$2}'" \
     "無法讀取 fingerprint" | tr -d '\r\n')"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "GitLab 認證"
note "known_hosts 已還原，所以第一次連線不需要有人回答 host key 的提示。"
rc=0
auth=$(guest_exec "$DEMO_VMID" \
  "sudo -u mobagel -H ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -T git@${REPO_HOST} 2>&1") || rc=$?
printf '%s\n' "$auth" | sed 's/^/    /'
# GitLab 的 shell 一律以非 0 結束，訊息才是判準。
if ! printf '%s' "$auth" | grep -qi 'welcome to gitlab'; then
  human_action "金鑰無法通過 GitLab 認證（已撤銷或權限變更？）。"
  say "spec 明訂：不自行產生替代金鑰。請人到 GitLab 確認這把 deploy key 的狀態。"
  abort "GitLab 認證失敗（ssh 結束碼 ${rc}）"
fi
ok "GitLab 接受這把金鑰"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "clone"
say "${REPO_URL} → ${CHECKOUT_DIR}（branch ${REPO_BRANCH}，擁有者 mobagel）"
note "反向動作：以 mobagel 身分刪掉 ${CHECKOUT_DIR} 後重跑本 stage。"
gate "開始 clone？"

existing=$(guest_exec_or_abort "$DEMO_VMID" \
  "if [ -d '${CHECKOUT_DIR}' ]; then ls -A '${CHECKOUT_DIR}' | wc -l; else echo 0; fi" \
  "無法檢查 ${CHECKOUT_DIR}" | tr -d ' \r\n')
[[ "$existing" == "0" ]] || abort "${CHECKOUT_DIR} 已存在且不是空的；先確認它是什麼再決定"

GUEST_EXEC_TIMEOUT=3600
rc=0
out=$(guest_exec "$DEMO_VMID" "
set -e
install -d -m 0755 -o mobagel -g mobagel '${CHECKOUT_DIR}'
sudo -u mobagel -H git clone --branch '${REPO_BRANCH}' '${REPO_URL}' '${CHECKOUT_DIR}'
") || rc=$?
printf '%s\n' "$out" | tail -n5 | sed 's/^/    /'
if [[ "$rc" -ne 0 ]]; then
  human_action "clone 失敗。spec 明訂：不自行產生替代金鑰，也不改用其他來源。"
  say "請人確認 GitLab 上這把 deploy key 的權限，以及 ${REPO_HOST} 的可達性。"
  abort "git clone 失敗（$(_guest_rc_reason "$rc")）"
fi
ok "clone 完成（結束碼不算證據，下一步才是）"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "驗證"
readback "分支" "$REPO_BRANCH" \
  "$(guest_exec_or_abort "$DEMO_VMID" "git -C '${CHECKOUT_DIR}' rev-parse --abbrev-ref HEAD" \
     "讀不到分支" | tr -d '\r\n')"
readback "working tree 乾淨（0 個變更）" "0" \
  "$(guest_exec_or_abort "$DEMO_VMID" "git -C '${CHECKOUT_DIR}' status --porcelain | wc -l" \
     "讀不到 git status" | tr -d ' \r\n')"
readback "checkout 的擁有者" "mobagel" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c %U '${CHECKOUT_DIR}/.git'" \
     "讀不到擁有者" | tr -d '\r\n')"
guest_exec_or_abort "$DEMO_VMID" \
  "sudo -u mobagel -H git -C '${CHECKOUT_DIR}' pull --ff-only" \
  "git pull 失敗" | sed 's/^/    /'
ok "git pull 可正常執行"

for e in "${REPO_ENTRIES[@]}"; do
  readback "${e} 存在" "yes" \
    "$(guest_exec_or_abort "$DEMO_VMID" \
       "test -e '${CHECKOUT_DIR}/${e}' && echo yes || echo no" "無法檢查 ${e}" | tr -d '\r\n')"
done

REV=$(guest_exec_or_abort "$DEMO_VMID" "git -C '${CHECKOUT_DIR}' rev-parse HEAD" \
  "讀不到 revision" | tr -d '\r\n')
ok "revision ${REV}"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "剩餘空間與記錄"
require_free_pct "$DEMO_VMID" /srv
say ""
guest_exec_or_abort "$DEMO_VMID" "df -hT /srv" "無法讀取 /srv 用量" | sed 's/^/    /'
{
  printf '\n### repo（票 06）\n\n'
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| checkout | `%s` |\n' "$CHECKOUT_DIR"
  printf '| branch / revision | `%s` / `%s` |\n' "$REPO_BRANCH" "$REV"
  printf '| deploy key | `%s`（fingerprint `%s`，內容 `<redacted>`） |\n' \
    "${SSH_DIR}/${DEPLOY_KEY}" "$FP_RECORDED"
} >> "$REPORT"
say ""
human_action "確認上面的輸出與報告都沒有出現金鑰內容（只該有 fingerprint）。"
gate "確認過了？"

finish "票 06 完成：${CHECKOUT_DIR} 是 ${REPO_BRANCH} 的完整 checkout"
say "下一步：PRESERVE_DIR=${HOST_DIR} ./07-restore-app-data.sh"
