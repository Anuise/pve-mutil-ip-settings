#!/usr/bin/env bash
#
# render-keycloak-compose.sh FIELD_DIR OLD_PREFIX NEW_PREFIX
#
# 把 `docker inspect typeai-demo-kc` 抽出的欄位轉成 compose 定義，並把
# OLD_PREFIX 底下的 bind mount source 改指 NEW_PREFIX。輸出寫到 stdout。
#
# 為什麼是「產生」而不是「手寫」：那顆容器是手動 docker run 起來的，環境變數
# 與啟動參數只有它自己知道，照抄一份猜的定義會得到一個起得來但行為不同的容器。
#
# 環境變數不經過這裡 —— 它們可能含密碼，由 11-demo-443-endpoint.sh 在 guest 內
# 直接寫成 keycloak.env（mode 0600），不離開 guest、不進 repo。
#
# FIELD_DIR 內容（由 docker inspect --format 產生）：
#   image       單行
#   entrypoint  一行一個參數，可為空
#   cmd         一行一個參數，可為空
#   mounts      type<TAB>source<TAB>destination<TAB>rw，一行一個
#   networks    一行一個網路名，沿用該容器原本接的網路
#
# 網路沿用而非改接：nginx 這一側沒有 upstream（ADR-0003），proxy 與 keycloak
# 不需要共用網路；把 keycloak 換到別的網路只會弄丟它原本連得到的東西。
#
# 結束碼：1 抽不到 image；3 出現非 bind 的 mount（有資料要跟著走，交人判斷）。

set -euo pipefail

FIELD_DIR="${1:?FIELD_DIR}"
OLD_PREFIX="${2:?OLD_PREFIX}"
NEW_PREFIX="${3:?NEW_PREFIX}"

# yaml_quote STRING — YAML 單引號字串；內含的單引號要成對。
yaml_quote() { printf "'%s'" "${1//\'/\'\'}"; }

image=$(tr -d '\n' < "${FIELD_DIR}/image")
[[ -n "$image" ]] || { echo "抽不到 image" >&2; exit 1; }

printf '# 由 render-keycloak-compose.sh 依 `docker inspect typeai-demo-kc` 產生。\n'
printf '# 手改前先想清楚：這份定義的來源是那顆現存容器，不是猜的。\n'
printf '# 環境變數在同目錄的 keycloak.env（mode 0600），不進 repo。\n\n'
printf 'services:\n'
printf '  keycloak:\n'
printf '    container_name: typeai-demo-kc\n'
printf '    image: %s\n' "$(yaml_quote "$image")"
printf '    restart: unless-stopped\n'
printf '    env_file:\n      - keycloak.env\n'

if [[ -s "${FIELD_DIR}/entrypoint" ]]; then
  printf '    entrypoint:\n'
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    printf '      - %s\n' "$(yaml_quote "$arg")"
  done < "${FIELD_DIR}/entrypoint"
fi

if [[ -s "${FIELD_DIR}/cmd" ]]; then
  printf '    command:\n'
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    printf '      - %s\n' "$(yaml_quote "$arg")"
  done < "${FIELD_DIR}/cmd"
fi

if [[ -s "${FIELD_DIR}/mounts" ]]; then
  printf '    volumes:\n'
  while IFS=$'\t' read -r type source dest rw; do
    [[ -n "$type" ]] || continue
    if [[ "$type" != "bind" ]]; then
      echo "出現非 bind 的 mount（${type} ${source} -> ${dest}）：有資料要跟著走，請人工決定" >&2
      exit 3
    fi
    [[ "$source" != "${OLD_PREFIX}"* ]] || source="${NEW_PREFIX}${source#"$OLD_PREFIX"}"
    if [[ "$rw" == "true" ]]; then
      printf '      - %s\n' "$(yaml_quote "${source}:${dest}")"
    else
      printf '      - %s\n' "$(yaml_quote "${source}:${dest}:ro")"
    fi
  done < "${FIELD_DIR}/mounts"
fi

if [[ -s "${FIELD_DIR}/networks" ]]; then
  printf '    networks:\n'
  while IFS= read -r net; do
    [[ -n "$net" ]] || continue
    printf '      - %s\n' "$net"
  done < "${FIELD_DIR}/networks"
  printf '\nnetworks:\n'
  while IFS= read -r net; do
    [[ -n "$net" ]] || continue
    printf '  %s:\n    name: %s\n    external: true\n' "$net" "$net"
  done < "${FIELD_DIR}/networks"
fi
