#!/bin/bash
set -u
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
# CSV séparé par des points-virgules, à nombre de colonnes attendu, champs nus ou entre guillemets ; une ligne par cible.
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
                    ';') csv_fields+=(""); field='' ;;
                    *) field=$char; state=bare ;;
                esac ;;
            bare)
                case "$char" in
                    '"') return 1 ;;
                    ';') field=${field%"${field##*[![:space:]]}"}; csv_fields+=("$field"); field=''; state=start ;;
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
                    ';') csv_fields+=("$field"); field=''; state=start ;;
                    *) return 1 ;;
                esac ;;
        esac
    done
    [[ $state != quoted ]] || return 1
    [[ $state != bare ]] || field=${field%"${field##*[![:space:]]}"}
    csv_fields+=("$field")
    [[ ${#csv_fields[@]} == ${2:-3} ]]
}
load_inventory() {
    local inventory=$1 line host user port number=0
    local -a csv_fields=()
    [[ -f $inventory && -r $inventory ]] || { printf 'ERREUR Inventaire illisible\n' >&2; return 2; }
    local first_record=1
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1))
        line=${line%$'\r'}
        (( number != 1 )) || line=${line#$'\xef\xbb\xbf'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if ! parse_csv_line "$line"; then
            printf 'ERREUR CSV ligne %s : trois colonnes attendues (host;user;port)\n' "$number" >&2
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
    done < "$inventory"
    ((${#hosts[@]})) || { printf 'ERREUR Inventaire vide\n' >&2; return 2; }
}
usage() {
    printf 'Usage : %s (--localhost | --inventory FICHIER) --flows MATRICE.csv [--json RAPPORT.json]\n' "$0"
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
main() {
    local flows_file='' inventory='' report='rapport-flux.json' mode='' flows_json rc
    local -a flow_sources=() flow_destinations=() flow_ports=() flow_protocols=() flow_descriptions=()
    local -a hosts=() users=() ports=() csv_fields=()
    while (( $# )); do
        case "$1" in
            --localhost) [[ -z $mode ]] || { usage >&2; return 2; }; mode=local; shift ;;
            --inventory) [[ -z $mode && $# -ge 2 ]] || { usage >&2; return 2; }; mode=remote; inventory=$2; shift 2 ;;
            --flows) [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; flows_file=$2; shift 2 ;;
            --json) [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; report=$2; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) usage >&2; return 2 ;;
        esac
    done
    [[ -n $mode && -n $flows_file ]] || { usage >&2; return 2; }
    load_flows || return 2
    if [[ $mode == remote ]]; then load_inventory "$inventory" || return 2; fi
    validate_flow_sources || return 2
    if ! (set -o noclobber; : > "$report") 2>/dev/null; then
        printf 'ERREUR Rapport déjà existant ou chemin inaccessible : %s\n' "$report" >&2
        return 2
    fi
    flows_json=$(run_flows); rc=$?
    if ! printf '{"flows":%s,"exit_code":%s}\n' "$flows_json" "$rc" > "$report"; then return 2; fi
    printf 'Rapport JSON : %s\n' "$report"
    return "$rc"
}
main "$@"
