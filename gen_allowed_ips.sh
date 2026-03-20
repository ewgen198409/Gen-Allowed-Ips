#!/bin/sh

# ─── Пути (относительно расположения скрипта) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAINS_FILE="$SCRIPT_DIR/domains.txt"
OUTPUT_FILE="$SCRIPT_DIR/allowed_ips.txt"
OUTPUT_WG_FILE="$SCRIPT_DIR/allowed_ips_wg.txt"
FAILED_FILE="$SCRIPT_DIR/allowed_ips_failed.txt"

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Проверка файла доменов ───────────────────────────────────────────────────
if [ ! -f "$DOMAINS_FILE" ]; then
    printf "${RED}Error: domains file not found: ${DOMAINS_FILE}${NC}\n"
    exit 1
fi

# ─── Определение IP роутера (LAN) ────────────────────────────────────────────
detect_router_ip() {
    local ip=""
    ip=$(uci get network.lan.ipaddr 2>/dev/null)
    [ -n "$ip" ] && echo "$ip" && return
    ip=$(ip route | awk '/default/{print $3; exit}')
    [ -n "$ip" ] && echo "$ip" && return
    ip=$(awk 'NR>1 && $2=="00000000"{
        h=$3
        printf "%d.%d.%d.%d\n",
            strtonum("0x"substr(h,7,2)),
            strtonum("0x"substr(h,5,2)),
            strtonum("0x"substr(h,3,2)),
            strtonum("0x"substr(h,1,2))
        exit
    }' /proc/net/route 2>/dev/null)
    [ -n "$ip" ] && echo "$ip" && return
    echo ""
}

# ─── Резолвинг домена с fallback DNS ─────────────────────────────────────────
# Порядок: локальный → 8.8.8.8 → 1.1.1.1 → 78.88.8.8
DNS_TMP="/tmp/.last_dns_$$"

resolve_domain() {
    local domain="$1"
    local ips=""

    # Локальный DNS
    ips=$(nslookup "$domain" 2>/dev/null \
        | awk '/^Address: /{print $2}' \
        | grep -v ':' \
        | head -2)
    if [ -n "$ips" ]; then
        echo "local" > "$DNS_TMP"
        echo "$ips"
        return
    fi

    # Fallback серверы
    for dns in 8.8.8.8 1.1.1.1 78.88.8.8; do
        ips=$(nslookup "$domain" "$dns" 2>/dev/null \
            | awk '/^Address: /{print $2}' \
            | grep -v ':' \
            | head -2)
        if [ -n "$ips" ]; then
            echo "$dns" > "$DNS_TMP"
            echo "$ips"
            return
        fi
    done

    echo "" > "$DNS_TMP"
    echo ""
}

# ─── Разделяем домены и подсети из файла ─────────────────────────────────────
DIRECT_SUBNETS=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$DOMAINS_FILE")
DOMAINS=$(grep -E '^[a-zA-Z]' "$DOMAINS_FILE")

TOTAL=$(echo "$DOMAINS" | grep -c .)
DIRECT_COUNT=$(echo "$DIRECT_SUBNETS" | grep -c .)
CURRENT=0

# ─── Прогресс бар ────────────────────────────────────────────────────────────
progress_bar() {
    local current=$1
    local total=$2
    local domain=$3
    local width=35
    local pct=$((current * 100 / total))
    local filled=$((current * width / total))
    local i=0
    local bar=""
    while [ $i -lt $filled ]; do bar="${bar}█"; i=$((i+1)); done
    while [ $i -lt $width ];  do bar="${bar}░"; i=$((i+1)); done
    # Очищаем всю строку перед перерисовкой
    printf "\r\033[2K${CYAN}[${GREEN}%s${CYAN}]${NC} ${BOLD}%3d%%${NC} ${DIM}(%d/%d)${NC} ${YELLOW}%-45s${NC}" \
        "$bar" "$pct" "$current" "$total" "$domain"
}

# ─── RIPE lookup ─────────────────────────────────────────────────────────────
get_subnet_for_ip() {
    local ip="$1"
    curl -s --max-time 5 \
        "https://stat.ripe.net/data/prefix-overview/data.json?resource=${ip}" \
        | grep -o '"resource":"[0-9./]*"' \
        | sed 's/"resource":"//;s/"//'
}

# ─── Шапка ───────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}\n"
printf "${BOLD}${BLUE}║     AllowedIPs Generator via RIPE API        ║${NC}\n"
printf "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}\n"
echo ""
printf "${DIM}Domains file:         ${BOLD}${DOMAINS_FILE}${NC}\n"
printf "${DIM}Domains to resolve:   ${BOLD}${TOTAL}${NC}\n"
printf "${DIM}Direct subnets/IPs:   ${BOLD}${DIRECT_COUNT}${NC}\n"
printf "${DIM}Output file:          ${BOLD}${OUTPUT_FILE}${NC}\n"
printf "${DIM}WG config file:       ${BOLD}${OUTPUT_WG_FILE}${NC}\n"
printf "${DIM}DNS fallback chain:   ${BOLD}local → 8.8.8.8 → 1.1.1.1 → 78.88.8.8${NC}\n"
echo ""

# ─── Определяем IP роутера ───────────────────────────────────────────────────
printf "${DIM}Detecting router DNS IP...${NC} "
ROUTER_IP=$(detect_router_ip)

if [ -n "$ROUTER_IP" ]; then
    printf "${GREEN}✓ ${BOLD}${ROUTER_IP}${NC}\n"
else
    printf "${YELLOW}⚠ Could not detect automatically${NC}\n"
    printf "${YELLOW}Enter router LAN IP manually: ${NC}"
    read ROUTER_IP
fi

echo ""

# ─── Очищаем старые tmp файлы ────────────────────────────────────────────────
rm -f "$OUTPUT_FILE.tmp" "$FAILED_FILE.tmp"

# ─── Добавляем IP роутера ────────────────────────────────────────────────────
echo "${ROUTER_IP}/32" >> "$OUTPUT_FILE.tmp"

# ─── Переносим прямые подсети/IP из файла ────────────────────────────────────
if [ -n "$DIRECT_SUBNETS" ]; then
    printf "${DIM}Adding direct subnets/IPs...${NC}\n"
    echo "$DIRECT_SUBNETS" | while read subnet; do
        [ -z "$subnet" ] && continue
        echo "$subnet" | grep -q '/' || subnet="${subnet}/32"
        grep -qF "$subnet" "$OUTPUT_FILE.tmp" 2>/dev/null || echo "$subnet" >> "$OUTPUT_FILE.tmp"
        printf "  ${GREEN}✓${NC} ${CYAN}${subnet}${NC}\n"
    done
    echo ""
fi

# ─── Основной цикл резолвинга доменов ────────────────────────────────────────
echo "$DOMAINS" | while read domain; do
    [ -z "$domain" ] && continue

    CURRENT=$((CURRENT + 1))
    progress_bar "$CURRENT" "$TOTAL" "$domain"

    ips=$(resolve_domain "$domain")
    LAST_DNS=$(cat "$DNS_TMP" 2>/dev/null)

    # Показываем DNS метку после прогресс бара
    if [ -n "$LAST_DNS" ]; then
        if [ "$LAST_DNS" = "local" ]; then
            printf " ${DIM}[DNS: local]${NC}"
        else
            printf " ${YELLOW}[DNS: ${LAST_DNS}]${NC}"
        fi
    fi

    if [ -z "$ips" ]; then
        echo "$domain" >> "$FAILED_FILE.tmp"
        continue
    fi

    found=0
    for ip in $ips; do
        subnets=$(get_subnet_for_ip "$ip")
        if [ -n "$subnets" ]; then
            echo "$subnets" | while read subnet; do
                echo "$subnet" | grep -qE '^[0-9]' || continue
                grep -qF "$subnet" "$OUTPUT_FILE.tmp" 2>/dev/null || echo "$subnet" >> "$OUTPUT_FILE.tmp"
            done
            found=1
        fi
        sleep 0.3
    done

    if [ $found -eq 0 ]; then
        echo "$domain" >> "$FAILED_FILE.tmp"
    fi
done

echo ""
echo ""

# ─── Финализация ─────────────────────────────────────────────────────────────
rm -f "$DNS_TMP" 
if [ -f "$OUTPUT_FILE.tmp" ]; then
    sort -u "$OUTPUT_FILE.tmp" > "$OUTPUT_FILE"
    rm "$OUTPUT_FILE.tmp"
fi

if [ -f "$FAILED_FILE.tmp" ]; then
    sort -u "$FAILED_FILE.tmp" > "$FAILED_FILE"
    rm "$FAILED_FILE.tmp"
fi

# Сохраняем WG формат (одна строка через запятую)
tr '\n' ',' < "$OUTPUT_FILE" | sed 's/,$//' > "$OUTPUT_WG_FILE"

UNIQUE=$(wc -l < "$OUTPUT_FILE" 2>/dev/null || echo 0)

printf "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}\n"
printf "${BOLD}${GREEN}║                   Готово!                    ║${NC}\n"
printf "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}\n"
echo ""
printf "${GREEN}✓${NC} Router DNS IP added: ${BOLD}${ROUTER_IP}/32${NC}\n"
printf "${GREEN}✓${NC} Unique subnets:      ${BOLD}${UNIQUE}${NC}\n"
printf "${GREEN}✓${NC} List saved to:       ${BOLD}${OUTPUT_FILE}${NC}\n"
printf "${GREEN}✓${NC} WG format saved to:  ${BOLD}${OUTPUT_WG_FILE}${NC}\n"

# ─── Провалившиеся домены ────────────────────────────────────────────────────
if [ -f "$FAILED_FILE" ] && [ -s "$FAILED_FILE" ]; then
    FAILED_COUNT=$(wc -l < "$FAILED_FILE")
    echo ""
    printf "${RED}╔══════════════════════════════════════════════╗${NC}\n"
    printf "${RED}║       Failed domains (%-3d)                   ║${NC}\n" "$FAILED_COUNT"
    printf "${RED}╚══════════════════════════════════════════════╝${NC}\n"
    while read d; do
        printf "  ${RED}✗${NC} ${d}\n"
    done < "$FAILED_FILE"
    printf "\n${DIM}Failed list saved to: ${FAILED_FILE}${NC}\n"
fi

# ─── Превью результата ───────────────────────────────────────────────────────
echo ""
printf "${DIM}AllowedIPs preview (first 3):${NC}\n"
head -3 "$OUTPUT_FILE" | while read s; do
    printf "  ${CYAN}→${NC} ${s}\n"
done
printf "  ${DIM}... and $((UNIQUE - 3)) more${NC}\n"
echo ""

# ─── Подсказка для конфига клиента ───────────────────────────────────────────
printf "${BOLD}Client config:${NC}\n"
printf "  ${CYAN}DNS = ${ROUTER_IP}${NC}\n"
printf "  ${CYAN}AllowedIPs = $(cat "$OUTPUT_WG_FILE")${NC}\n"
echo ""
