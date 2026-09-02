# devin 훅·플러그인 실측 노트

이 시스템이 의존하는 devin 동작을 직접 재서 남긴 기록. devin CLI 는 문서화가 얇아서,
여기 적힌 것 대부분은 바이너리 문자열과 실행 실험으로 확인한 것이다.

측정 환경: Windows 11 / devin CLI / `-p --model swe-1-7-medium --permission-mode dangerous
--respect-workspace-trust false`. 기능의 유무를 가리는 이진 판정이라 n=1~2 로 확인했다.

## 훅

### 이벤트

`PreToolUse` `PostToolUse` `UserPromptSubmit` `Stop` `PostCompaction` `SessionStart`
`SessionEnd` `PermissionRequest`

Claude Code 와 이름이 같고, 내부 타입도 `ClaudeHookEvent` 계열이다.

### hooks.json 형식

```json
{
  "<Event>": [
    { "matcher": "<tool_name>",
      "hooks": [ { "type": "command", "command": "<shell>", "timeout": <초> } ] }
  ]
}
```

- `matcher` 는 생략 가능하다. 생략하면 그 이벤트 전체에 걸린다.
- `timeout` 은 **초** 단위로 주면 내부에서 ms 로 환산된다 (`15` → `15000ms`).
- ⛔ **devin 이 모르는 필드가 하나라도 있으면 훅 블록 전체가 조용히 무시된다.**
  `"powershell": true` 를 넣었더니 `plugins info` 의 Hooks 가 `(none)` 이 됐다.
  타입 자체는 바이너리에 있지만 이 형식에서는 받지 않는다. **쓰지 말 것.**
- 설치 출력(`plugins install`)에 훅이 나열되는지로 등록 여부를 확인할 수 있다.

### 훅에 들어오는 stdin

```json
{"hook_event_name":"PreToolUse","tool_name":"exec","tool_input":{"command":"echo hi"},
 "tool_use_id":"functions.exec:0","session_id":"abstracted-hovercraft","prompt_id":"..."}
{"hook_event_name":"SessionStart","source":"startup","session_id":"..."}
{"hook_event_name":"UserPromptSubmit","prompt":"...","session_id":"...","prompt_id":"..."}
```

`session_id` 는 사람이 읽는 슬러그다(`devin ls`·`--resume` 에서 쓰는 그 값).

### 도구 이름

소문자다. 셸은 **`exec`**, 파일 읽기는 `read`. `Bash` 로 matcher 를 걸면 아무것도 안 걸린다.

### 훅 실행 환경

- 실행 셸은 MSYS `/usr/bin/bash` 다 (`$0` 로 확인).
- ⛔ **python 은 그 bash 의 PATH 에 없을 수 있다.** python 으로 훅을 짜면 조용히 미발화한다.
  실제로 그것 때문에 가드가 안 도는 것을 matcher 문제로 오진했다.
  → 훅은 bash 에서 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>` 를
  부르는 형태로 짠다.
- 환경변수 `DEVIN_PLUGIN_ROOT` (별칭 `CLAUDE_PLUGIN_ROOT`) 로 설치된 플러그인 경로가 들어온다.
  훅 커맨드 문자열 안에서 `$DEVIN_PLUGIN_ROOT` 로 전개된다.
- **부모 프로세스의 환경변수가 훅까지 상속된다.** 이 시스템의 `FABLE_ROLE` 역할 분기가
  여기에 의존한다.

### 컨텍스트 주입

훅이 stdout 으로 아래를 내면 모델의 턴에 주입된다.

```json
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}
```

한국어도 그대로 들어간다 (`—`·`·` 같은 문자 포함). 다만 PowerShell 쪽에서
`[Console]::OutputEncoding` 을 UTF-8 로 두어야 한다.

### 차단

`exit 2` 도, stdout 에 `{"decision":"block","reason":"..."}` 를 내는 것도 **도구 실행을 막는다.**
다만 `devin -p` 에서는 **그 턴이 그대로 끝난다** — 모델이 사유를 받아 다른 방법을 시도하는
식으로는 이어지지 않았다(모델 출력 0). 그래서 가드는 좁게 잡고, 헤드리스 워커에는 차단을
남발하지 않는 편이 낫다.

## 플러그인

### 구성

```
plugin.json          name·version·description·author·homepage·repository·license·keywords
                     requiredPlugins·optionalPlugins·forbiddenPlugins·skills·mcpServers
hooks/hooks.json     위 형식
rules/*.md           frontmatter(name·description) + 본문
skills/<name>/SKILL.md
```

### 설치

```
devin plugins install <owner/repo>          # GitHub 에서 바로
devin plugins install --local -y <path>     # 로컬 체크아웃에서
devin plugins info <name>                   # 등록된 skills·hooks·rules 확인
devin plugins remove <name>
```

- 설치하면 플러그인이 `%APPDATA%\devin\cli\plugins\cache\<슬러그>-<해시>\<버전>\` 로 **복사**된다.
  즉 훅이 실행하는 것은 사본이다. **체크아웃을 고쳤으면 재설치해야 반영된다.**
- 같은 이유로 런타임 상태를 플러그인 디렉터리 안에 두면 안 된다. 이 시스템은
  `%USERPROFILE%\.fable-devin\` 을 쓴다.
- 플러그인은 **전역**이다. 설치해 두면 그 계정의 모든 devin 세션에 붙는다 — 실험용 플러그인을
  깔아두면 무관한 세션까지 영향을 받으므로 반드시 지운다.

### rules 의 활성화

플러그인의 rule 은 `agent-decided` 로 잡힌다. frontmatter 에 `always_on: true` 나
`activation: always_on` 을 넣어도 바뀌지 않았다. always-on 은 프로젝트의
`.windsurf/rules/*.md` 쪽 얘기다.

⇒ 항상 보여야 하는 지시는 rule 이 아니라 **UserPromptSubmit 훅의 additionalContext** 로 넣는다.

## PowerShell 쪽 함정

- **`Start-Process -PassThru` 의 `ExitCode` 가 `null` 로 남는다.** `WaitForExit()` 을 불러도
  그렇다. `$null = $proc.Handle` 로 핸들을 한 번 만져 두면 채워진다. 이걸 놓치면 완료 판정이
  통째로 무의미해진다.
- **`Set-Content -Encoding UTF8` 은 BOM 을 붙인다**(5.1). jq·node 가 그 JSON 을 못 읽는다.
  `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))` 를 쓴다.
- **콘솔 출력 인코딩이 OEM 코드페이지다.** 파일은 멀쩡한데 파이프로 넘길 때만 한글이 깨진다.
  `[Console]::OutputEncoding` 을 UTF-8 로 바꾼다.
- **BOM 없는 `.ps1` 을 5.1 은 ANSI 로 읽는다.** 그래서 이 시스템은 `.ps1` 을 ASCII 로만 쓰고
  한국어 문구는 전부 `messages/*.md` 에 둔다.

## 워커 스폰

```
devin -p --model <model> --permission-mode dangerous --respect-workspace-trust false \
      --prompt-file <path>
```

- ⛔ `-p "프롬프트"` 는 `[PATH]...` 인자와 충돌한다. 프롬프트는 `-- <프롬프트>` 로 주거나
  `--prompt-file` 로 넘긴다. 계약은 길고 한국어가 섞이므로 **파일 쪽이 안전하다**
  (BOM 없는 UTF-8 로 쓸 것).
- 실측 왕복 시간: 파일 하나 만드는 계약이 16~21초 (swe-1-7-medium).
