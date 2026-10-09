# Flutter 유지보수 정리

현재 배포 대상인 `flutter_app`의 `main.dart`부터 import/export/part 연결과 실제 화면·서비스 호출을 확인했다. 기존 작업 데이터, 사용자 설정 파일, 자격증명 및 원격 저장소는 직접 변경하지 않았다. 버전은 기존 1.0.0을 유지한다.

## 제거한 코드

현재 실행 경로에서 사용하지 않는 화면·편집기 13파일, 총 5,102줄을 제거했다.

- `parts_panel.dart`, `task_recovery_dialog.dart`
- `workflow_automation.dart`, `workflow_automation_panel.dart`, `workflow_automation_tree.dart`
- `workflow_definition_editor.dart`, `workflow_panel.dart`, `workflow_stage_order.dart`
- `workflow_sheet_canvas.dart`, `workflow_sheet_handoff.dart`, `workflow_sheet_menu.dart`, `workflow_sheet_settings.dart`, `workflow_sheet_style.dart`

동일하게 호출되지 않는 다음 항목도 제거했다.

- `GitHubSession.saveRole`, `deleteRole`, `saveParts`
- `saveWorkflowStages`, `saveWorkflowSheet`, `saveWorkflowDefinition`, `applyDefaultWorkflow`, `saveWorkflowAutomation` 및 해당 기능 전용 검증·동시 저장 비교 코드
- `GitHubPublisher.workflowStageBlockers`, `TaskStore.workflowFlowLabel`
- `SettingsShell`의 미사용 워크플로 생성자 인자와 폐기 설정 enum, 사용되지 않는 화면 제목 함수 및 `permissionGroups`
- 중복 Discord ID 저장 모델 `DiscordPersonalProfile`, 미사용 `profilesPath`·`setPersonalDiscordId`·`loadProfiles`, 미사용 `DiscordCredentials.disconnect`

현재 파트 CRUD, 참여자 관리, 개인 Discord ID 등록 및 기기 해제 경로는 계속 사용한다. 삭제된 화면·API만 대상으로 하던 테스트는 정리하고, 혼합 테스트의 활성 기능과 과거 데이터 해석 검증은 유지했다. 옛 자동화 실행을 기대하던 검증은 현재 수동 전달·잠금 동작 또는 직렬화 호환 검증으로 구분했다.

## 호환성 유지

- 과거 `WorkflowStage`, `WorkflowSheet`, `WorkflowAutomation` 데이터 형식 및 모델 해석은 보존했다. 현재 수동 작업 시스템에서 사용하지 않는 옛 설정을 다시 실행시키지 않는다.
- 저장된 설정 이름 `assignments`는 현재 파트 설정으로, `workflow`는 프로젝트 일반 설정으로 복원한다. 옛 설정 화면 page 3은 현재 프로젝트 설정 page 2로 한 번 정규화해 저장한다.
- 테스트 전용 데모 JSON은 보존하지만 배포 자산에는 포함하지 않는다. 시작 시 사용하는 임시 메모리 저장소는 빈 작업 목록으로 생성된다.
- 문서상 보관용인 별도 Electron 프로토타입과 아이콘 생성 원본은 이번 Flutter 정리 대상에서 제외했다.

## 조회 최적화

- 프로젝트 메타데이터 문자열이 같으면 해석된 프로젝트 정보를 재사용한다. 문자열은 매번 SQLite에서 확인하므로 다른 연결의 수정·삭제, 트랜잭션 롤백, 잘못된 데이터도 감지한다.
- baseline 작업을 항목마다 두 번 JSON 해석하던 경로를 한 번으로 줄였다. 작업 본문의 ID와 엄격한 데이터 검증은 유지한다.
- Discord 이벤트·전송은 ID 직접 조회 및 상태·작업·revision 조건 조회로 바꿨다. 해당 조건의 SQLite 인덱스를 추가했고, 손상된 JSON이 있어도 인덱스 생성·정리가 실패하지 않도록 처리했다.
- 알림 설정의 기록 조회는 최신 200건으로 제한한다. 표시하지 않는 취소 기록은 제한 전에 제외하고, 표시할 전송의 이벤트만 ID로 조회한다. 대기 알림 전송 자체는 화면 기록 제한과 무관하다.
- 오래된 완료 기록의 작업 사본 축소는 JSON 전체를 Dart로 읽지 않고 SQL에서 처리한다. 기존 대기·보관 기간·건수 제한을 유지한다.
- 같은 Discord 처리 묶음에서 이미 검증한 설정을 재사용해 중복 GitHub 설정 조회를 줄였다. 멤버십, 소유자 키, 서명, revision·해제 상태 검증과 전송 전 최신 설정 확인은 유지한다.

사용하지 않는 소스 삭제는 유지보수 정리다. Flutter의 기존 tree shaking을 고려해 실행파일 크기나 프레임 속도 향상률은 별도로 주장하지 않는다.

## 검증

실제 앱 조작, Discord 메시지 전송 및 실제 프로젝트의 GitHub 변경은 이 검증에 포함하지 않는다. 테스트는 메모리 DB·임시 DB·가짜 GitHub API를 사용했다.

- 전체 `flutter analyze`: 문제 없음.
- Discord 보안·조회·설정·기기 잠금과 프로젝트 캐시 관련 9개 테스트 파일: 65개 통과. 알림 조회의 마지막 필터 수정 및 작업 단계 삭제 스캐너 제거 후 outbox·작업 삭제 테스트 23개도 통과했다.
- 설정 복원·파트·참여자·일정·워크스페이스·모델 호환 UI 회귀 9개 파일: 44개 통과. Discord 설정 테스트는 앞 항목과 중복된다.
- 캐시·과거 데이터 fixture·자동화 제거·GitHub revision 증명·현행 권한/전달 백엔드 집중 검사: 47개 통과. 프로젝트 캐시 테스트는 앞 항목과 중복된다. 구형 저장소 회귀 파일은 현재 6개 상태·코멘트·잠금 인계·알림 중복 방지 검증을 포함해 10개 모두 통과했다.
- 폐기 화면 제거 후 `main.dart`에서 남은 `lib` 73파일 모두 연결되며, 누락된 로컬 import는 없다. 운영 의존성은 모두 사용한다. 테스트용 데모 데이터는 배포 자산에서 제외된다.
- Windows Release: `cmake --build build/windows/x64 --config Release --target INSTALL --parallel 4` 성공. 결과는 `flutter_app/build/windows/x64/runner/Release/ieum_flutter.exe` 및 같은 디렉터리의 DLL·data 파일이다.
- `git diff --check`: 문제 없음.
