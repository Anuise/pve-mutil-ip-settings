#!/usr/bin/env bash
#
# 票 04 — Demo 盤點與量測。
#
# 唯讀：只跑讀取指令，不改動 guest 任何狀態。經 guest agent 收集，產出一份
# Markdown 報告，報告中同時記錄每個數字所用的指令，讓任何人都能重新覆算。
#
# 報告不得包含任何 secret 值、token 或授權標頭 —— 只記錄鍵名。
#
# Blocked by 票 03：Demo 必須已持有 172.23.57.12。
# 在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

REPORT="$(pwd)/demo-inventory-$(date +%Y%m%d).md"

sect() { printf '\n## %s\n' "$1" >> "$REPORT"; }

# probe "標題" '指令' [redact] — 執行唯讀指令，把指令與輸出一起寫進報告。
# 第三個參數給 `redact` 時，輸出會先遮蔽常見的密碼／權杖欄位值：`/etc/fstab`
# 可能帶 CIFS `password=`／`credentials=`，`daemon.json` 可能帶 registry 認證，
# 而這份報告會進 repo。
probe() {
  local label="$1" cmd="$2" redact="${3:-}" out rc=0
  printf '\n### %s\n\n```console\n$ %s\n' "$label" "$cmd" >> "$REPORT"
  out=$(guest_exec "$DEMO_VMID" "$cmd" 2>&1) || rc=$?
  if [[ "$redact" == "redact" ]]; then
    out=$(printf '%s' "$out" | redact_secrets)
  fi
  printf '%s\n' "$out" >> "$REPORT"
  [[ $rc -eq 0 ]] || printf '(exit code: %s)\n' "$rc" >> "$REPORT"
  printf '```\n' >> "$REPORT"
  if [[ $rc -eq 0 ]]; then ok "$label"; else warn "${label}（exit ${rc}，已記錄於報告）"; fi
}

TOTAL_STAGES=7
banner "票 04 — Demo 盤點與量測（唯讀）"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"
readback_contains "guest 內部位址" "=${DEMO_IP}/24" "$(guest_global_addrs "$DEMO_VMID")"

say ""
say "本腳本只執行讀取指令，不改動 guest 任何狀態。"
say "報告輸出：${REPORT}"
gate "開始收集？"

cat > "$REPORT" <<EOF
# Demo（VM ${DEMO_VMID}）盤點報告

產生時間：$(date -Is)
來源：PVE host 經 qemu-guest-agent，全部為唯讀指令
用途：票 05 Phase 2 搬移機制決策的實際數字依據

每一節都記錄了取得該數字的指令，可直接重新執行覆算。
本報告只記錄設定的**鍵名**；密碼、token 與授權欄位的值在寫入前已遮蔽為 \`<redacted>\`。
EOF

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "${HOME_DIR} 的大小與結構"
sect "${HOME_DIR} 的大小與結構"
probe "總大小" "du -sh ${HOME_DIR}"
probe "兩層目錄用量（大到小）" "du -h --max-depth=2 ${HOME_DIR} 2>/dev/null | sort -rh | head -40"
probe "頂層內容" "ls -la ${HOME_DIR}"
probe "專案 checkout（含 .git 的目錄）" \
  "find ${HOME_DIR} -maxdepth 4 -type d -name .git 2>/dev/null | sed 's#/.git\$##' | while read -r d; do printf '%s\trevision=%s\tsize=%s\n' \"\$d\" \"\$(git -C \"\$d\" rev-parse HEAD 2>/dev/null || echo unknown)\" \"\$(du -sh \"\$d\" 2>/dev/null | cut -f1)\"; done"
probe "user-level systemd services" \
  "ls -la ${HOME_DIR}/.config/systemd/user 2>/dev/null || echo '(no user-level units)'"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "Docker 現況"
sect "Docker 現況"
probe "data-root 與物件數量" \
  "docker info --format 'DockerRootDir={{.DockerRootDir}} Containers={{.Containers}} Running={{.ContainersRunning}} Images={{.Images}}'"
probe "daemon.json" "cat /etc/docker/daemon.json 2>/dev/null || echo '(no /etc/docker/daemon.json)'" redact
probe "磁碟用量彙總" "docker system df"
probe "containers" "docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
probe "images" "docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}'"
probe "volumes" "docker volume ls --format '{{.Driver}}\t{{.Name}}'"
probe "data-root 實際佔用" "du -sh \$(docker info --format '{{.DockerRootDir}}') 2>/dev/null"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "目前提供 443 與 80 的服務"
sect "目前提供 443 與 80 的服務"
probe "host listener" "ss -ltnp 2>/dev/null | awk 'NR==1 || \$4 ~ /:(80|443)\$/'"
probe "container port 發佈" \
  "docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E ':(80|443)->' || echo '(no container publishes 80/443)'"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "容量與剩餘空間"
sect "容量與剩餘空間"
probe "區塊裝置" "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT"
probe "volume groups" "vgs"
probe "logical volumes" "lvs -o lv_name,vg_name,lv_size,data_percent,lv_path"
probe "檔案系統用量" "df -hT -x tmpfs -x devtmpfs -x squashfs"
probe "掛載表" "findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE% -t ext4,xfs,btrfs"
probe "fstab" "cat /etc/fstab" redact

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "引用 ${HOME_DIR} 絕對路徑的設定"
sect "引用 ${HOME_DIR} 絕對路徑的設定"
note "只輸出檔名、行號與被引用的路徑本身，不輸出整行，避免帶出設定值。"
probe "container bind mounts" \
  "docker ps -aq | while read -r c; do docker inspect -f '{{.Name}}{{range .Mounts}} {{.Source}}->{{.Destination}}{{end}}' \"\$c\"; done | grep '${HOME_DIR}' || echo '(no bind mount under ${HOME_DIR})'"
probe "systemd units" \
  "grep -rno '${HOME_DIR}[^\"'\\'' :]*' /etc/systemd/system /lib/systemd/system 2>/dev/null || echo '(none)'"
probe "Compose 與設定檔" \
  "grep -rno '${HOME_DIR}[^\"'\\'' :]*' --include='*.yml' --include='*.yaml' --include='*.conf' --include='*.service' ${HOME_DIR} /srv /etc 2>/dev/null | head -100 || echo '(none)'"
probe "環境檔位置（不含值）" \
  "find ${HOME_DIR} /srv -maxdepth 5 \\( -name '.env' -o -name '.env.*' -o -name '*.env' \\) 2>/dev/null | while read -r f; do printf '%s mode=%s keys=%s\n' \"\$f\" \"\$(stat -c %a \"\$f\")\" \"\$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' \"\$f\" 2>/dev/null || echo 0)\"; done"
probe "環境檔鍵名（只有鍵名）" \
  "find ${HOME_DIR} /srv -maxdepth 5 \\( -name '.env' -o -name '.env.*' -o -name '*.env' \\) 2>/dev/null | while read -r f; do printf '\n%s:\n' \"\$f\"; grep -oE '^[A-Za-z_][A-Za-z0-9_]*' \"\$f\" 2>/dev/null | sed 's/^/  /'; done"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "檢查報告並收尾"
say "報告已寫入：${REPORT}"
say ""
say "疑似高熵字串掃描（image ID 與 checksum 會被誤判，屬正常）："
scan=$(grep -nE '[A-Za-z0-9+/]{40,}' "$REPORT" || true)
if [[ -n "$scan" ]]; then
  printf '%s\n' "$scan" | head -20 | sed 's/^/    /' || true
  say "    （共 $(printf '%s\n' "$scan" | wc -l) 行符合，上面最多列 20 行）"
else
  say "    （無符合項）"
fi
say ""
human_action "確認報告中沒有任何 secret 值、token 或授權標頭再往下。"
gate "報告內容可以進 repo？"

readback "Demo 電源狀態（本票不得改動 guest）" "running" "$(qmstatus "$DEMO_VMID")"

finish "票 04 完成"
say "把報告放進 repo："
say ""
say "    scp root@10.1.2.50:${REPORT} docs/reports/"
say ""
say "下一步：票 05 依這份報告的實際數字決定 Phase 2 的搬移機制。"
say "在票 05 完成前不要開始票 06。"
