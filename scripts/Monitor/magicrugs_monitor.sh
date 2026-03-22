#!/bin/bash

# ============================================================
# magicrugs.com — 48-Hour Traffic Monitor & Auto-Block
# Executed via GitHub Actions on EC2 instance
# Report saved to /var/log/magicrugs-monitor/
# Window: last 48 hours to current time (dynamic, no fixed dates)
# ============================================================

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
NGINX_LOG="/var/log/nginx/access.log"
NGINX_ERROR_LOG="/var/log/nginx/error.log"
REPORT_DIR="/var/log/magicrugs-monitor"
BLOCK_FILE="/etc/nginx/conf.d/blocked-ips.conf"
WHITELIST_IPS=("18.206.107.28" "127.0.0.1" "::1")
AUTO_BLOCK_THRESHOLD=50      # min total requests for IP to be considered
DEV_EMAIL="raghavendra.guptha@gmail.com"
SITE="magicrugs.com"
DAYS=2                       # 48 hours = 2 days
# ─────────────────────────────────────────────
# Auto-block formula:
#   - IP must have >= AUTO_BLOCK_THRESHOLD total requests (minimum activity)
#   - IP must have >= 10 error requests (minimum confirmed errors)
#   - 80%+ of that IP's requests must be 4xx or 5xx errors
# ─────────────────────────────────────────────

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$REPORT_DIR"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
DATE_TAG=$(date '+%Y%m%d_%H%M')
REPORT_FILE="$REPORT_DIR/monitor_report_$DATE_TAG.txt"
START_DATE=$(date -d "$DAYS days ago" '+%Y-%m-%d' 2>/dev/null || date -v-${DAYS}d '+%Y-%m-%d')
END_DATE=$(date '+%Y-%m-%d')

echo -e "${BLUE}[magicrugs monitor]${NC} Window: $START_DATE to $END_DATE (48 hours)"

# ─────────────────────────────────────────────
# BUILD DATE PATTERNS — last 48 hours dynamically
# ─────────────────────────────────────────────
DATE_PATTERNS=""
for i in $(seq 0 $((DAYS-1))); do
    D=$(date -d "$i days ago" '+%d/%b/%Y' 2>/dev/null || date -v-${i}d '+%d/%b/%Y')
    DATE_PATTERNS="${DATE_PATTERNS}${D}\|"
done
DATE_PATTERNS=$(echo "$DATE_PATTERNS" | sed 's/\\|$//')

# Filter logs
WEEK_LOGS=$(grep -E "$DATE_PATTERNS" "$NGINX_LOG" 2>/dev/null)

# Check rotated gz logs too
if [ -z "$WEEK_LOGS" ]; then
    for GZ in /var/log/nginx/access.log.*.gz; do
        [ -f "$GZ" ] && WEEK_LOGS="$WEEK_LOGS$(zcat "$GZ" 2>/dev/null | grep -E "$DATE_PATTERNS")"
    done
fi

# Final fallback
[ -z "$WEEK_LOGS" ] && WEEK_LOGS=$(cat "$NGINX_LOG" 2>/dev/null)

WEEK_ERROR_LOGS=$(grep -E "$DATE_PATTERNS" "$NGINX_ERROR_LOG" 2>/dev/null)

echo -e "${BLUE}[magicrugs monitor]${NC} Processing $(echo "$WEEK_LOGS" | wc -l) log entries"

# ─────────────────────────────────────────────
# COUNTS
# ─────────────────────────────────────────────
TOTAL=$(echo "$WEEK_LOGS" | wc -l)
C_2XX=$(echo "$WEEK_LOGS" | grep -c '" 2[0-9][0-9] ')
C_404=$(echo "$WEEK_LOGS" | grep -c '" 404 ')
C_400=$(echo "$WEEK_LOGS" | grep -c '" 400 ')
C_403=$(echo "$WEEK_LOGS" | grep -c '" 403 ')
C_429=$(echo "$WEEK_LOGS" | grep -c '" 429 ')
C_500=$(echo "$WEEK_LOGS" | grep -c '" 500 ')
C_502=$(echo "$WEEK_LOGS" | grep -c '" 502 ')
C_503=$(echo "$WEEK_LOGS" | grep -c '" 503 ')
C_DELETED=$(echo "$WEEK_LOGS" | grep '" 404 ' | grep -c '/all-rugs/')
C_STORAGE=$(echo "$WEEK_LOGS" | grep '" 404 ' | grep -c '/storage/')
C_HTML=$(echo "$WEEK_LOGS" | grep '" 404 ' | grep -c '\.html')
C_BOTS=$(echo "$WEEK_LOGS" | grep -ci 'bot\|crawler\|spider')
C_VPN=$(echo "$WEEK_LOGS" | grep -cE 'global-protect|ssl-vpn|dana-na|myvpn|vpntunnel|sra_')

# Daily breakdown
DAILY_BREAKDOWN=""
for i in $(seq $((DAYS-1)) -1 0); do
    D=$(date -d "$i days ago" '+%d/%b/%Y' 2>/dev/null || date -v-${i}d '+%d/%b/%Y')
    D_LABEL=$(date -d "$i days ago" '+%Y-%m-%d (%A)' 2>/dev/null || date -v-${i}d '+%Y-%m-%d')
    D_TOTAL=$(echo "$WEEK_LOGS" | grep "$D" | wc -l)
    D_404=$(echo "$WEEK_LOGS" | grep "$D" | grep -c '" 404 ')
    D_500=$(echo "$WEEK_LOGS" | grep "$D" | grep -c '" 500 ')
    D_BOTS=$(echo "$WEEK_LOGS" | grep "$D" | grep -ci 'bot\|crawler')
    DAILY_BREAKDOWN="$DAILY_BREAKDOWN\n  $D_LABEL  |  Requests: $D_TOTAL  |  404: $D_404  |  500: $D_500  |  Bots: $D_BOTS"
done

# Server health
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "N/A")
MEM=$(free -m | awk 'NR==2{printf "%.1f%%", $3*100/$2}' 2>/dev/null || echo "N/A")
DISK=$(df -h /var/www/html | awk 'NR==2{print $5}' 2>/dev/null || echo "N/A")
PHP_STATUS=$(systemctl status php-fpm 2>/dev/null | grep "Status:" | sed 's/.*Status: //')
PHP_SLOW=$(systemctl status php-fpm 2>/dev/null | grep -o 'slow: [0-9]*' | head -1 || echo "slow: 0")

# ─────────────────────────────────────────────
# SECTION DATA
# ─────────────────────────────────────────────
SEC1=$(echo "$WEEK_LOGS" | grep '" 404 ' | grep '/all-rugs/' | awk '{print $7}' | sort | uniq -c | sort -rn | head -50)
SEC2=$(echo "$WEEK_LOGS" | grep '" 404 ' | grep '/storage/' | awk '{print $7}' | sort | uniq -c | sort -rn | head -50)
SEC3=$(echo "$WEEK_LOGS" | grep '" 404 ' | awk '{print $7}' | sort | uniq -c | sort -rn | head -50)
SEC4=$(echo "$WEEK_LOGS" | grep '" 400 ' | awk '{print $7}' | sort | uniq -c | sort -rn | head -30)
SEC5=$(echo "$WEEK_LOGS" | grep '" 5[0-9][0-9] ' | awk '{print $4, $7, $9}' | sort | uniq -c | sort -rn | head -30)
SEC6=$(echo "$WEEK_LOGS" | grep '" [45][0-9][0-9] ' | grep -i 'bot\|crawler\|spider\|python\|urllib' | awk -F'"' '{print $6}' | sort | uniq -c | sort -rn | head -25)
SEC7=$(echo "$WEEK_LOGS" | grep '" [45][0-9][0-9] ' | awk '{print $1}' | sort | uniq -c | sort -rn | head -25)
SEC8=$(echo "$WEEK_LOGS" | grep -iE 'global-protect|ssl-vpn|dana-na|myvpn|vpntunnel|sra_|\.env|\.git|phpMyAdmin|eval\(|base64_decode|union.*select|/etc/passwd|shell\.php|webshell|wp-login\.php|xmlrpc' | awk '{print $1, $7}' | sort | uniq -c | sort -rn | head -30)
SEC9=$(echo "$WEEK_ERROR_LOGS" | grep '\[error\]' | grep -oE 'open\(\).*failed \(.*\)|upstream.*failed|connect\(\) failed' | sort | uniq -c | sort -rn | head -20)
SEC10=$(echo "$WEEK_LOGS" | grep '" 404 ' | grep '\.html' | awk '{print $7}' | sort | uniq -c | sort -rn | head -30)
SEC11=$(echo "$WEEK_LOGS" | grep '" [45][0-9][0-9] ' | awk -F'"' '{print $6}' | sort | uniq -c | sort -rn | head -20)

# ─────────────────────────────────────────────
# AUTO-BLOCK — 80% ERROR RATE
# ─────────────────────────────────────────────
BLOCKED_IPS=()
NEW_BLOCKS=""

ALL_IPS=$(echo "$WEEK_LOGS" | awk '{print $1}' | sort | uniq -c | sort -rn | head -50)

while IFS= read -r line; do
    TOTAL=$(echo "$line" | awk '{print $1}')
    IP=$(echo "$line" | awk '{print $2}')
    [ -z "$IP" ] && continue

    [ "$TOTAL" -lt "$AUTO_BLOCK_THRESHOLD" ] && continue

    SKIP=0
    for WHITE in "${WHITELIST_IPS[@]}"; do
        [ "$IP" = "$WHITE" ] && SKIP=1 && break
    done
    [ $SKIP -eq 1 ] && continue

    echo "$IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' && continue

    ERROR_COUNT=$(echo "$WEEK_LOGS" | grep "$IP" | grep -c '" [45][0-9][0-9] ')
    
    if [ "$TOTAL" -gt 0 ]; then
        ERROR_PCT=$((ERROR_COUNT * 100 / TOTAL))
    else
        ERROR_PCT=0
    fi

    if [ "$ERROR_PCT" -ge 80 ] && [ "$ERROR_COUNT" -ge 10 ]; then
        BLOCKED_IPS+=("$IP — $ERROR_COUNT/$TOTAL errors ($ERROR_PCT%)")
        if [ -f "$BLOCK_FILE" ] && ! grep -q "$IP" "$BLOCK_FILE" 2>/dev/null; then
            echo "deny $IP;  # auto-blocked $(date '+%Y-%m-%d %H:%M') — $ERROR_COUNT/$TOTAL errors ($ERROR_PCT%)" >> "$BLOCK_FILE"
            NEW_BLOCKS="$NEW_BLOCKS\n  $IP — $ERROR_COUNT/$TOTAL ($ERROR_PCT%) — NEWLY BLOCKED"
        fi
    fi
done <<< "$ALL_IPS"

[ -n "$NEW_BLOCKS" ] && nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null && echo -e "${RED}[AUTO-BLOCK]${NC} IPs blocked, nginx reloaded"

# Alert level
ALERT="OK"; ALERT_SYMBOL="✅"
[ "$C_500" -gt 20 ] || [ "$C_503" -gt 10 ] && ALERT="CRITICAL" && ALERT_SYMBOL="🔴"
[ "$C_VPN" -gt 5 ] && ALERT="SECURITY ALERT" && ALERT_SYMBOL="🚨"
[ "$C_404" -gt 200 ] && ALERT="WARNING" && ALERT_SYMBOL="🟡"

# ─────────────────────────────────────────────
# WRITE REPORT
# ─────────────────────────────────────────────
cat > "$REPORT_FILE" << REPORT
====================================================================
  $ALERT_SYMBOL  $SITE — 48-HOUR TRAFFIC & ERROR REPORT
  Status     : $ALERT
  Generated  : $NOW
  Window     : Last 48 hours ($START_DATE  to  $END_DATE)
  Report     : $REPORT_FILE
====================================================================

SUMMARY
═══════════════════════════════════════════════════════════════════
  Total Requests      : $TOTAL
  Successful (2xx)    : $C_2XX
  ─── Client Errors (4xx) ───────────────────────────────────────
  404 Not Found       : $C_404
  400 Bad Request     : $C_400
  403 Forbidden       : $C_403
  429 Too Many Reqs   : $C_429
  ─── Server Errors (5xx) ───────────────────────────────────────
  500 Server Error    : $C_500
  502 Bad Gateway     : $C_502
  503 Unavailable     : $C_503
  ─── Specific Issues ───────────────────────────────────────────
  Deleted Products    : $C_DELETED   (/all-rugs/* 404s)
  Missing Images      : $C_STORAGE   (/storage/* 404s)
  Fake HTML URLs      : $C_HTML      (*.html bot hits)
  Bot Requests        : $C_BOTS
  VPN/Exploit Probes  : $C_VPN
  ─── Server Health (current) ───────────────────────────────────
  CPU Usage           : $CPU%
  Memory Usage        : $MEM
  Disk Usage          : $DISK
  PHP-FPM             : $PHP_STATUS
  PHP Slow Requests   : $PHP_SLOW

====================================================================
HOURLY BREAKDOWN — Last 48 Hours
═══════════════════════════════════════════════════════════════════
  Date                    Requests   404    500    Bots
  ─────────────────────────────────────────────────────
$(echo -e "$DAILY_BREAKDOWN")

====================================================================
AUTO-BLOCKED IPs THIS RUN
  Threshold : 80%+ error rate, minimum 50 total requests, 10+ errors
═══════════════════════════════════════════════════════════════════
$(if [ ${#BLOCKED_IPS[@]} -eq 0 ]; then echo "  No IPs auto-blocked"; else printf '  %s\n' "${BLOCKED_IPS[@]}"; fi)
$([ -n "$NEW_BLOCKS" ] && echo -e "$NEW_BLOCKS")

====================================================================
SECTION 1 — DELETED PRODUCT URLs  [DEV FIX REQUIRED]
  Fix : add 301 redirect in Laravel Handler.php for /all-rugs/*
  Impact : $C_DELETED wasted PHP renders in 48 hours
═══════════════════════════════════════════════════════════════════
Count  URL
─────────────────────────────────────────────────────────────────
$([ -z "$SEC1" ] && echo "  None — great!" || echo "$SEC1")

====================================================================
SECTION 2 — MISSING STORAGE IMAGES  [DEV FIX REQUIRED]
  Fix : check S3 sync and file upload pipeline
  Impact : $C_STORAGE wasted 404 responses in 48 hours
═══════════════════════════════════════════════════════════════════
Count  URL
─────────────────────────────────────────────────────────────────
$([ -z "$SEC2" ] && echo "  None this period" || echo "$SEC2")

====================================================================
SECTION 3 — ALL 404 URLs RANKED BY FREQUENCY
═══════════════════════════════════════════════════════════════════
Count  URL
─────────────────────────────────────────────────────────────────
$([ -z "$SEC3" ] && echo "  No 404 errors" || echo "$SEC3")

====================================================================
SECTION 4 — 400 BAD REQUEST ERRORS
═══════════════════════════════════════════════════════════════════
Count  URL
─────────────────────────────────────────────────────────────────
$([ -z "$SEC4" ] && echo "  No 400 errors" || echo "$SEC4")

====================================================================
SECTION 5 — 500 SERVER ERRORS  [CRITICAL — CHECK IMMEDIATELY]
═══════════════════════════════════════════════════════════════════
Count  Date                   URL                         Status
─────────────────────────────────────────────────────────────────
$([ -z "$SEC5" ] && echo "  No 500 errors — good!" || echo "$SEC5")

====================================================================
SECTION 6 — BOT REQUESTS CAUSING ERRORS
═══════════════════════════════════════════════════════════════════
Count  Bot User Agent
─────────────────────────────────────────────────────────────────
$([ -z "$SEC6" ] && echo "  No bot errors" || echo "$SEC6")

====================================================================
SECTION 7 — TOP IPs WITH ERRORS  [POTENTIAL ATTACKERS]
  Auto-block: 80%+ errors, min 50 requests, min 10 errors
═══════════════════════════════════════════════════════════════════
Count  IP Address
─────────────────────────────────────────────────────────────────
$([ -z "$SEC7" ] && echo "  No suspicious IPs" || echo "$SEC7")

====================================================================
SECTION 8 — VULNERABILITY PROBES & ATTACK ATTEMPTS
═══════════════════════════════════════════════════════════════════
Count  IP Address      URL Probed
─────────────────────────────────────────────────────────────────
$([ -z "$SEC8" ] && echo "  No vulnerability probes — good!" || echo "$SEC8")

====================================================================
SECTION 9 — NGINX INTERNAL ERRORS
═══════════════════════════════════════════════════════════════════
$([ -z "$SEC9" ] && echo "  No nginx errors" || echo "$SEC9")

====================================================================
SECTION 10 — FAKE HTML URLs  [BOT SEO CRAWL WASTE]
  Cloudflare WAF block rule should be catching these
═══════════════════════════════════════════════════════════════════
Count  URL
─────────────────────────────────────────────────────────────────
$([ -z "$SEC10" ] && echo "  None — Cloudflare blocking working!" || echo "$SEC10")

====================================================================
SECTION 11 — TOP USER AGENTS CAUSING ERRORS
═══════════════════════════════════════════════════════════════════
Count  User Agent
─────────────────────────────────────────────────────────────────
$([ -z "$SEC11" ] && echo "  None" || echo "$SEC11")

====================================================================
  Report file : $REPORT_FILE
  All reports : ls $REPORT_DIR/
  View report : cat $REPORT_FILE
====================================================================
REPORT

# Email report
SUBJECT="$ALERT_SYMBOL [$ALERT] $SITE | 404:$C_404 500:$C_500 Bots:$C_BOTS | Last 48h"
if command -v mail &>/dev/null; then
    mail -s "$SUBJECT" "$DEV_EMAIL" < "$REPORT_FILE"
    echo -e "${GREEN}[EMAIL]${NC} Sent to $DEV_EMAIL"
elif command -v sendmail &>/dev/null; then
    { echo "To: $DEV_EMAIL"; echo "Subject: $SUBJECT"; echo ""; cat "$REPORT_FILE"; } | sendmail -t
    echo -e "${GREEN}[EMAIL]${NC} Sent via sendmail"
else
    echo -e "${YELLOW}[EMAIL]${NC} No mail command available"
fi

# Cleanup — keep last 20 reports
ls -t "$REPORT_DIR"/monitor_report_*.txt 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null

# Terminal summary
echo ""
echo -e "${BLUE}════════════════════════════════════════════════${NC}"
echo -e "  $ALERT_SYMBOL  Status      : ${RED}$ALERT${NC}"
echo -e "  Window      : $START_DATE → $END_DATE (48 hours)"
echo -e "  Total Req   : $TOTAL"
echo -e "  404 Errors  : $C_404"
echo -e "  500 Errors  : $C_500"
echo -e "  VPN Probes  : $C_VPN"
echo -e "  Bots        : $C_BOTS"
echo -e "  Blocked IPs : ${#BLOCKED_IPS[@]}"
echo -e "  CPU Now     : $CPU%"
echo -e "  Report      : $REPORT_FILE"
echo -e "${BLUE}════════════════════════════════════════════════${NC}"

exit 0