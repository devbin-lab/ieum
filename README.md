# 이음 · IEUM

현재 개발 대상은 Flutter Windows 앱입니다. GitHub 로그인, 빈 프로젝트 생성·참여, 개인 DB 폴더 선택, 가입 승인과 역할 지정, 작업별 자동 커밋·PR·통합본 가져오기를 제공합니다. 실행은 `Start-Ieum-Flutter.bat`, 사용 안내는 [flutter_app](flutter_app/README.md)을 참고하세요. 테스트 데이터 저장소는 [ieum-test-fresh](https://github.com/devbin-lab/ieum-test-fresh)입니다.

Electron 기준본은 `codex/electron-prototype`, Flutter 작업은 `codex/flutter-desktop`에 분리했습니다. 아래 내용은 기존 Electron 예시 버전에 대한 안내입니다.

팀의 작업과 일정을 연결하는 Electron 데스크톱 프로토타입입니다.
React + TypeScript로 화면을 구성하고 Electron 메인 프로세스에서 개인 SQLite를 관리합니다. 공유 서버 없이 각자 수정한 데이터를 JSON 변경안으로 내보내고, 승인된 통합본을 다시 가져오는 구조입니다.

## 실행

Node.js 24 이상이 설치된 Windows에서 `Start-Ieum.bat`을 실행하세요. 첫 실행에는 의존성과 Electron 런타임을 내려받습니다. 현재 버전은 개발용 실행이며 설치형 exe 배포본은 아직 만들지 않았습니다.

```powershell
npm ci
npm start
```

## 지금 사용할 수 있는 기능

- 할 일 → 진행 중 → 검토 → 완료, 또는 검토 → 재작업 → 진행 중.
- 칸반 카드 클릭과 드래그 이동. 재작업은 사유를 입력한 뒤 요청합니다.
- 작업 등록·수정, 파트별 기본 담당자/검토자 배정, 우선순위 높음/보통/낮음.
- 일정표: 작업내용, 담당자, 현재 처리자, 작업 지정일, 마감일, 완료일.
- 검색, 파트 필터, 내 할 일, 내 검토 요청.
- SQLite 자동 저장, 활동 기록, Discord 알림 이벤트 미리보기.
- 개인 변경안 JSON 내보내기, 통합본 JSON 가져오기, 항목별 3-way 병합과 충돌 감지.

첫 실행에는 예시 작업 8개가 들어 있습니다. 왼쪽 아래 **테스트 사용자**를 바꿔 작업자와 PD / PM을 체험할 수 있습니다. 실제 로그인·권한 인증 기능은 아닙니다. 검토 상태에서는 원래 작업자를 보존하면서 현재 처리자를 검토자로 표시합니다. 완료 승인 시 완료일을 자동 기록합니다.

## 데이터와 GitHub

개인 DB의 기본 위치는 `%APPDATA%\Ieum-Prototype\ieum.sqlite`입니다. 테스트 환경은 `IEUM_DATA_DIR`로 별도 지정할 수 있습니다. DB 파일과 빌드 산출물은 Git 추적에서 제외됩니다.

GitHub 인증, 자동 커밋·브랜치 생성·PR·main 가져오기는 아직 연결되지 않았습니다. 현재는 `내 변경내역`에서 파일로 내보내거나 가져옵니다. 내보낸 변경안과 가져오는 통합본은 서로 다른 형식입니다. 통합본 형식은 [구조 설계](docs/architecture.md)를 참고하세요.

Discord 토큰은 저장하지 않으며 외부 메시지도 보내지 않습니다. 실제 전송은 승인된 main 반영 이벤트를 기준으로 중복 없이 실행하는 방향입니다. 후속 파트의 새 작업 자동 생성은 배정 규칙만 설계되어 있고 현재 기능에는 포함되지 않습니다.

## 확인

```powershell
npm test             # SQLite, 상태 전환, 권한, 버전, 병합 검증
npm run build        # TypeScript 검사 + 화면 빌드
npm run test:desktop # 별도 임시 DB로 실제 Electron UI 검증
```
