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
