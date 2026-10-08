# GitHub 인증 연결 보완 · 0.8.0

기존 OAuth 통신은 DNS, 인증서, 시간 초과와 JSON 응답 오류를 모두 인터넷 연결 실패로 표시했다. 프록시가 필요한 Windows 환경에서도 Dart의 직접 연결을 사용해 브라우저 접속과 앱 접속의 결과가 달라질 수 있었다.

Windows의 OAuth와 GitHub JSON API는 이제 WinHTTP 네이티브 채널을 사용한다. 시스템 및 사용자 프록시, 자동 프록시와 Windows 인증서 검증을 적용한다. TLS 1.2 이상을 사용하며 인증서 검증을 우회하지 않는다. Linux의 Dart 통신은 환경 변수 프록시 설정을 사용한다. 업데이트 파일의 스트리밍 다운로드 경로는 이번 변경 범위에 포함하지 않는다.

네트워크 I/O는 최대 8개의 작업자에서 실행하고 플랫폼 응답은 UI 스레드에서 전달한다. 각 네트워크 단계에 시간 제한을 적용한다. 응답 본문은 OAuth 64 KiB, API 32 MiB까지 허용하고 닫힌 창에 결과를 보내지 않는다. OAuth 주소는 GitHub의 두 인증 엔드포인트, API 주소는 api.github.com의 HTTPS 443으로 제한한다. 리디렉션과 쿠키를 사용하지 않으며 서버 응답·토큰·인증 코드를 오류 문구에 넣지 않는다.

DNS, 연결 차단, 인증서, 프록시, 시간 초과와 비정상 응답을 구분해 표시한다. Windows 오류 번호와 HTTP 상태를 표시하므로 다른 컴퓨터에서도 원인을 좁힐 수 있다. 해당 컴퓨터의 실제 실패 원인을 확인한 것은 아니며, 관리자에 의한 접속 차단까지 자동으로 해제하는 기능은 아니다.

검증은 통신 경계·응답 제한·오류 구분·기밀 미노출 테스트, 기존 OAuth 및 API 회귀 검사, 정적 분석과 Windows Release 빌드를 사용한다. 네이티브 Release 검사는 공개 GitHub API 읽기와 무효 진단 Client ID 요청만 사용하며 실제 로그인 코드나 작업 데이터를 생성하지 않는다. 작업 저장 회귀 검사는 삭제되는 임시 SQLite에 한정한다.

참고: [WinHttpOpen의 시스템·사용자 프록시 처리](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpopen), [Windows 네트워크 오류 번호](https://learn.microsoft.com/en-us/windows/win32/winhttp/error-messages).
