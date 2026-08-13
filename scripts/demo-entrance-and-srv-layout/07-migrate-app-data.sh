#!/usr/bin/env bash
#
# 票 07 — 把專案 checkout 從 /home/mobagel 搬到 /srv/platform。
#
# 複製、驗證、延後刪除：來源保留不刪，刪除由票 10 在票 09 驗收通過後執行。
# 引用舊絕對路徑的設定本票只負責「列出」；改指交給票 11 連同 stack 定義一起做，
# 因為那個改指等於重建容器。
#
# 家目錄本身不動。UAT 從未搬過家目錄；「結構參考 UAT」指的是應用資料的擺放。
#
# Blocked by 票 06。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
GUEST_STATE="/root/demo-migrate-${TS}"
HOST_STATE="$(pwd)/demo-migrate-${TS}"

SRC_DIR="${HOME_DIR}/${CHECKOUT_NAME}"
DST_DIR="${PLATFORM_ROOT}/${CHECKOUT_NAME}"

# 不搬的東西在 wizard.sh 的 KEEP_IN_HOME；這裡逐項驗證它們沒被順手帶走。

# manifest DIR — 型別、權限、擁有者與 symlink 目標，一行一項，可直接 diff。
manifest() {
  printf "cd '%s' && find . -mindepth 1 -printf '%%m %%U:%%G %%y %%p %%l\\n' | LC_ALL=C sort" "$1"
}

# checksums DIR — 每個一般檔案的 SHA-256。複製工具的結束碼不算證據。
checksums() {
  printf "cd '%s' && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum" "$1"
}

TOTAL_STAGES=8
banner "票 07 — ${CHECKOUT_NAME} 搬到 ${PLATFORM_ROOT}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"
readback "Docker 的 data-root（票 06 已完成）" "${PLATFORM_ROOT}/docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.DockerRootDir}}'" \
     "無法讀取 data-root" | tr -d '\n')"
readback "${PLATFORM_ROOT} 的來源" "/dev/mapper/vg_data-lv_docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE '${PLATFORM_ROOT}'" \
     "${PLATFORM_ROOT} 未掛載" | tr -d '\n')"
guest_exec "$DEMO_VMID" "test -d '${SRC_DIR}'" >/dev/null || abort "找不到來源 ${SRC_DIR}"
ok "來源 ${SRC_DIR} 存在"

existing=$(guest_exec_or_abort "$DEMO_VMID" \
  "if [ -d '${DST_DIR}' ]; then ls -A '${DST_DIR}' | wc -l; else echo 0; fi" \
  "無法檢查目標目錄" | tr -d '\n')
if [[ "$existing" != "0" ]]; then
  warn "${DST_DIR} 已存在且有 ${existing} 個項目（上一次執行中斷？）"
  note "續跑會覆蓋同名檔案；最終判準仍是 stage 4 的逐檔 SHA-256 比對。"
  gate "在既有目標上續跑？"
fi

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "量測來源並投影剩餘空間"
src_bytes=$(guest_exec_or_abort "$DEMO_VMID" "du -sb '${SRC_DIR}' | cut -f1" \
  "無法量測來源大小" | tr -d '\n')
avail_bytes=$(guest_exec_or_abort "$DEMO_VMID" \
  "df -PB1 '${PLATFORM_ROOT}' | awk 'NR==2 {print \$4}'" \
  "無法讀取 ${PLATFORM_ROOT} 的可用空間" | tr -d '\n')
size_bytes=$(guest_exec_or_abort "$DEMO_VMID" \
  "df -PB1 '${PLATFORM_ROOT}' | awk 'NR==2 {print \$2}'" \
  "無法讀取 ${PLATFORM_ROOT} 的總容量" | tr -d '\n')

say "來源大小：$(( src_bytes / 1024 / 1024 )) MiB"
say "${PLATFORM_ROOT} 可用：$(( avail_bytes / 1024 / 1024 )) MiB / 總量 $(( size_bytes / 1024 / 1024 )) MiB"

[[ "$src_bytes" -lt "$avail_bytes" ]] || abort "${PLATFORM_ROOT} 放不下來源"
projected_pct=$(( (avail_bytes - src_bytes) * 100 / size_bytes ))
say "搬移後投影剩餘：${projected_pct}%"
if [[ "$projected_pct" -lt "$MIN_FREE_PCT" ]]; then
  human_action "spec 的停止條款：投影剩餘不足 ${MIN_FREE_PCT}% 時停止，不得刪資料騰空間。"
  abort "投影剩餘 ${projected_pct}% 低於 ${MIN_FREE_PCT}%"
fi
ok "投影剩餘 ${projected_pct}%，未觸發停止條款"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "複製（保留屬性、hard link 與 sparse）"
say "${SRC_DIR} → ${DST_DIR}"
note "以 tar 串接複製：保留權限、擁有者、hard link、sparse 與 xattr/ACL。"
note "來源保留不刪。刪除是票 10 的事，且要等票 09 驗收通過。"
note "反向動作：rm -rf ${DST_DIR}（來源未動，所以刪掉目標就回到原狀）。"
gate "開始複製？"

guest_exec_or_abort "$DEMO_VMID" "
set -e
mkdir -p '${GUEST_STATE}' '${DST_DIR}'
chown --reference='${SRC_DIR}' '${DST_DIR}'
chmod --reference='${SRC_DIR}' '${DST_DIR}'
tar -C '${SRC_DIR}' --xattrs --acls -cSpf - . |
  tar -C '${DST_DIR}' --xattrs --acls -xpf -
" "複製失敗；來源未被改動，刪掉 ${DST_DIR} 即可重來" >/dev/null
ok "複製完成（結束碼不算證據，下一步才是）"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "逐檔 SHA-256 與屬性比對"
mkdir -p "$HOST_STATE"

# 掃全樹算 SHA-256 在數十萬個檔案上要跑很久，預設的 300 秒不夠。等不夠久的下場
# 不是報錯，是 PVE 提早回傳、清單只寫到一半，而比對還會說「相符」。
GUEST_EXEC_TIMEOUT=3600

guest_exec_or_abort "$DEMO_VMID" "$(manifest "$SRC_DIR") > '${GUEST_STATE}/src-manifest.txt'" \
  "無法產生來源 manifest" >/dev/null
guest_exec_or_abort "$DEMO_VMID" "$(manifest "$DST_DIR") > '${GUEST_STATE}/dst-manifest.txt'" \
  "無法產生目標 manifest" >/dev/null
guest_exec_or_abort "$DEMO_VMID" "$(checksums "$SRC_DIR") > '${GUEST_STATE}/src-sha256.txt'" \
  "無法計算來源 SHA-256" >/dev/null
guest_exec_or_abort "$DEMO_VMID" "$(checksums "$DST_DIR") > '${GUEST_STATE}/dst-sha256.txt'" \
  "無法計算目標 SHA-256" >/dev/null

note "比對在 guest 內做。manifest 與 checksum 有數萬行、數 MB，把它們搬回主機"
note "只為了跑 diff，是把大量資料塞進 guest agent 那條窄通道；需要的答案只有"
note "「相不相符」與不符的那幾行。完整清單留在 guest 的 ${GUEST_STATE}。"

say ""
# 不寫成 say "$(guest_exec_or_abort …)"：abort 在 command substitution 裡只殺得掉
# subshell，say 拿到空字串照樣回 0，序列會印完「已停止」再繼續跑下去。
counts=$(guest_exec_or_abort "$DEMO_VMID" "
printf '檔案數：來源 %s，目標 %s\n' \
  \"\$(wc -l < '${GUEST_STATE}/src-sha256.txt')\" \"\$(wc -l < '${GUEST_STATE}/dst-sha256.txt')\"
printf '項目數：來源 %s，目標 %s' \
  \"\$(wc -l < '${GUEST_STATE}/src-manifest.txt')\" \"\$(wc -l < '${GUEST_STATE}/dst-manifest.txt')\"
" "無法清點來源與目標")
say "$counts"

for kind in sha256 manifest; do
  case "$kind" in
    sha256)   label="每一個檔案的來源與目標 SHA-256"; fail="搬移不完整" ;;
    manifest) label="權限、擁有者、型別與 symlink 目標"; fail="屬性未完整保留" ;;
  esac
  n=$(guest_diff "$DEMO_VMID" \
    "${GUEST_STATE}/src-${kind}.txt" "${GUEST_STATE}/dst-${kind}.txt" \
    "${GUEST_STATE}/diff-${kind}.txt")
  if [[ "$n" == "0" ]]; then
    ok "${label}逐項相符"
    : > "${HOST_STATE}/diff-${kind}.txt"
  else
    warn "${label}不符（共 ${n} 行差異，前 40 行）："
    guest_exec "$DEMO_VMID" "head -40 '${GUEST_STATE}/diff-${kind}.txt'" |
      sed 's/^/    /' || true
    guest_exec "$DEMO_VMID" "head -200 '${GUEST_STATE}/diff-${kind}.txt'" \
      > "${HOST_STATE}/diff-${kind}.txt" || true
    abort "${fail}；來源仍在原處，刪掉 ${DST_DIR} 後重跑"
  fi
done
ok "比對紀錄：guest 的 ${GUEST_STATE}，主機的 ${HOST_STATE}"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "建立 ${PLATFORM_ROOT}/app-data"
note "比照 UAT 的形狀建成空目錄。Demo 目前的持久資料在 Docker volume 裡，"
note "隨 data-root 一起移動，本票不搬它。"

guest_exec_or_abort "$DEMO_VMID" "mkdir -p '${PLATFORM_ROOT}/app-data'" \
  "無法建立 app-data" >/dev/null
readback "app-data 是目錄" "d" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c %F '${PLATFORM_ROOT}/app-data' | cut -c1" \
     "無法讀取 app-data" | tr -d '\n')"
say ""
guest_exec_or_abort "$DEMO_VMID" "ls -la '${PLATFORM_ROOT}'" "無法列出 ${PLATFORM_ROOT}" |
  sed 's/^/    /'

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "家目錄與不搬的東西都沒被動到"
readback "來源仍在原處（票 10 才刪）" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" "test -d '${SRC_DIR}' && echo yes || echo no" \
     "無法檢查來源" | tr -d '\n')"
readback "家目錄本身未被搬移" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "test -d '${HOME_DIR}' && test -f '${HOME_DIR}/.bashrc' && echo yes || echo no" \
     "無法檢查家目錄" | tr -d '\n')"
readback "SSH 授權仍在家目錄" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "test -f '${HOME_DIR}/.ssh/authorized_keys' && echo yes || echo no" \
     "無法檢查 SSH 授權" | tr -d '\n')"
readback "沒有 user-level systemd unit（票 04 盤點如此）" "0" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "ls -1 '${HOME_DIR}/.config/systemd/user' 2>/dev/null | wc -l" \
     "無法檢查 user-level unit" | tr -d '\n')"

for d in "${KEEP_IN_HOME[@]}"; do
  in_home=$(guest_exec_or_abort "$DEMO_VMID" \
    "test -e '${HOME_DIR}/${d}' && echo yes || echo absent" "無法檢查 ${d}" | tr -d '\n')
  in_platform=$(guest_exec_or_abort "$DEMO_VMID" \
    "test -e '${PLATFORM_ROOT}/${d}' && echo yes || echo no" "無法檢查 ${d}" | tr -d '\n')
  [[ "$in_platform" == "no" ]] || abort "${d} 不該出現在 ${PLATFORM_ROOT}"
  ok "${d} 留在 ${HOME_DIR}（${in_home}），未出現在 ${PLATFORM_ROOT}"
done

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "列出引用舊路徑的設定，移交票 11"
note "本票只列出。改指等於重建容器，交給票 11 連同 stack 定義一起做。"

guest_exec "$DEMO_VMID" "
{
  echo '## container bind mounts'
  docker ps -aq | while read -r c; do
    docker inspect -f '{{.Name}}{{range .Mounts}} {{.Source}}->{{.Destination}}{{end}}' \"\$c\"
  done | grep '${HOME_DIR}' || echo '(none)'
  echo
  echo '## systemd units'
  grep -rlo '${HOME_DIR}' /etc/systemd/system /lib/systemd/system 2>/dev/null || echo '(none)'
  echo
  echo '## compose 與 .conf'
  grep -rno '${HOME_DIR}[^\" :]*' --include='*.yml' --include='*.yaml' --include='*.conf' \
    '${HOME_DIR}' /srv /etc 2>/dev/null | head -50 || echo '(none)'
} > '${GUEST_STATE}/old-path-refs.txt' 2>/dev/null
" >/dev/null || true
pull_guest_file "$DEMO_VMID" "${GUEST_STATE}/old-path-refs.txt" "${HOST_STATE}/old-path-refs.txt"

say ""
sed 's/^/    /' "${HOST_STATE}/old-path-refs.txt"
say ""
say "票 04 的盤點只找到一條：typeai-demo-kc 的 Keycloak realm import bind mount。"
say "新位置應為 ${DST_DIR}/type-ai-platform-infra/base/keycloak/realm-typeai.json"
gate "這份清單已交接給票 11？"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "剩餘空間與 UAT"
require_free_pct "$DEMO_VMID" "$PLATFORM_ROOT"
say ""
guest_exec_or_abort "$DEMO_VMID" "df -hT '${PLATFORM_ROOT}' '${HOME_DIR}'" \
  "無法讀取用量" | sed 's/^/    /'
verify_uat_entrance

finish "票 07 完成：${CHECKOUT_NAME} 已在 ${PLATFORM_ROOT}，來源保留"
say "比對紀錄（票 10 刪除前要重新確認的就是這份）：${HOST_STATE}"
say "guest 內副本：${GUEST_STATE}"
say "下一步：./11-demo-443-endpoint.sh"
