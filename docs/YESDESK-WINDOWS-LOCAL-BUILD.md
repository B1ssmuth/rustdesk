# Локальная сборка YES Desk для Windows x64

Команды рассчитаны на PowerShell 7.2+ x64, Git for Windows, штатный Windows tar.exe и 7-Zip для распаковки LLVM. Запускайте их из обычного PowerShell. Установка Visual Studio Build Tools запросит явное подтверждение перед UAC. Совместимый экземпляр VS Build Tools 2022 переиспользуется. Остальные инструменты и кеши размещаются в отдельном каталоге, по умолчанию C:\Projects\YESDesk-local, без изменений системного PATH, SDK других проектов и настроек защиты.

## Настройка

~~~powershell
Set-Location C:\Projects\YESDesk
pwsh -NoProfile -File .\scripts\setup-windows-build.ps1 -Diagnostic
pwsh -NoProfile -File .\scripts\setup-windows-build.ps1 -Install
pwsh -NoProfile -File .\scripts\setup-windows-flutter.ps1 -Diagnostic
~~~

Диагностика выводит результат в терминал без создания файлов. Для режима установки по умолчанию требуется 80 ГиБ на диске сборки при неполном окружении и 20 ГиБ на системном диске, если нужен Visual Studio. Для уже готового окружения порог повторной настройки — 5 ГиБ. При необходимости путь задаётся через -Root, одинаковый во всех командах. Короткий путь без пробелов уменьшает риск ошибок сторонних инструментов.

Настройка использует VS Build Tools 2022 17.14.44 для новой установки, MSVC v143, Windows SDK 10.0.26100 и CMake из VS. Остальные выбранные версии включают Rust 1.75.0 с rustfmt, Flutter 3.24.5, LLVM 15.0.6, CPython 3.12.10 с pip, Brotli 1.1.0, NuGet 6.14.0, .NET SDK 8.0.428 и WiX 4.0.5. Версия утилиты vcpkg берётся из bootstrap закреплённого checkout. CPython распаковывается из официального NuGet-пакета с pip. 7-Zip читает официальный NSIS-архив LLVM как архив.

Прямые загрузки сверяются с SHA-256 из [манифеста](../scripts/windows-build-dependencies.json) до распаковки или запуска. Кеш тоже проверяется. Для Flutter и Rustup использованы опубликованные хеши, для Brotli — хеш PyPI, для vcpkg — digest GitHub. SHA-256 .NET SDK получен из архива, проверенного по официальному SHA-512. Для Engine, драйвера, CPython и NuGet SHA-256 зафиксирован по файлам с официальных адресов. Visual Studio дополнительно проверяется по Microsoft Authenticode. Rustup, Cargo, Pub, NuGet, Visual Studio Installer и vcpkg управляют загрузками собственных зависимостей. Их фиксация опирается на выбранные версии, lock-файлы, метаданные поставщиков и хеши портов.

Настройка автоматически применяет патч dropdown к отдельному Flutter SDK и заменяет файлы в кеше Windows x64 Release Engine. При сбросе Flutter-кеша или для отдельной проверки применяется тот же сценарий.

~~~powershell
pwsh -NoProfile -File .\scripts\setup-windows-flutter.ps1 -Configure
~~~

## Rust/Dart bridge

Нативный сценарий использует Flutter 3.24.5, LLVM 15.0.6, cargo-expand 1.0.95 и flutter_rust_bridge_codegen 1.80.1 с feature uuid. Версия codegen реализует вызовы через PowerShell и поддерживает явный путь к LLVM. Фактический запуск на целевом Windows toolchain следует проверить после установки. Команда ниже останавливается после проверки шести файлов bridge, до сборки vcpkg, Rust-приложения, Windows runner и MSI.

~~~powershell
pwsh -NoProfile -File .\scripts\build-windows-local.ps1 -BridgeOnly -BridgeMode Native -Ref 3f49a70b8
~~~

Если нативный codegen не пройдёт, доступен маршрут через WSL2, повторяющий Ubuntu 22.04 из bridge.yml. Он использует отдельный Flutter 3.22.3 и заменяет extended_text на 13.0.0 только в Linux-снимке. WSL2 не нужен для компиляции Windows-приложения. Скрипт сборки не включает WSL и не выполняет команды с sudo.

При необходимости установите Ubuntu 22.04 в WSL2 по правилам своей машины. В повышенном Windows PowerShell эта установка запускается следующей командой. После установки завершите первичную настройку пользователя Ubuntu и убедитесь, что дистрибутив имеет версию WSL 2.

~~~powershell
wsl --install -d Ubuntu-22.04
wsl --list --verbose
~~~

В терминале Ubuntu установите зависимости bridge, которые перечисляет CI.

~~~bash
sudo apt-get update
sudo apt-get install -y ca-certificates clang cmake curl gcc git g++ libclang-dev libgtk-3-dev llvm-dev nasm ninja-build pkg-config wget xz-utils
~~~

Затем из Windows PowerShell запустите сценарий через WSL. Он перепроверяет архивы внутри WSL, генерирует файлы на файловой системе Linux и переносит результат в снимок сборки Windows.

~~~powershell
pwsh -NoProfile -File .\scripts\build-windows-local.ps1 -BridgeOnly -BridgeMode Wsl -WslDistribution Ubuntu-22.04 -Ref 3f49a70b8
~~~

## Сборка

~~~powershell
pwsh -NoProfile -File .\scripts\build-windows-local.ps1 -Diagnostic
pwsh -NoProfile -File .\scripts\build-windows-local.ps1 -Build -BridgeMode Native -Ref 3f49a70b8
~~~

Для Linux-генерации bridge замените -BridgeMode Native на -BridgeMode Wsl -WslDistribution Ubuntu-22.04. Полный проход требует по умолчанию 45 ГиБ свободного места после настройки инструментов. Можно задать -MinFreeGiB для ожидаемых размеров кешей. -Ref принимает коммит или ветку, по умолчанию HEAD. Сборка использует только отслеживаемые файлы выбранного коммита. Снимок, сгенерированный bridge и изменения для WiX и portable остаются под каталогом runs.

Сборка запускает vcpkg с локальным файловым кешем и триплетом x64-windows-static, собирает те же Rust-библиотеки и features, что и build.py в CI, затем запускает Flutter Release с подробным выводом и уже разрешёнными Dart-зависимостями. В Release-каталог добавляется драйвер usbmmidd_v2. Как и в Windows job, WindowInjection.dll из отдельного workflow в пакет не включается. MSI собирается первым и встраивается в portable EXE. Проверка читает PE и MSI без установки и сверяет SHA-256 вложенного MSI с отдельным файлом.

Если запуск прервался после сборки Rust DLL, укажите его каталог через -ResumeRun и тот же -Ref. Сценарий сверит коммит и lock-файлы с source.tar, проверит сгенерированный bridge и продолжит с Flutter Release. Каждая попытка упаковки получает свой каталог с логом MSBuild. Старые логи, кеши и готовые артефакты сохраняются.

~~~powershell
pwsh -NoProfile -File .\scripts\build-windows-local.ps1 -Build -Ref 3f49a70b8 -ResumeRun 'C:\Projects\YESDesk-local\runs\20261123-171747-958-3f49a70b8-2588'
~~~

Готовые файлы находятся в C:\Projects\YESDesk-local\runs\<запуск>\SignOutput. Для версии 1.4.6 это YES_Desk-1.4.6-x86_64.exe, YES_Desk-1.4.6-x86_64.msi и SHA256SUMS.txt. Сборка создаёт локальные неподписанные артефакты. Расшифровка команд и вывод инструментов записываются в logs. Ошибки Visual Studio Installer можно дополнительно искать в dd_*.log в TEMP учётной записи установщика.

Одинаковые входы позволяют повторить процесс сборки. Хеши файлов разных запусков могут различаться из-за даты сборки Rust, метки времени portable и идентификаторов MSI.

## Установка и удаление в тестовой VM

Скопируйте два артефакта и res\msi\test-yesdesk-install.ps1 в чистую одноразовую Windows VM. Запустите этот тест в PowerShell 7 x64 с правами администратора в гостевой системе. Переменные требуются существующему тесту и задаются только в гостевом процессе.

~~~powershell
$env:GITHUB_ACTIONS = 'true'
$env:RUNNER_TEMP = Join-Path $env:TEMP 'yesdesk-local-smoke'
New-Item -ItemType Directory -Path $env:RUNNER_TEMP -Force | Out-Null
.\test-yesdesk-install.ps1 -Msi .\YES_Desk-1.4.6-x86_64.msi -PortableExe .\YES_Desk-1.4.6-x86_64.exe
~~~

[Windows CI](../.github/workflows/flutter-build.yml) · [Bridge CI](../.github/workflows/bridge.yml) · [История VS Build Tools](https://learn.microsoft.com/en-us/visualstudio/releases/2022/release-history) · [CPython для CI](https://docs.python.org/3.12/using/windows.html#the-nuget-org-packages)
