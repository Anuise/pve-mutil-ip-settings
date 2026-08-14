# 07 — 還原保全的應用資料，並確認重開機後站得住

**What to build:** 把票 01 保全的 `/srv/typeai-demo/` 與 Keycloak 資料庫 volume 放回新
機器，然後重開機驗證整台機器自己站得起來。

**還原是有選擇的，不是無條件照搬。** 舊 `/srv/typeai-demo/` 裡混了三種東西：

| 類別 | 內容 | 處置 |
| --- | --- | --- |
| secret | `demo-password`、`kc-admin-password`、`kc-token`、`seed-client-secret`、`service-token-secret` | 還原，mode `0600`，擁有者 `mobagel` |
| 設定與文件 | `nginx.conf`、`試用說明.md` | 還原，供日後參考 |
| 舊執行產物 | `backend.log`、`frontend.log`、`frontend-build.log`、`screenshots/`、`smoke-shots/`、`tls.crt`、`tls.key` | **不還原**，留在保全副本裡 |

`tls.crt`／`tls.key` 明確不還原：2026-09-09 就到期，而 ADR-0001 要的是永久入口。日後
真的要開 443 端點時另外處理，不要讓一張快過期的憑證混進新機器。

Keycloak 的 volume 還原是**可選的，且要有閘門**。新機器上還沒有 stack，volume 還原後
沒有容器會用它。決定：還原成一個 tar 檔放在 `/srv/typeai-demo/`，**不建立 docker
volume** —— 等真的要跑 Keycloak 時再由那時候的 compose 決定怎麼掛。這樣不會憑空造出
一個沒人用、卻又被當成資料庫的 volume。

重開機驗證：`onboot` 先設 `1`，重開機，確認位址、`/srv`、Docker、repo、還原的檔案
全部自己回來。

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] 五個 secret 檔已還原，mode `0600`，擁有者 `mobagel`，SHA-256 與票 01 記錄相符
- [ ] `nginx.conf` 與 `試用說明.md` 已還原
- [ ] `tls.crt`／`tls.key` 與舊 log **未**被還原
- [ ] Keycloak volume 以 tar 形式放在 `/srv/typeai-demo/`，未建立 docker volume
- [ ] `onboot` 設為 `1`
- [ ] 重開機後：位址 `172.23.57.12`、`/srv` 已掛載、Docker 可用、repo 在原處、
      還原的檔案權限未變
- [ ] guest agent 重開機後正常回應
- [ ] UAT 的 `10.1.2.57:8081` 不受影響
