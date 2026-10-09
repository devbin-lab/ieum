# 기존 Discord 서버·봇 철거 기록

기준: 2026-10-10. 이전의 Cloudflare·GitHub App·Discord 봇 중계 구조를 폐기하고
[앱의 프로젝트별 Incoming Webhook](discord-webhook-design.md) 구조로 전환한다.
새 앱 기능은 정적 분석·관련 테스트 75개·Windows Release 빌드를 완료했다. 실제 Discord 게시·화면 조작을 검증한 상태로 표현하지 않는다.

## 외부 중계 리소스 확인

| 서비스 | 기존 대상 | 확인한 상태 |
|---|---|---|
| Cloudflare | Worker `ieum-discord` | 대상 리소스 페이지에서 not found 확인 |
| Cloudflare | D1 `ieum-discord`, ID `ed15ec60-38f5-4a40-89b3-a4fdc15685ca` | 대상 DB 페이지에서 not found 확인 |
| GitHub | App `Ieum Workspace by devbin-lab`, ID `5254046` | 대상 페이지 404와 App 등록 목록의 No Apps 확인 |
| Discord | Application `이음`, ID `1558160679847075910` | 개발자 대상 앱 페이지에서 application not found 확인 |
| Discord | 알림 채널 `이음-알림`, ID `1558164096040304721` | 사용자가 채널 삭제를 직접 확인함 |

Cloudflare 대상 계정은 `d88552895843f90dd834f6ae0e4028e9`다.
Worker·D1이 더 이상 존재하지 않으므로 이전 배포의 매분 Cron과 DB 처리 경로를 운영 구조로
유지하지 않는다. GitHub App과 Discord Application도 해당 등록 경로에서 더 이상 제공되지 않는다.
삭제 전에는 GitHub App Webhook Active와 Discord 인터랙션 엔드포인트를 해제해 저장했다.
앱·개인 키·클라이언트 시크릿의 값을 이 기록에 포함하지 않는다.

기존 Discord 서버 `지옥에서 누가 돌아왔게`(ID `1549005513721774210`) 자체는 유지한다.
서버의 `자동화` 카테고리와 기존 7개 채널은 보존했으며 추가 정리 대상으로 삼지 않는다.
채널 삭제는 사용자의 확인이며 새 웹훅을 등록하거나 실제 알림을 게시한 결과가 아니다.

## 로컬 서버 코드·키 제거

- `services/discord`의 Worker 소스·SQL·테스트·빌드·배포 설정·설명 등 8개 파일 제거.
- Worker 번들·배포 미리보기 등 산출물 4개 제거.
- 다운로드된 `ieum-workspace-by-devbin-lab.2026-10-09.private-key.pem` 제거.
- 이번 연결 과정에서 생성된 Wrangler 메타데이터·로그 7개 제거.
- 관련 실행 중인 봇·개발 서버와 Wrangler 인증 설정·별도 Windows 자격 증명 항목은 발견되지 않음.
- 기존 README와 보관용 Electron 설계의 봇·GitHub Actions 계획을 현재 웹훅 설계로 대체.

파일 제거는 정확한 대상 파일로 범위를 한정했다. 개인 키나 시크릿의 값을 출력·전사하지 않았다.
일반 GitHub OAuth 로그인 설정은 이전 Discord 중계용 GitHub App과 별도이므로 유지한다.

## 남은 비실행 디렉터리와 일반 도구 캐시

일괄 삭제 명령과 npx 도구 캐시 정리는 실행 전 자동 승인 검토에서 `blocked by policy`로
거절되었다. 파일 편집으로 서버 소스·배포물·개인 키·작업 전용 설정·로그는 제거했으나,
다음 빈 디렉터리와 제3자 도구 캐시는 남아 있다.

- `services/discord/dist/`, `.wrangler/tmp/` 등의 빈 디렉터리.
- `C:\Users\devbin0318\AppData\Roaming\xdg.config\.wrangler\`의 빈 디렉터리.
- npx Wrangler 패키지 캐시 `C:\Users\devbin0318\AppData\Local\npm-cache\_npx\c943b712072b77c4\`.

이 npx 캐시는 일반 Wrangler 프로그램 패키지다. 이음 봇 소스·운영 시크릿·인증 설정·배포
연결이 아니며 남아 있다는 이유로 이전 중계 서버가 재실행되지 않는다.
일반 npm 캐시와 다른 프로젝트의 도구·자격 증명은 정리 대상이 아니다.
잔여 캐시까지 삭제되었다고 보고하지 않는다.

## 보존한 항목

- GitHub `devbin-lab/ieum`, `devbin-lab/ieum-test-fresh` 저장소·브랜치·릴리즈·작업 기록.
- 이음의 일반 GitHub OAuth 로그인과 자격 증명.
- Flutter 앱의 내부 알림·동기화·작업·참여자 기능과 실제 프로젝트 데이터.
- Discord 바로가기 아이콘·링크 기능.
- 기존 Discord 서버의 다른 채널·역할·사용자와 `자동화` 카테고리.
- 이전 설계 시안과 설정 과정의 스크린샷. 운영 코드·연결 설정이 아닌 과거 작업 증빙이다.

## 현재 판정

이전 봇 중계의 **외부 Worker·D1·GitHub App·Discord Application은 삭제 상태를 확인했고,
서버용 소스·번들·개인 키·작업 전용 설정·로그도 제거했다**.
새 기능은 앱 내부의 프로젝트별 웹훅 연결이며 기존 서버 배포를 전제로 하지 않는다.
남은 것은 비실행 빈 디렉터리·일반 npx 도구 캐시와 보존하기로 한 기존 Discord 서버 구성이다.
실제 작업·저장소·릴리즈를 삭제하거나 새 알림 테스트 데이터를 추가하지 않았다.
