# Meter

[English](README.md)

Meter는 Codex, Claude, Cursor, DeepSeek API, Command Code GOAT의 사용량과 한도를 한곳에서 확인하는 비공개 macOS 메뉴바 앱 및 CLI입니다.

## 주요 기능

- Codex 기본 한도와 모델별 롤링 한도 표시
- Claude 구독의 세션·주간 한도 및 모델별 윈도우 표시
- Cursor 플랜 사용량과 온디맨드 지출 표시
- DeepSeek API 잔액 표시
- Command Code GOAT 월간 크레딧과 롤링 한도 표시
- 앱을 다시 실행해도 유지되는 제공자별 토글
- 로그인 시 자동 실행
- **⌃⌥M**으로 어디서든 메뉴 열고 닫기
- 제공자 카드를 드래그해서 순서 변경, 터미널 `meter` 출력도 같은 순서
- 5분마다 자동 갱신 및 메뉴에서 수동 갱신
- 일시적인 갱신 실패 시 마지막 정상 데이터 보존
- 활성화된 제공자 중 가장 높은 사용률에 따라 변하는 메뉴바 게이지
- 대화형 사용과 자동화를 위한 독립 실행형 `meter` 명령

## 요구 사항

- macOS 14 이상
- Codex 사용량 조회를 위한 Codex 앱 또는 Codex CLI 로그인
- Claude 구독 사용량 조회를 위한 Claude Code 로그인
- Cursor 사용량 조회를 위한 Cursor 데스크톱 앱 로그인
- DeepSeek 잔액 조회를 위한 DeepSeek API 키 (Meter에 붙여넣거나 `DEEPSEEK_API_KEY`에 설정)
- Command Code 사용량 조회를 위한 Command Code CLI 로그인 또는 `COMMAND_CODE_API_KEY`
- 키체인 허용이 리빌드 후에도 유지되도록 하는 코드 서명 인증서 — [서명](#서명) 참고

Cursor를 제외한 모든 제공자가 기본으로 켜져 있습니다. Cursor는 데스크톱 앱 설치가 필요하므로 Meter 메뉴나 `meter enable cursor`로 직접 켭니다.

각 자격 증명의 출처와 존재 여부는 `meter doctor`로 확인할 수 있습니다. 어떤 제공자도 브라우저가 설치되거나 실행되어 있을 필요는 없습니다.

## 설치

[v0.4.18 릴리즈](https://github.com/justn-hyeok/meter/releases/tag/v0.4.18)에서 `Meter-0.4.18-macos-universal-app.zip`을 내려받아 압축을 풀고 `Meter.app`을 `/Applications`로 옮깁니다.

**설치 후 필수:** 릴리즈는 공증되지 않아서, 브라우저가 붙인 격리 속성을 지우기 전까지 macOS가 실행을 막습니다. 앱을 옮긴 뒤 한 번만 실행하세요.

```sh
xattr -dr com.apple.quarantine /Applications/Meter.app
```

macOS 15(Sequoia)부터는 예전의 Control-클릭 → **열기** 방법이 통하지 않습니다. 명령어 말고는 한 번 실행을 시도한 뒤 시스템 설정 → 개인정보 보호 및 보안에서 **그래도 열기**를 누르는 방법뿐입니다.

> 이 단계 없애고 싶으면 저한테 $99 입금하세요. 공증에 필요한 Apple Developer 연회비가 딱 그만큼입니다.

직접 빌드하면 이 과정이 필요 없고, 키체인 허용도 리빌드 후에 유지됩니다 — [서명](#서명) 참고.

앱과 CLI 압축 파일의 SHA-256 체크섬은 릴리즈 노트에 포함됩니다.

Meter는 메뉴바에서만 실행되며 Dock에는 나타나지 않습니다.

## 제공자 설정

### Codex

Meter는 먼저 공식 로컬 Codex app-server의 `account/rateLimits/read` 메서드로 한도를 조회합니다. 기본 한도와 GPT-5.3-Codex-Spark 같은 모델별 한도를 함께 받을 수 있습니다. 로컬 app-server를 사용할 수 없으면 기존 `~/.codex/auth.json` 세션으로 인증된 `wham/usage` 요청을 사용합니다.

Meter에서 별도로 로그인할 필요는 없습니다. 자격 증명이나 원본 인증 응답은 로그에 남기지 않습니다.

### Claude

1. 아직 로그인하지 않았다면 `claude`(Claude Code)로 로그인합니다.
2. macOS가 처음 키체인 허용을 물으면 **항상 허용**을 선택합니다.

Claude Code는 구독 OAuth 토큰을 로그인 키체인에 보관하며 갱신합니다. Meter는 그 항목을 읽어 계정 사용량
엔드포인트를 호출합니다. 윈도우는 응답의 자기설명적인 `limits` 배열에서 읽습니다. 그 옆에 있는 코드네임 키들은
플랜이 바뀌면 생기고 사라지기 때문입니다.

### Cursor

1. Cursor 데스크톱 앱에 로그인합니다.
2. Meter에서 **Cursor**를 켜거나 `meter enable cursor`를 실행합니다.
3. macOS가 처음 키체인 허용을 물으면 **항상 허용**을 선택합니다.

Cursor 앱은 WorkOS 세션을 로그인 키체인에 보관하며 토큰을 스스로 갱신합니다. Meter는 그 항목을 읽어 대시보드 엔드포인트를 직접 호출하므로 브라우저가 관여하지 않습니다.

### DeepSeek API

Meter 메뉴의 DeepSeek 카드에 키를 붙여넣거나, 파이프로 넣습니다.

```sh
meter set-key deepseek
```

`set-key`는 터미널 에코를 끄고 stdin에서 읽으므로 키가 셸 히스토리에 남지 않습니다. 키는 `~/Library/Application Support/Meter/credentials.json`에 `0600`으로 저장되어 앱과 CLI가 함께 읽습니다. Finder에서 실행한 앱은 셸 환경을 전혀 상속하지 않기 때문에 환경 변수만으로는 부족했습니다. `DEEPSEEK_API_KEY`가 설정되어 있으면 그쪽이 우선하므로 기존 설정은 그대로 동작하고, `meter clear-key deepseek`으로 저장된 키를 지울 수 있습니다.

수집기는 DeepSeek 공식 `/user/balance` 엔드포인트를 사용합니다. 잔액만 제공하는 데이터는 알려진 지출 한도가 없으므로 메뉴바 게이지에 반영되지 않습니다.

### Command Code GOAT

Command Code 공식 CLI로 한 번 로그인합니다.

```sh
cmd login
```

Meter는 그 CLI가 쓰는 것과 동일한 `alpha/billing/credits`·`alpha/usage/summary` 경로를 동일한 API 키로 호출합니다. 키는 `COMMAND_CODE_API_KEY`, `meter set-key command-code`로 저장한 키, `~/.commandcode/auth.json` 순으로 찾습니다. 브라우저는 관여하지 않으며 실행 중이어야 하는 것도 없습니다.

## 개인정보 보호 및 안정성

- 자격 증명, 쿠키, 토큰을 로그에 남기지 않습니다.
- 자격 증명은 로컬 키체인, 각 서비스 공식 CLI가 기록한 파일, 사용자가 Meter에 준 키에서 읽으며, 발급한 서비스에만 전송됩니다.
- 모든 제공자는 해당 서비스의 공식 클라이언트가 쓰는 API로 접근합니다.
- JWT는 `sub` 클레임만 읽습니다. Meter는 토큰을 검증하거나 생성하거나 다른 곳으로 보내지 않습니다.
- Cursor와 Command Code는 비공개 대시보드 엔드포인트를 사용하므로 대시보드가 변경되면 유지보수가 필요할 수 있습니다.
- 갱신에 실패해도 마지막 정상 스냅샷을 지우지 않고 오래된 데이터로 표시합니다.
- 모든 제공자 요청은 15초 후 타임아웃됩니다.

## 문제 해결

- **Codex를 사용할 수 없음:** Codex 앱 또는 CLI에서 로그인한 뒤 Meter를 새로고침합니다.
- **Cursor를 사용할 수 없음:** Cursor 앱에 로그인한 뒤 Meter를 새로고침합니다.
- **Command Code를 사용할 수 없음:** `cmd login`으로 로그인하거나 `meter set-key command-code`로 키를 지정합니다.
- **실행할 때마다 키체인 프롬프트가 뜸:** ad-hoc 서명 빌드라 리빌드마다 신원이 바뀌기 때문입니다. [서명](#서명)을 참고하세요.
- **DeepSeek을 사용할 수 없음:** `meter set-key deepseek`을 실행합니다. `DEEPSEEK_API_KEY`는 CLI에서는 동작하지만 Finder에서 실행한 앱은 볼 수 없으며, `meter doctor`가 이를 `blocked`로 보고합니다.
- **Dock 아이콘이 없음:** 정상 동작입니다. 메뉴바의 게이지 아이콘을 사용하세요.

## 개발

Swift Package Manager로 앱과 테스트를 실행합니다.

```sh
swift test
./Scripts/build-dev.sh
swift run MeterApp
```

`Scripts/build-dev.sh`는 디버그 산출물을 빌드한 뒤 서명합니다. 리빌드마다 macOS가 키체인 허용을 다시 묻는 것을 막아 줍니다. `swift Scripts/make-icon.swift`는 CoreGraphics로 `Resources/AppIcon.icns`를 다시 그립니다. 결과물은 커밋되어 있으므로 일반 빌드에는 추가로 필요한 것이 없습니다.

### 서명

Meter는 다른 앱이 소유한 자격 증명을 읽고, macOS는 그 허용을 앱의 **지정 요구사항(DR)** 기준으로 기록합니다.

```
ad-hoc  => cdhash H"97720ab1..."                 리빌드마다 변경
인증서  => identifier "com.justn.meter" and ...  고정
```

즉 ad-hoc 서명은 리빌드할 때마다 스스로의 키체인 접근 권한을 무효화합니다. `Scripts/sign.sh`는 Developer ID 인증서를 우선 사용하고, 없으면 무료 Apple ID로 발급되는 Apple Development 인증서를 사용합니다. `METER_SIGN_IDENTITY`로 직접 지정할 수 있습니다. 공증은 다른 맥에 배포할 때만 필요합니다.

## CLI

메뉴바 앱과 동일한 제공자 및 활성화 설정을 사용하는 `meter` CLI가 포함되어 있습니다. 앱이 실행 중이지 않아도 최신 사용량을 직접 조회합니다.

```sh
swift run meter
swift run meter codex
swift run meter cursor command-code --json
swift run meter doctor
swift run meter set-key deepseek
swift run meter providers
swift run meter enable cursor
swift run meter disable deepseek
```

제공자를 생략하면 공유 설정에서 활성화된 제공자를 조회합니다. `meter all`은 비활성 제공자까지 모두 조회하며 `meter codex`는 `meter status codex`의 단축형입니다. `providers` 명령은 현재 활성화 상태를 표시합니다.

`meter set-key <provider>`는 Meter가 이 맥에서 찾을 수 없는 제공자의 API 키를 stdin에서 읽어 저장하고, `meter clear-key <provider>`는 지웁니다. `meter doctor`는 각 자격 증명의 출처와 존재 여부를 보고합니다. 네트워크 요청을 하지 않고 키체인 프롬프트도 띄우지 않으므로 제공자가 고장난 상태에서도 사용할 수 있습니다. `--strict`와 함께 쓰면 활성화된 제공자에 자격 증명이 없을 때 1을 반환합니다.

기본 모드에서는 하나 이상의 제공자가 성공하면 종료 코드 0을 반환합니다. 일부 제공자 실패도 코드 1로 처리하려면 `--strict`를 사용합니다. 모든 제공자가 실패하면 2, 잘못된 인자에는 64를 반환합니다. JSON 출력은 버전이 지정된 `schemaVersion` 봉투와 조회 불가 제공자를 `snapshots`에 포함합니다. 스키마 2에서 Cursor 지출 버킷 id가 `on-demand` → `spend`로 바뀌었고 doctor의 `availability`에 `blocked`가 추가됐습니다.

v0.4.18 릴리즈에는 `meter-0.4.18-macos-universal-cli.zip`도 포함됩니다. 압축을 풀어 `meter`를 `PATH`에 포함된 디렉터리로 옮기고 같은 방법으로 격리 속성을 지우거나(`xattr -d com.apple.quarantine <경로>/meter`), 현재 체크아웃에서 릴리즈 빌드를 만들어 `~/.local/bin`에 설치합니다.

```sh
./Scripts/install-cli.sh
```

다른 위치에 설치하려면 `PREFIX`를 지정합니다.

```sh
PREFIX=/usr/local ./Scripts/install-cli.sh
```

Apple Silicon과 Intel을 모두 지원하는 ad-hoc 서명 앱 번들을 빌드합니다.

```sh
./Scripts/package-app.sh
```

결과물은 `dist/Meter.app`에 생성됩니다.

GitHub 릴리즈용 버전 지정 앱 및 universal CLI 압축 파일을 함께 빌드합니다.

```sh
./Scripts/package-release.sh
```

실행 파일 경로를 바꿔야 할 때 사용할 수 있는 환경 변수:

- `CODEX_CLI_PATH`: 별도 Codex CLI 실행 파일 경로
- `METER_SIGN_IDENTITY`: 패키징 스크립트가 사용할 코드 서명 인증서

## 라이선스

비공개 프로젝트이며 공개 라이선스를 부여하지 않습니다.
