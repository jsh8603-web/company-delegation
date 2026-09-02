---
name: fable
description: 위임 오케스트레이션 모드를 확인·전환하고, 워커에 위임하거나 결과를 회수한다. 사용자가 "fable on", "fable off", "위임", "회수", "워커 상태" 를 말할 때 쓴다.
---

# fable

위임 오케스트레이션 제어. `<PLUGIN>` = `$DEVIN_PLUGIN_ROOT`.

## 모드

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<PLUGIN>/scripts/fable.ps1" status
powershell -NoProfile -ExecutionPolicy Bypass -File "<PLUGIN>/scripts/fable.ps1" on
powershell -NoProfile -ExecutionPolicy Bypass -File "<PLUGIN>/scripts/fable.ps1" off
```

- `on` — 오케스트레이터로 동작한다. 구현은 워커에 위임한다.
- `off` — 직접 구현해도 된다. 위임은 여전히 가능하다.

## 위임

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<PLUGIN>/scripts/delegate.ps1" \
  -Contract "<계약>" -Cwd "<작업트리>"
```

기본은 동기다 — 워커가 끝나면 출력이 그대로 돌아온다. 계약이 길면 파일에 쓰고
`-ContractFile <경로>` 로 넘긴다. 독립 계약을 동시에 여러 개 돌릴 때만 `-Async` 를 쓰고,
그때는 `reap.ps1 -Run <run_id>` 로 회수한다.

계약에는 **인수기준을 명령으로** 적는다. 워커가 로컬에서 닫을 수 있어야 한다.

## 회수·조회

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<PLUGIN>/scripts/reap.ps1"
... reap.ps1 -Run <run_id>      # 특정 실행의 출력·종료코드
... reap.ps1 -Clean -Days 7     # 끝난 기록 정리
... reap.ps1 -Stale             # 방치된 async 실행 정리
```

## 규율

- 워커가 반환하면 **산출물의 실재를 직접 확인한다.** `exit 0` 은 완료의 증거가 아니다.
- 워커 모델은 luna 로 고정돼 있다. 다른 모델을 쓰려 하면 가드가 막는다 — 과금 때문이다.
- 워커는 재위임하지 않는다.
