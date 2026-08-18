# shellcheck shell=bash
#
# 本 spec（VM 103 抽換為 cib-ai-platform 並開通 8082）的共用 wizard library。
# 由同目錄的 NN-*.sh 以 `source` 載入，不單獨執行。
#
# 沿用 ../demo-rebuild-from-template/wizard.sh —— 它自己會載入更底層的共用畫面、
# 閘門、讀回驗證與 guest agent 通道。那些函式帶著幾次現場失敗的教訓（abort 走
# stderr、guest_exec 分辨得出四種失敗、agent 打嗝要等它回來），不重寫一份。
# 這裡直接用到的是：vm_exists、type_to_confirm、require_pool_free、has_lan_addr，
# 以及底層的 stage／readback／gate／nft_add_entrance_rules 與兩種 guest 通道
# （guest_exec_or_abort 與會等 agent 回來的 guest_retry_or_abort）。

_WIZARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PREV_LIB="${_WIZARD_DIR}/../demo-rebuild-from-template/wizard.sh"
if [[ ! -f "$_PREV_LIB" ]]; then
  printf '找不到上一個 spec 的 wizard.sh（%s）。\n' "$_PREV_LIB" >&2
  printf '請把整個 scripts/ 目錄一起複製到 PVE host，三個目錄要維持相鄰。\n' >&2
  exit 1
fi
# shellcheck source=../demo-rebuild-from-template/wizard.sh
source "$_PREV_LIB"

# 舊機器的身分與那一批隨它消失的東西（ADR-0006）。名字留著只會被誤用。
unset DEMO_NAME DEMO_PROXY DEMO_KC DEMO_PG DEMO_STACK_CONTAINERS KEEP_IN_HOME \
      CHECKOUT_NAME CHECKOUT_DIR APP_DIR REPO_URL REPO_BRANCH REPO_ENTRIES \
      SSH_DIR DEPLOY_KEY SSH_FILES SECRET_FILES KEEP_FILES NO_RESTORE \
      PG_VOLUME_TAR BACKUP_STORAGE

# ── 本 spec 的固定值 ──────────────────────────────────────────────────────

CIB_VMID=103
CIB_NAME="cib-ai-platform"
CIB_IP="172.23.57.12"
CIB_ENTRANCE_PORT=8082
CIB_SERVICE_PORT=443
CIB_MEMORY=65536
CIB_CORES=8

# 執行紀錄。四支腳本往同一個檔案附加，不用時間戳目錄 —— 這一輪沒有保全產物，
# 沒有「同一天跑兩次要分得開」的問題。
STATE_DIR="/root/cib-ai-platform-rebuild"
REPORT="${STATE_DIR}/report.md"

# 票 04 的臨時 listener。用後即拆（ADR-0007）。
PROBE_DIR="/tmp/cib-entrance-probe"
PROBE_TEXT="cib-ai-platform entrance probe"
PROBE_TTL=300

# ── 執行紀錄 ──────────────────────────────────────────────────────────────

# init_report — 建立紀錄檔（已存在就沿用）。
init_report() {
  mkdir -p "$STATE_DIR"
  [[ -f "$REPORT" ]] && return 0
  {
    printf '# VM %s 抽換為 %s\n\n' "$CIB_VMID" "$CIB_NAME"
    printf 'spec：`.scratch/cib-ai-platform-rebuild/spec.md`\n\n'
    printf '每一段都已過 redact_secrets。放進 repo 的 docs/reports/ 之前請自己看一遍。\n'
  } > "$REPORT"
}

# report_section TITLE — 開一節。後續 printf 由呼叫端自己接 >> "$REPORT"。
report_section() {
  printf '\n## %s（%s）\n\n' "$1" "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$REPORT"
}

# read_guest TITLE CMD — 讀回、印出、寫進紀錄。
#
# 每一段都先過 redact_secrets：daemon.json 可能帶 registry 認證，fstab 可能帶
# CIFS 憑證。「這份沒有 secret」不能只是宣稱。
#
# 走 guest_retry_or_abort 而不是 guest_exec_or_abort：這裡的指令全是唯讀的
# （docker info、lsblk、df、du、cat、ss、ufw status），重跑一次無害。而其中
# `du -sh` 掃整個 data-root 正是會讓 agent 一時回不了話的那種重活 —— 票 03
# stage 5 就是這樣被一句 `qga command 'guest-exec' failed - got timeout` 停掉的：
# 那是 agent 的狀態，不是資料的狀態，不該由它決定要不要重跑整票。
read_guest() {
  local out
  out=$(guest_retry_or_abort "$CIB_VMID" "$2" "無法讀取：$1" | redact_secrets)
  { printf '\n### %s\n\n```\n' "$1"; printf '%s\n' "$out"; printf '```\n'; } >> "$REPORT"
  say ""; say "$1"; printf '%s\n' "$out" | sed 's/^/    /'
}

# ── 純函式 ────────────────────────────────────────────────────────────────

# nft_uncomment_entrance_rules PORT GUEST_IP SERVICE_PORT — 把設定檔裡那三條被
# 註解掉的 entrance 規則解除註解（stdin → stdout），縮排原樣保留。
#
# Edge 上的 8082 規則是「已產生、尚未安裝」——三條規則本來就在 /etc/nftables.conf
# 裡，只是前面有 `#`。所以動作是解除註解，而不是新增：用 nft_add_entrance_rules
# 反而會因為註解行裡就有 "tcp dport 8082 dnat to" 而誤判成「port 已被佔用」。
#
# 只認 `#` 後面直接是 `iifname` 的行，說明用的中文註解不會被誤解除。
# PORT 已有未被註解的 DNAT 時回傳 2；找到的規則不是恰好三條時回傳 1。
nft_uncomment_entrance_rules() {
  awk -v port="$1" -v ip="$2" -v sport="$3" '
    function indent(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
    {
      line = $0
      body = line
      commented = sub(/^[[:space:]]*#[[:space:]]?/, "", body)
      if (!commented && index(line, "tcp dport " port " dnat to")) active = 1
      if (commented && body ~ /^iifname/) {
        if (index(body, "tcp dport " port " dnat to " ip ":" sport) ||
            index(body, "ip daddr " ip " tcp dport " sport " ct status dnat accept") ||
            index(body, "ip daddr " ip " tcp dport " sport " snat to")) {
          line = indent(line) body
          n++
        }
      }
      out[NR] = line
    }
    END {
      if (active) exit 2
      if (n != 3) exit 1
      for (i = 1; i <= NR; i++) print out[i]
    }'
}

# ss_reachable_listener PORT — stdin 的 `ss -ltn` 輸出裡，PORT 上有綁在非 loopback
# 位址的 listener 就回傳 0。
#
# 綁在 127.0.0.1 的 listener 永遠不會回答 DNAT，卻能讓「有 listener」這個檢查通過
# ——票 04 的停止條款要擋的正是這件事。LISTEN 那一行的 peer 欄位是 `0.0.0.0:*`，
# 不以數字結尾，所以掃全行不會把它誤認成 port。
ss_reachable_listener() {
  awk -v port="$1" '
    $1 == "LISTEN" {
      for (i = 2; i <= NF; i++) {
        f = $i
        if (f !~ /:[0-9]+$/) continue
        p = f; sub(/^.*:/, "", p)
        if (p != port) continue
        a = f; sub(/:[0-9]+$/, "", a)
        if (a ~ /^127\./ || a == "[::1]") continue
        found = 1
      }
    }
    END { exit !found }'
}
