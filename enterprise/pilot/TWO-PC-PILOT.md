# Пилот YES Desk Enterprise на двух Windows ПК

Рабочий ПК администратора использует локальную учётную запись Management API с TOTP. Принимающий ПК — YESSPB-006.mcm.ru, Windows 11 Pro x64, YES Desk ID `54787641`. Сервер sctgdesk обслуживает существующие Management API, PostgreSQL, hbbs/hbbr и старый RustDesk API. Команды в этом документе выполняет администратор на соответствующей машине после согласования окна обслуживания.

## 1–4. Резервное копирование и Management API

1. На sctgdesk сохраните текущие Compose-файлы, образ API, настройки reverse proxy, переменные окружения и все используемые файлы секретов. Подставьте фактический каталог Management. Проверьте, что резервный том зашифрован и доступ ограничен оператором. Если PostgreSQL внешний, используйте его штатное резервное копирование и проверку восстановления.

~~~bash
cd /путь/к/текущему/management-compose
umask 077
backup="/secure/backup/yesdesk-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"
docker compose exec -T db pg_dump -U yesdesk -d yesdesk -Fc > "$backup/management.dump"
docker compose exec -T db pg_dumpall -U yesdesk --globals-only > "$backup/pg-globals.sql"
docker image tag "$(docker compose images -q api)" yesdesk-management:pre-38
docker save yesdesk-management:pre-38 > "$backup/api-pre-38.tar"
tar -cf "$backup/deployment.tar" compose.yaml secrets
sha256sum "$backup"/management.dump "$backup"/pg-globals.sql "$backup"/api-pre-38.tar "$backup"/deployment.tar > "$backup/SHA256SUMS"
~~~

Отдельно включите в резервную копию фактические `.env`, `YESDESK_CONFIG`, файлы Compose override, настройки TLS и reverse proxy, а при наличии брокера его конфигурацию и защищённые файлы. Проверьте `pg_restore --list` и полное восстановление в отдельную БД. Зафиксируйте результаты входа с TOTP, heartbeat, GUID и YES Desk ID устройства. Зафиксируйте ответ действующей проверки старого RustDesk API по её фактическому URL и коды ответа. Для проверки повторно используйте тот же путь после обновления.

2. Сверьте Git SHA серверного архива и MSI с поставкой. Сценарий обновления воспроизводится с базой Sprint 3.6, содержащей миграции 001–006. На копии БД проверьте 007 (каталог), 008 (сертификатная регистрация), 009 (локальные политики корпоративного допуска) и 010 (ключи хостов и одноразовые разрешения). Перед обновлением сохраните список `schema_migrations`, GUID устройства, `yesdesk_id`, признак наличия `agent_hash`, состояние heartbeat и индивидуальные назначения. Токены и хеши в отчёте не нужны.

~~~bash
docker compose exec -T db psql -U yesdesk -d yesdesk -c 'SELECT name, installed_at FROM schema_migrations ORDER BY name;'
docker compose exec -T db psql -U yesdesk -d yesdesk -c "SELECT id,dns_name,yesdesk_id,windows_enrollment,(agent_hash IS NOT NULL) AS enrolled,last_heartbeat FROM devices WHERE yesdesk_id='54787641';"
~~~

3. Проверьте подпись и SHA-256 MSI до передачи на ПК. Проверьте установку на чистом тестовом ПК и имеющийся сценарий обновления на восстановленной копии Windows. Сведения о запрете обновления приведены ниже. Не продолжайте к замене служб при отказе установщика.

4. Положите новый каталог `management` рядом с копией действующего Compose. Используйте действующие конфигурацию, MFA-ключ и файлы подключения к той же базе. Держите выключенным пилотный override до подготовки доверия устройства. Плановое обновление API запускается отдельно от RustDesk.

~~~bash
docker compose build api migrate
docker compose run --rm --no-deps migrate
docker compose up -d --no-deps api
curl -fsS http://127.0.0.1:18083/health/ready
docker compose logs --tail 100 api migrate
~~~

Проверьте наличие миграций 007–010, сохранение строки устройства, прежних назначений и heartbeat агента Sprint 3.6. Проверьте обычный вход TOTP, отказ с ошибочным кодом, доступ к каталогу и прежний RustDesk API. Проверьте готовность по `https://desk.yesapart.com/management/health/ready` из корпоративного тестового окружения.

## 5–6. Подготовка двух ПК

На каждом ПК сравните SHA-256 MSI с отдельно полученным значением и поместите `SHA256SUMS.txt` рядом с MSI. Скрипты сохраняют конфигурацию и сведения об установке в новую защищённую папку. Резервную копию токена DPAPI восстанавливают на исходном ПК с исходной идентичностью и правами службы. Состояние ключей сертификатов сохраняйте штатным образом через PKI и образ системы.

~~~powershell
$root = 'C:\Pilot'
$msi = Join-Path $root 'YES_Desk-Enterprise-1.4.6-x86_64.msi'
& "$root\enterprise\pilot\Prepare-Admin.ps1" -Msi $msi -BackupDirectory "$root\backup-admin"
~~~

Для чистого ПК администратора предусмотрен параметр `-InstallClean` с новой папкой резервной копии. Скрипт блокирует его, если обнаружены существующий продукт или служба. После установки проверьте вход с TOTP, каталог и соединение по ID.

~~~powershell
$root = 'C:\Pilot'
$msi = Join-Path $root 'YES_Desk-Enterprise-1.4.6-x86_64.msi'
& "$root\enterprise\pilot\Prepare-YESSPB006.ps1" -Msi $msi -BackupDirectory "$root\backup-endpoint"
Get-Service -Name 'RustDesk','YES Desk','YESDeskAgent' -ErrorAction SilentlyContinue
~~~

На YESSPB-006 создание резервной копии не меняет работающие службы. Единый MSI блокирует переход поверх старой службы RustDesk, прежнего MSI или отдельного YESDeskAgent. На восстановленной копии ПК подтвердите ожидаемый отказ и сохранение служб, MachineGuid, параметров RustDesk, зарегистрированного ID и состояния DPAPI. Для действующего ПК нужен проверенный перенос владения обеими службами и файлами между пакетами. До него остановитесь после резервной копии. Прежний RustDesk Service не удаляйте. После согласованного обновления сравните инвентарь до и после, проверьте один экземпляр транспортной службы, один YESDeskAgent и их автоматический запуск после перезагрузки.

## 7–14. Допуск и испытания после проверенного обновления хоста

1. Сопоставьте MachineGuid с существующей строкой `54787641`. Регистрация через старый код допускает прежний heartbeat. Для корпоративного допуска требуется активная запись использованного mTLS-сертификата, связанная с текущим хешем регистрации. Если её нет, согласуйте точечную перерегистрацию с тем же GUID через брокер. Процедура сертификатной регистрации описана в [Unified Workspace](../UNIFIED-WORKSPACE.md). Смена токена требует сверки heartbeat и сценария отката.
2. Из доверенного источника на хосте получите **публичный** Ed25519-ключ транспортной службы RustDesk. Закрытый ключ остаётся на хосте. Доверенный оператор БД закрепляет открытый ключ за использованным сертификатом, с текущим `agent_hash` и сроком. Если атрибуты не совпадают, вставка должна вернуть ноль строк. Связь не устанавливается по одному имени хоста или сообщению от удалённого клиента.

~~~sql
INSERT INTO corporate_endpoint_keys(certificate_fingerprint,agent_hash,public_key,valid_until)
SELECT e.fingerprint,d.agent_hash,decode(:'endpoint_key_hex','hex'),:'valid_until'::timestamptz
FROM devices d JOIN device_enrollment_certificates e ON e.device_id=d.id
WHERE d.id=:'pilot_guid'::uuid AND lower(d.dns_name)='yesspb-006.mcm.ru' AND d.yesdesk_id='54787641'
  AND d.enabled AND d.windows_enrollment AND d.agent_hash IS NOT NULL
  AND e.enabled AND e.used_at IS NOT NULL AND e.fingerprint=:'certificate_sha256'
RETURNING certificate_fingerprint,valid_until;
~~~

3. Дайте локальной учётной записи индивидуальное право через `docker compose exec api python local_auth.py grant-device <оператор> --device-id <GUID>`. Администратор сохраняет `{"attended":true}` в `PUT /v2/devices/<GUID>/corporate-policy`. Для запроса используйте текущую MFA-сессию в памяти, избегайте токенов в командной строке и логах. Действующий публичный ключ Management и SHA-256 DER сертификата хоста закрепите в 64-битной ветке HKLM.

~~~powershell
$key = 'HKLM:\SOFTWARE\YES Apart\YES Desk\CorporateSession'
New-Item -Path $key -Force | Out-Null
Set-ItemProperty $key DeviceId $machineGuid -Type String
Set-ItemProperty $key CertificateFingerprint $certificateSha256 -Type String
Set-ItemProperty $key ManagementSigningKey $issuerEd25519Hex -Type String
Set-ItemProperty $key ManagementUrl 'https://desk.yesapart.com/management' -Type String
Set-ItemProperty $key AllowConsent 1 -Type DWord
Set-ItemProperty $key AllowUnattended 0 -Type DWord
~~~

Переменные `$machineGuid`, `$certificateSha256` и `$issuerEd25519Hex` заполните проверенными значениями. Проверьте, что писать в ключ могут только администраторы и SYSTEM. Хост должен иметь активную физическую консоль с рабочим столом Default. При включённой штатной 2FA корпоративный допуск закрыт.

4. Для ограниченного пилота подключите `compose.corporate-pilot.yaml`. Передайте `YESDESK_CORPORATE_PILOT_DEVICE` как GUID YESSPB-006 и `YESDESK_CORPORATE_SIGNING_KEY_PATH` как абсолютный локальный путь к защищённому PEM Ed25519. Ключ должен быть читаем процессом API с UID 65532. В пакете нет закрытых ключей. Успешный `GET /v2/devices/<GUID>/connection-options` должен вернуть `launch`, согласованный ID, закреплённый ключ, `attended.available=true` и `unattended.available=false`.

~~~bash
docker compose -f compose.yaml -f pilot/compose.corporate-pilot.yaml up -d --no-deps api
~~~

5. Сверьте инвентаризацию и heartbeat. Сначала проверьте обычный вход по ID `54787641`. Затем запустите consent из каталога, проверьте имя оператора, появление живого изображения, реакцию на клавишу и мышь, завершение. Повторите попытку с отказом сотрудника и убедитесь, что нет экрана, ввода и предложения постоянного пароля. Проверьте аудит выдачи и погашения в Management, а также события `corporate_admit` и `corporate_close` с ID разрешения в аудите хоста.
6. После успешного consent администратор выставляет **только для этого GUID** `unattended_until` с коротким сроком UTC через предыдущий PUT и отдельно изменяет `AllowUnattended` на 1 на хосте. Проверьте unattended, отключите его после испытаний и подтвердите отказ повторной попытки. Проверьте истечение и отзыв, потерю доступа к Management, закрытие окна в процессе допуска и новое соединение после перезагрузки обеих служб. Сохраняйте UTC, режим, оператора, GUID, ID разрешения и результат. Закрытые ключи, TOTP и bearer-токены в отчёт не включайте.

## 15. Откат

- Снимите пилотный Compose override и верните исходную конфигурацию API. Закройте выдачу и новые попытки, отзовите индивидуальное право при необходимости и установите `AllowUnattended=0`. Закройте активные пилотные сеансы в Connection Manager.
- Для отката кода API поднимите сохранённый образ `yesdesk-management:pre-38` с прежними параметрами и секретами. Для временного Compose override достаточно задать этому сервису `image: yesdesk-management:pre-38`, затем запустить `docker compose ... up -d --no-deps --no-build api`. Проверьте старый RustDesk API, вход TOTP и heartbeat. Добавленные миграции совместимы с таким откатом кода.
- Чтобы физически вернуться к схеме Sprint 3.6, сначала сохраните новый полный dump, роли и аудит. Восстановите исходный dump Sprint 3.6 в **другую** PostgreSQL БД. Сопоставьте записи за окно пилота и перенесите в старую схему совместимые данные через проверенную выборочную процедуру. Новые таблицы остаются в отдельно сохранённой БД. Перенаправляйте API только после повторной проверки, исходную обновлённую БД сохраните.
- Клиент и агент откатывайте образом исходного ПК или ранее проверенными пакетами, сохраняя владельцев служб, учётный контекст и конфигурацию DPAPI. При отозванном серверном токене используйте новую санкционированную регистрацию того же GUID. Проверьте ID, обе службы, инвентаризацию и отсутствие дубликатов. Без проверенного образа и восстановления не заменяйте текущий RustDesk Service.

Открытие рабочего стола, отказ, unattended, перезагрузка и откат считаются проверенными только после выполнения этих шагов на двух реальных ПК.
