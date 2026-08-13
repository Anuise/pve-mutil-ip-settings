# shellcheck shell=bash
#
# 共用 wizard library：畫面、確認閘門、本功能的常數，以及 PVE 讀回驗證。
# 由同目錄的 NN-*.sh 以 `source` 載入，不單獨執行。

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# ── 本功能的固定值 ────────────────────────────────────────────────────────
# 集中在這裡，讓「改一個私有 IP 要動三個檔案」不會發生。

DEMO_VMID=103
DEMO_NAME="type-ai-platform-demo"
EDGE_VMID=104
UAT_VMID=105
UAT_OLD_NAME="type-ai-platform-backend"
UAT_NEW_NAME="type-ai-platform-uat"

PRIVATE_BRIDGE="vmbr3"
DEMO_IP="172.23.57.12"
EDGE_PRIVATE_IP="172.23.57.1"
EDGE_EXTERNAL_IP="10.1.2.57"
UAT_ENTRANCE_PORT=8081

DEMO_MEMORY=65536
DEMO_CORES=8
HOME_DIR="/home/mobagel"

TOTAL_STAGES=0
_STAGE_INDEX=0

_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

# banner "Title" — 開場：這支 wizard 做什麼。
banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  每一步執行後都會讀回結果。讀回不符時整個序列停止，不會繼續。\n' "$DIM"
  printf '  隨時可 Ctrl-C 中止；已完成的步驟不會自動回復，請依 README 的回復點處理。%s\n' "$RESET"
  pause "準備好開始了嗎？"
}

# stage "Name" — 清畫面、標示進度。
stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

say()  { printf '  %s\n' "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET"; }
ok()   { printf '  %s✓ %s%s\n' "$GREEN" "$1" "$RESET"; }

# human_action "說明" — 需要使用者憑證、核准或手動基礎設施操作的步驟。
human_action() {
  printf '  %s%s[HUMAN ACTION]%s %s\n' "$BOLD" "$YELLOW" "$RESET" "$1"
}

pause() {
  printf '  %s%s%s ' "$DIM" "${1:-按 Enter 繼續}" "$RESET"
  read -r _ || true
}

confirm() {
  local reply=""
  printf '  %s? %s [y/N] %s' "$YELLOW" "$1" "$RESET"
  read -r reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

# abort "原因" — 停止整個序列。
#
# 一律印到 stderr：abort 會在 `x=$(guest_exec_or_abort …)` 這種 command
# substitution 底下被呼叫，印到 stdout 會被變數吃掉，操作者只看到腳本無聲結束。
abort() {
  printf '\n  %s✗ %s%s\n' "$RED" "$1" "$RESET" >&2
  printf '  %s序列已停止。修正後從本 stage 重跑，不要跳過。%s\n\n' "$DIM" "$RESET" >&2
  exit 1
}

# gate "說明" — 使用者不確認就停止。
gate() {
  confirm "$1" || abort "使用者未確認：$1"
}

# readback LABEL EXPECTED ACTUAL — 讀回值比對；不符即停止整個序列。
readback() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label = $actual"
  else
    printf '  %s✗ %s%s\n' "$RED" "$label" "$RESET" >&2
    printf '  %s    expected: %s%s\n' "$DIM" "$expected" "$RESET" >&2
    printf '  %s    actual:   %s%s\n' "$DIM" "$actual" "$RESET" >&2
    abort "讀回結果與預期不符"
  fi
}

# readback_match LABEL REGEX ACTUAL — 讀回值需符合 regex，否則停止。
readback_match() {
  local label="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    ok "$label = $actual"
  else
    printf '  %s✗ %s%s\n' "$RED" "$label" "$RESET" >&2
    printf '  %s    expected to match: %s%s\n' "$DIM" "$pattern" "$RESET" >&2
    printf '  %s    actual:            %s%s\n' "$DIM" "$actual" "$RESET" >&2
    abort "讀回結果與預期不符"
  fi
}

# readback_contains LABEL NEEDLE HAYSTACK — HAYSTACK 必須含 NEEDLE，否則停止。
# 用於「一組值裡必須有這一個」的情形：跑著 Docker 的 guest 會有 docker0 與
# br-* 等多個 scope global 位址，不能用相等比較。
readback_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label 含 $needle"
    note "    完整讀回值：$haystack"
  else
    printf '  %s✗ %s%s\n' "$RED" "$label" "$RESET" >&2
    printf '  %s    expected to contain: %s%s\n' "$DIM" "$needle" "$RESET" >&2
    printf '  %s    actual:              %s%s\n' "$DIM" "$haystack" "$RESET" >&2
    abort "讀回結果與預期不符"
  fi
}

# ── PVE 存取 ──────────────────────────────────────────────────────────────

# need_pve — 必須在 PVE host 上以 root 執行。
need_pve() {
  [[ "$(id -u)" -eq 0 ]] || abort "必須以 root 在 PVE host 上執行"
  command -v qm >/dev/null 2>&1 || abort "找不到 qm，這支腳本必須在 PVE host 上執行"
  command -v pvesh >/dev/null 2>&1 || abort "找不到 pvesh"
  command -v perl >/dev/null 2>&1 || abort "找不到 perl，無法解析 PVE 的 JSON 回應"
}

# qmcfg VMID KEY — 取 `qm config` 的單一欄位值；欄位不存在時輸出空字串。
qmcfg() { qm config "$1" | sed -n "s/^$2: //p"; }

# qmstatus VMID — running / stopped。
qmstatus() { qm status "$1" | sed -n 's/^status: //p'; }

# qm_set_help — `qm set` 的說明文字。永遠回傳 0：PVE 的 help 會以非 0 結束，
# pipefail 下直接 `qm … | grep` 會把它誤判成「選項不存在」。
#
# 先問 `qm help set --verbose`：PVE 9 的 `qm set --help` 只印 USAGE 摘要，一個
# 選項名都沒有。兩個來源都收，才不會因為某一版的輸出格式而問不到。
qm_set_help() {
  qm help set --verbose 2>&1 || true
  qm set --help 2>&1 || true
}

# qm_set_options — `qm set` 支援的選項名，一行一個、不帶破折號。
# 問不到時輸出空字串 —— 呼叫端必須把「空清單」當成無法判定，而不是「都不支援」。
qm_set_options() {
  qm_set_help |
    grep -oE '^[[:space:]]*-{1,2}[a-z][a-z0-9_]*' |
    sed -E 's/^[[:space:]]*-{1,2}//' |
    sort -u
}

# qm_supports_option NAME — `qm set` 是否支援某個選項。NAME 不帶破折號。
qm_supports_option() {
  qm_set_options | grep -qx -- "$1"
}

# list_snapshots VMID — 逗號分隔的快照名稱，不含 PVE 的 `current` 偽節點。
list_snapshots() {
  local node json
  node=$(hostname -s)
  json=$(pvesh get "/nodes/${node}/qemu/$1/snapshot" --output-format json) ||
    abort "無法讀取 VM $1 的快照清單"
  printf '%s' "$json" | perl -MJSON::PP -0777 -ne '
    my $r = eval { decode_json($_) } or exit 1;
    print join(",", map { $_->{name} } grep { $_->{name} ne "current" } @$r);' ||
    abort "無法解析 VM $1 的快照清單"
}

# net0_mac NET0 — 從 net0 設定字串取出 MAC address。
net0_mac() {
  printf '%s' "$1" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n1
}

# net0_bridge_set NET0 BRIDGE — 只改寫 bridge= 欄位，model、MAC 與其他旗標
# 原樣保留。沒有 bridge= 欄位時回傳 1。
net0_bridge_set() {
  [[ "$1" == *bridge=* ]] || return 1
  printf '%s' "$1" | sed -E "s/bridge=[^,]+/bridge=$2/"
}

# urldecode STRING — 解開 qm config 對 sshkeys 之類欄位所做的 URL 編碼。
urldecode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

# ssh_key_bodies — 從 stdin 的 authorized_keys 內容取出每一行的 base64 金鑰本體。
# 取「第一個看起來像金鑰本體的欄位」而不是固定第 2 欄，才能同時涵蓋
# `sk-ssh-ed25519@openssh.com`、`ssh-rsa` 等各種型別，以及帶 `command="…"`
# options 前綴的行 —— 漏掉它們就等於漏列會被 Cloud-Init 移除的金鑰。
ssh_key_bodies() {
  awk '{for (i = 1; i <= NF; i++) if ($i ~ /^AAAA[A-Za-z0-9+\/]+={0,2}$/) { print $i; break }}' |
    sort -u
}

# redact_secrets — 從 stdin 遮蔽常見的密碼／權杖欄位值，只留鍵名。
# 給會被寫進 repo 的報告用：`/etc/fstab` 可能帶 CIFS `password=`／`credentials=`，
# `daemon.json` 可能帶 registry 認證。
redact_secrets() {
  sed -E \
    -e 's/(password|passwd|credentials|secret|token|auth)=[^,[:space:]]*/\1=<redacted>/gI' \
    -e 's/"(password|passwd|secret|token|auth|identitytoken|registrytoken)"([[:space:]]*:[[:space:]]*)"[^"]*"/"\1"\2"<redacted>"/gI'
}

# guest_exec VMID 'sh -c 的指令' — 經 guest agent 以 root 執行，印出 guest
# stdout，回傳 guest 的 exit code。guest agent 不通時回傳 125，回應無法解析時 126。
guest_exec() {
  local vmid="$1" cmd="$2" json
  json=$(qm guest exec "$vmid" --timeout 300 -- /bin/sh -c "$cmd" 2>/dev/null) || return 125
  printf '%s' "$json" | perl -MJSON::PP -0777 -ne '
    my $r = eval { decode_json($_) } or exit 126;
    print $r->{"out-data"} // "";
    print STDERR $r->{"err-data"} // "";
    exit(($r->{"exitcode"} // 0) + 0);'
}

# guest_exec_or_abort VMID 'cmd' '失敗說明' — guest 指令失敗即停止整個序列。
guest_exec_or_abort() {
  local out
  if ! out=$(guest_exec "$1" "$2"); then
    abort "$3"
  fi
  printf '%s' "$out"
}

# guest_global_addrs VMID — guest 內部所有 scope global 的 `iface=CIDR`，單行。
guest_global_addrs() {
  guest_exec_or_abort "$1" \
    "ip -4 -o addr show scope global | awk '{print \$2\"=\"\$4}' | paste -sd' ' -" \
    "無法從 guest 讀取位址" | tr -d '\n'
}

# pull_guest_file VMID SRC DEST — 把 guest 的檔案取回 PVE host。
# guest 上不存在會明講並留空檔；取回失敗（agent 出錯）則停止整個序列 ——
# 靜默留空檔會讓後續的金鑰比對得出「沒有多餘金鑰」這個危險的錯誤結論。
pull_guest_file() {
  local vmid="$1" src="$2" dest="$3"
  if guest_exec "$vmid" "test -e '$src'" >/dev/null; then
    guest_exec_or_abort "$vmid" "cat '$src'" "無法從 guest 讀取 $src" > "$dest"
    ok "已取回 $src"
  else
    : > "$dest"
    warn "guest 上沒有 $src，記為空檔"
  fi
}

# wait_agent VMID SECONDS — 等 guest agent 回應。
wait_agent() {
  local vmid="$1" deadline=$(( SECONDS + $2 ))
  while (( SECONDS < deadline )); do
    if qm agent "$vmid" ping >/dev/null 2>&1; then ok "guest agent 已回應"; return 0; fi
    sleep 5
  done
  return 1
}

# verify_uat_entrance — UAT 入口未受影響。需要使用者的 VPN session，腳本無法代勞。
verify_uat_entrance() {
  human_action "從已連上核准 FortiClient VPN 的 Windows client 執行："
  say ""
  say "    Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${UAT_ENTRANCE_PORT}"
  say "    curl.exe -kfsS https://${EDGE_EXTERNAL_IP}:${UAT_ENTRANCE_PORT}/healthz"
  say ""
  say '預期 TcpTestSucceeded=True，且 healthz 回 {"status":"ok"}。'
  gate "UAT 的 ${UAT_ENTRANCE_PORT} 仍正常回應？"
}

finish() {
  _clear
  printf '\n%s%s  ✓ %s%s\n\n' "$BOLD" "$GREEN" "${1:-完成}" "$RESET"
}
