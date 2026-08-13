#!/usr/bin/env bash
#
# 票 11 — Demo 的 443 端點與 stack 定義入 repo。
#
# 本票不部署應用本體（見 ADR-0003），只做兩件事：把 443 端點立起來，並把既有
# stack 的定義落成可據以重建的 compose。
#
# typeai-demo-pg 不得重建：唯一那顆 66.65MB 匿名 volume 就是它的資料，重建會
# 拿到一顆新的空 volume。它以 docker update --restart unless-stopped 取得重開機
# 恢復，不重建、不改網路。
#
# Blocked by 票 07。在 PVE host 上以 root 執行。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wizard.sh
source "${SCRIPT_DIR}/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
CHECKOUT_DIR="${PLATFORM_ROOT}/${CHECKOUT_NAME}"
DEPLOY_DIR="${CHECKOUT_DIR}/deploy"
OLD_CHECKOUT_DIR="${HOME_DIR}/${CHECKOUT_NAME}"

PROXY="$DEMO_PROXY"
KC="$DEMO_KC"
PG="$DEMO_PG"
CERT_VOLUME="typeai-demo_nginx-certs"
FINGERPRINT_FILE="/etc/type-ai-platform/demo-nginx-cert.sha256"
INSPECT_FILE="${DEPLOY_DIR}/docker-inspect-before-${TS}.json"

TAB=$'\t'

# dexec 'docker 指令' '失敗說明' — guest 內的指令，失敗即停止整個序列。
dexec() { guest_exec_or_abort "$DEMO_VMID" "$1" "$2" | tr -d '\r'; }

TOTAL_STAGES=11
banner "票 11 — Demo 的 443 端點與 stack 定義"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"
readback "Docker 的 data-root（票 06）" "${PLATFORM_ROOT}/docker" \
  "$(dexec "docker info --format '{{.DockerRootDir}}'" "無法讀取 data-root" | tr -d '\n')"
readback "checkout 已在新位置（票 07）" "yes" \
  "$(dexec "test -d '${CHECKOUT_DIR}' && echo yes || echo no" "無法檢查 checkout" | tr -d '\n')"
dexec "docker compose version >/dev/null" "guest 沒有 docker compose plugin" >/dev/null
ok "guest 有 docker compose"

for c in "$PROXY" "$KC" "$PG"; do
  dexec "docker inspect '${c}' >/dev/null" "找不到容器 ${c}；盤點與現況不符" >/dev/null
done
ok "三顆容器都在"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "開工前的唯讀補查"
say "三個分支的處置已在 spec 預先決定，這裡只是把事實讀出來。"

say ""
say "① 三顆容器是 Compose 還是手動建的："
dexec "for c in ${PROXY} ${KC} ${PG}; do
  printf '%s compose-project=%s\n' \"\$c\" \
    \"\$(docker inspect -f '{{index .Config.Labels \"com.docker.compose.project\"}}' \"\$c\")\"
done" "無法讀取 compose label" | sed 's/^/    /'

say ""
say "   checkout 裡現成的部署定義："
existing_defs=$(guest_exec "$DEMO_VMID" \
  "find '${CHECKOUT_DIR}' -maxdepth 3 \\( -name 'docker-compose*.y*ml' -o -name 'compose*.y*ml' \\) 2>/dev/null" ||
  true)
if [[ -n "$existing_defs" ]]; then
  printf '%s\n' "$existing_defs" | sed 's/^/    /'
  say ""
  say "spec 的預先決定：有現成定義就沿用，沒有才用 docker inspect 產生。"
  if confirm "要沿用上面某一份定義嗎？"; then
    human_action "沿用哪一份、以及它是否已提供 443 與 /healthz，只有你判斷得了。"
    say ""
    say "這是 spec 的 [HUMAN ACTION] 逸出：腳本不猜一份任意定義的形狀。"
    say "請以該定義部署 443 端點，確認 Edge 取得 /healthz 後，直接進行票 08。"
    abort "改由既有定義部署，本腳本不繼續"
  fi
  note "不沿用，繼續以 docker inspect 產生。"
else
  say "    （沒有）"
  ok "沒有現成定義，依預先決定以 docker inspect 產生"
fi

say ""
say "② nginx 現有的 TLS 憑證："
dexec "docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}' '${PROXY}'" \
  "無法讀取 ${PROXY} 的 mounts" | sed 's/^/    /'
REUSE_CRT=""; REUSE_KEY=""
if confirm "上面有可沿用的 TLS 憑證嗎？"; then
  printf '  %s憑證檔（guest 內絕對路徑）：%s ' "$YELLOW" "$RESET"; read -r REUSE_CRT || true
  printf '  %s私鑰檔（guest 內絕對路徑）：%s ' "$YELLOW" "$RESET"; read -r REUSE_KEY || true
  [[ -n "$REUSE_CRT" && -n "$REUSE_KEY" ]] || abort "沿用憑證需要憑證與私鑰兩個路徑"
  dexec "test -f '${REUSE_CRT}' && test -f '${REUSE_KEY}'" "指定的憑證或私鑰不存在" >/dev/null
  ok "沿用既有憑證，稍後複製進具名 volume 並記錄 fingerprint"
else
  note "依預先決定：產生自簽憑證放具名 volume，比照 UAT。"
fi

say ""
say "③ Keycloak 的 realm 狀態："
kc_db=$(guest_exec "$DEMO_VMID" \
  "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' '${KC}' | grep '^KC_DB=' || true" |
  tr -d '\r\n')
say "    ${kc_db:-（沒有 KC_DB，代表用內建資料庫）}"
if [[ "$kc_db" == "KC_DB=postgres" ]]; then
  ok "realm 狀態在 PostgreSQL，重建容器安全"
else
  warn "realm 狀態不在 PostgreSQL，重建會丟掉它。先把容器內的資料匯出。"
  dexec "mkdir -p '${DEPLOY_DIR}'" "無法建立 ${DEPLOY_DIR}" >/dev/null
  if ! guest_exec "$DEMO_VMID" \
       "docker cp '${KC}:/opt/keycloak/data' '${DEPLOY_DIR}/keycloak-data-${TS}'" >/dev/null; then
    human_action "無法從容器取出 Keycloak 的資料目錄。請人工處理 realm 狀態後再重跑本票。"
    abort "realm 狀態匯不出來"
  fi
  # 取出成功但空目錄，等於什麼都沒備到。docker cp 對空來源一樣回 0。
  exported=$(guest_exec_or_abort "$DEMO_VMID" \
    "find '${DEPLOY_DIR}/keycloak-data-${TS}' -type f | wc -l" "無法清點匯出內容" | tr -d '\r\n')
  if [[ "$exported" == "0" ]]; then
    human_action "取出的資料目錄是空的，沒有任何 realm 狀態可回復。請人工確認後再重跑本票。"
    abort "匯出內容為空"
  fi
  ok "已取出 ${exported} 個檔案到 ${DEPLOY_DIR}/keycloak-data-${TS}"
fi

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "保存重建前的原始定義"
note "docker inspect 含環境變數，可能有密碼，因此留在 guest（mode 0600），不進 repo。"
note "進 repo 的是 compose 定義 —— 它把環境變數留在 env_file 裡。"

dexec "mkdir -p '${DEPLOY_DIR}'" "無法建立 ${DEPLOY_DIR}" >/dev/null
dexec "umask 077; docker inspect '${PROXY}' '${KC}' '${PG}' > '${INSPECT_FILE}'" \
  "無法保存 docker inspect" >/dev/null
# grep -c 沒有命中時回非 0。走 guest_exec_or_abort 會變成以錯誤訊息中止，
# 讀回就永遠印不出 expected/actual —— 而那正是這一行存在的理由。
readback "保存的定義涵蓋三顆容器" "3" \
  "$(guest_exec "$DEMO_VMID" "grep -c '^        \"Id\": ' '${INSPECT_FILE}' || true" |
     tr -d '\r\n')"
ok "原始定義：${INSPECT_FILE}"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "推送 stack 定義到 guest"
say "目標：${DEPLOY_DIR}"
gate "推送？"

dexec "mkdir -p '${DEPLOY_DIR}/nginx' '${DEPLOY_DIR}/fields'" "無法建立部署目錄" >/dev/null
guest_put_file "$DEMO_VMID" "${DEPLOY_DIR}/compose.yml" 0644 \
  < "${SCRIPT_DIR}/demo-stack/compose.yml"
guest_put_file "$DEMO_VMID" "${DEPLOY_DIR}/nginx/default.conf" 0644 \
  < "${SCRIPT_DIR}/demo-stack/nginx/default.conf"
guest_put_file "$DEMO_VMID" "${DEPLOY_DIR}/nginx/index.html" 0644 \
  < "${SCRIPT_DIR}/demo-stack/nginx/index.html"
guest_put_file "$DEMO_VMID" "${DEPLOY_DIR}/render-keycloak-compose.sh" 0755 \
  < "${SCRIPT_DIR}/demo-stack/render-keycloak-compose.sh"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "產生 keycloak 的 compose 定義"
say "環境變數原樣寫進 ${DEPLOY_DIR}/keycloak.env（mode 0600），不離開 guest。"
note "realm import 的 bind mount 由 ${OLD_CHECKOUT_DIR} 改指 ${CHECKOUT_DIR}。"
note "這是票 07 列出的唯一一條舊路徑引用。"

dexec "
set -e
cd '${DEPLOY_DIR}'
docker inspect -f '{{.Config.Image}}' '${KC}' > fields/image
docker inspect -f '{{range .Config.Entrypoint}}{{println .}}{{end}}' '${KC}' > fields/entrypoint
docker inspect -f '{{range .Config.Cmd}}{{println .}}{{end}}' '${KC}' > fields/cmd
docker inspect -f '{{range .Mounts}}{{.Type}}${TAB}{{.Source}}${TAB}{{.Destination}}${TAB}{{.RW}}{{println}}{{end}}' '${KC}' > fields/mounts
docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{println \$k}}{{end}}' '${KC}' > fields/networks
umask 077
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' '${KC}' > keycloak.env
chmod 0600 keycloak.env
" "無法從 ${KC} 抽出定義" >/dev/null

dexec "cd '${DEPLOY_DIR}' && ./render-keycloak-compose.sh fields '${OLD_CHECKOUT_DIR}' '${CHECKOUT_DIR}' > compose.keycloak.yml" \
  "產生 compose.keycloak.yml 失敗（非 bind 的 mount 需人工判斷）" >/dev/null

say ""
dexec "cat '${DEPLOY_DIR}/compose.keycloak.yml'" "無法讀回產生的定義" | sed 's/^/    /'
say ""
kc_refs_old=$(guest_exec "$DEMO_VMID" \
  "grep -c '${OLD_CHECKOUT_DIR}' '${DEPLOY_DIR}/compose.keycloak.yml' || true" | tr -d '\r\n')
readback "產生的定義不再引用舊路徑" "0" "$kc_refs_old"
gate "這份定義正確？"

dexec "cd '${DEPLOY_DIR}' && docker compose -f compose.yml -f compose.keycloak.yml config -q" \
  "compose 定義無法通過驗證" >/dev/null
ok "compose 定義通過驗證"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "憑證進具名 volume 並記錄 fingerprint"
dexec "docker volume create '${CERT_VOLUME}' >/dev/null" "無法建立憑證 volume" >/dev/null
CERT_MP=$(dexec "docker volume inspect -f '{{.Mountpoint}}' '${CERT_VOLUME}'" \
  "無法取得憑證 volume 的路徑" | tr -d '\n')
say "憑證 volume：${CERT_VOLUME}（${CERT_MP}）"

if [[ -n "$REUSE_CRT" ]]; then
  dexec "install -o root -g root -m 0644 '${REUSE_CRT}' '${CERT_MP}/server.crt' &&
         install -o root -g root -m 0600 '${REUSE_KEY}' '${CERT_MP}/server.key'" \
    "複製既有憑證失敗" >/dev/null
  ok "已沿用既有憑證"
else
  say ""
  say "將在 ${CERT_VOLUME} 內產生一張自簽的服務憑證（有效期 825 天）。"
  note "這是服務用的 TLS 憑證，比照 UAT；不是為了救援而建立的憑證，也不新增"
  note "憑證機構或公開信任憑證。README 說的「不建立新憑證」指的是後者。"
  gate "產生自簽憑證？"

  dexec "
set -e
if [ ! -f '${CERT_MP}/server.crt' ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -subj '/CN=${DEMO_NAME}' \
    -addext 'subjectAltName=IP:${DEMO_IP},IP:${EDGE_EXTERNAL_IP},DNS:${DEMO_NAME}' \
    -keyout '${CERT_MP}/server.key' -out '${CERT_MP}/server.crt' >/dev/null 2>&1
fi
chown root:root '${CERT_MP}/server.crt' '${CERT_MP}/server.key'
chmod 0644 '${CERT_MP}/server.crt'
chmod 0600 '${CERT_MP}/server.key'
" "產生自簽憑證失敗" >/dev/null
  ok "自簽憑證已就緒（不新增憑證機構，也不引入公開信任憑證）"
fi

FINGERPRINT=$(dexec "openssl x509 -in '${CERT_MP}/server.crt' -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//; s/://g'" "無法計算憑證 fingerprint" | tr -d '\n')
readback_match "憑證 fingerprint" '^[0-9A-Fa-f]{64}$' "$FINGERPRINT"

dexec "
set -e
install -d -o root -g root -m 0755 /etc/type-ai-platform
tmp=\$(mktemp /etc/type-ai-platform/.demo-nginx-cert.sha256.XXXXXX)
printf '%s\n' '${FINGERPRINT}' > \"\$tmp\"
chown root:root \"\$tmp\"
chmod 0644 \"\$tmp\"
mv -f \"\$tmp\" '${FINGERPRINT_FILE}'
" "寫入 fingerprint 檔失敗" >/dev/null
readback "fingerprint 檔的擁有者與權限" "root root 644" \
  "$(dexec "stat -c '%U %G %a' '${FINGERPRINT_FILE}'" "無法讀取 fingerprint 檔" | tr -d '\n')"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "${PG} 只加重啟策略，不重建"
PG_VOLUME=$(dexec "docker inspect -f '{{range .Mounts}}{{if eq .Type \"volume\"}}{{.Name}}{{end}}{{end}}' '${PG}'" \
  "無法讀取 ${PG} 的 volume" | tr -d '\n')
[[ -n "$PG_VOLUME" ]] || abort "${PG} 沒有 volume；與盤點的 66.65MB 匿名 volume 不符"
say "資料 volume：${PG_VOLUME}"
note "重開機恢復靠 restart policy。重建會拿到一顆新的空 volume，等於刪掉資料庫。"
gate "設定 restart policy 並啟動 ${PG}？"

dexec "docker update --restart unless-stopped '${PG}' >/dev/null && docker start '${PG}' >/dev/null" \
  "無法設定重啟策略或啟動 ${PG}" >/dev/null
readback "${PG} 的重啟策略" "unless-stopped" \
  "$(dexec "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '${PG}'" \
     "無法讀取重啟策略" | tr -d '\n')"
readback "${PG} 執行狀態" "running" \
  "$(dexec "docker inspect -f '{{.State.Status}}' '${PG}'" "無法讀取狀態" | tr -d '\n')"
readback "${PG} 的 volume 未更換" "$PG_VOLUME" \
  "$(dexec "docker inspect -f '{{range .Mounts}}{{if eq .Type \"volume\"}}{{.Name}}{{end}}{{end}}' '${PG}'" \
     "無法讀取 volume" | tr -d '\n')"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "重建 ${PROXY} 與 ${KC}"
say "只有這兩顆重建：nginx 要換設定與憑證，keycloak 的 bind mount 要改指。"
note "重建前先確認它們沒有 volume 型 mount —— 有的話代表有資料會被丟掉。"

for c in "$PROXY" "$KC"; do
  vols=$(dexec "docker inspect -f '{{range .Mounts}}{{if eq .Type \"volume\"}}{{.Name}} {{end}}{{end}}' '${c}'" \
    "無法讀取 ${c} 的 mounts" | tr -d '\n')
  [[ -z "${vols// /}" ]] || abort "${c} 有 volume 型 mount（${vols}）；重建會丟掉它，請人工判斷"
  ok "${c} 沒有 volume 型 mount"
done
note "反向動作：以 ${INSPECT_FILE} 的內容重建原容器。"
gate "移除舊的 ${PROXY} 與 ${KC} 並以 compose 起來？"

dexec "docker rm '${PROXY}' '${KC}' >/dev/null" "移除舊容器失敗" >/dev/null
dexec "cd '${DEPLOY_DIR}' && docker compose -f compose.yml -f compose.keycloak.yml up -d" \
  "compose 啟動失敗；docker compose logs 可看原因" >/dev/null

for c in "${DEMO_STACK_CONTAINERS[@]}"; do
  readback "${c} 執行狀態" "running" "$(wait_container_running "$DEMO_VMID" "$c")"
  readback "${c} 的重啟策略" "unless-stopped" \
    "$(dexec "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' '${c}'" \
       "無法讀取 ${c} 重啟策略" | tr -d '\n')"
done
readback "${KC} 的 realm import 已改指新路徑" "1" \
  "$(guest_exec "$DEMO_VMID" "docker inspect -f '{{range .Mounts}}{{.Source}}{{println}}{{end}}' '${KC}' |
     grep -c '^${CHECKOUT_DIR}/' || true" | tr -d '\r\n')"
readback "${KC} 不再引用 ${HOME_DIR}" "0" \
  "$(guest_exec "$DEMO_VMID" "docker inspect -f '{{range .Mounts}}{{.Source}}{{println}}{{end}}' '${KC}' |
     grep -c '^${HOME_DIR}/' || true" | tr -d '\r\n')"

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "從 Edge 驗證 443"
say "驗證的是 Edge 的私有位址打得到 ${DEMO_IP}:443 —— 那正是票 08 的 DNAT 目的地。"

qm agent "$EDGE_VMID" ping >/dev/null 2>&1 || abort "Edge 的 guest agent 不可用，無法從 Edge 驗證"
health=$(guest_exec_or_abort "$EDGE_VMID" \
  "curl -kfsS --max-time 10 https://${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" \
  "從 Edge 取不到 ${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" | tr -d '\r\n')
readback "/healthz 回應" '{"status":"ok","env":"demo"}' "$health"

edge_fp=$(guest_exec "$EDGE_VMID" \
  "echo | openssl s_client -connect ${DEMO_IP}:${DEMO_SERVICE_PORT} 2>/dev/null |
   openssl x509 -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//; s/://g'" |
  tr -d '\r\n' || true)
if [[ -n "$edge_fp" ]]; then
  readback "Edge 看到的憑證與記錄的 fingerprint 相同" "$FINGERPRINT" "$edge_fp"
else
  warn "Edge 上無法取得憑證 fingerprint（openssl 不可用？），改由票 08 的 client 驗證"
fi

# ── 10 ────────────────────────────────────────────────────────────────────
stage "重開機後三顆自動恢復"
gate "重新開機 Demo？"

reboot_and_wait "$DEMO_VMID"

readback "${PLATFORM_ROOT} 自動掛回" "/dev/mapper/vg_data-lv_docker" \
  "$(dexec "findmnt -rno SOURCE '${PLATFORM_ROOT}'" "${PLATFORM_ROOT} 沒有掛回" | tr -d '\n')"
for c in "${DEMO_STACK_CONTAINERS[@]}"; do
  readback "${c} 重開機後自動恢復" "running" "$(wait_container_running "$DEMO_VMID" "$c")"
done
health=$(guest_exec_or_abort "$EDGE_VMID" \
  "curl -kfsS --max-time 10 https://${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" \
  "重開機後從 Edge 取不到 /healthz" | tr -d '\r\n')
readback "重開機後的 /healthz" '{"status":"ok","env":"demo"}' "$health"

# ── 11 ────────────────────────────────────────────────────────────────────
stage "收尾"
require_free_pct "$DEMO_VMID" "$PLATFORM_ROOT"
verify_uat_entrance

finish "票 11 完成：${DEMO_IP}:${DEMO_SERVICE_PORT} 已可驗收"
say "把產生的定義放回 repo（裡面沒有 secret，環境變數在 guest 的 keycloak.env）："
say ""
say "    scp root@${PVE_HOST_IP}:${DEPLOY_DIR}/compose.keycloak.yml \\"
say "        scripts/demo-entrance-and-srv-layout/demo-stack/"
say ""
say "重建前的原始定義（含環境變數，留在 guest）：${INSPECT_FILE}"
say "憑證 fingerprint：${FINGERPRINT_FILE}"
say "下一步：./08-publish-entrance-port-8082.sh"
