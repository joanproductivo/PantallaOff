#!/bin/bash
#
# PantallaOff — instalador de un clic.
#
# Doble clic en Finder y ya está: comprueba las herramientas necesarias,
# compila, instala en /Applications y abre la app.
#
# La extensión .command es lo que hace que Finder lo ejecute en una ventana de
# Terminal al hacer doble clic. No hace falta escribir nada.

set -uo pipefail

# Finder lanza el script desde cualquier directorio; nos movemos al del repo.
cd "$(dirname "$0")" || exit 1

bold=$'\033[1m'; green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; off=$'\033[0m'

say()  { printf "%s\n" "$*"; }
ok()   { printf "%s✓%s %s\n" "$green" "$off" "$*"; }
warn() { printf "%s!%s %s\n" "$yellow" "$off" "$*"; }
fail() { printf "%s✗%s %s\n" "$red" "$off" "$*"; }

# Deja la ventana abierta para poder leer el resultado, salga bien o mal.
pausa() {
    say ""
    say "Pulsa cualquier tecla para cerrar esta ventana."
    read -r -n 1 -s
}

say ""
say "${bold}PantallaOff — instalación${off}"
say "Apaga la pantalla interna del MacBook con un clic."
say ""

# --- 1. Comprobaciones del sistema -----------------------------------------

if [ "$(uname -m)" != "arm64" ]; then
    fail "Este Mac no es Apple Silicon (arch: $(uname -m))."
    say  "  PantallaOff usa APIs que sólo se han verificado en Apple Silicon."
    pausa; exit 1
fi
ok "Apple Silicon"

version=$(sw_vers -productVersion)
mayor=${version%%.*}
if [ "$mayor" -lt 13 ]; then
    fail "Necesitas macOS 13 o posterior (tienes $version)."
    pausa; exit 1
fi
ok "macOS $version"

# --- 2. Herramientas de compilación ----------------------------------------

if ! xcode-select -p >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
    warn "Faltan las Herramientas de Línea de Comandos de Xcode."
    say  ""
    say  "  Voy a abrir el instalador de Apple. Es una descarga de unos minutos."
    say  "  ${bold}Cuando termine, vuelve a hacer doble clic en este instalador.${off}"
    say  ""
    xcode-select --install 2>/dev/null
    pausa; exit 1
fi
ok "Herramientas de compilación"

# --- 3. Compilar e instalar -------------------------------------------------

say ""
say "Compilando…"
if ! make install >/tmp/pantallaoff-install.log 2>&1; then
    fail "La compilación ha fallado."
    say  ""
    say  "  Últimas líneas del error:"
    tail -15 /tmp/pantallaoff-install.log | sed 's/^/    /'
    say  ""
    say  "  Registro completo en /tmp/pantallaoff-install.log"
    pausa; exit 1
fi
ok "Instalado en /Applications/PantallaOff.app"
ok "Herramienta de rescate en ~/rescue"

# --- 4. Arrancar ------------------------------------------------------------

# Si había una versión anterior corriendo, la reemplazamos por la nueva.
killall PantallaOff 2>/dev/null && sleep 1
open /Applications/PantallaOff.app

say ""
say "${bold}${green}Listo.${off}"
say ""
say "Busca el icono de portátil en la barra de menú, arriba a la derecha,"
say "junto al reloj. Ahí tienes ${bold}Apagar pantalla del MacBook${off}."
say ""
say "Para que se abra sola al iniciar sesión, actívalo en ese mismo menú."
pausa
