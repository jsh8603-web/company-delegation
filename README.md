# company-delegation

devin 하나만 있는 환경을 위한 위임 오케스트레이션. **메인 = grok**(사용자가 직접 대화하는
인터랙티브 세션), **워커 = luna**(헤드리스 재위임). 그 외 기능은 없다.

devin 플러그인이라 설치는 한 줄이고, 훅·가드·모드 토글이 함께 따라온다.

---

## 요구사항

- Windows + PowerShell 5.1 이상 (PowerShell 7 도 동작)
- devin CLI (로그인 완료)
- devin 계정에서 `grok-4-6-*` 와 `gpt-5-6-luna-*` 가 보일 것

```powershell
devin models list | Select-String -Pattern 'grok|luna'
```

## 설치

```powershell
git clone https://github.com/jsh8603-web/company-delegation.git
cd company-delegation
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

체크아웃에서 설치하면 실행할 런처와 등록된 훅이 같은 버전을 가리킨다. 훅·스킬만 필요하면
`devin plugins install jsh8603-web/company-delegation` 로도 된다.

설치 후 판정 로직이 성한지 확인한다. devin 을 부르지 않으므로 즉시 끝나고 과금도 없다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\selftest.ps1
```

`passed=N failed=0` 과 함께 `checks_run=N` 이 찍힌다. **`failed=0` 만 보지 말고 `checks_run`
개수를 같이 봐라** — 스위트가 중간에 죽어도 그때까지의 PASS 만 찍히기 때문이다.

⛔ **스크립트를 고쳤으면 `install.ps1` 을 다시 돌려라.** 훅은 설치 시점에 복사된 사본을
실행하므로, 체크아웃만 고치면 훅은 옛 코드를 계속 쓴다.

## 사용

### 메인 세션 열기

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\main.ps1 -Path D:\work\myrepo
```

`-Path` 를 빼면 현재 디렉터리에서 연다. 여기에 사용자가 직접 대화한다.

### 모드

```powershell
.\scripts\fable.ps1 status
.\scripts\fable.ps1 on
.\scripts\fable.ps1 off
```

| 모드 | 메인의 행동 |
|---|---|
| `on` | 오케스트레이터로 동작한다. 구현은 워커에 위임한다. |
| `off` | 직접 구현해도 된다. 위임은 여전히 가능하고, 그 안내가 매 턴 뜬다. |

세션 안에서는 `/company-delegation:fable` 스킬로도 다룰 수 있다.

### 위임 — 구조를 먼저 고른다

분기는 둘뿐이다. **인수기준을 명령으로 명확히 줄 수 있는가.**

| 인수기준 | 구조 | 판정자 |
|---|---|---|
| 명령으로 줄 수 있다 | **랑데부** | 검증자가 실행해 판정, 실패하면 구현자가 다시 돈다 |
| 애매해서 사람이 봐야 한다 | **단발** | 메인이 받아서 검수한다 |

애매한 기준을 랑데부로 보내면 검증자도 판정하지 못해 루프가 헛돌고, 명확한 기준을 단발로
보내면 워커의 자기보고를 그대로 받게 된다. 이 분기표는 문서에만 두지 않고 **매 턴 주입되는
`[fable]` 문구에 직접 들어간다** — 문서에만 있으면 실제로는 선택되지 않기 때문이다.

#### 랑데부 (worker ↔ verifier, 둘 다 luna)

```powershell
.\scripts\rendezvous.ps1 -Contract "<계약>" -Criteria "<판정 명령>" -Cwd "D:\work\myrepo"
.\scripts\rendezvous.ps1 -ContractFile .\c.txt -CriteriaFile .\crit.txt -Cwd "D:\work\myrepo" -MaxRounds 3
```

한 라운드는 `구현자 → 검증자` 다. 검증자는 인수기준의 명령을 실제로 돌리고 마지막 줄에
`VERDICT: PASS|FAIL` 을 낸다. FAIL 이면 그 사유가 다음 라운드 구현자에게 피드백으로
들어간다. `-MaxRounds`(기본 3) 안에 PASS 가 없으면 종료 코드 1 로 끝난다.

- 판정 줄이 없으면 **FAIL 로 처리**한다 (없는 판정을 통과로 읽지 않는다).
- 검증자가 작업트리를 고쳤으면 그 라운드의 PASS 는 **무효**다. 자기가 고친 것을 자기가
  통과시킨 것이기 때문이고, 스크립트가 파일 스냅샷을 비교해 기계적으로 잡는다.

#### 단발

```powershell
.\scripts\delegate.ps1 -Contract "<계약>" -Cwd "D:\work\myrepo"
.\scripts\delegate.ps1 -ContractFile .\contract.txt -Cwd "D:\work\myrepo"
```

기본은 **동기**다. 워커가 끝나면 출력이 그대로 돌아오므로 "띄워놓고 잊어버리는" 실패가
구조적으로 생기지 않는다. 독립 계약을 동시에 여러 개 돌릴 때만 `-Async` 를 쓰고, 그때는
`reap.ps1` 로 회수한다.

### 회수·조회

```powershell
.\scripts\reap.ps1                 # 진행 중 + 최근 완료
.\scripts\reap.ps1 -Run <run_id>   # 그 실행의 출력·종료코드
.\scripts\reap.ps1 -Clean -Days 7  # 끝난 기록 정리
.\scripts\reap.ps1 -Stale          # 방치된 async 실행 정리
```

---

## 구조

```
plugin.json          매니페스트
hooks/hooks.json     UserPromptSubmit(주입) · PreToolUse:exec(가드)
rules/fable.md       명령 참조표 (agent-decided)
skills/fable/        /company-delegation:fable
messages/*.md        주입되는 한국어 문구 (모드별·역할별) + 랑데부 프롬프트 템플릿
scripts/*.ps1        런처 · 토글 · 주입 · 가드 · 위임(단발/랑데부) · 회수
```

런타임 상태는 플러그인 안이 아니라 `%USERPROFILE%\.fable-devin\` 에 산다
(`devin plugins update` 가 플러그인 트리를 통째로 교체하기 때문).

```
%USERPROFILE%\.fable-devin\
  state.txt              on | off
  runs\<run_id>\         contract.txt · meta.json · done.json · stdout.log · stderr.log
  log\fable.log
```

### 지시는 한 곳에서만 주입한다

워커도 같은 devin 이므로 **같은 플러그인이 워커에도 붙는다.** 그래서 역할별 지시를
rules 와 hook 두 곳에서 주면 반드시 어긋난다. 이 시스템은 `scripts/inject.ps1`
**한 곳에서만** 주입한다.

- 분기 기준 = 자식을 띄울 때 심는 `FABLE_ROLE` 환경변수 (`worker` / `verifier` / 없으면 메인)
- `rules/fable.md` 는 명령 참조표일 뿐이고, "정본은 주입된 `[fable]` 쪽" 이라고 명시한다

같은 이유로 devin 을 실제로 실행하는 코드도 `lib.ps1` 의 `Invoke-DevinRun` 한 곳뿐이다.
단발과 랑데부가 각자 실행 코드를 들고 있으면 언젠가 한쪽만 고쳐진다.

### 가드 (`scripts/guard.ps1`)

모든 도구 호출 직전에 돈다. hooks.json 의 matcher 로 도구를 거르지 않고 스크립트 안에서
판단한다 — matcher 를 틀리면 **가드가 조용히 죽기** 때문이다 (`Bash` 로 걸었더니 아무것도
안 걸리는 것을 실측했다. devin 의 셸 도구 이름은 `exec` 다).

**항상 적용**

1. **워커 모델 화이트리스트** — luna 가 아닌 모델로 워커를 띄우려 하면 막는다. 다른 모델은
   과금되므로 취향 문제가 아니다. 로컬 테스트에서만 `FABLE_ALLOW_TEST_MODELS=1` 로 완화한다.
2. **재위임 금지** — 워커·검증자가 다시 위임하려 하면 막는다.
3. **보호 경로** — 플러그인 자신과 `.fable-devin` 상태 디렉터리에 대한 파괴적 명령을 막는다.

**`on` 일 때만, 메인에게만 — 하드 게이트**

4. **셸로 코드 파일을 못 고친다** — `sed -i` / `perl -i` / `> file.py` / `tee` /
   `Set-Content`·`Add-Content`·`Out-File` / `[IO.File]::WriteAllText` / `New-Item -Value`.
   개수 무관 **항상** 차단이다.
5. **턴당 코드 파일 2개까지만 직접 편집** (`FABLE_MAIN_EDIT_LIMIT` 로 조정). 3개째부터 차단되고
   위임하라는 메시지가 나온다. 같은 파일 재편집은 예산을 쓰지 않고, 문서·설정 같은 비코드
   파일은 제한이 없다. 턴이 바뀌면 예산이 초기화되지만 **같은 구현을 다음 턴으로 미루는 것은
   우회**다.

워커와 검증자는 4·5의 대상이 아니다 — 그들이 구현자다.

⛔ **"위임하라"는 지시만으로는 강제가 아니다.** 이 게이트가 없으면 `on` 모드의 메인은 그냥
직접 구현한다. 그래서 지시(주입)와 강제(가드)를 둘 다 둔다.

⛔ 차단은 **현재 턴을 종료시킨다**(devin `-p` 에서 실측). 메인은 인터랙티브라 사용자가 다시
지시하면 되지만, 그래서 가드를 넓히면 워커가 조용히 죽는다. 좁게 유지할 것.

## 환경변수

| 변수 | 기본값 | 용도 |
|---|---|---|
| `FABLE_MAIN_MODEL` | `grok-4-6-high` | 메인 모델 |
| `FABLE_WORKER_MODEL` | `gpt-5-6-luna-high` | 워커 모델 |
| `FABLE_ALLOW_TEST_MODELS` | (없음) | `1` 이면 swe 를 한시 허용 (**로컬 테스트 전용**) |
| `FABLE_MAIN_EDIT_LIMIT` | `2` | `on` 일 때 메인이 한 턴에 직접 편집할 수 있는 코드 파일 수 |
| `FABLE_HOME` | `%USERPROFILE%\.fable-devin` | 상태 디렉터리 |
| `FABLE_DEVIN_BIN` | 자동 탐색 | devin 실행 파일 경로 |
| `FABLE_ROLE` | (자동) | `worker` 면 워커 지시가 주입된다. 손으로 설정하지 말 것 |

## 트러블슈팅

**주입이 안 뜬다** — `devin plugins info company-delegation` 으로 훅 2개가 보이는지 확인한다.
안 보이면 `install.ps1` 을 다시 돌린다. `hooks.json` 에 devin 이 모르는 필드가 있으면
훅 전체가 조용히 무시된다 (`"powershell": true` 가 그 예다 — 쓰지 말 것).

**한글이 깨진다** — `.ps1` 에는 한국어를 넣지 않는다. 사용자에게 보이는 문구는 전부
`messages/*.md` 에 있다. PowerShell 5.1 은 BOM 없는 `.ps1` 을 ANSI 로 읽기 때문이다.

**워커가 아무것도 안 했다** — `reap.ps1 -Run <run_id>` 로 `stderr.log` 를 본다. 가드에 막혔다면
`%USERPROFILE%\.fable-devin\log\fable.log` 에 사유가 남는다.

**`exit 0` 이 나왔는데 산출물이 없다** — 정상적으로 가능한 일이다. 종료 코드는 왕복이 됐다는
뜻일 뿐이니 산출물의 실재를 직접 확인한다.
