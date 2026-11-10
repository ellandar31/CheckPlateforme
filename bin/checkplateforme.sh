#!/bin/bash
set -u
usage() {
    printf 'Usage : %s (--localhost | --inventory FICHIER) [--json RAPPORT.json] [--flows MATRICE.csv] [--expectations ATTENTES.csv]\n' "$0"
}
# Encode une chaîne JSON sans dépendre de Python ou jq.
json_string() {
    local LC_ALL=C text=$1 char i code
    printf '"'
    for ((i=0; i<${#text}; i++)); do
        char=${text:i:1}
        case "$char" in
            '"') printf '\\"' ;;
            \\) printf '\\\\' ;;
            *) printf -v code '%d' "'$char"
               if (( code < 32 )); then printf '\\u%04x' "$code"; else printf '%s' "$char"; fi ;;
        esac
    done
    printf '"'
}
json_number() {
    if [[ $1 =~ ^[0-9]+$ ]]; then printf '%d' "$((10#$1))"; else printf 'null'; fi
}
# Convertit la sortie POSIX de df (blocs de 1 kio) en objets JSON.
filesystems_json() {
    local line first=1 separator='' invalid=0
    local pattern='^(.+[^[:space:]])[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)%[[:space:]]+(.+)$'
    printf '['
    while IFS= read -r line; do
        if (( first )); then first=0; continue; fi
        [[ -n $line ]] || continue
        if [[ $line =~ $pattern ]]; then
            # Sauvegarder les captures avant tout appel modifiant BASH_REMATCH.
            local device=${BASH_REMATCH[1]} size=${BASH_REMATCH[2]}
            local used=${BASH_REMATCH[3]} available=${BASH_REMATCH[4]}
            local percent=${BASH_REMATCH[5]} mountpoint=${BASH_REMATCH[6]}
            printf '%s{"device":' "$separator"; json_string "$device"
            printf ',"mountpoint":'; json_string "$mountpoint"
            printf ',"size_kib":'; json_number "$size"
            printf ',"used_kib":'; json_number "$used"
            printf ',"available_kib":'; json_number "$available"
            printf ',"use_percent":'; json_number "$percent"
            printf '}'
            separator=','
        else
            printf 'ERREUR Ligne filesystem non interprétable : %s\n' "$line" >&2
            invalid=1
        fi
    done <<< "$1"
    printf ']'
    return "$invalid"
}
collect() {
    local checks='[]' disks_ok=1
    local id='' key value errors=0 failed=0 kernel='' disks='' filesystems='[]' system_state='' failed_units='' rc=0
    printf '\n=== %s ===\n' "${HOSTNAME:-serveur}"
    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r key value; do
            value=${value#\"}; value=${value%\"}
            case "$key" in
                ID) id=$value ;;
                PRETTY_NAME) printf 'INFO OS : %s\n' "$value" ;;
            esac
        done < /etc/os-release
        if [[ $id == rhel ]]; then
            printf 'OK Distribution RHEL\n'
        else
            printf 'ECART Distribution attendue : RHEL\n'; failed=1
        fi
    else
        printf 'ERREUR /etc/os-release illisible\n'; errors=1
    fi
    printf 'INFO Noyau et architecture\n'
    kernel=$(uname -srmo) || errors=1
    printf '%s\n' "$kernel"
    local cpu_count=0 cpu_model='' field
    if [[ -r /proc/cpuinfo ]]; then
        while IFS=: read -r key value; do
            # Retirer les espaces autour du nom du champ et devant sa valeur.
            key=${key//[[:space:]]/}
            value=${value#"${value%%[![:space:]]*}"}
            case "$key" in
                processor) ((cpu_count+=1)) ;;
                modelname|Processor|cpu) [[ -n $cpu_model ]] || cpu_model=$value ;;
            esac
        done < /proc/cpuinfo
        if (( cpu_count > 0 )); then
            printf 'INFO CPU : %s processeur(s) logique(s) en ligne\n' "$cpu_count"
        else
            printf 'ERREUR Nombre de CPU indéterminé\n'; errors=1
        fi
        printf 'INFO Modèle CPU : %s\n' "${cpu_model:-non renseigné}"
    else
        printf 'ERREUR /proc/cpuinfo illisible\n'; errors=1
    fi
    local ram_total='' ram_available='' swap_total='' swap_free=''
    if [[ -r /proc/meminfo ]]; then
        while read -r key value unit; do
            case "$key" in
                MemTotal:) ram_total=$value ;;
                MemAvailable:) ram_available=$value ;;
                SwapTotal:) swap_total=$value ;;
                SwapFree:) swap_free=$value ;;
            esac
        done < /proc/meminfo
        for field in ram_total ram_available swap_total swap_free; do
            if [[ ! ${!field} =~ ^[0-9]+$ ]]; then
                printf 'ERREUR Champ mémoire absent ou invalide : %s\n' "$field"
                errors=1
            fi
        done
        if [[ $ram_total =~ ^[0-9]+$ && $ram_available =~ ^[0-9]+$ ]]; then
            printf 'INFO RAM (kio) : totale=%s disponible=%s utilisée (estimée)=%s\n' \
                "$ram_total" "$ram_available" "$((ram_total - ram_available))"
        fi
        if [[ $swap_total =~ ^[0-9]+$ && $swap_free =~ ^[0-9]+$ ]]; then
            printf 'INFO SWAP (kio) : totale=%s libre=%s utilisée=%s\n' \
                "$swap_total" "$swap_free" "$((swap_total - swap_free))"
            (( swap_total > 0 )) || printf 'INFO Aucun swap configuré\n'
        fi
    else
        printf 'ERREUR /proc/meminfo illisible\n'; errors=1
    fi
    printf 'INFO Systèmes de fichiers\n'
    disks=$(LC_ALL=C df -Pk) || { errors=1; disks_ok=0; }
    printf '%s\n' "$disks"
    filesystems=$(filesystems_json "$disks") || { errors=1; disks_ok=0; }
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        system_state=$(systemctl is-system-running)
        rc=$?
        printf '%s\n' "$system_state"
        if (( rc != 0 )); then
            printf 'ECART systemd ne signale pas un système running\n'; failed=1
        fi
        failed_units=$(systemctl --failed --no-pager --no-legend) || errors=1
        printf '%s\n' "$failed_units"
    else
        printf 'ERREUR systemd indisponible : contrôle non exécuté\n'; errors=1
    fi
    check_expectations "${1:-localhost}"
    rc=0
    (( failed )) && rc=1
    (( errors )) && rc=2
    # Le descripteur 3 transporte uniquement les données JSON, y compris via SSH.
    {
        printf '{"hostname":'; json_string "${HOSTNAME:-serveur}"
        printf ',"distribution":'; json_string "$id"
        printf ',"kernel":'; json_string "$kernel"
        printf ',"cpu":{"logical_count":'; json_number "$cpu_count"
        printf ',"model":'; json_string "$cpu_model"
        printf '},"ram_kib":{"total":'; json_number "$ram_total"
        printf ',"available":'; json_number "$ram_available"
        printf ',"used_estimated":'
        if [[ $ram_total =~ ^[0-9]+$ && $ram_available =~ ^[0-9]+$ ]]; then
            printf '%s' "$((ram_total - ram_available))"
        else printf 'null'; fi
        printf '},"swap_kib":{"total":'; json_number "$swap_total"
        printf ',"free":'; json_number "$swap_free"
        printf ',"used":'
        if [[ $swap_total =~ ^[0-9]+$ && $swap_free =~ ^[0-9]+$ ]]; then
            printf '%s' "$((swap_total - swap_free))"
        else printf 'null'; fi
        printf '},"filesystems":%s' "$filesystems"
        printf ',"expectations":%s' "$checks"
        printf ',"systemd":{"state":'; json_string "$system_state"
        printf ',"failed_units_text":'; json_string "$failed_units"
        printf '},"exit_code":%s}\n' "$rc"
    } >&3
    return "$rc"
}
# CSV à nombre de colonnes attendu, champs nus ou entre guillemets ; une ligne par cible.
parse_csv_line() {
    csv_fields=()
    local text=$1 field='' state=start char next i
    for ((i=0; i<${#text}; i++)); do
        char=${text:i:1}
        case "$state" in
            start)
                case "$char" in
                    ' '|$'\t') ;;
                    '"') state=quoted ;;
                    ',') csv_fields+=(""); field='' ;;
                    *) field=$char; state=bare ;;
                esac ;;
            bare)
                case "$char" in
                    '"') return 1 ;;
                    ',') field=${field%"${field##*[![:space:]]}"}; csv_fields+=("$field"); field=''; state=start ;;
                    *) field+=$char ;;
                esac ;;
            quoted)
                if [[ $char == '"' ]]; then
                    next=${text:i+1:1}
                    if [[ $next == '"' ]]; then field+='"'; ((i+=1)); else state=closed; fi
                else field+=$char; fi ;;
            closed)
                case "$char" in
                    ' '|$'\t') ;;
                    ',') csv_fields+=("$field"); field=''; state=start ;;
                    *) return 1 ;;
                esac ;;
        esac
    done
    [[ $state != quoted ]] || return 1
    [[ $state != bare ]] || field=${field%"${field##*[![:space:]]}"}
    csv_fields+=("$field")
    [[ ${#csv_fields[@]} == ${2:-3} ]]
}
# Le probe est envoyé à la source ; aucune commande applicative ni authentification.
probe_flow() {
    local destination=$1 port=$2 protocol=$3 detail='' rc=0 status='indeterminate'
    if [[ $protocol == udp ]]; then
        detail='UDP non testé : une réponse spécifique au service est nécessaire'
        rc=2
    elif ! command -v timeout >/dev/null 2>&1; then
        detail='Commande timeout absente sur la source'; rc=2
    else
        detail=$(LC_ALL=C timeout -k 1 5 bash -c '
            if command -v getent >/dev/null 2>&1; then
                getent hosts "$1" >/dev/null || getent ahosts "$1" >/dev/null || exit 3
            fi
            exec 4<>"/dev/tcp/$1/$2"
        ' check-flow "$destination" "$port" 2>&1)
        rc=$?
        case "$rc" in
            0) status=accessible; detail='Connexion TCP établie' ;;
            3) status=dns_error; detail='Résolution du nom impossible'; rc=1 ;;
            124|137) status=timeout; detail='Délai de 5 secondes dépassé'; rc=1 ;;
            *)
                case "$detail" in
                    *'Connection refused'*) status=refused; rc=1 ;;
                    *'Name or service not known'*|*'Temporary failure in name resolution'*) status=dns_error; rc=1 ;;
                    *) status=connection_error; rc=1 ;;
                esac ;;
        esac
    fi
    printf '{"status":'; json_string "$status"
    printf ',"detail":'; json_string "$detail"
    printf ',"exit_code":%s}' "$rc"
    return "$rc"
}
load_flows() {
    local line number=0 first=1 source destination port protocol description
    [[ -r $flows_file && -f $flows_file ]] || { printf 'ERREUR Matrice illisible\n' >&2; return 2; }
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1)); line=${line%$'\r'}
        (( number != 1 )) || line=${line#$'\xef\xbb\xbf'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if ! parse_csv_line "$line" 5; then
            printf 'ERREUR Matrice ligne %s : cinq colonnes attendues\n' "$number" >&2; return 2
        fi
        source=${csv_fields[0]}; destination=${csv_fields[1]}; port=${csv_fields[2]}
        protocol=${csv_fields[3]}; description=${csv_fields[4]}
        if ((first)) && [[ $source == source && $destination == destination && $port == port && $protocol == protocole && $description == description ]]; then
            first=0; continue
        fi
        first=0
        if [[ ( $source != ::1 && ! $source =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]*$ ) ||
              ( $destination != ::1 && ! $destination =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]*$ ) ||
              ! $port =~ ^[0-9]{1,5}$ || ( $protocol != tcp && $protocol != udp ) ]]; then
            printf 'ERREUR Matrice ligne %s : source, destination, port ou protocole invalide\n' "$number" >&2; return 2
        fi
        if ((10#$port < 1 || 10#$port > 65535)); then
            printf 'ERREUR Port matrice ligne %s\n' "$number" >&2; return 2
        fi
        flow_sources+=("$source"); flow_destinations+=("$destination")
        flow_ports+=("$((10#$port))"); flow_protocols+=("$protocol"); flow_descriptions+=("$description")
    done < "$flows_file"
    ((${#flow_sources[@]})) || { printf 'ERREUR Matrice vide\n' >&2; return 2; }
}
validate_flow_sources() {
    local source host found
    for source in "${flow_sources[@]}"; do
        case "$source" in localhost|127.0.0.1|::1) continue ;; esac
        found=0
        for host in "${hosts[@]}"; do [[ $host != "$source" ]] || found=1; done
        if (( ! found )); then
            printf 'ERREUR Source %s absente de l’inventaire SSH\n' "$source" >&2; return 2
        fi
    done
}
run_flows() {
    local i j source destination port protocol data rc overall=0 separator='' payload
    local -a options=()
    printf '['
    for ((i=0; i<${#flow_sources[@]}; i++)); do
        source=${flow_sources[i]}; destination=${flow_destinations[i]}
        port=${flow_ports[i]}; protocol=${flow_protocols[i]}
        printf '\nFLUX %s -> %s:%s (%s) : %s\n' "$source" "$destination" "$port" "$protocol" "${flow_descriptions[i]}" >&2
        case "$source" in
            localhost|127.0.0.1|::1)
                data=$(probe_flow "$destination" "$port" "$protocol"); rc=$? ;;
            *)
                options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
                for ((j=0; j<${#hosts[@]}; j++)); do
                    if [[ ${hosts[j]} == "$source" ]]; then
                        options+=(-p "${ports[j]}")
                        [[ -z ${users[j]} ]] || options+=(-l "${users[j]}")
                        break
                    fi
                done
                payload="$(declare -f json_string probe_flow)"$'\n'
                printf -v payload '%sprobe_flow %q %q %q\n' "$payload" "$destination" "$port" "$protocol"
                data=$(ssh "${options[@]}" "$source" 'bash -s' <<< "$payload"); rc=$?
                case "$rc" in
                    0|1|2) ;;
                    *) data=''; rc=2 ;;
                esac ;;
        esac
        if [[ -z $data ]]; then
            data='{"status":"source_error","detail":"Exécution impossible sur la source (SSH ou commande distante)","exit_code":2}'
            rc=2
        fi
        printf 'RÉSULTAT FLUX : %s\n' "$data" >&2
        printf '%s{"source":' "$separator"; json_string "$source"
        printf ',"destination":'; json_string "$destination"
        printf ',"port":%s,"protocole":' "$port"; json_string "$protocol"
        printf ',"description":'; json_string "${flow_descriptions[i]}"
        printf ',"result":%s}' "$data"
        separator=','
        ((rc <= overall)) || overall=$rc
    done
    printf ']'
    return "$overall"
}
load_expectations() {
    local line number=0 first=1 host resource mountpoint operator value key
    local -A seen=()
    [[ -f $expectations_file && -r $expectations_file ]] || { printf 'ERREUR Attendus illisibles\n' >&2; return 2; }
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1)); line=${line%$'\r'}
        (( number != 1 )) || line=${line#$'\xef\xbb\xbf'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if ! parse_csv_line "$line" 6; then
            printf 'ERREUR Attendus ligne %s : six colonnes attendues\n' "$number" >&2; return 2
        fi
        host=${csv_fields[0]}; resource=${csv_fields[1]}; mountpoint=${csv_fields[2]}
        operator=${csv_fields[3]}; value=${csv_fields[4]}
        if (( first )) && [[ $host == host && $resource == resource && $mountpoint == mountpoint && $operator == operator && $value == value && ${csv_fields[5]} == unit ]]; then
            first=0; continue
        fi
        first=0
        if [[ ( $host != ::1 && ! $host =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]*$ ) ||
              ! $value =~ ^[0-9]{1,12}$ || ( $operator != ge && $operator != eq && $operator != le ) ]]; then
            printf 'ERREUR Attendus ligne %s : hôte, opérateur ou valeur invalide\n' "$number" >&2; return 2
        fi
        case "$resource:${csv_fields[5]}" in
            cpu:count|ram:MiB|swap:MiB) [[ -z $mountpoint ]] || return 2 ;;
            filesystem_size:MiB|filesystem_available:MiB|filesystem_use:percent)
                [[ $mountpoint == /* ]] || { printf 'ERREUR Point de montage ligne %s\n' "$number" >&2; return 2; } ;;
            *) printf 'ERREUR Ressource ou unité ligne %s\n' "$number" >&2; return 2 ;;
        esac
        key="$host|$resource|$mountpoint|$operator"
        [[ ! ${seen[$key]+present} ]] || { printf 'ERREUR Attendu dupliqué ligne %s\n' "$number" >&2; return 2; }
        seen[$key]=1
        expected_hosts+=("$host"); expected_resources+=("$resource"); expected_mounts+=("$mountpoint")
        expected_operators+=("$operator"); expected_values+=("$((10#$value))"); expected_units+=("${csv_fields[5]}")
    done < "$expectations_file"
    ((${#expected_hosts[@]})) || { printf 'ERREUR Fichier attendus vide\n' >&2; return 2; }
}
validate_expectation_hosts() {
    local target host found
    for target in "${expected_hosts[@]}"; do
        found=0
        if [[ $mode == local ]]; then
            [[ $target != localhost ]] || found=1
        else
            for host in "${hosts[@]}"; do [[ $host != "$target" ]] || found=1; done
        fi
        ((found)) || { printf 'ERREUR Hôte attendu non sélectionné : %s\n' "$target" >&2; return 2; }
    done
}
# Utilise les mesures déjà collectées ; ne relance pas df pour chaque règle.
check_expectations() {
    local target=$1 i resource mountpoint operator expected actual unit status line first
    local separator='' threshold
    local pattern='^(.+[^[:space:]])[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)%[[:space:]]+(.+)$'
    checks='['
    for ((i=0; i<${#expected_hosts[@]}; i++)); do
        [[ ${expected_hosts[i]} == "$target" ]] || continue
        resource=${expected_resources[i]}; mountpoint=${expected_mounts[i]}
        operator=${expected_operators[i]}; expected=${expected_values[i]}
        unit=${expected_units[i]}; threshold=$expected; actual=''; status=pass
        case "$resource" in
            cpu) (( cpu_count > 0 )) && actual=$cpu_count ;;
            ram) actual=$ram_total ;;
            swap) actual=$swap_total ;;
            filesystem_*)
                first=1
                while IFS= read -r line; do
                    if ((first)); then first=0; continue; fi
                    if [[ $line =~ $pattern && ${BASH_REMATCH[6]} == "$mountpoint" ]]; then
                        case "$resource" in
                            filesystem_size) actual=${BASH_REMATCH[2]} ;;
                            filesystem_available) actual=${BASH_REMATCH[4]} ;;
                            filesystem_use) actual=${BASH_REMATCH[5]} ;;
                        esac
                        break
                    fi
                done <<< "$disks" ;;
        esac
        if [[ $unit == MiB ]]; then threshold=$((expected * 1024)); unit=KiB; fi
        if [[ $resource == filesystem_* ]] && (( ! disks_ok )); then
            actual=''; status=error; errors=1
        elif [[ -z $actual && $resource == filesystem_* && $disks ]]; then
            status=fail; failed=1
        elif [[ ! $actual =~ ^[0-9]+$ ]]; then
            status=error; errors=1
        else
            case "$operator" in
                ge) (( actual >= threshold )) || status=fail ;;
                eq) (( actual == threshold )) || status=fail ;;
                le) (( actual <= threshold )) || status=fail ;;
            esac
            [[ $status != fail ]] || failed=1
        fi
        printf 'ATTENDU %s %s : %s %s %s ; mesuré=%s (%s)\n' "$resource" "$mountpoint" "$operator" "$threshold" "$unit" "${actual:-absent/inconnu}" "$status"
        checks+="$separator"'{"resource":'"$(json_string "$resource")"',"mountpoint":'"$(json_string "$mountpoint")"',"operator":'"$(json_string "$operator")"',"expected":'"$threshold"',"actual":'"$(json_number "$actual")"',"unit":'"$(json_string "$unit")"',"status":'"$(json_string "$status")"'}'
        separator=','
    done
    checks+=']'
}
main() {
    local line host user port number=0 rc result=0 i payload
    local expectations_file=''
    local -a expected_hosts=() expected_resources=() expected_mounts=() expected_operators=() expected_values=() expected_units=()
    local flows_file='' flows_json='[]' flows_rc=0
    local -a flow_sources=() flow_destinations=() flow_ports=() flow_protocols=() flow_descriptions=()
    local -a hosts=() users=() ports=() options=() csv_fields=()
    local report='rapport.json' mode='' inventory='' data='' entries='' separator=''
    while (( $# )); do
        case "$1" in
            --localhost) [[ -z $mode ]] || { usage >&2; return 2; }; mode=local; shift ;;
            --inventory) [[ -z $mode && $# -ge 2 ]] || { usage >&2; return 2; }; mode=remote; inventory=$2; shift 2 ;;
            --expectations) [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; expectations_file=$2; shift 2 ;;
            --flows) [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; flows_file=$2; shift 2 ;;
            --json) [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; report=$2; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) usage >&2; return 2 ;;
        esac
    done
    [[ -n $mode ]] || { usage >&2; return 2; }
    if [[ -n $expectations_file ]]; then load_expectations || return 2; fi
    if [[ -n $flows_file ]]; then load_flows || return 2; fi
    if [[ $mode == local ]]; then
        validate_flow_sources || return 2
        validate_expectation_hosts || return 2
    # Ne jamais écraser un fichier existant (inventaire ou code compris).
    if ! (set -o noclobber; : > "$report") 2>/dev/null; then
        printf 'ERREUR Rapport déjà existant ou chemin inaccessible : %s\n' "$report" >&2
        return 2
    fi
        data=$(collect 3>&1 1>&2)
        rc=$?
        result=$rc
        if [[ -n $flows_file ]]; then
            flows_json=$(run_flows); flows_rc=$?
            (( flows_rc <= result )) || result=$flows_rc
        fi
        if ! printf '{"servers":[{"target":"localhost","exit_code":%s,"data":%s}],"flows":%s,"exit_code":%s}\n' "$rc" "${data:-null}" "$flows_json" "$result" > "$report"; then return 2; fi
        printf 'Rapport JSON : %s\n' "$report"
        return "$result"
    fi
    set -- --inventory "$inventory"
    [[ -f $2 && -r $2 ]] || { printf 'ERREUR Inventaire illisible\n' >&2; return 2; }
    local first_record=1
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1))
        line=${line%$'\r'}
        (( number != 1 )) || line=${line#$'\xef\xbb\xbf'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if ! parse_csv_line "$line"; then
            printf 'ERREUR CSV ligne %s : trois colonnes attendues (host,user,port)\n' "$number" >&2
            return 2
        fi
        host=${csv_fields[0]}; user=${csv_fields[1]}; port=${csv_fields[2]}
        if (( first_record )) && [[ $host == host && $user == user && $port == port ]]; then
            first_record=0; continue
        fi
        first_record=0
        port=${port:-22}
        if [[ ( $host != ::1 && ! $host =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]*$ ) || ( -n $user && ! $user =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ) || ! $port =~ ^[0-9]{1,5}$ ]]; then
            printf 'ERREUR Inventaire ligne %s\n' "$number" >&2; return 2
        fi
        if ((10#$port < 1 || 10#$port > 65535)); then
            printf 'ERREUR Port ligne %s\n' "$number" >&2; return 2
        fi
        hosts+=("$host"); users+=("$user"); ports+=("$port")
    done < "$2"
    ((${#hosts[@]})) || { printf 'ERREUR Inventaire vide\n' >&2; return 2; }
    validate_flow_sources || return 2
    validate_expectation_hosts || return 2
    # Ne jamais écraser un fichier existant (inventaire ou code compris).
    if ! (set -o noclobber; : > "$report") 2>/dev/null; then
        printf 'ERREUR Rapport déjà existant ou chemin inaccessible : %s\n' "$report" >&2
        return 2
    fi

    for ((i=0; i<${#hosts[@]}; i++)); do
        printf '\nCible : %s\n' "${hosts[i]}"
        options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -p "${ports[i]}")
        [[ -z ${users[i]} ]] || options+=(-l "${users[i]}")
        case "${hosts[i]}" in
            localhost|127.0.0.1|::1)
                printf 'INFO Contrôle local sans SSH (utilisateur et port ignorés)\n'
                data=$(collect "${hosts[i]}" 3>&1 1>&2)
                rc=$?
                ;;
            *)
                payload="$(declare -f json_string json_number filesystems_json check_expectations collect)"$'\n'
                payload+="$(declare -p expected_hosts expected_resources expected_mounts expected_operators expected_values expected_units)"$'\n'
                printf -v payload '%scollect %q 3>&1 1>&2\n' "$payload" "${hosts[i]}"
                data=$(ssh "${options[@]}" "${hosts[i]}" 'bash -s' <<< "$payload")
                rc=$?
                ;;
        esac
        printf 'BILAN %s : code %s\n' "${hosts[i]}" "$rc"
        # Une rupture SSH peut laisser une réponse partielle : ne pas la conserver.
        case "$rc" in 0|1|2) ;; *) data='' ;; esac
        entries+="$separator"'{"target":'"$(json_string "${hosts[i]}")"',"exit_code":'"$rc"',"data":'"${data:-null}"'}'
        separator=','

        case "$rc" in 0) ;; 1) ((result < 1)) && result=1 ;; *) result=2 ;; esac
    done
    if [[ -n $flows_file ]]; then
        flows_json=$(run_flows); flows_rc=$?
        (( flows_rc <= result )) || result=$flows_rc
    fi
    if ! printf '{"servers":[%s],"flows":%s,"exit_code":%s}\n' "$entries" "$flows_json" "$result" > "$report"; then return 2; fi
    printf 'Rapport JSON : %s\n' "$report"
    return "$result"
}
main "$@"
