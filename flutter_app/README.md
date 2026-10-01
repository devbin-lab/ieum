# 이음 · Flutter 데스크톱 비교 버전

Flutter 3.47.5 / Dart 3.13.4로 만든 Windows 프로토타입입니다. Electron 기준본과 같은 예시 작업 및 상태 흐름을 사용하며 브랜치는 `codex/flutter-desktop`입니다. 기존 Electron 구현도 이 브랜치에 포함되어 있어 나란히 실행할 수 있습니다. Electron만 보존한 기준 브랜치는 `codex/electron-prototype`입니다.

## 실행

저장소 루트의 `Start-Ieum-Flutter.bat`을 실행하거나 `build/windows/x64/runner/Release/ieum_flutter.exe`를 실행하세요. Release 폴더 전체가 실행 패키지입니다. exe 옆의 DLL과 data 폴더를 함께 유지해야 합니다. 빌드된 앱을 실행하는 팀원 PC에는 Flutter SDK나 Node.js가 필요하지 않습니다. Windows의 Microsoft Visual C++ 런타임은 필요합니다.

현재 PC에는 Release 빌드가 준비되어 있습니다. 개발용 빌드 폴더는 Git에 포함되지 않습니다. 소스만 복제한 경우 아래 절차로 빌드하세요.

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

현재 PC처럼 Visual Studio의 게임용 C++ 도구가 설치되어 있고 CMake가 별도로 있는 경우, `build-windows.ps1`은 일반 Flutter 빌드를 먼저 시도한 뒤 기존 MSVC와 CMake로 표준 Windows runner를 빌드합니다. Flutter SDK나 Visual Studio 설치 구성을 변경하지 않습니다. SDK가 PATH에 없으면 `%USERPROFILE%\develop\flutter`를 확인합니다.

## 동작

- 칸반 5단계와 드래그 이동: 할 일 / 진행 중 / 검토 / 재작업 / 완료.
- 작업 등록·수정, 파트별 기본 담당자·검토자 배정, 우선순위 높음·보통·낮음.
- 일정표: 작업내용, 상태, 원 작업자, 현재 처리자, 지정일, 마감일, 완료일.
- 검색·파트 필터·내 할 일·내 검토 요청.
- 검토 요청 시 현재 처리자를 검토자로 전환; 재작업은 사유 입력 후 원 작업자로 전환; 완료 승인 시 완료일 기록.
- SQLite 저장, 활동 기록, Discord 알림 이벤트 미리보기.
- 공통 JSON 변경안 내보내기, 통합본 가져오기, 3-way 병합·충돌 감지.

프로젝트 구성과 사용자 선택은 예시 데이터용입니다. 테스트 사용자 선택은 실제 계정 인증이 아닙니다. GitHub 자동 커밋·PR과 Discord 전송, 후속 제작 파트의 작업 자동 생성은 연결 전입니다. Discord 이벤트는 SQLite outbox에 미리보기 상태로 보관합니다.

## 파일과 저장 위치

| 파일 | 역할 |
| --- | --- |
| lib/models.dart | 작업 형식, 유효성 검증, 배정 규칙 |
| lib/store.dart | SQLite, 전환 권한, 기준본 비교, 충돌 감지 |
| lib/app.dart | 칸반·일정·변경·연결 화면 |
| lib/task_editor.dart | 작업 등록·수정 및 재작업 사유 입력 |
| lib/main.dart | 앱 시작 및 개인 DB 열기 |

DB 기본 위치는 `%APPDATA%\Ieum-Flutter-Prototype\ieum.sqlite`입니다. Electron의 `%APPDATA%\Ieum-Prototype`과 분리되어 있습니다. 테스트 실행의 저장 위치는 `IEUM_FLUTTER_DATA_DIR`로 바꿀 수 있습니다. DB 파일은 커밋하지 않습니다.

통합에 쓰는 JSON 형식은 Electron과 같습니다. `schemaVersion: 1`, `projectId: ieum-demo`가 공통이며 변경안은 `baseRevision/authorId/changes`, 통합본은 `revision/tasks`를 포함합니다. 동일 항목 충돌과 날짜·상태 관계가 맞지 않는 통합은 전체 반영을 멈춥니다. 삭제 병합은 현재 지원하지 않습니다. 전체 예시 통합본은 `assets/demo-snapshot.json`입니다. SQLite 파일 내부 테이블 구성은 두 버전이 다르므로 JSON으로 데이터를 교환하세요.

## 검증 범위

정적 분석, SQLite 저장·재열기, 역할/전환 규칙, 입력 검증, 버전 충돌, JSON 병합, 칸반 드래그, 작업 등록·자동 배정·검토·재작업·승인을 자동 테스트합니다. 1480×940과 1160×740 화면 크기도 화면 조작 없이 테스트 엔진에서 확인합니다.

사용자 요청에 따라 실제 데스크톱 화면을 조작하거나 창을 띄우는 테스트는 진행하지 않았습니다. 따라서 Windows 파일 선택 대화상자와 실제 그래픽 드라이버의 실행 동작은 아직 사용자 PC에서 대화형으로 확인하지 않았습니다.

Release 폴더는 첫 빌드 기준 약 29MB입니다. 이전 Electron 런타임 폴더는 약 367MB였습니다. 두 수치는 압축 전 파일 크기이며 Flutter 개발 SDK·빌드 캐시를 제외합니다. 실행 중 메모리나 CPU 절약률은 Flutter 앱을 실제 실행하여 같은 조건에서 측정하기 전까지 확정하지 않습니다.

현재 DB 처리는 작은 프로토타입 데이터에 맞춰 동기적으로 구현했습니다. 작업 수가 커지면 DB 접근과 JSON 병합을 별도 isolate에서 처리하도록 확장할 계획입니다.
