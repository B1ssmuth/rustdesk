# Синтетический каталог для проверки LDAPS

Используйте одноразовый OpenLDAP с суффиксом `dc=example,dc=test`, LDAP-портом LDAPS на loopback и сертификатом с DNS SAN `localhost`, подписанным новой тестовой CA. Например, в контейнере `osixia/openldap:1.5.0` задайте `LDAP_DOMAIN=example.test`, отключите запрос клиентского сертификата и передайте актуальные тестовые сертификаты. Сертификаты, включённые в старый образ, имеют ограниченный срок действия.

Из каталога `enterprise/management` загрузите файлы в тестовый сервер:

~~~sh
docker exec -i "$ldap_container" ldapadd -Q -Y EXTERNAL -H ldapi:/// < testdata/ldap-schema.ldif
docker exec -i "$ldap_container" ldapadd -x -H ldapi:/// -D 'cn=admin,dc=example,dc=test' -y /path/to/test-password < testdata/ldap-directory.ldif
~~~

Синтетическая учётная запись `cn=reader,dc=example,dc=test` использует пароль из LDIF. Дайте ей право чтения дерева каталога через ACL тестового экземпляра. Для чистого образа выше добавьте ACL перед правилом, которое заканчивается `by * none` для всего дерева, сохранив предшествующее правило `userPassword`. Например:

~~~ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {2}to * by dn.exact="cn=reader,dc=example,dc=test" read by * break
~~~

Задайте `YESDESK_LDAPS_INTEGRATION=1`, `YESDESK_AD_HOST=localhost`, `YESDESK_AD_PORT` (фактический опубликованный порт), `YESDESK_AD_BASE=dc=example,dc=test`, `YESDESK_AD_BIND=cn=reader,dc=example,dc=test`, `YESDESK_AD_CA_FILE`, `YESDESK_AD_PASSWORD_FILE` и `YESDESK_DATABASE_URL_FILE`. Последний файл должен указывать на одноразовый PostgreSQL с базой `yesdesk_enterprise_test`. Тест берёт правила отелей из `ldap-hotels.json`. Запустите `python -m unittest -v test_ad_sync`. Проверка включает намеренный отказ TLS по адресу `127.0.0.1`, которого нет в сертификате.
