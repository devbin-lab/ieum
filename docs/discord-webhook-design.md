# Discord 채널 알림 설계와 구현

상태: **앱 구현 · 정적 분석과 로컬 테스트 및 Windows Release 빌드 완료**

기준: 2026-10-10. Windows Flutter 앱에 프로젝트별 Discord Incoming Webhook 연결을
구현했다. 이 문서는 현재 코드 경로와 사용 범위를 설명한다. 실제 Discord 메시지 게시와
사용자의 화면 조작 검증은 수행하지 않았다. 기존 서버·봇 철거 내역은
[철거 기록](discord-bot-retirement.md)에 별도로 남긴다.

## 1. 운영 구조

- 프로젝트 소유자가 `프로젝트 설정 → 알림`에서 채널과 받을 알림을 등록한다.
- 프로젝트마다 여러 Discord 채널을 연결할 수 있다. 다른 프로젝트의 설정·키·전송 큐는 분리한다.
- 참여자는 같은 화면의 `내 Discord 계정`에서 **본인 숫자 사용자 ID**를 등록한다.
- 작업 배정·전달·상태 변경·완료를 채널에 게시하며 담당자 또는 담당 파트 구성원을 멘션한다.
- 작업 변경을 저장한 기기만 발신한다. 다른 참여자 앱의 동기화 수신은 추가 발신을 만들지 않는다.
- 중앙 서버, 공유 봇, Discord 봇 토큰, Cloudflare, GitHub Actions, 개인 DM을 사용하지 않는다.
- `바로가기`의 Discord 링크는 브라우저로 여는 주소다. 알림 연결이나 계정 인증과 구분한다.

이 구조는 앱이 실행 중인 동안 동작한다. 모든 앱이 종료된 동안 메시지를 보내는 상주 서버는 없다.
원본 기기가 다시 실행되고 같은 프로젝트를 열면 남은 반영 확인과 알림 전송을 이어간다.

## 2. 프로젝트 소유자: 채널 연결

1. Discord의 `채널 설정 → 연동 → 웹훅`에서 Incoming Webhook을 만들고 URL을 복사한다.
2. 이음의 `프로젝트 설정 → 알림 → 채널 연결`에서 이름과 URL을 입력한다.
3. 앱은 Discord GET 조회로 웹훅 종류·서버·실제 채널을 확인한다. 등록 과정에 메시지를 보내지 않는다.
4. 받을 알림 종류인 `작업 배정`, `작업 전달`, `상태 변경`, `작업 완료`와 담당 파트를 선택한다.
5. 최초 등록 기기가 관리자 서명 키와 장치 키를 만들고 해당 프로젝트의 첫 신뢰 기기로 등록된다.
6. 채널 카드에서 알림 사용 여부·파트·전송 가능한 기기 상태를 확인하고 설정을 수정한다.

채널 관리 권한은 프로젝트 소유자에게 있다. 다른 관리 파트의 권한만으로 채널·장치 연결을
변경하지 않는다. 저장한 웹훅 URL은 채널 카드에 표시하지 않는다. URL 입력은 가리고,
전송 오류에도 토큰이 들어 있는 원본 URL·HTTP 응답을 표시하지 않는다.

## 3. 참여자: 멘션 ID와 기기 연결

### 본인 Discord 사용자 ID

Discord 설정의 `고급 → 개발자 모드`를 켠 뒤 내 프로필에서 `사용자 ID 복사`를 선택한다.
이음의 `내 Discord 계정`에 17~20자리 숫자 ID를 등록한다. 닉네임으로 사용자를 검색하지 않는다.
입력을 비우고 저장하면 해당 프로젝트의 멘션 ID를 해제한다.

현재 연결은 `Person.discordUserId`를 해당 프로젝트의 `.ieum/project.json`에 저장한다.
`GitHubSession.setOwnDiscordUserId`는 매번 로그인한 활성 참여자와 최신 manifest를 확인하고
본인 항목만 수정한다. 이름 변경의 계정 전역 전파를 Discord ID에 적용하지 않는다.
다른 프로젝트에도 사용하려면 각 프로젝트에서 등록해야 한다.

이 값은 **자가 등록한 멘션 대상 ID**다. Discord OAuth 로그인, ID 소유권 증명,
서버 가입 여부 확인을 제공하지 않는다. ID 등록을 작업 수정 권한이나 로그인 인증에 사용하지 않는다.
웹훅만으로 서버 참여자 목록을 조회할 수 없으며, 저장소 접근자는 manifest의 ID를 볼 수 있다.

### 이 기기에서 알림 전송

멘션을 받는 데에는 기기 승인이 필요 없다. 참여자의 PC에서도 작업 변경 알림을 보내려면
프로젝트에 승인된 기기가 되어야 한다.

1. 소유자가 `참여자 연결 코드`에서 현재 참여자 한 명을 선택한다.
2. 앱이 해당 계정·프로젝트·관리자 키에 묶인 32바이트 난수 비밀을 포함하는 코드를 만든다.
3. 코드는 15분 동안 유효하다. 소유자는 선택한 사람에게 개인 메시지 등 별도 경로로 전달한다.
4. 참여자는 `연결 코드 입력`에서 코드를 등록한다. 로그인 GitHub ID와 코드의 대상 ID를 대조한다.
5. 참여자 앱이 자기 장치 공개키와 서명·페어링 증명을 GitHub에 게시한다. 비밀 자체는 게시하지 않는다.
6. 소유자가 참여자의 기기 확인 코드를 대조하고 승인한다. 승인·거절 후 요청과 로컬 코드를 정리한다.
7. 승인된 장치는 암호화된 웹훅 정보를 받아 Windows 자격 증명 보관소에 저장한다.

웹훅을 직접 붙여넣지 않고 새 참여자 기기를 연결할 수 있으나, 별도 코드 전달과 소유자의 승인은
필요하다. GitHub 파일명이나 commit author만 보고 새 키를 자동 승인하지 않는다.
최초 관리 PC 외의 새 PC는 같은 계정으로 로그인했더라도 별도 장치다.
관리자 서명 키를 잃은 경우 다른 PC가 자동으로 관리자 키를 대체하는 복구 기능은 제공하지 않는다.

현재 코드에서는 **발신 준비가 된 기기의 작업 저장**에 Discord 이벤트를 기록한다.
기기 연결 전·승인 전 저장한 변경은 뒤늦게 전체 알림으로 재생하지 않는다.

## 4. 채널과 멘션 선택

| 작업 대상 | 채널과 멘션 |
|---|---|
| 특정 담당자 | 담당자 ID를 멘션하고 담당자의 파트로 채널을 선택 |
| 파트 전체 | 해당 파트의 활성 참여자 중 등록된 ID를 멘션 |
| 파트와 담당자 동시 지정 | 명시적인 담당자 한 명을 우선 |
| ID 미등록 | 이름을 표시하고 그 사람의 멘션은 생략 |
| 전체 작업자 | 기본 채널에 게시하며 전체 서버 멘션은 생성하지 않음 |

- 활성 경로의 이벤트 종류와 받을 쪽 파트를 대조한다.
- 해당 파트의 특정 경로가 있으면 특정 경로를 선택하고 `모든 파트` 경로를 제외한다.
- 특정 경로가 없으면 `모든 파트` 경로를 사용한다.
- 여러 특정 경로가 일치하면 각 채널에 보낸다. 실제 channelId가 같은 경로는 한 번으로 합친다.
- 동일한 Discord 사용자 ID도 한 메시지에 한 번만 포함한다.
- `allowed_mentions`는 `parse: []`와 명시적인 `users` 목록만 사용한다. `@everyone`, 역할 멘션을 활성화하지 않는다.
- 발신 직전에도 현재 활성 참여자와 등록 ID, 서명된 설정과 실제 웹훅 채널을 다시 확인한다.

## 5. 코드와 저장 위치

| 코드 | 책임 |
|---|---|
| `flutter_app/lib/discord_settings.dart` | 채널·ID·기기 승인·전송 기록 UI, 한국어/영어 표시 |
| `flutter_app/lib/discord_service.dart` | 프로젝트 수명, 설정 조회·등록, 본인 ID 변경, 승인·전송 연결 |
| `flutter_app/lib/discord_models.dart` | scope·경로·장치 인증서·암호화 envelope·페어링 요청의 엄격한 스키마 |
| `flutter_app/lib/discord_configuration.dart` | GitHub 설정 CAS 저장, 초기 신뢰, 코드 교환, 관리자 승인·취소 |
| `flutter_app/lib/discord_crypto.dart` | Ed25519 서명, X25519·HKDF·AES-GCM 암호화와 페어링 증명 |
| `flutter_app/lib/discord_credentials.dart` | 기기 키·관리자 신뢰 키·버전 상한·웹훅의 계정/프로젝트별 보관 |
| `flutter_app/lib/discord_vault.dart` | GitHub OAuth와 별도인 Windows 자격 증명 저장 채널 |
| `flutter_app/lib/discord_transport.dart` | Discord 전용 HTTPS GET/POST, 호스트·응답·멘션 검증 |
| `flutter_app/lib/discord_outbox.dart` | SQLite 이벤트·전송 기록, 본인 통합 영수증 연결·재전송·보존 |
| `flutter_app/lib/store.dart`, `flutter_app/lib/github_sync.dart` | 작업 변경 트랜잭션과 본인 proposal 통합 후 알림 활성화 |

현재 프로젝트의 GitHub 통합 브랜치에는 다음 파일을 저장한다.

```text
.ieum/project.json                         # 참여자별 discordUserId
.ieum/notifications/routes.json            # 서명된 경로·승인 장치·관리자 공개키
.ieum/notifications/requests/<gh-id>/<pairing-id>.json
.ieum/notifications/envelopes/<device-id>/<route-id>-<config-revision>.json
```

scope는 저장소·projectId·통합 브랜치 조합이다. 설정은 현재 scope·소유자·스키마·필드를 검증한다.
GitHub에는 공개 정보·공개키·증명·암호문을 저장한다. 웹훅 URL과 개인키·페어링 비밀은
일반 프로젝트 JSON·PR 설명·SQLite metadata에 저장하지 않는다. 동시 변경은 SHA를 대조하며
무조건 덮어쓰지 않는다. 알림 파일은 기존 작업 proposal 경로와 분리한다.

기기마다 별도 암호화 키와 서명 키를 사용한다. 관리자 서명과 scope·채널·secretVersion·기기·
configRevision·revocationEpoch를 대조하며, 저장한 신뢰 버전보다 오래된 설정은 거절한다.
Windows의 `ieum/discord_vault`와 `ieum/discord_http` 채널은 GitHub 로그인 통신·자격 증명과 분리한다.
이번 구현의 네이티브 보관 경로는 Windows 기준이며 Linux의 실제 보관·실행을 검증한 것으로 표현하지 않는다.

## 6. 발신 상태와 중복 방지

```text
waitingIntegration → ready → sending → delivered
                        ↑       ├→ retry_wait → ready
                        │       ├→ failed / blocked → 사용자 다시 전송
                        │       └→ uncertain → 사용자 확인 후 다시 전송
                        └──────────── 사용자 다시 전송
```

작업 변경 트랜잭션에서 `discord_events`에 후보를 기록한다. 새 작업은 배정,
담당자 변경·검토 전달은 전달, 완료 처리는 완료 종류로 분류한다.
해당 후보를 정확한 자신의 proposal revision·작업 내용과 연결한 뒤 `merged` 영수증을 확인해야
`discord_deliveries`를 만든다. PR 제출의 `sent` 상태만으로 발신하지 않는다.
이전 저장이 다음 저장으로 대체된 후보는 취소하며, 다른 사람의 수신 변경으로 후보를 만들지 않는다.

원본 deviceId와 scope를 검사하고 이벤트/실제 채널의 유일 ID, SQLite 조건부 claim으로
일반적인 중복 실행을 막는다. 전송 직전 경로가 삭제·중지·교체되었으면 차단 상태로 남긴다.
사용자가 다시 전송할 때에도 기존 서버·채널을 검사하며 다른 채널로 조용히 바꾸지 않는다.

- Discord POST에는 `wait=true`를 사용한다. 정상 messageId를 받은 뒤 전송 완료로 기록한다.
- 429 응답은 Retry-After를 따르며 자동 재시도 횟수는 최대 5회다.
- 전송 전 GET 연결 점검 실패도 제한된 재시도 후 실패로 남긴다.
- POST 시간 초과·응답 유실·5xx·불명확한 성공 응답은 `uncertain`으로 남기고 자동 재전송하지 않는다.
- 앱이 전송 중 종료된 기록도 다음 실행에서 `uncertain`으로 복구한다.
- 401/403/404, redirect 등의 오류는 토큰 없는 안내로 보여 주고 연결을 점검한다.
- 수동 재전송은 같은 메시지가 이미 Discord에 있을 수 있다는 확인을 거친다.

웹훅 실행에는 nonce를 통한 중복 제거 기능이 없으므로 정확히 한 번 전달을 보장하지 않는다.
실제 멘션 푸시 여부는 Discord 참여자·채널 알림 설정에도 달려 있다.

## 7. 보존·연결 해제

대기 이벤트는 프로젝트별 최대 1,000건이다. 한도에 도달하면 작업 저장은 유지하고
알림을 추가하지 못했다는 안내를 남긴다. 전송 기록 화면은 최신 20건을 표시한다.
완료·취소 이벤트의 작업 snapshot은 30일 이후 제거하며 완료·취소 기록은 180일 이후 정리한다.
이벤트·전송 테이블마다 완료·취소 기록은 최신 2,000건으로 제한한다.
미완료·실패·수신 미확정 기록은 이 정리 대상에 포함하지 않는다.
기록을 정리한 뒤 과거 PR을 다시 받아도 알림 후보를 새로 만들지 않는다.

암호화 경로 파일도 무한히 늘리지 않는다. 현재 활성 기기×채널 조합은 최대 250개,
envelope 파일 목록은 최대 2,000개이며, 이전 revision을 소량씩 정리한다.
Git 커밋 이력에 남은 이전 암호문까지 삭제하는 기능은 제공하지 않는다.

기기에 제공한 웹훅 토큰은 해당 기기에서 사용 가능하므로 앱 승인만 취소해 물리적으로 회수할 수 없다.
기기 연결 해제는 **일시 중지한 경로도 포함해 모든 채널의 기존 웹훅 삭제와 새 웹훅 등록**을 요구한다.
앱은 새 주소가 같은 서버·채널인지 조회하고, 관리자 기기에 보관된 이전 주소가 404로 폐기되었는지
확인한 뒤 장치를 취소하고 남은 승인 장치에 새 암호문을 배포한다.
참여자를 제외한 경우에도 Discord에서 기존 웹훅을 폐기해야 이미 공유한 주소를 차단할 수 있다.
이음의 `채널 연결 해제`는 Discord 채널·메시지·웹훅 자체를 삭제하지 않는다.

## 8. 검증 경계

### 상태 변경 알림 보완

일반 `task.moved`/단계 이동 이벤트가 배정·전달·완료 분류에 들지 않아 알림 후보를 만들지 않았던 문제를 수정했다. 상태 변경을 독립 알림으로 추가하고 변경 전후 상태를 메시지에 담는다. 완료 이동은 완료 알림 한 건으로 처리하며 일반 본문 수정·댓글은 상태 변경 알림을 만들지 않는다.

기존 서명된 경로는 JSON과 서명을 그대로 보존한다. 기존 전달 알림이 켜진 경로에는 상태 변경도 포함하며, 새 채널 설정은 `notificationVersion: 2`로 상태 변경의 선택 여부를 별도 저장한다. 일시 중지나 기기 해제에서도 기존 설정 버전을 보존한다.

이번 보완의 정적 분석에 이상이 없고, 전송 큐·설정 호환·UI·여섯 단계 이동·GitHub 동기화 관련 회귀 테스트 **53개가 통과**했다. 실제 프로젝트의 Discord 메시지는 테스트로 발신하지 않았다.

검증은 변경 코드의 정적 분석과 임시 DB·가짜 transport를 사용하는 로컬 테스트로 제한한다.
본인 ID 수정 범위, 페어링 대상·서명·scope·버전, 기기별 복호화와 토큰 비노출,
본인 통합 이후만 발신, 채널/멘션 중복 제거, 재실행 복구와 수신 미확정 재전송 확인을 검토한다.
2026-10-10 최종 검증 결과:

- `flutter analyze`: 오류·경고·스타일 지적 없음.
- Discord 전송·자격 증명·프로세스 잠금·설정 UI·보안 구성·전송 큐·본인 ID와 기존 GitHub 동기화·프로젝트·알림함·설정 배치 관련 테스트 **75개 통과**.
- Windows Release 빌드 완료. 설치된 Visual Studio 2026 도구는 Flutter의 자동 탐지에서 거부되어 기존 `build-windows.ps1`의 CMake 경로로 구성·빌드하고, 최종 수정 후 `cmake --build build/windows/x64 --config Release --target INSTALL --parallel 4`로 다시 빌드했다.
- 실행 파일: `flutter_app/build/windows/x64/runner/Release/ieum_flutter.exe`. Dart와 네이티브 코드를 컴파일했으며 앱 실행·실제 Discord 메시지 전송은 수행하지 않았다.

실제 Discord 게시, Discord의 멘션 푸시, 두 PC의 승인·통합·알림 전송,
사용자가 운영 중인 저장소·채널·프로젝트의 화면 조작은 사용자가 확인한다.
테스트를 위해 실제 프로젝트에 샘플 작업·채널·PR·메시지를 만들지 않는다.
설정 등록 시 메시지가 전송되었다는 주장을 하지 않는다.

## 공식 참고

- [Discord Webhook API](https://docs.discord.com/developers/resources/webhook)
- [Discord Allowed Mentions](https://docs.discord.com/developers/resources/message#allowed-mentions-object)
- [Discord 사용자 ID 복사](https://support.discord.com/hc/en-us/articles/206346498-Where-can-I-find-my-User-Server-Message-ID)
- [Windows Credential Manager](https://learn.microsoft.com/en-us/windows/win32/api/wincred/)
- [HKDF](https://www.rfc-editor.org/rfc/rfc5869), [X25519](https://www.rfc-editor.org/rfc/rfc7748)
