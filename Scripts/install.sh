#!/bin/zsh
set -euo pipefail

if (( EUID == 0 )); then
    print -u2 "No ejecutes este instalador con sudo: VPS Monitor se instala para el usuario actual."
    exit 1
fi

root=${0:A:h:h}
applications="$HOME/Applications"
app="$applications/VPSMonitor.app"
executable="$app/Contents/MacOS/VPSMonitor"
launch_agents="$HOME/Library/LaunchAgents"
launch_agent="$launch_agents/com.vpsmonitor.app.plist"
service="gui/$UID/com.vpsmonitor.app"
staging="$applications/.VPSMonitor.app.staging.$$"
previous="$applications/.VPSMonitor.app.previous.$$"
agent_staging="${TMPDIR:-/tmp}/com.vpsmonitor.app.$$.plist"
agent_previous="${TMPDIR:-/tmp}/com.vpsmonitor.app.previous.$$.plist"
signing_identity=${VPSMONITOR_SIGNING_IDENTITY:--}

transaction_active=0
app_backed_up=0
new_app_installed=0
agent_backed_up=0
new_agent_installed=0

stop_installed_app() {
    if pgrep -f -x "$executable" >/dev/null 2>&1; then
        pkill -TERM -f -x "$executable" || true
        for _ in {1..30}; do
            pgrep -f -x "$executable" >/dev/null 2>&1 || break
            sleep 0.1
        done
        pkill -KILL -f -x "$executable" 2>/dev/null || true
    fi
}

rollback() {
    set +e
    launchctl bootout "$service" >/dev/null 2>&1
    stop_installed_app

    if (( new_app_installed )); then
        /bin/rm -rf "$app"
    fi
    if (( app_backed_up )) && [[ -e "$previous" ]]; then
        mv "$previous" "$app"
    fi

    if (( new_agent_installed )); then
        /bin/rm -f "$launch_agent"
    fi
    if (( agent_backed_up )) && [[ -e "$agent_previous" ]]; then
        mv "$agent_previous" "$launch_agent"
    fi

    if [[ -e "$app" && -e "$launch_agent" ]]; then
        if launchctl bootstrap "gui/$UID" "$launch_agent" >/dev/null 2>&1; then
            for _ in {1..30}; do
                pgrep -f -x "$executable" >/dev/null 2>&1 && break
                sleep 0.1
            done
        else
            print -u2 "Aviso: no se pudo volver a registrar el LaunchAgent anterior."
        fi
        if ! pgrep -f -x "$executable" >/dev/null 2>&1; then
            /usr/bin/open -n "$app" >/dev/null 2>&1
            for _ in {1..30}; do
                pgrep -f -x "$executable" >/dev/null 2>&1 && break
                sleep 0.1
            done
        fi
        if ! pgrep -f -x "$executable" >/dev/null 2>&1; then
            print -u2 "Aviso: la versión restaurada tampoco pudo arrancar."
        fi
    fi
    set -e
}

finish() {
    local exit_code=$?
    trap - EXIT HUP INT TERM
    if (( exit_code != 0 && transaction_active )); then
        print -u2 "La instalación falló; restaurando la versión anterior."
        rollback
    fi
    /bin/rm -rf "$staging"
    /bin/rm -f "$agent_staging"
    if (( exit_code == 0 )); then
        /bin/rm -rf "$previous"
        /bin/rm -f "$agent_previous"
    fi
    exit $exit_code
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

swift build -c release --package-path "$root"
bin_path=$(swift build -c release --package-path "$root" --show-bin-path)

mkdir -p "$applications" "$launch_agents" "$staging/Contents/MacOS"
install -m 755 "$bin_path/VPSMonitor" "$staging/Contents/MacOS/VPSMonitor"
install -m 644 "$root/Packaging/Info.plist" "$staging/Contents/Info.plist"
install -m 644 "$root/Packaging/com.vpsmonitor.app.plist" "$agent_staging"
plutil -remove ProgramArguments.1 "$agent_staging"
plutil -insert ProgramArguments.1 -string "$app" "$agent_staging"

plutil -lint "$staging/Contents/Info.plist" "$agent_staging"
codesign --force --deep --sign "$signing_identity" "$staging"
codesign --verify --deep --strict --verbose=2 "$staging"

transaction_active=1
if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service"
fi
stop_installed_app

if [[ -e "$app" ]]; then
    app_backed_up=1
    mv "$app" "$previous"
fi
if [[ -e "$launch_agent" ]]; then
    agent_backed_up=1
    mv "$launch_agent" "$agent_previous"
fi

new_app_installed=1
mv "$staging" "$app"
new_agent_installed=1
install -m 644 "$agent_staging" "$launch_agent"

launchctl enable "$service"
launchctl bootstrap "gui/$UID" "$launch_agent"

for _ in {1..50}; do
    pgrep -f -x "$executable" >/dev/null 2>&1 && break
    sleep 0.1
done

if ! pgrep -f -x "$executable" >/dev/null 2>&1; then
    /usr/bin/open -n "$app"
    for _ in {1..30}; do
        pgrep -f -x "$executable" >/dev/null 2>&1 && break
        sleep 0.1
    done
fi

if ! pgrep -f -x "$executable" >/dev/null 2>&1; then
    print -u2 "La app instalada no arrancó."
    false
fi

transaction_active=0
print "VPS Monitor instalado en $app"
print "Inicio automático habilitado mediante $launch_agent"
