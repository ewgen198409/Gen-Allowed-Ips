# 🌐 Gen-Allowed-Ips

Генератор списка `AllowedIPs` для WireGuard на основе доменных имён с использованием RIPE API.

## 📋 Описание

Скрипт автоматически преобразует список доменов в подсети для конфигурации WireGuard VPN. Это полезно для настройки выборочной маршрутизации трафика — только через определённые домены/сервисы проходит через VPN.

### Как это работает

1. 📖 Читает домены из файла `domains.txt`
2. 🔍 Резолвит каждый домен в IP-адреса (с fallback DNS: локальный → 8.8.8.8 → 1.1.1.1 → 78.88.8.8)
3. 🌐 Через RIPE API определяет подсеть для каждого IP
4. 📝 Генерирует список подсетей в формате `CIDR`
5. 💾 Сохраняет результат в двух форматах:
   - `allowed_ips.txt` — построчный список
   - `allowed_ips_wg.txt` — строка через запятую для WireGuard

## 🚀 Быстрый старт

### Требования

- Linux/macOS
- `curl`, `nslookup`, `awk`, `grep`, `sed`
- Доступ к интернету

### Установка

```bash
git clone https://github.com/YOUR_USERNAME/Gen-Allowed-Ips.git
cd Gen-Allowed-Ips
chmod +x gen_allowed_ips.sh
```

### Использование

1. Отредактируйте файл `domains.txt` — добавьте нужные домены (по одному на строку):
   ```
   example.com
   api.example.com
   cdn.example.com
   ```

2. Запустите скрипт:
   ```bash
   ./gen_allowed_ips.sh
   ```

3. Результат будет сохранён в:
   - `allowed_ips.txt` — список подсетей
   - `allowed_ips_wg.txt` — формат для WireGuard

## 📁 Структура файлов

```
Gen-Allowed-Ips/
├── gen_allowed_ips.sh      # Основной скрипт
├── domains.txt             # Входной файл с доменами
├── allowed_ips.txt         # Выходной файл (список)
├── allowed_ips_wg.txt      # Выходной файл (WireGuard формат)
└── allowed_ips_failed.txt  # Домены, которые не удалось резолвить
```

## ⚙️ Функции

### Автоматическое определение IP роутера
Скрипт автоматически определяет LAN IP роутера через:
- `uci get network.lan.ipaddr` (OpenWrt)
- `ip route` (Linux)
- `/proc/net/route` (fallback)

### Поддержка прямых IP и подсетей
В `domains.txt` можно указывать не только домены, но и IP-адреса/подсети:
```
example.com
91.108.4.0/22
149.154.160.0/20
```

### Цепочка DNS с fallback
Порядок резолвинга:
1. Локальный DNS
2. Google DNS (8.8.8.8)
3. Cloudflare DNS (1.1.1.1)
4. Yandex DNS (78.88.8.8)

### Прогресс-бар
Скрипт отображает прогресс выполнения с цветным выводом:
```
[███████████████████████████████████] 100% (50/50) example.com
```

## 📝 Пример конфигурации WireGuard

После выполнения скрипта, используйте сгенерированные данные в конфигурации клиента:

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY
DNS = 192.168.1.1

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = server.example.com:51820
AllowedIPs = 192.168.1.1/32,91.108.4.0/22,91.108.8.0/22,...
```

## 🔧 Настройка

### Изменение DNS серверов

Отредактируйте функцию `resolve_domain()` в скрипте, чтобы изменить порядок DNS серверов:

```bash
for dns in 8.8.8.8 1.1.1.1 78.88.8.8; do
    # ...
done
```

### Изменение таймаутов

- DNS таймаут: настраивается в `nslookup` (по умолчанию системный)
- RIPE API таймаут: `--max-time 5` в функции `get_subnet_for_ip()`

## 📊 Выходные файлы

| Файл | Описание |
|------|----------|
| `allowed_ips.txt` | Список подсетей, по одной на строку |
| `allowed_ips_wg.txt` | Подсети через запятую (для WireGuard) |
| `allowed_ips_failed.txt` | Домены, которые не удалось резолвить |

## 🐛 Отладка

Если возникли проблемы:

1. Проверьте наличие всех зависимостей:
   ```bash
   which curl nslookup awk grep sed
   ```

2. Убедитесь, что файл `domains.txt` существует и не пуст

3. Проверьте доступ к RIPE API:
   ```bash
   curl -s "https://stat.ripe.net/data/prefix-overview/data.json?resource=8.8.8.8"
   ```

## 📄 Лицензия

MIT License

## 🤝 Участие

Pull requests и issues приветствуются!

## ⭐ Поддержка

Если проект был полезен — поставьте звезду на GitHub!