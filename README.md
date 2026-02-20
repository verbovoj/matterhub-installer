# MatterHub Tour Installer

Универсальный автоустановщик 3D-туров MatterHub на Linux-серверы.  
**Одна команда — всё работает.**

---

## Быстрая установка (одна команда)

Подключитесь к серверу по SSH от root и выполните:

```bash
curl -sSL https://raw.githubusercontent.com/verbovoj/matterhub-installer/main/scripts/matterhub-installer.sh | sudo bash -s -- --url "ССЫЛКА_НА_АРХИВ"
```

Замените `ССЫЛКА_НА_АРХИВ` на URL вашего .zip файла с туром.

### Примеры

```bash
# Интерактивный режим (скрипт спросит всё сам)
curl -sSL https://raw.githubusercontent.com/verbovoj/matterhub-installer/main/scripts/matterhub-installer.sh | sudo bash

# С указанием URL архива (скрипт спросит куда ставить)
curl -sSL https://raw.githubusercontent.com/verbovoj/matterhub-installer/main/scripts/matterhub-installer.sh | sudo bash -s -- --url "https://example.com/EpfRaivJYbB.zip"

# Полностью автоматически (без вопросов)
curl -sSL https://raw.githubusercontent.com/verbovoj/matterhub-installer/main/scripts/matterhub-installer.sh | sudo bash -s -- --url "https://example.com/tour.zip" --dir /var/www/html/tour --yes
```

---

## Что делает скрипт

1. Проверяет и устанавливает **PHP 8.2** (параллельно существующему PHP — ничего не ломает)
2. Проверяет и устанавливает **ionCube Loader**
3. Определяет веб-сервер (Nginx / Apache) и панель управления
4. Скачивает архив тура по URL
5. Распаковывает в выбранную директорию
6. Настраивает права, FPM-пул, конфиг веб-сервера
7. Проверяет что тур открывается

## Поддерживаемые конфигурации

- **Веб-серверы:** Apache, Nginx, Nginx+Apache (reverse proxy)
- **Панели:** HestiaCP, VestaCP, ISPmanager, cPanel, Plesk, без панели
- **ОС:** Ubuntu/Debian, CentOS/RHEL

## Принцип — изолированная установка

- PHP 8.2 ставится **параллельно** другим версиям
- Отдельный FPM-пул «matterhub» со своим сокетом
- Nginx location только для тура — не трогает другие сайты
- Автоматический **откат** при ошибках

## Требования

- Linux-сервер с root-доступом
- `curl` или `wget` (для скачивания)
- Всё остальное устанавливается автоматически
