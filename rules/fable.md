---
name: fable
description: devin 위임 오케스트레이션 — 사용 가능한 명령과 정본의 위치
---

# fable — devin 위임 오케스트레이션

이 환경에는 위임 도구가 설치돼 있다. `<PLUGIN>` 은 `$DEVIN_PLUGIN_ROOT` 다.

| 목적 | 명령 |
|---|---|
| 모드 확인 | `powershell -NoProfile -File "<PLUGIN>/scripts/fable.ps1" status` |
| 모드 전환 | `... fable.ps1 on` / `... fable.ps1 off` |
| 위임 | `... delegate.ps1 -Contract "<계약>" -Cwd "<작업트리>"` |
| 회수·조회 | `... reap.ps1` / `... reap.ps1 -Run <run_id>` |

⛔ **행동 지시의 정본은 이 파일이 아니다.** 현재 모드와 역할(오케스트레이터냐 워커냐)에 따른
지시는 매 턴 `[fable]` 로 시작하는 컨텍스트로 주입된다. 이 파일과 주입된 내용이 어긋나면
**주입된 쪽을 따른다** — 지시를 두 곳에서 주면 반드시 어긋나기 때문에 그렇게 정해 두었다.
