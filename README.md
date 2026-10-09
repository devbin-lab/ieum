# 이음 · IEUM

**1.0.0 · GitHub 기반 팀 작업 공간**

이음은 팀의 작업, 일정, 자료와 변경 기록을 한곳에서 관리하는 데스크톱 앱입니다. GitHub 저장소를 팀 데이터의 기준으로 사용하고, 각자의 컴퓨터에는 SQLite로 작업을 저장합니다. 작업을 등록하고 다음 담당자에게 전달하며, 필요한 작업만 잠가 편집 범위를 지정할 수 있습니다.

[Windows 1.0.0 다운로드](https://github.com/devbin-lab/ieum/releases/tag/v1.0.0) · [사용 안내](https://github.com/devbin-lab/ieum/blob/v1.0.0/flutter_app/README.md) · [이전 Beta 배포 기록](https://github.com/devbin-lab/ieum/releases/tag/beta)

## 주요 기능

| 기능 | 내용 |
| --- | --- |
| 작업 | 목록·칸반 보기, 검색과 필터, 우선순위, 상단 고정, 보관·복원·삭제 |
| 담당자 전달 | 받을 파트·작업자와 목적을 지정하고 최종 확인 후 전달 |
| 작업 잠금 | 작성자 또는 지정한 작업자만 수정하도록 설정하고 다음 담당자에게 잠금 이전 |
| 일정 | 작업 지정일부터 마감일까지 연속된 기간으로 표시, 상태별 색상 적용 |
| 알림·타임라인 | 담당 작업 알림, 작업 상세로 이동, 프로젝트 전체 변경 기록 확인 |
| 작업 자료 | 파일·HTTPS 링크 첨부, Markdown 미리보기, 프로젝트별 파일 용량 한도 |
| 참여자·파트 | 가입 승인, 사용자 지정 파트 추가·수정·삭제와 참여자 배정 |
| 팀 바로가기 | 팀 도구 링크 공유, 사이트 아이콘 탐색, 검색과 개인 즐겨찾기 |
| 디자인·언어 | 라이트·다크 모드, 포인트 컬러, 한국어·영어 |
| Discord 알림 | 채널별 웹훅 연결, 배정·전달·상태 변경·완료 알림과 담당자 멘션 |
| GitHub 동기화 | 작업별 변경 제출·PR·검증·통합, 충돌 확인과 전송 복구 기록 |

## 시작하기

Windows 배포 파일은 릴리즈 목록에서 관리합니다. EXE 배포본은 `Ieum-Windows-x64.exe` 하나를 실행하고, ZIP 배포본은 전체를 압축 해제한 뒤 `ieum_flutter.exe`를 실행합니다. 배포본 실행에는 Git이나 Flutter SDK가 필요하지 않습니다.

1. **GitHub로 로그인**을 선택하고 브라우저에서 인증 코드를 승인합니다.
2. 프로젝트 관리자는 GitHub 저장소를 지정해 **프로젝트 생성**을 진행합니다.
3. 팀원은 해당 저장소의 협업자 초대를 수락한 뒤 **프로젝트 참여**를 요청합니다.
4. 관리자가 참여 요청을 승인하고 필요한 파트를 만들어 배정합니다.
5. **작업**에서 새 작업을 등록하고, **일정**에서 작업 기간을 확인합니다.

새 프로젝트는 작업과 파트 목록이 비어 있는 상태로 시작합니다. 프로젝트 소유자에게도 파트를 배정할 수 있습니다.

## 작업 흐름

칸반은 **확인중 · 진행중 · 검토중 · 완료 · 보류 · 드랍**의 여섯 상태를 사용합니다. 확인중은 담당자가 아직 시작하지 않은 작업, 진행중은 작성·수정 단계, 검토중은 전달받은 내용을 확인하는 단계입니다. 보류와 드랍에는 사유를 남기며, 드랍 작업은 일정에서 제외됩니다.

진행중·검토중에서 다음 담당자에게 전달하면 작업은 **확인중**으로 돌아갑니다. 전달받은 작업을 시작하면 목적에 따라 진행중 또는 검토중으로 이동합니다. 의견과 수정 요청은 코멘트로 남깁니다.

잠금 없는 확인중·진행중·검토중 작업은 활성 참여자가 함께 수정할 수 있습니다. **작업 잠금**을 사용하면 지정한 한 사람만 수정할 수 있고, 다른 참여자는 열람하고 코멘트를 남길 수 있습니다. **잠근 채 전달**하면 다음 담당자에게 잠금도 함께 이전됩니다. 완료·보류·드랍 상태에서는 내용을 직접 수정하지 않습니다.

## 자료와 팀 도구

작업에 파일과 HTTPS 링크를 첨부할 수 있습니다. 파일당 기본 한도는 **50MB**이며, 관리자는 프로젝트 설정에서 **1~50MB**로 조절할 수 있습니다. Markdown 파일은 앱에서 미리보기하고, 다른 파일은 내려받습니다.

**바로가기**에는 Google Drive, Notion, Jira, Discord, 카카오톡, GitHub, Figma, Slack의 추천 목록과 직접 링크 등록 기능이 있습니다. 등록한 링크는 팀과 공유하며 기본 브라우저에서 엽니다. Discord 채널 알림은 **프로젝트 설정 → 알림**에서 별도로 연결합니다.

## Discord 채널 알림

Windows 1.0.0에 포함된 기능입니다. 별도 서버나 공용 봇 없이 Discord 웹훅을 사용합니다.

프로젝트 소유자가 Discord 채널의 웹훅을 등록하고, 받을 알림 종류와 담당 파트를 선택합니다. 참여자는 본인의 숫자 Discord 사용자 ID를 등록해 멘션을 받을 수 있습니다.

작업을 변경한 기기가 **자신의 변경이 GitHub에 반영된 뒤** 알림을 보냅니다. 다른 참여자의 동기화 수신은 같은 알림을 다시 보내지 않습니다. 다른 PC에서도 알림을 보내려면 소유자의 연결 코드와 기기 승인을 거칩니다.

웹훅과 기기 키는 Windows 자격 증명 보관소에 저장하고, 승인 기기에는 암호화해 전달합니다. 앱이 종료된 동안에는 발신하지 않으며, 원본 기기에서 프로젝트를 다시 열면 대기 전송을 이어갑니다. 자세한 설정은 [Discord 채널 알림 안내](https://github.com/devbin-lab/ieum/blob/v1.0.0/docs/discord-webhook-design.md)를 참고하세요.

## 저장과 동기화

작업은 먼저 개인 SQLite에 저장합니다. 팀 반영은 GitHub의 변경 제출·검증·통합을 거쳐 이루어지므로 **로컬 저장**과 **팀 동기화 완료**는 서로 다른 상태입니다. 대기·오류·충돌과 복구 기록은 **연결**에서 확인할 수 있습니다.

동기화와 Discord 발신은 앱이 실행 중일 때 동작합니다. GitHub 저장소 접근 권한과 이음의 참여 승인·파트 배정은 별도로 관리합니다. 기존 로컬 데이터와 로그인 정보는 배포 파일에 포함하지 않습니다.

## 소스에서 빌드하기

현재 앱 소스는 **`codex/flutter-desktop` 브랜치**의 `flutter_app/`에 있습니다. Windows 빌드에는 Git, Flutter SDK, MSVC C++ 도구와 CMake가 필요합니다.

```powershell
git clone --branch codex/flutter-desktop https://github.com/devbin-lab/ieum.git
cd ieum/flutter_app
flutter pub get
flutter analyze
.\build-windows.ps1
```

빌드 후 저장소 루트의 `Start-Ieum-Flutter.bat`을 실행하거나 `flutter_app/build/windows/x64/runner/Release/ieum_flutter.exe`를 실행합니다.

배포 파일을 만들려면 `flutter_app/`에서 다음 명령을 실행합니다.

```powershell
.\package-windows.ps1
```

EXE·ZIP·사용 안내·체크섬은 `dist/windows/<빌드 시각>/`에 생성됩니다. 패키징 스크립트는 버전 일치와 필수 파일을 검사하며 GitHub 릴리즈를 게시하지 않습니다.

## 문서와 소스 구성

- [앱 사용·개발 안내](https://github.com/devbin-lab/ieum/blob/v1.0.0/flutter_app/README.md)
- [Discord 채널 알림 설계](https://github.com/devbin-lab/ieum/blob/v1.0.0/docs/discord-webhook-design.md)
- [코드 정리와 검증 내역](https://github.com/devbin-lab/ieum/blob/v1.0.0/docs/maintenance-cleanup.md)
- [일정·작업 잠금 설계](https://github.com/devbin-lab/ieum/blob/v1.0.0/flutter_app/docs/task-lock-and-schedule-plan.md)
- [Linux 실행 안내](https://github.com/devbin-lab/ieum/blob/v1.0.0/flutter_app/linux/README-Linux.md)

Windows가 현재 개발·배포 기준 플랫폼입니다. Linux 실행 환경과 지원 범위는 별도 안내를 확인하세요. Discord 웹훅의 네이티브 자격증명·전송 기능은 Windows용입니다.

루트의 `electron/`, `src/`, `package.json`은 초기 Electron 프로토타입의 보관용 소스입니다. 현재 앱의 버전은 `flutter_app/pubspec.yaml`과 `flutter_app/lib/app_release.dart`를 기준으로 합니다. 서비스 아이콘과 앱 아이콘의 출처·라이선스 고지는 `flutter_app/third_party/`에 보관합니다.
