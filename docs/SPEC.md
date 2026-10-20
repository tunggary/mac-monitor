# mac-monitor 구현 스펙

> HANDOFF.md(삭제됨)의 결정사항과 2026-10-18 구현 착수 시 확정한 결정을 합친 유일한 원본. 결정이 바뀌면 이 파일을 같이 고친다.

레포: /Users/m1-mac/Documents/project/mac-monitor  (git: main / develop / feature/*)
시안 HTML: design/mockups/{Palette,Main,Danger,Notification,Icon,Settings}.dc.html — 폭·패딩·폰트·색 수치는 여기서 읽는다.
앵무새: design/parrot-sprite.png (1280×384, 128px 프레임 10열 × 3행 초록·노랑·코랄), design/parrot-frames/{green,yellow,coral}-01..10.png

## 목적
16GB 맥에서 스왑·메모리 압박으로 맥이 멈추기 전에 알아채고, 원인 앱을 바로 끄는 메뉴바 앱. 원인 신호는 스왑과 메모리 압박. Aside처럼 프로세스 100개+로 쪼개진 앱은 합산해야 보인다.

## 기본
- 개인용. 샌드박스 없음(다른 프로세스 조회·종료 필요). 앱 스토어 X.
- Swift 6 (strict concurrency) + SwiftUI + AppKit. 외부 라이브러리 없음. Xcode 프로젝트, "Sign to Run Locally", 설치 위치 /Applications.
- 환경: Xcode 27.1, Swift 6.4, macOS 27 (deployment target macOS 27).
- LSUIElement = YES (Dock 아이콘 없음, 메뉴바 전용).
- 로그인 시 자동 실행: SMAppService.mainApp, 기본 켬, 설정에서 끔.
- 앱 자체 목표: CPU 1% 미만, 메모리 80MB 미만.

## 측정
- 시스템 지표(CPU·메모리·스왑·압력) 1초, 프로세스 목록 3초.
- 시계열은 메모리에만 1시간 링버퍼(1초 × 3600). 디스크 저장 없음.
- API: host_statistics64(HOST_CPU_LOAD_INFO, HOST_VM_INFO64), sysctl vm.swapusage, kern.memorystatus_level, proc_listallpids / proc_pidinfo / proc_pid_rusage(RUSAGE_INFO_V4+), NSRunningApplication + responsibility(responsibility_get_pid_responsible_for_pid, 비공개 심볼 dlsym) / 부모 체인, proc_pidinfo(PROC_PIDVNODEPATHINFO)로 cwd, proc_pidfdinfo로 리슨 포트(lsof 안 씀).
- 프로세스 메모리는 RSS가 아니라 phys_footprint (ri_phys_footprint). RSS는 과소 집계(실측 next-server RSS 189MB vs footprint 8.4GB).
- CPU%: 프로세스는 ri_user_time+ri_system_time 델타(mach time → ns, timebase 변환 필요) / 경과 시간. 코어 1개 = 100%.
- 시스템 CPU: 시스템 % · 사용자 % · 대기 % (top의 "CPU usage: x% user, y% sys, z% idle"와 같은 정의, nice는 user에 합산). 큰 수치 = 100 − 대기.

### 메모리 정의 (확정)
- 앱 메모리 = (internal_page_count − purgeable_count) × pagesize  (활성 상태 보기 방식)
- 와이어드 = wire_count × pagesize
- 압축됨 = compressor_page_count × pagesize
- 메모리 % = (앱 메모리 + 와이어드 + 압축됨) / hw.memsize
- 사용 가능 % = kern.memorystatus_level (memory_pressure 의 "System-wide memory free percentage" 와 같은 값)
- 압력 % = 100 − 사용 가능 %
- 압력 칩 색·문구 = 메모리 상태(정상/주의/위험): "압력 정상 31%"

## 상태 판정 (기준은 설정에서 변경)
- 메모리 주의: 스왑 > 4 GB → 팝오버에 주의 표시, 알림 없음
- 메모리 위험: 스왑 > 8 GB 또는 사용 가능 메모리 < 20% → 팝오버 위험 배너 + 알림
- CPU 급증(주의): 한 앱(그룹)이 CPU ≥ 300%를 30초 넘게 지속 → 알림
- CPU 칩: 어떤 앱이든 CPU ≥ 300%(앱 CPU 주의 기준)면 "CPU 주의"(노랑), 아니면 "CPU 정상"(초록)
- 앱 행 상태 점: 메모리 위험 → 1위 원인 앱 코랄, 2·3위 노랑 / 메모리 주의 → 1~3위 노랑 / CPU ≥ 300% 앱은 메모리 상태와 상관없이 노랑(코랄이 우선) / 나머지 초록
  ("원인" = 메모리 footprint 큰 순)

## 메뉴바 아이콘 — 파티 앵무새
- NSStatusItem에 10프레임 앵무새. 숫자 없음, 아이콘만. 높이 18pt, 하단 여백 3pt(메뉴바 22pt). 원본 프레임 위쪽 투명 여백은 전 프레임 그림 영역 합집합으로 잘라낸다(약 24×18pt, 칸 폭 32pt).
- 속도 = 전체 CPU 사용률: CPU ≤ 10% → 10장/1.2초, CPU ≥ 90% → 10장/0.35초, 사이는 fps(초당 프레임 수)를 선형 보간. (fps 8.33 → 28.57)
- 모양: 테두리만 흰색, 몸통 등 내부는 투명. 메모리 상태에 따른 색 변화 없음(2026-10-20 변경 — 이전 결정 "몸 색 = 메모리 상태"를 대체).
  원본 green 프레임의 검은 테두리 픽셀(밝기 < 0.25)만 흰색으로 바꾸고 나머지는 투명 처리한다. 노랑·코랄 프레임은 앱에서 쓰지 않는다.
- 흰색 고정이라 밝은 메뉴바에서는 잘 안 보일 수 있다(알려진 한계).
- 캐릭터 교체 가능한 구조: Character 프로토콜(이름, 상태별 프레임 배열, 속도 범위). 지금은 파티 앵무새 하나.

## 팝오버 (아이콘 클릭) — NSPopover + SwiftUI, 폭 380, 시안 Main / Danger
배경 surface, 테두리 line-strong 1px, radius 12, padding 16, 섹션 gap 14. 폰트 시스템(SF Pro), 숫자 tabular-nums(.monospacedDigit()).
1. (메모리 위험일 때만) 상단 배너: danger 16% 배경, radius 10, padding 10×12, 경고 삼각형 18px.
   제목 13 semibold "메모리 위험 — 스왑 12.7 GB", 본문 12 text-2 "경고 기준 8 GB를 4분째 넘고 있어요. 가장 큰 원인은 Aside(20.7 GB)예요."
   사용 가능 메모리가 원인이면: 제목 "메모리 위험 — 사용 가능 18%" / 본문 "경고 기준 20%보다 4분째 적어요. 가장 큰 원인은 Aside(20.7 GB)예요." 둘 다 해당하면 스왑 문구 우선.
   "N분째"는 앱이 위험을 처음 감지한 시각부터(최소 1분 표기).
2. "시스템"(13 semibold text-2) + 범위 토글 1분 / 10분(기본) / 1시간 (세그먼트: surface-2 배경 radius 7 padding 2 gap 2, 버튼 12px padding 4×10 radius 5, 선택 = surface-3 배경 + accent 글자 semibold)
3. CPU: "CPU 18.2%" 20 semibold(수치는 cpu 색) + 오른쪽 상태 칩 / 아랫줄 12 text-2 "시스템 6.4% · 사용자 11.8% · 대기 81.8%" / 영역 그래프 높이 56
4. (구분선 1px line) 메모리: "메모리 63.9%" 20 semibold + 칩 "압력 정상 31%" / 3열(앱 메모리·와이어드·압축됨, 라벨 12 text-2, 값 14 text) / 그래프 높이 48
5. 스왑: "스왑 1.2 GB" 14 semibold(수치 swap 색) + 오른쪽 12 "주의 4 GB · 위험 8 GB"(각각 warn/danger 색, 초과 시 "위험 8 GB 초과" semibold) / 그래프 높이 40, warn·danger 점선 기준선 2개(1px, dash 4 4, opacity 0.7)
6. (구분선) 상위 앱 5개: "상위 앱" + 정렬 토글 메모리/CPU (버튼 padding 3×10)
   행: padding 8 상하좌우, gap 10, 아이콘 28×28 radius 7(앱 아이콘, 없으면 surface-3 배경에 이니셜), 이름 13 / 부가정보 11 text-3 (말줄임), 상태 점 8×8, 값 13, 종료 × 버튼 28×28(아이콘 14, text-3)
   행 클릭 → 펼침: surface-2 배경 radius 10 컨테이너. 펼침 화살표 없음. 하위 행은 이름 시작 위치(왼쪽 46px)에 정렬, padding 6 8 6 46, 이름 12 / 부가 11 text-3 / 값 12 text-2 / × 26×26(아이콘 12).
   펼쳐도 상위 행은 같은 × 버튼(앱 전체 종료) 유지(2026-10-20 변경 — 시안의 "종료" 글자 버튼 대신). 상위 앱 목록은 접힌 행 5개 높이의 고정 스크롤 영역. 펼친 내용은 그 행 바로 아래에 끼워 넣고(아래 행은 목록 안에서만 내려감), 펼치면 보이도록 자동 스크롤. 시스템 스크롤 막대는 숨기고(폭을 차지해 행이 밀림) 목록 위에 겹친 3pt 막대(text-3 60%)로 표시. 팝오버 높이·하단 바는 불변(2026-10-20 변경 — 이전 "겹쳐 그리기"는 아래쪽 행에서 하단 바와 겹치는 버그가 있었음).
   부가정보: GUI 앱 "프로세스 42개" (위험 시 "프로세스 123개 · CPU 112%"), CLI "next-server · 1pm_clinic_web-new-work-1018 · :3110" 형태에서 이름 뒤 부분 = "cwd폴더명 · :포트"
   하위 행: 같은 실행 파일 이름끼리 묶어 메모리 상위 3줄 + "그 외 N개"(부가: "Helper (GPU) 외"). 묶인 줄 부가 "96개", × 는 그 줄의 프로세스 전체에 신호.
7. 하단(border-top line, padding-top 6): "측정 1초 · 앱 목록 3초"(11 text-3), 설정(톱니 16) 버튼, "앱 종료" 버튼.
- 그래프: Swift Charts AreaMark(24%) + LineMark(100%, 1.5px). 1시간 범위는 다운샘플링해서 점 수를 그래프 폭(~348) 이하로.

## 앱 묶기 규칙
- GUI 앱은 .app 번들 단위로 합산 (Aside Helper ×96 → Aside). responsible pid → NSRunningApplication / 실행 경로에서 가장 바깥 .app 번들.
- 터미널에서 띄운 CLI 프로세스(node, next-server, vite, python…)는 터미널 앱에 묶지 않는다. 키 = 명령 이름 + cwd 폴더. 같은 폴더의 같은 명령은 한 줄로 합친다. 부가정보 = cwd 폴더명 · :리슨포트(여러 개면 첫 번째), 합친 프로세스가 2개 이상이면 뒤에 " · N개".
- 프로세스 이름이 버전 문자열(예 "2.1.302", Claude Code CLI)이면 실행 경로에서 versions 같은 컨테이너 폴더를 건너뛴 상위 폴더명으로 보정("claude").
- 셸(zsh/bash/fish/sh, login)은 터미널 앱에 합산.
- "터미널에서 띄운" 판정: responsible 앱이 터미널 계열(Terminal, iTerm2, cmux, Ghostty, WezTerm, Warp, Alacritty, kitty 등)이고, 그 터미널 앱 번들 바깥의 실행 파일인 경우.

## 종료
- × → 즉시 SIGTERM (앱 단위 = 그룹 내 모든 프로세스). 3초 뒤에도 살아 있으면 그 행 아래 인라인 강제종료 확인 박스:
  margin 8 8 0 46, padding 10, radius 8, surface 배경, 테두리 danger 50%.
  "Aside를 강제종료할까요?"(12 semibold) / "일반 종료에 응답하지 않아요. 저장 안 된 작업은 사라져요."(11 text-2) / 버튼 취소(surface-3) · 강제종료(alert-deep 배경 흰 글자 semibold), 높이 26.
  강제종료 = SIGKILL.
- 종료 동작은 종료(SIGTERM)와 강제종료(SIGKILL) 두 가지뿐. 일시정지(SIGSTOP)는 넣지 않기로 확정.
- 다른 계정 소유 프로세스(WindowServer, kernel_task 등)는 root 없이 메모리·CPU를 읽을 수 없어 상위 앱 목록에 나오지 않는다(확정). 전체 메모리·스왑·CPU 수치는 시스템 전체 값이라 영향 없음.
- 내 계정(uid == getuid()) 프로세스만. 그룹에 다른 계정 프로세스가 섞여 있으면 내 계정 프로세스만 있는 줄에만 × 표시, 앱 단위 종료는 내 계정 프로세스에만 신호. 시스템 프로세스(다른 uid, kernel_task, WindowServer 등)와 이 앱 자신은 × 숨김. root 권한 상승 없음. 자동 kill 없음.

## 알림 — UNUserNotificationCenter + 카테고리 액션
- 제목: "[위험] 메모리 — 스왑 12.7 GB" / "[주의] CPU 급증 — next-server 340%" (글자만, 이모지 X)
- 본문: 메모리 = 원인 앱 상위 3개 "Aside 20.7 GB · ego lite 3.9 GB · Claude 1.8 GB" / CPU = "1pm_clinic_web-new-work-1018 · :3110 · 35초째"
- 소리: 메모리 위험 알림만 기본 알림음, CPU 급증(주의)은 무음.
- 알림 버튼으로 종료했는데 3초 뒤에도 살아 있으면 팝오버를 열고 그 앱 행 아래 강제종료 확인 박스를 띄운다(강제종료는 사용자가 눌러야 함).
- 액션 버튼: 원인 상위 3개 앱의 "OO 종료"(SIGTERM)만. 강제종료·팝오버 열기 버튼 없음. 알림 본문 클릭 → 팝오버 열기.
- 알림 아이콘 = 앱 아이콘 = 번개 아이콘 고정. macOS 알림은 앱 아이콘을 그대로 보여주므로 AppIcon 에셋 자체를 번개로 만든다
  (시안 Notification: viewBox 0 0 20 20, path "M11 2 L4 11.5 H9.5 L8.5 18 L16 8 H10.5 Z", 색 brand #7C85FF, 배경 surface #15171D). design/ 에는 이 에셋이 없으니 path에서 생성한다.
- 반복: 기준 초과 시 1회, 계속되면 설정 간격(기본 10분)마다, 정상 복귀 시 초기화. 메모리 위험·CPU 급증 각각 독립.

## 설정 창 — 시안 Settings (창 제목 "mac-monitor 설정")
- 일반: 로그인 시 자동 실행 (체크박스)
- 위험 기준 (각 행 라벨 + 주의/위험 칩 + 힌트 11 text-3 + 숫자 입력 64px + 단위):
  스왑 사용량 [주의] 4 GB "앵무새가 노랑으로 바뀌어요" / 스왑 사용량 [위험] 8 GB "앵무새가 코랄로 바뀌고 알림이 와요" /
  사용 가능 메모리 [위험] 20 % "이 값보다 적으면 위험" / 앱 하나의 CPU [주의] 300 % "코어 1개 = 100%" / CPU 급증 지속 시간 [주의] 30 초 "이만큼 계속되면 알림"
- 알림: "위험이 계속되면 다시 알림" (힌트 "정상으로 돌아오면 초기화돼요") — 5분마다 / 10분마다(기본) / 30분마다 / 다시 안 함
- 캐릭터: 3칸 그리드, 파티 앵무새(선택됨, accent 2px 테두리, 움직이는 미리보기) + "추가 예정" 점선 칸 2개(disabled)
- 설정은 UserDefaults. 스왑 주의 ≥ 스왑 위험 입력은 저장하지 않고 입력칸 아래 "주의는 위험보다 작아야 해요" 안내, 이전 값 유지. 사용 가능 메모리 %는 1~99.

## 단위
- 용량은 1024 기준(GiB) 값에 "GB" 라벨 (활성 상태 보기·sysctl 과 같은 기준). 스왑 기준 비교도 같은 기준.

## 색 팔레트 — Ink Indigo (Theme.swift 한 곳에 토큰, 화면은 의미 토큰만 참조)
| 토큰 | 연함 | 기본 | 진함 |
| brand | #B9BEFF | #7C85FF | #545DE8 |
| green | #B4EDD2 | #6FD6A8 | #2FA877 |
| yellow | #FBE3A8 | #F5C96A | #C08A1E |
| alert | #FFB0A6 | #FF7A6B | #D2453A |
중립: ground #0D0E12 · surface #15171D · surface-2 #1E2129 · surface-3 #2A2E38 · text #ECEEF3 · text-2 #9AA0AD · text-3 #7D8391 · line white 8% / line-strong white 14% · menubar #08090C
의미: cpu = brand · mem = brand · swap = brand-연함 · ok = green · warn = yellow · danger = alert · accent(선택·토글·포커스) = brand · 강제종료 버튼 면 = alert-진함(흰 글자)
규칙: 상태 칩 배경 16%(칩 padding 3×8 radius 10, 12 semibold), 그래프 면 24%. 평소 화면엔 인디고·먹색·초록만, 노랑·코랄은 주의·위험에만(예외: 스왑 기준 점선).
다크 고정(팝오버·설정 창은 .preferredColorScheme(.dark) / NSAppearance darkAqua).

## 버전 관리 (../git-graph-panel 과 같은 방식)
- Semantic Versioning `MAJOR.MINOR.PATCH`. 버전 값은 Xcode `MARKETING_VERSION`(앱 타깃 Debug/Release 와 테스트 타깃 모두 같은 값)이다.
- 릴리스: develop 에서 `release/x.y.z` 분기 → `build: 버전을 x.y.z로 올린다` 커밋(MARKETING_VERSION 변경, CURRENT_PROJECT_VERSION +1) → main 에 `--no-ff` 머지("Merge branch 'release/x.y.z' into main") → main 머지 커밋에 annotated 태그 `vx.y.z`(메시지 `vx.y.z`) → develop 에도 머지.
- 올릴 자리: 직전 태그 이후 커밋에 `feat` 가 있으면 MINOR, `fix`·`style`·`refactor` 등만 있으면 PATCH. 0.x 동안 MAJOR 는 올리지 않는다.
- 첫 릴리스 v0.1.0 (2026-10-20): 프로젝트 기본값이 이미 0.1.0 이라 버전 올림 커밋 없이 태그만 붙였다.
