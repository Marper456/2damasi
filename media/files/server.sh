#!/bin/bash

# ==========================================
#  VBox Backend - Dashboard Manager
#  Ejecutar con: bash server.sh
# ==========================================

PORT=8000
PIPE="/tmp/vbox_pipe_$$"

# Detectar banderas de netcat (nc)
if nc -h 2>&1 | grep -q "OpenBSD"; then
    NC_FLAGS="-l -p $PORT -q 1"
else
    NC_FLAGS="-l -p $PORT -w 1"
fi

clean_exit() {
    echo -e "\n🔴 Apagando servidor..."
    rm -f "$PIPE"
    exit 0
}
trap clean_exit SIGINT SIGTERM EXIT

if [[ ! -p $PIPE ]]; then mkfifo "$PIPE"; fi

# Detección de VirtualBox
if command -v VBoxManage &> /dev/null; then
    MODE="LIVE"
    STATUS_MSG="✅ VirtualBox detectado."
else
    MODE="MOCK"
    STATUS_MSG="⚠️ Modo Simulación (VBoxManage no encontrado)."
fi

echo -e "\033[32m🟢 Servidor listo en http://localhost:$PORT\033[0m"
echo "   $STATUS_MSG"

# Función para listar VMs en formato JSON
get_vms_json() {
    if [ "$MODE" = "LIVE" ]; then
        VBoxManage list vms | while read line; do
            vm_name=$(echo "$line" | sed -E 's/^"([^"]+)".*$/\1/')
            vm_uuid=$(echo "$line" | sed -E 's/^.*\{(.*)\}$/\1/')
            info=$(VBoxManage showvminfo "$vm_uuid" --machinereadable)
            vm_state=$(echo "$info" | grep '^VMState=' | cut -d'=' -f2 | tr -d '"')
            vm_os=$(echo "$info" | grep '^ostype=' | cut -d'=' -f2 | tr -d '"')
            echo "{\"name\": \"$vm_name\", \"id\": \"$vm_uuid\", \"os\": \"$vm_os\", \"state\": \"$vm_state\"},"
        done | sed '$ s/,$//'
    else
        echo '{"name": "VM_Simulada_Linux", "id": "123", "os": "Ubuntu_64", "state": "running"}'
    fi
}

# Bucle del servidor
while true; do
    cat "$PIPE" | nc $NC_FLAGS 2>/dev/null | (
        read request
        while read header && [ "$header" != $'\r' ] && [ -n "$header" ]; do :; done

        path=$(echo "$request" | awk '{print $2}')
        path_decoded=$(echo -e "${path//%/\\x}")

        status="200 OK"
        ctype="application/json"
        body="{}"

        case "$path_decoded" in
            # Servimos el HTML tal cual, sin inyecciones complejas
            /|/index.html)
                status="200 OK"
                ctype="text/html"
                if [ -f "dashboard.html" ]; then
                    body=$(cat dashboard.html)
                else
                    body="<h1>Error: No se encuentra dashboard.html</h1>"
                fi
                ;;
            /api/list)
                body="[$(get_vms_json)]"
                ;;
            /api/vm/*/on)
                vm_name=$(echo "$path_decoded" | awk -F'/' '{print $4}')
                [ "$MODE" = "LIVE" ] && VBoxManage startvm "$vm_name" --type headless >/dev/null 2>&1
                body="{\"status\": \"started\", \"vm\": \"$vm_name\"}"
                ;;
            /api/vm/*/off)
                vm_name=$(echo "$path_decoded" | awk -F'/' '{print $4}')
                [ "$MODE" = "LIVE" ] && VBoxManage controlvm "$vm_name" acpipowerbutton >/dev/null 2>&1
                body="{\"status\": \"stopping\", \"vm\": \"$vm_name\"}"
                ;;
            /api/vm/*/preview)
                vm_name=$(echo "$path_decoded" | awk -F'/' '{print $4}')
                if [ "$MODE" = "LIVE" ]; then
                    tmp_img="/tmp/vbox_snap_${RANDOM}.png"
                    VBoxManage controlvm "$vm_name" screenshotpng "$tmp_img" >/dev/null 2>&1
                    if [ -f "$tmp_img" ]; then
                        body="{\"image\": \"data:image/png;base64,$(base64 -w 0 "$tmp_img")\"}"
                        rm "$tmp_img"
                    else
                        body="{\"image\": null}"
                    fi
                else
                    body="{\"image\": \"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=\"}"
                fi
                ;;
        esac

        len=$(echo -n "$body" | wc -c)
        echo -e "HTTP/1.1 $status\r\nContent-Type: $ctype\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: $len\r\n\r\n$body"
    ) > "$PIPE"
done