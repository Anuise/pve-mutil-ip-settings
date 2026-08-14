# shellcheck shell=bash
#
# 本 spec（Demo 從範本 109 重建）的共用 wizard library。
# 由同目錄的 NN-*.sh 以 `source` 載入，不單獨執行。
#
# 畫面、確認閘門、讀回驗證與 guest agent 通道沿用上一個 spec 的 wizard.sh，
# 不重寫一份 —— 那些函式帶著幾次現場失敗的教訓（abort 走 stderr、guest_exec
# 分辨得出四種失敗、agent 打嗝要等它回來）。這裡只加本 spec 的常數與分段傳輸。

_WIZARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SHARED_LIB="${_WIZARD_DIR}/../demo-entrance-and-srv-layout/wizard.sh"
if [[ ! -f "$_SHARED_LIB" ]]; then
  printf '找不到共用的 wizard.sh（%s）。\n' "$_SHARED_LIB" >&2
  printf '請把整個 scripts/ 目錄一起複製到 PVE host，兩個目錄要維持相鄰。\n' >&2
  exit 1
fi
# shellcheck source=../demo-entrance-and-srv-layout/wizard.sh
source "$_SHARED_LIB"

# ADR-0002 隨 VM 103 一起作廢：新機器沒有 /srv/platform 這一層，也沒有 lv_docker。
# 取消繼承來的名字，免得誤用。
unset PLATFORM_ROOT DOCKER_OLD_MOUNT

# ── 本 spec 的固定值 ──────────────────────────────────────────────────────

TEMPLATE_VMID=109
TEMPLATE_NAME="ub-26-4-srv-docker"

DISK_STORAGE="VMdisk"          # 範本磁碟所在的 zfspool，clone 的落點
BACKUP_STORAGE="local"         # dir 型，vzdump 的落點
MIN_POOL_FREE_GIB=500          # spec 停止條款：低於此值就停，不刪東西騰空間

# guest 內的位置。/srv 是獨立檔案系統，兩者都在其下。
CHECKOUT_DIR="/srv/${CHECKOUT_NAME}"
APP_DIR="/srv/typeai-demo"

REPO_URL="git@source.mobagel.com:type-ai-platform/type-ai-platform-demo.git"
REPO_BRANCH="main"
REPO_HOST="source.mobagel.com"
# monorepo，clone 後這些都該在
REPO_ENTRIES=(type-ai-platform-backend type-ai-platform-frontend
              type-ai-platform-infra type-ai-platform-docs
              e2e tools deliverables)

SSH_DIR="${HOME_DIR}/.ssh"
DEPLOY_KEY="id_ed25519_mobagel_gitlab"
SSH_FILES=("$DEPLOY_KEY" "${DEPLOY_KEY}.pub" known_hosts)

# 票 07 的三分法。還原是有選擇的，不是無條件照搬。
SECRET_FILES=(demo-password kc-admin-password kc-token
              seed-client-secret service-token-secret)
KEEP_FILES=(nginx.conf 試用說明.md)
# 不還原：舊執行產物留在保全副本裡。tls.* 2026-09-09 到期，而 ADR-0001 要的是
# 永久入口，不讓一張快過期的憑證混進新機器。
NO_RESTORE=(backend.log frontend.log frontend-build.log
            screenshots smoke-shots tls.crt tls.key)

PG_VOLUME_TAR="typeai-demo-pg-volume.tar"

# 分段傳輸的段長。
# 取回：回應走 QGA 的 out-data，整包數 MB 會失敗；256 KiB（base64 後 344 KiB）安全。
# 送出：內容是 `sh -c` 那一個 argv 的一部分，Linux 單一參數上限 128 KiB，
#       48 KiB（base64 後 64 KiB）留了足夠餘裕。
CHUNK_PULL_BYTES=262144
CHUNK_PUSH_BYTES=49152

# 對外網段。新機器只要出現這個網段的位址，就是接錯橋接了（票 05 的停止條件）。
EXTERNAL_NET_PREFIX="${EDGE_EXTERNAL_IP%.*}"

# ── 純函式 ────────────────────────────────────────────────────────────────

# chunk_count SIZE CHUNK — 涵蓋 SIZE bytes 需要幾段（無條件進位）。
# CHUNK 非正數時回傳 1；呼叫端用 `n=$(chunk_count …) || abort …` 接。
chunk_count() {
  [[ "$2" -gt 0 ]] || { printf '段長必須為正數\n' >&2; return 1; }
  printf '%s' $(( ($1 + $2 - 1) / $2 ))
}

# pvesm_avail_kib NAME — 從 stdin 的 `pvesm status` 取該儲存池的可用 KiB。
# 查不到回傳 1：把「查不到」當成 0 會誤觸停止條款，當成無限大則更糟。
pvesm_avail_kib() {
  awk -v name="$1" '$1 == name { print $6; found = 1 } END { exit !found }'
}

# has_lan_addr ADDRS — ADDRS 裡有對外網段的位址就回傳 0（找到了）。
# 前面補數字界線，`110.1.2.3` 這種只是開頭長得像的位址不算。
has_lan_addr() {
  local re="(^|[^0-9])${EXTERNAL_NET_PREFIX//./\\.}\.[0-9]"
  [[ "$1" =~ $re ]]
}

# vzdump_archive_path — 從 stdin 的 vzdump 輸出取出封存路徑。取不到回傳 1。
vzdump_archive_path() {
  sed -n "s/.*creating vzdump archive '\([^']*\)'.*/\1/p" | tail -n1 | grep .
}

# preserve_dir — 定位票 01 的保全目錄。PRESERVE_DIR 優先，否則取最新的一個。
# 找不到就停止：猜一個目錄比停下來危險得多。
preserve_dir() {
  local d="${PRESERVE_DIR:-}"
  [[ -n "$d" ]] || d=$(ls -1d /root/demo-preserve-* 2>/dev/null | sort | tail -n1)
  [[ -n "$d" && -d "$d" ]] ||
    abort "找不到票 01 的保全目錄；以 PRESERVE_DIR=/root/demo-preserve-<TS> 指定"
  printf '%s' "$d"
}

# ── 大檔的分段傳輸 ────────────────────────────────────────────────────────
#
# guest agent 那條通道是 base64 的 JSON，整包數 MB 會失敗，而失敗訊息只說
# 「讀不到」。所以兩個方向都：來源端先算 SHA-256 → 分段搬 → 目的端重算比對。
# 傳輸工具的結束碼不算證據。

# pull_guest_blob VMID SRC DEST — 把 guest 的檔案分段取回主機並複驗。
pull_guest_blob() {
  local vmid="$1" src="$2" dest="$3" size sha_guest sha_host n i
  size=$(guest_exec_or_abort "$vmid" "wc -c < '$src'" \
    "無法讀取 guest 的 $src 大小" | tr -d ' \r\n')
  sha_guest=$(guest_exec_or_abort "$vmid" "sha256sum '$src' | cut -d' ' -f1" \
    "無法在 guest 內計算 $src 的 SHA-256" | tr -d ' \r\n')
  n=$(chunk_count "$size" "$CHUNK_PULL_BYTES") || abort "段長設定有誤"

  note "取回 $src：${size} bytes，分 ${n} 段（每段 $((CHUNK_PULL_BYTES / 1024)) KiB）"
  : > "$dest"
  printf '  '
  for (( i = 0; i < n; i++ )); do
    guest_exec_or_abort "$vmid" \
      "dd if='$src' bs=$CHUNK_PULL_BYTES skip=$i count=1 2>/dev/null | base64 -w0" \
      "無法取回 $src 的第 $((i + 1))/$n 段" | base64 -d >> "$dest"
    printf '.'
  done
  printf '\n'

  sha_host=$(sha256sum "$dest" | cut -d' ' -f1)
  [[ "$sha_host" == "$sha_guest" ]] ||
    abort "$dest 的 SHA-256 與 guest 內的不符（guest ${sha_guest} / 主機 ${sha_host}）"
  ok "已取回 $(basename "$dest")（${size} bytes，SHA-256 相符）"
}

# push_guest_blob VMID SRC DEST [MODE] — 把主機的檔案分段送進 guest 並複驗。
#
# 附加寫入一律走 guest_exec_or_abort：它只在「PVE 根本沒把指令送出去」時重試。
# 若改用會等 agent 回來的 guest_retry_or_abort，一次 agent 逾時就可能把同一段
# 寫進去兩次 —— 而每一個指令都還是回 0。
push_guest_blob() {
  local vmid="$1" src="$2" dest="$3" mode="${4:-0600}" size sha_host sha_guest n i b64
  size=$(wc -c < "$src" | tr -d ' ')
  sha_host=$(sha256sum "$src" | cut -d' ' -f1)
  n=$(chunk_count "$size" "$CHUNK_PUSH_BYTES") || abort "段長設定有誤"

  note "送出 $(basename "$src")：${size} bytes，分 ${n} 段（每段 $((CHUNK_PUSH_BYTES / 1024)) KiB）"
  guest_exec_or_abort "$vmid" "umask 077; : > '$dest'" \
    "無法在 guest 建立 $dest" >/dev/null
  printf '  '
  for (( i = 0; i < n; i++ )); do
    b64=$(dd if="$src" bs="$CHUNK_PUSH_BYTES" skip="$i" count=1 2>/dev/null | base64 -w0)
    guest_exec_or_abort "$vmid" "printf '%s' '${b64}' | base64 -d >> '$dest'" \
      "無法寫入 $dest 的第 $((i + 1))/$n 段" >/dev/null
    printf '.'
  done
  printf '\n'

  guest_exec_or_abort "$vmid" "chmod ${mode} '$dest'" \
    "無法設定 $dest 的權限" >/dev/null
  sha_guest=$(guest_exec_or_abort "$vmid" "sha256sum '$dest' | cut -d' ' -f1" \
    "無法在 guest 內計算 $dest 的 SHA-256" | tr -d ' \r\n')
  [[ "$sha_guest" == "$sha_host" ]] ||
    abort "$dest 落地後的 SHA-256 與來源不符（主機 ${sha_host} / guest ${sha_guest}）"
  ok "已送出 $dest（${size} bytes，mode ${mode}，SHA-256 相符）"
}

# ── PVE 端的小工具 ────────────────────────────────────────────────────────

# pool_free_gib NAME — 儲存池可用空間（GiB，整數）。
pool_free_gib() {
  local kib
  kib=$(pvesm status | pvesm_avail_kib "$1") ||
    abort "pvesm status 裡找不到儲存池 $1"
  printf '%s' $(( kib / 1024 / 1024 ))
}

# require_pool_free NAME — 可用空間低於 MIN_POOL_FREE_GIB 時停止。
require_pool_free() {
  local gib
  gib=$(pool_free_gib "$1")
  if [[ "$gib" -lt "$MIN_POOL_FREE_GIB" ]]; then
    warn "儲存池 $1 可用 ${gib} GiB，低於要求的 ${MIN_POOL_FREE_GIB} GiB"
    human_action "spec 的停止條款：空間不足時停止，不得為了騰空間刪除任何東西。"
    abort "儲存池 $1 可用空間不足"
  fi
  ok "儲存池 $1 可用 ${gib} GiB（要求至少 ${MIN_POOL_FREE_GIB} GiB）"
}

# vm_exists VMID — VM 存在回傳 0。
vm_exists() { qm config "$1" >/dev/null 2>&1; }

# type_to_confirm PHRASE — 不可逆動作的第二道確認：要一字不差地打出來。
# y/N 太容易順手按下去，而這一步之後沒有回頭路。
type_to_confirm() {
  local reply=""
  printf '  %s? 確定要繼續，請輸入 %s%s%s：%s ' \
    "$YELLOW" "$BOLD" "$1" "$RESET$YELLOW" "$RESET"
  read -r reply || true
  [[ "$reply" == "$1" ]] || abort "輸入不符，未執行"
}
