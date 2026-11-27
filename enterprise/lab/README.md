# Изолированный стенд YES Desk Sprint 3.8

> История стенда Sprint 3.8. Сборка для текущей ветки описана в [инструкции Sprint 4.0](../SPRINT-4-WINDOWS.md).


Две отдельные Windows x64 VM и одна Linux x64 VM работают на частном коммутаторе Hyper-V. На гостях отсутствуют шлюз по умолчанию и корпоративные DNS. Доставка файлов производится через консоль либо отдельный виртуальный носитель. Hyper-V описывает границы сети типа Private в [документации коммутаторов](https://learn.microsoft.com/windows-server/virtualization/hyper-v/get-started/create-a-virtual-switch-for-hyper-v-virtual-machines).

| Узел | Имя ОС | Адрес |
| --- | --- | --- |
| Оператор | YD38-OPERATOR | 192.168.237.21/24 |
| Принимающее устройство | YD38-ENDPOINT | 192.168.237.22/24 |
| Management, PostgreSQL, брокер, hbbs/hbbr | Linux | 192.168.237.10/24 |

## Подготовка файлов

Подготовьте три независимых загрузочных VHDX поколения 2. Используйте чистые Windows x64 в рабочей группе с разными MachineGuid, отдельными локальными учётками, включёнными UAC, Secure Boot и виртуальным TPM. Образ Linux должен поддерживать Secure Boot и содержать Docker Engine с Compose v2, OpenSSL и curl. Для обновления образов используйте отдельную машину подготовки до подключения к стенду.

На машине подготовки соберите архив из проверенных digest официальных образов, сверив платформу linux/amd64. Команда печатает SHA-256 артефакта для передачи в отдельном доверенном канале. Зафиксируйте коммит Management, исходные digest и SHA-256 архива вместе. Версия RustDesk Server закреплена на [1.1.16](https://github.com/rustdesk/rustdesk-server/releases/tag/1.1.16), а источником образа служит [официальный GHCR](https://github.com/rustdesk/rustdesk-server/pkgs/container/rustdesk-server/).

~~~bash
bash enterprise/lab/pack-images.sh /tmp/yesdesk38-images.tar <sha-postgres> <sha-rustdesk> <sha-python>
~~~

На Windows-машине сборки создайте отдельный JSON и соберите пилотный MSI из той же ревизии. На чистых VM проверяйте SHA-256 MSI по файлу сборки. Используйте подписанный пакет, если того требует политика. Настройки защиты и доверенные корни хоста не меняются.

~~~powershell
Set-Location C:\Projects\YESDesk
@{ YESDESK_MANAGEMENT_URL = 'https://192.168.237.10:8443' } |
    ConvertTo-Json | Set-Content C:\Projects\yesdesk38-client.json -Encoding utf8
.\scripts\build-windows-local.ps1 -Build -Ref HEAD -UnifiedEnterpriseMsi `
    -BridgeMode Native -EnterpriseConfig C:\Projects\yesdesk38-client.json
~~~

## Hyper-V и запуск сервисов

В выделенном каталоге поместите копии VHDX. Сначала запустите команду без `-Create` для просмотра плана, затем повторите с `-Create` с повышенными правами. Гости останутся выключенными. Проверьте сетевые подключения в Hyper-V до включения. Сценарий создания описан в [документации Hyper-V](https://learn.microsoft.com/windows-server/virtualization/hyper-v/get-started/create-a-virtual-machine-in-hyper-v).

~~~powershell
Set-Location C:\Projects\YESDesk
$lab = 'C:\Projects\YESDesk38Lab'
.\scripts\New-YesDeskHyperVLab.ps1 -LabRoot $lab `
    -OperatorVhdx "$lab\operator.vhdx" -EndpointVhdx "$lab\endpoint.vhdx" `
    -BackendVhdx "$lab\backend.vhdx" -Create
~~~

Задайте Linux статический адрес `192.168.237.10/24` на единственном гостевом интерфейсе. Оставьте шлюз и DNS пустыми. Скопируйте каталог `enterprise/lab` и проверенный архив. Запустите от локального пользователя с доступом к Docker. Скрипт применит миграции и проверит HTTPS с корнем стенда. Состояние и ключи остаются в каталоге `state` и томах лабораторного проекта.

~~~bash
bash start-backend.sh /media/lab/yesdesk38-images.tar <доверенный-sha256>
export LAB_UID=$(id -u) LAB_GID=$(id -g)
docker compose exec -T hbbs cat /root/id_ed25519.pub
docker compose exec api python local_auth.py bootstrap lab-admin
~~~

Для последующих команд Compose в новой сессии на Linux сначала выполните `export LAB_UID=$(id -u) LAB_GID=$(id -g)` из каталога с `compose.yaml`. Bootstrap интерактивно выдаёт секрет TOTP. Передайте его отдельному лабораторному аутентификатору и исключите из логов.

## Настройка Windows и регистрация

1. Передайте обеим Windows VM только публичный `state/server-ca.cer` и его SHA-256, сверенный на Linux-консоли. Выполните `Configure-WindowsGuest.ps1 -Role Operator` или `-Role Endpoint` с параметрами `-CaCertificate <путь>` и `-CaSha256 <digest>` от администратора соответствующего гостя. Проверьте `Invoke-RestMethod https://192.168.237.10:8443/health/ready` и отсутствие маршрутов по умолчанию. Сертификат доверен только на тестовых гостях.
2. Установите пилотный MSI внутри VM и сохраните лог каждого запуска. Для `msiexec.exe` используйте `/i`, `/norestart` и `/l*v` с абсолютными путями. В сетевых настройках обоих клиентов задайте ID-сервер `192.168.237.10:21116`, ретранслятор `192.168.237.10:21117` и проверенный публичный ключ из hbbs. Поле API-сервера RustDesk оставьте пустым. Management API задан при сборке.
3. На принимающей VM возьмите YES Desk ID из GUI, MachineGuid из `HKLM:\SOFTWARE\Microsoft\Cryptography` и префикс SID интерактивного **локального** пользователя до последнего дефиса из `whoami /user`. Используйте имя `YD38-ENDPOINT` и лабораторное имя `yd38-endpoint.yesdesk.test` для записи каталога. DNS-запись для этого имени не нужна.
4. На Linux выполните `bash issue-endpoint-certificate.sh <MachineGuid>`. Скопируйте SHA-256 DER из вывода в CSV `state/approvals/endpoint.csv` с заголовком `machine_guid,computer_sid,hostname,dns_name,yesdesk_id,certificate_sha256`. Внесите только проверенные данные принимающей VM и примените одобрение.

~~~bash
docker compose exec broker python enrollment_broker.py --approve-csv /approvals/endpoint.csv
docker compose exec api python local_auth.py grant-device lab-admin --device-id <MachineGuid>
~~~

5. Передайте зашифрованный `endpoint.pfx` только принимающей VM, а пароль передайте отдельно. Импортируйте PFX через `Import-PfxCertificate -CertStoreLocation Cert:\LocalMachine\My` с паролем из `Read-Host -AsSecureString`. Убедитесь, что закрытый ключ доступен SYSTEM. Передайте скрипту агента отдельные адреса API и брокера и перезапустите агент. После успешной регистрации проверьте каталог и heartbeat из учётки `lab-admin`.

~~~powershell
pwsh -File .\enterprise\agent\Provision-Agent.ps1 -Api 'https://192.168.237.10:8443' `
    -Broker 'https://192.168.237.10:18443' -CertificateIssuer 'CN=YESDesk 38 Lab Device CA'
Restart-Service -Name YESDeskAgent
~~~

Для проверки допуска выдайте политику для GUID устройства через существующий аутентифицированный `PUT /v2/devices/{id}/corporate-policy` с `attended: true` и коротким `unattended_until` в UTC. Используйте токен лабораторной админской сессии только в памяти. Отдельную локальную учётку с ролью support без права на это устройство используйте для проверки отказа. Точная схема API доступна через `/openapi.json` на стенде.

## Протокол испытаний

Сохраняйте время UTC, commit, SHA-256 MSI, логи установки обеих VM, журналы клиента и `docker compose logs --no-color --timestamps`. Для событий Management сопоставляйте решения с аудитом. Скрывайте токены, пароли, TOTP и закрытые ключи.

| Сценарий | Наблюдаемый результат |
| --- | --- |
| Обычный доступ по ID | Рабочий стол открыт штатным способом. В госте подтверждается реальное действие оператора |
| Корпоративный с подтверждением | Принимающая VM показывает идентификатор оператора и открывает сеанс только после согласия |
| Корпоративный unattended | Сеанс открывается только при явной политике. В аудите есть начало и завершение |
| Нет разрешения, срок истёк или разрешение повторено | Передача экрана и ввода не начинается |
| Перезагрузка и обрыв | Фиксируется завершение. Повторное подключение проходит действующую проверку заново |

На текущем коммите разрешённые политикой корпоративные запросы получают 501. В Windows-приёмнике ещё нет проверяемой привязки разрешения к удостоверению устройства и конкретному соединению, проверки локальной политики и подтверждения операторской идентичности. До реализации этих проверок статус двух корпоративных сценариев — **заблокирован**. Отказ 501 и проверка обычного подключения записываются отдельно от результатов корпоративного доступа.
