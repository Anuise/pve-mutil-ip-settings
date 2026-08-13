# 05 — Phase 2 搬移機制決策

**What to build:** 決策，不是程式。依票 04 的量測結果，把 Phase 2 的機制定下來並寫回 spec。

spec 明文禁止在量測存在前決定這些。沒有這道閘，票 06 的實作只會自己猜。

要定的事：

- 搬移目標是目前掛在 Docker 預設路徑的 80G volume，還是改用大資料卷
- Docker 與應用服務的停機順序，以及各步驟的 rollback
- remount 在 Demo 這種非空 Docker 環境是否可行。既有 tutorial 明文警告：當時 UAT 是 0 containers、0 images 的空環境，非空環境不得直接照搬那組步驟
- 搬移後由什麼服務提供 `443`
- 搬完之後目標是否仍保有至少二成剩餘空間

若推估搬移後剩餘空間低於二成，本票以 `[HUMAN ACTION]` 停止，等待使用者決定。不得為了騰出空間而刪除資料。

不可逆且代價高的決策另立 ADR，其餘寫回 spec。

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] 搬移目標 volume 已選定，且理由連結到票 04 的實際數字
- [ ] 服務停機順序與各步驟 rollback 已寫明
- [ ] 非空 Docker 環境的 remount 可行性已判斷，並說明與 UAT 空環境步驟的差異
- [ ] 搬移後由什麼服務提供 `443` 已決定
- [ ] 推估搬移後剩餘空間已計算；低於二成時本票停止並標記 `[HUMAN ACTION]`
- [ ] 決策寫回 spec，不可逆者另立 ADR
- [ ] 本票未改動 Demo 任何狀態

## Comments

票 04 的量測完成，報告在 `docs/reports/demo-inventory-20260813.md`。以下是進決策前必須先知道的
發現：其中兩項推翻了本票原本的前提。決策本身留給本票，這裡只記錄事實。

### Docker 已經在專屬 LV 上，不在 OS 卷

本票第一項寫「搬移目標是目前掛在 Docker 預設路徑的 80G volume，還是改用大資料卷」，前提是
Docker 還擠在 OS 卷上。實測不是：

```
DockerRootDir=/var/lib/docker
/dev/mapper/vg_data-lv_docker  ext4  79G  67M  75G  1%  /var/lib/docker
```

`/var/lib/docker` 這個「預設路徑」本身就是 `vg_data` 上的 80G 專屬 LV，來自 curtin 安裝時的
`/etc/fstab`，不是 OS 卷的一部分。用了 67M，剩 75G。

連帶影響：

- 本票第三項「remount 在非空 Docker 環境是否可行」在 Docker 不需要搬的前提下不成立。
  環境確實非空（3 containers、7 images、1 volume），但 data-root 已在該去的位置。
- 票 06 標題是「Docker relocation to /srv/platform」。若 Docker 不搬，該票可能整票不需要，
  或縮成只處理 bind mount 來源路徑。這是本票要判的，不要在票 06 才發現。

### 需要搬的資料遠比 `/home/mobagel` 的 8.1G 小

8.1G 裡絕大多數是開發工具的快取，不是應用資料：

| 內容 | 大小 | 性質 |
|---|---|---|
| `.claude`（其中 `remote` 4.4G） | 4.5G | 開發工具 |
| `.vscode-server` | 1.5G | 開發工具 |
| `.cache`（其中 ms-playwright 656M） | 665M | 開發工具 |
| `.venvs`（其中 `typeai-backend` 465M） | 483M | 邊界不明 |
| `.local` + `.npm` | 319M | 開發工具 |
| `type-ai-platform-demo`（含 `.git` 32M） | 694M | 應用 |
| `rfp-workspace` | 19M | 應用？ |

應用相關約 713M；`/srv` 是 20G 的專屬 LV，目前用 3.9M（0%）。剩餘空間二成的門檻不會是問題，
本票「低於二成則 `[HUMAN ACTION]` 停止」那條大機率用不到。

真正要在本票劃清的是**界線**，不是容量：`.venvs/typeai-backend` 是應用執行環境還是開發工具，
`rfp-workspace` 算不算這次的搬移範圍，`.claude/remote` 那 4.4G 是否就留在 home 不動。
spec 已定 home 目錄本身不搬遷，所以留下的東西會繼續佔 `/home` 的 15G（現用 58%）。

大資料卷確認存在且健在：`/data/model-cache`，`/dev/sdc1` xfs 500G，已用 18G，剩 482G。

### 目前沒有任何服務提供 `443` 或 `80`

```
$ ss -ltnp | awk 'NR==1 || $4 ~ /:(80|443)$/'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
```

三個容器 `typeai-demo-proxy`（nginx:1.27-alpine）、`typeai-demo-kc`（keycloak:26.0）、
`typeai-demo-pg`（postgres:18-alpine）全部 `Exited`，兩天前停的。

本票第四項問「搬移後由什麼服務提供 `443`」—— 實情是**搬移前就沒有**。這不是搬移的副作用，
是既存的缺口。票 08 要把 `8082` 發佈出去，DNAT 的目的地得先有人在聽。誰負責把
`typeai-demo-proxy` 起起來、用什麼設定，是本票要一起定的，不能留給票 08 才發現。

### 舊路徑的引用面極窄

只有一條：

```
/typeai-demo-kc  /home/mobagel/type-ai-platform-demo/type-ai-platform-infra/base/keycloak/realm-typeai.json
                 -> /opt/keycloak/data/import/realm-typeai.json
```

systemd units 零引用（`/etc/systemd/system`、`/lib/systemd/system` 皆無命中），
compose 與 `.conf` 掃描零命中，也沒有 user-level systemd unit。路徑改寫的成本很低。

### 容量餘裕

`vg_data` 尚有 <50G 未配置，`vg_os` 只剩 <3.95G。要擴 `/srv` 有空間，要擴 `/home` 幾乎沒有。
