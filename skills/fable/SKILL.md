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

## 위임 — 구조를 먼저 고른다

분기는 둘뿐이다. **인수기준을 명령으로 명확히 줄 수 있는가.**

| 인수기준 | 구조 | 판정자 |
|---|---|---|
| 명령으로 줄 수 있다 | **랑데부** | 검증자가 실행해 판정, 실패하면 구현자가 다시 돈다 |
| 애매해서 직접 봐야 한다 | **단발** | 오케스트레이터가 받아서 검수한다 |

⛔ 애매한 기준을 랑데부로 보내면 검증자도 판정하지 못해 루프가 헛돈다.
⛔ 명확한 기준을 단발로 보내면 워커의 자기보고를 그대로 받게 된다.

### 랑데부 (worker ↔ verifier)

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<PLUGIN>/scripts/rendezvous.ps1" \
  -Contract "<계약>" -Criteria "<판정 명령>" -Cwd "<작업트리>" [-MaxRounds 3]
```

`-Criteria` 에는 **검증자가 실제로 실행할 명령**과 기대 결과를 적는다. 검증자는 그것을
돌려보고 마지막 줄에 `VERDICT: PASS|FAIL` 을 낸다. FAIL 이면 그 사유가 구현자에게
피드백으로 들어가 다음 라운드가 돈다. `-MaxRounds` 안에 PASS 가 안 나오면 종료 코드 1 로
돌아오니, 그때는 기준을 다시 쓰거나 직접 손을 댄다.

검증자가 작업트리를 고치면 그 라운드의 PASS 는 **무효 처리**된다 (자기가 고친 것을 자기가
통과시킨 셈이므로).

### 단발

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<PLUGIN>/scripts/delegate.ps1" \
  -Contract "<계약>" -Cwd "<작업트리>"
```

기본은 동기다 — 워커가 끝나면 출력이 그대로 돌아온다. 계약이 길면 파일에 쓰고
`-ContractFile <경로>` 로 넘긴다. 독립 계약을 동시에 여러 개 돌릴 때만 `-Async` 를 쓰고,
그때는 `reap.ps1 -Run <run_id>` 로 회수한다.

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
