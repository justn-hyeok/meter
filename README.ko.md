# Meter

[English](README.md)

Meter는 Codex, Cursor, DeepSeek API, Command Code GOAT의 사용량과 한도를 한곳에서 확인하는 비공개 macOS 메뉴바 앱 및 CLI입니다.

## 주요 기능

- Codex 기본 한도와 모델별 롤링 한도 표시
- Cursor 플랜 사용량과 온디맨드 지출 표시
- DeepSeek API 잔액 표시
- Command Code GOAT 월간 크레딧과 롤링 한도 표시
- 앱을 다시 실행해도 유지되는 제공자별 토글
- 5분마다 자동 갱신 및 메뉴에서 수동 갱신
- 일시적인 갱신 실패 시 마지막 정상 데이터 보존
- 알려진 사용률 중 가장 높은 값에 따라 변하는 메뉴바 게이지
- 대화형 사용과 자동화를 위한 독립 실행형 `meter` 명령

## 요구 사항

- macOS 14 이상
- Codex 사용량 조회를 위한 Codex 앱 또는 Codex CLI 로그인
- DeepSeek 잔액 조회를 위해 앱 실행 환경에 설정된 `DEEPSEEK_API_KEY`
- Cursor와 Command Code 수집을 위한 Aside Browser 및 CLI 설치와 실행, 각 서비스의 로그인 세션

Codex와 DeepSeek은 기본으로 켜져 있습니다. Cursor와 Command Code는 기본으로 꺼져 있으며 Meter 메뉴나 `meter enable`로 켤 수 있습니다.

## 설치

[v0.3.1 릴리즈](https://github.com/justn-hyeok/meter/releases/tag/v0.3.1)에서 `Meter-0.3.1-macos-universal-unsigned.zip`을 내려받아 압축을 풀고 `Meter.app`을 `/Applications`로 옮깁니다.

릴리즈에는 ad-hoc 서명만 적용되어 있으며 공증되지 않았습니다. macOS가 첫 실행을 막으면 Finder에서 `Meter.app`을 Control-클릭하고 **열기**를 선택한 뒤 한 번 승인하세요.

앱과 CLI 압축 파일의 SHA-256 체크섬은 릴리즈 노트에 포함됩니다.

Meter는 메뉴바에서만 실행되며 Dock에는 나타나지 않습니다.

## 제공자 설정

### Codex

Meter는 먼저 공식 로컬 Codex app-server의 `account/rateLimits/read` 메서드로 한도를 조회합니다. 기본 한도와 GPT-5.3-Codex-Spark 같은 모델별 한도를 함께 받을 수 있습니다. 로컬 app-server를 사용할 수 없으면 기존 `~/.codex/auth.json` 세션으로 인증된 `wham/usage` 요청을 사용합니다.

Meter에서 별도로 로그인할 필요는 없습니다. 자격 증명이나 원본 인증 응답은 로그에 남기지 않습니다.

### Cursor

1. Aside Browser에서 `https://cursor.com/dashboard/spending`을 열고 로그인합니다.
2. Aside Browser를 실행 상태로 둡니다.
3. Meter에서 **Cursor**를 켜거나 `meter enable cursor`를 실행합니다.

Meter는 기존 Aside 브라우저 세션 안에서 대시보드 JSON 엔드포인트를 요청합니다. 브라우저 쿠키를 읽거나 저장하지 않습니다.

### DeepSeek API

Meter를 실행하는 환경에 `DEEPSEEK_API_KEY`를 설정합니다. 수집기는 DeepSeek 공식 `/user/balance` 엔드포인트를 사용합니다.

현재 버전에는 앱 안에서 API 키를 입력하는 기능이 없습니다. Finder에서 실행한 앱은 일반적으로 대화형 셸의 환경 변수를 상속하지 않습니다. CLI는 셸 환경을 상속하므로 `DEEPSEEK_API_KEY`가 이미 설정된 셸에서 `meter deepseek`을 실행하면 됩니다.

잔액만 제공하는 데이터는 알려진 지출 한도가 없으므로 메뉴바 게이지에 반영되지 않습니다.

### Command Code GOAT

1. Aside Browser에서 `https://commandcode.ai/justn-hyeok/settings/usage`를 열고 로그인합니다.
2. Aside Browser를 실행 상태로 둡니다.
3. Meter에서 **Command Code GOAT**를 켜거나 `meter enable command-code`를 실행합니다.

Meter는 인증된 브라우저 세션 안에서 크레딧 및 사용량 요약 JSON 엔드포인트를 요청합니다.

이 비공개 빌드는 `justn-hyeok` Command Code 워크스페이스에 고정되어 있습니다. 다른 워크스페이스용으로 빌드하려면 `CommandCodeUsageProvider`의 대시보드 경로를 변경해야 합니다.

## 개인정보 보호 및 안정성

- 자격 증명, 쿠키, 토큰을 로그에 남기지 않습니다.
- Cursor와 Command Code의 인증 요청은 Aside가 브라우저 페이지 컨텍스트 안에서 수행합니다.
- Cursor와 Command Code는 비공개 대시보드 엔드포인트를 사용하므로 대시보드가 변경되면 유지보수가 필요할 수 있습니다.
- 갱신에 실패해도 마지막 정상 스냅샷을 지우지 않고 오래된 데이터로 표시합니다.
- Aside 수집은 20초, Codex app-server 수집은 15초 후 타임아웃됩니다.

## 문제 해결

- **Codex를 사용할 수 없음:** Codex 앱 또는 CLI에서 로그인한 뒤 Meter를 새로고침합니다.
- **Cursor 또는 Command Code를 사용할 수 없음:** Aside Browser가 실행 중이고 해당 대시보드에 로그인된 상태인지 확인합니다.
- **DeepSeek을 사용할 수 없음:** Meter를 실행한 프로세스 환경에 `DEEPSEEK_API_KEY`가 있는지 확인합니다.
- **Dock 아이콘이 없음:** 정상 동작입니다. 메뉴바의 게이지 아이콘을 사용하세요.

## 개발

Swift Package Manager로 앱과 테스트를 실행합니다.

```sh
swift test
swift run MeterApp
```

## CLI

메뉴바 앱과 동일한 제공자 및 활성화 설정을 사용하는 `meter` CLI가 포함되어 있습니다. 앱이 실행 중이지 않아도 최신 사용량을 직접 조회합니다.

```sh
swift run meter
swift run meter codex
swift run meter cursor command-code --json
swift run meter providers
swift run meter enable cursor
swift run meter disable deepseek
```

제공자를 생략하면 공유 설정에서 활성화된 제공자를 조회합니다. `meter all`은 비활성 제공자까지 모두 조회하며 `meter codex`는 `meter status codex`의 단축형입니다. `providers` 명령은 현재 활성화 상태를 표시합니다.

기본 모드에서는 하나 이상의 제공자가 성공하면 종료 코드 0을 반환합니다. 일부 제공자 실패도 코드 1로 처리하려면 `--strict`를 사용합니다. 모든 제공자가 실패하면 2, 잘못된 인자에는 64를 반환합니다. JSON 출력은 버전이 지정된 `schemaVersion` 봉투와 조회 불가 제공자를 `snapshots`에 포함합니다.

v0.3.1 릴리즈에는 `meter-0.3.1-macos-universal.zip`도 포함됩니다. 압축을 풀어 `meter`를 `PATH`에 포함된 디렉터리로 옮기거나, 현재 체크아웃에서 릴리즈 빌드를 만들어 `~/.local/bin`에 설치합니다.

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
- `ASIDE_CLI_PATH`: 별도 Aside CLI 실행 파일 경로

## 라이선스

비공개 프로젝트이며 공개 라이선스를 부여하지 않습니다.
