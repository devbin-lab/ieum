# 이음 Linux x64

Ubuntu 22.04 이상 x64 기준 빌드입니다. GTK 데스크톱 환경에서 실행합니다.

필요한 시스템 패키지 (Ubuntu):

```sh
sudo apt-get install libgtk-3-0 libsecret-1-0 libblkid1 liblzma5 xdg-utils gnome-keyring fonts-noto-cjk
```

`Ieum-Linux-x64.tar.gz`를 폴더에 압축 해제한 뒤 그 폴더의 `./ieum_flutter`를 실행하세요. `lib`와 `data` 폴더는 실행파일과 함께 유지해야 합니다.

GitHub 로그인은 기본 브라우저에서 Device Flow로 진행합니다. 로그인 유지는 Secret Service 키링에 저장합니다. 키링이 없거나 잠겨 있으면 키링을 준비하거나 로그인 유지 체크를 끄고 사용하세요. 인증 토큰을 일반 파일에 저장하지 않습니다.

프로젝트 선택은 계정 메뉴 → 프로젝트 설정 → 사이드바 최상단에서 합니다. 홈은 현재 프로젝트의 일정·작업 화면으로 돌아갑니다.

Linux 업데이트는 설정의 앱 정보에서 릴리즈를 열고 새 tar.gz를 받아 압축 해제합니다. Windows EXE 자동 업데이트는 Linux에서 실행하지 않습니다. 프로젝트 DB와 설정은 앱 설치 폴더 외부에 보관되므로 앱 폴더를 교체해도 유지됩니다.

Linux 네이티브 빌드, 단위·위젯 테스트와 가상 화면 시작 검증을 수행했습니다. 실제 배포판별 Wayland/X11·키링 잠금 해제·외부 GitHub 로그인은 해당 PC에서 확인해야 합니다.
