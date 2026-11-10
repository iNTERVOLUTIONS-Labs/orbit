#!/usr/bin/env bash
# orbit firewall lock|unlock y cf-update contra un ufw de mentira con estado.
#   bash tests/firewall_test.sh
#
# Lo que se fija es el orden. 'lock' borraba las reglas abiertas a todos y
# **después** descargaba la lista de Cloudflare: con la descarga caída, 80 y 443
# quedaban cerrados para todo el mundo y todas las webs del servidor fuera, con
# un «Sólo Cloudflare puede llegar» en verde. Salió auditando un servidor de
# verdad antes de usarlo.
#
# El doble de ufw guarda las reglas en un fichero y apunta cada momento en que
# 80/443 no los alcanza nadie: el agujero es eso, y es lo que se cuenta.
#
# shellcheck disable=SC2034  # variables que lee el 'orbit' cargado por lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"

UFW_RULES="$TMP/ufw.rules"   # una regla por línea: <destino>|<origen>|<comentario>
UFW_GAPS="$TMP/ufw.gaps"     # una línea cada vez que nadie llega a la web
UFW_ON="yes"
UFW_DEFAULTS="$TMP/ufw.defaults"; printf 'IPV6=yes\n' > "$UFW_DEFAULTS"

# ¿Llega alguien a 80/443 con estas reglas? Abierto a todos, o algún rango.
_ufw_reachable() { grep -qE '^(80/tcp|443/tcp|80,443/tcp)\|' "$UFW_RULES"; }

ufw() {
  local r
  case "$1" in
    status)
      [[ "$UFW_ON" == yes ]] || { echo "Status: inactive"; return 0; }
      [[ "${2:-}" == numbered ]] || { echo "Status: active"; return 0; }
      echo "Status: active"; echo
      echo "     To                         Action      From"
      echo "     --                         ------      ----"
      local n=0 to from c
      while IFS='|' read -r to from c; do
        n=$((n + 1))
        printf '[%2d] %-26s ALLOW IN    %-26s %s\n' "$n" "$to" "$from" "${c:+# $c}"
      done < "$UFW_RULES" ;;
    allow)
      if [[ "$2" == proto ]]; then   # allow proto tcp from IP to any port 80,443 comment X
        r="80,443/tcp|$5|${11}"
      else                           # allow 80/tcp
        r="$2|Anywhere|"
      fi
      grep -qxF "$r" "$UFW_RULES" || echo "$r" >> "$UFW_RULES" ;;
    --force)
      shift
      if [[ "$2" == allow ]]; then   # delete allow 80/tcp
        grep -vxF "$3|Anywhere|" "$UFW_RULES" > "$UFW_RULES.n"; mv "$UFW_RULES.n" "$UFW_RULES"
      else                           # delete <n>
        sed -i "${2}d" "$UFW_RULES"
      fi ;;
    reload) : ;;
  esac
  _ufw_reachable || echo "hueco tras: ufw $*" >> "$UFW_GAPS"
  return 0
}

V4="$(printf '173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n190.93.240.0/20\n188.114.96.0/20\n197.234.240.0/22\n198.41.128.0/17\n162.158.0.0/15\n104.16.0.0/13\n104.24.0.0/14\n172.64.0.0/13\n131.0.72.0/22')"
V6="$(printf '2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n2405:b500::/32\n2405:8100::/32\n2a06:98c0::/29\n2c0f:f248::/32')"
CURL_MODE="ok"
curl() {
  local url="${*: -1}"
  case "$CURL_MODE" in
    down) return 22 ;;
    html) echo "<html>portal cautivo</html>"; return 0 ;;
  esac
  case "$url" in
    *ips-v4) printf '%s\n' "$V4" ;;
    *ips-v6) printf '%s\n' "$V6" ;;
  esac
}
nginx() { :; }
systemctl() { :; }

fresh() { printf '22/tcp|Anywhere|SSH\n80/tcp|Anywhere|\n443/tcp|Anywhere|\n' > "$UFW_RULES"; : > "$UFW_GAPS"; }
n_cf() { grep -c '|Cloudflare$' "$UFW_RULES"; }

section "lock con la descarga caída no toca nada"
fresh; CURL_MODE="down"
run cmd_firewall lock >/dev/null 2>&1; check "lock falla" "1" "$?"
check "80 sigue abierto"    "1" "$(grep -c '^80/tcp|Anywhere' "$UFW_RULES")"
check "443 sigue abierto"   "1" "$(grep -c '^443/tcp|Anywhere' "$UFW_RULES")"
check "sin huecos"          "0" "$(grep -c . "$UFW_GAPS")"

section "Una página que no es la lista tampoco"
fresh; CURL_MODE="html"
run cmd_firewall lock >/dev/null 2>&1; check "lock falla" "1" "$?"
check "80 sigue abierto"    "1" "$(grep -c '^80/tcp|Anywhere' "$UFW_RULES")"
check "ni una regla nueva"  "0" "$(n_cf)"

section "lock bueno: Cloudflare entra antes de que salga el mundo"
fresh; CURL_MODE="ok"
run cmd_firewall lock >/dev/null 2>&1; check "lock sale con 0" "0" "$?"
check "22 rangos"           "22" "$(n_cf)"
check "80 ya no abierto"    "0" "$(grep -c '^80/tcp|Anywhere' "$UFW_RULES")"
check "443 ya no abierto"   "0" "$(grep -c '^443/tcp|Anywhere' "$UFW_RULES")"
check "SSH intacto"         "1" "$(grep -c '^22/tcp' "$UFW_RULES")"
check "sin huecos"          "0" "$(grep -c . "$UFW_GAPS")"
run _fw_locked; check "se ve bloqueado" "0" "$?"

section "Repetir lock no duplica"
run cmd_firewall lock >/dev/null 2>&1
check "siguen 22"           "22" "$(n_cf)"

section "cf-update quita el rango que Cloudflare retira y añade el nuevo"
V4="$(sed '1d' <<<"$V4"; echo '198.51.100.0/22')"
: > "$UFW_GAPS"
cmd_cf_update >/dev/null 2>&1
check "siguen 22"           "22" "$(n_cf)"
check "el retirado, fuera"  "0" "$(grep -c '173.245.48.0/20' "$UFW_RULES")"
check "el nuevo, dentro"    "1" "$(grep -c '198.51.100.0/22' "$UFW_RULES")"
check "sin huecos"          "0" "$(grep -c . "$UFW_GAPS")"

section "cf-update con la descarga caída deja el firewall como estaba"
before="$(cat "$UFW_RULES")"; CURL_MODE="down"
cmd_cf_update >/dev/null 2>&1
check "reglas iguales"      "yes" "$([[ "$(cat "$UFW_RULES")" == "$before" ]] && echo yes || echo no)"

section "unlock abre antes de quitar"
CURL_MODE="ok"; : > "$UFW_GAPS"
run cmd_firewall unlock >/dev/null 2>&1; check "unlock sale con 0" "0" "$?"
check "sin reglas de CF"    "0" "$(n_cf)"
check "80 abierto"          "1" "$(grep -c '^80/tcp|Anywhere' "$UFW_RULES")"
check "sin huecos"          "0" "$(grep -c . "$UFW_GAPS")"
run _fw_locked; check "ya no bloqueado" "1" "$?"

section "cf-update sin bloquear no crea reglas"
cmd_cf_update >/dev/null 2>&1
check "ninguna de CF"       "0" "$(n_cf)"

section "Una regla tuya que nombra a Cloudflare no se toca"
# Un 22 para Cloudflare Access, por ejemplo. Con un grep de «Cloudflare» a
# secas, cada lock y cada cf-update la borraban: sin SSH.
fresh; printf '22/tcp|10.0.0.0/8|Cloudflare Access SSH\n' >> "$UFW_RULES"
run cmd_firewall lock >/dev/null 2>&1
check "lock la deja"        "1" "$(grep -c 'Cloudflare Access SSH' "$UFW_RULES")"
cmd_cf_update >/dev/null 2>&1
check "cf-update la deja"   "1" "$(grep -c 'Cloudflare Access SSH' "$UFW_RULES")"
run cmd_firewall unlock >/dev/null 2>&1
check "unlock la deja"      "1" "$(grep -c 'Cloudflare Access SSH' "$UFW_RULES")"

section "Con ufw apagado, lock no se anuncia como hecho"
fresh; UFW_ON="no"
run cmd_firewall lock >/dev/null 2>&1; check "lock falla"   "1" "$?"
check "ni una regla nueva"  "0" "$(n_cf)"
cmd_cf_update >/dev/null 2>&1
check "cf-update no añade"  "0" "$(n_cf)"
UFW_ON="yes"

section "Con IPv6 apagado en ufw, sólo los rangos IPv4"
fresh; printf 'IPV6=no\n' > "$UFW_DEFAULTS"
run cmd_firewall lock >/dev/null 2>&1; check "lock sale con 0" "0" "$?"
check "sólo los 15 IPv4"    "15" "$(n_cf)"
check "ninguno IPv6"        "0" "$(grep '|Cloudflare$' "$UFW_RULES" | grep -c ':')"
printf 'IPV6=yes\n' > "$UFW_DEFAULTS"

report
