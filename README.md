# MatterHub Export

Универсальный автоустановщик 3D-туров MatterHub на Linux-серверы.

## Скрипт

`scripts/matterhub-installer.sh` — интерактивный установщик v3.0

### Возможности

- Работает на любом Linux-сервере: Apache / Nginx / Nginx+Apache (reverse proxy)
- Поддержка панелей: HestiaCP, VestaCP, ISPmanager, cPanel, Plesk, без панели
- Изолированная установка PHP 8.2 параллельно другим версиям
- ionCube Loader — автоматическая установка
- Отдельный FPM-пул «matterhub» со своим сокетом
- Nginx location только для тура — не трогает другие сайты
- Автоматический откат при ошибках

### Использование

```bash
# Интерактивный режим
sudo bash scripts/matterhub-installer.sh

# С параметрами
sudo bash scripts/matterhub-installer.sh --url https://example.com/tour.zip --dir /var/www/html/tour

# Автоподтверждение (без вопросов)
sudo bash scripts/matterhub-installer.sh --url https://example.com/tour.zip --yes
```

### Требования (на целевом сервере)

- Linux (Ubuntu/Debian, CentOS/RHEL)
- root-доступ
- unzip, wget/curl
- PHP 8.2+ (устанавливается автоматически если нет)
- ionCube Loader (устанавливается автоматически если нет)
