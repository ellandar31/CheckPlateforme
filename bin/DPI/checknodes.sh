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
nodes_disks_json() {
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
            printf '%s{"name":' "$separator"; json_string "$device"
            printf ',"mount":'; json_string "$mountpoint"
            printf ',"total":'; json_number "$size"
            printf ',"used":'; json_number "$used"
            printf ',"available":'; json_number "$available"
            printf ',"percentUsed":'; json_string "$percent%"
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
usage() {
    printf 'Usage : %s (--localhost | --inventory SERVEURS.csv) [--json nodes.json] [--id IDENTIFIANT] [--oid OBJECTID] [--include-command-line]\n' "$0"
}
# Appelée dans collect_node_packages : variables de collecte partagées par portée Bash.
collect_debian_packages() {
    local output='' line status name full epoch version release arch rest tabs
    packages=''; separator=''; count=0; rc=0; error=''; manager=dpkg
    if ! command -v dpkg-query >/dev/null 2>&1; then
        error='Repli APT impossible : dpkg-query absent'; rc=2; return
    fi
    if ! output=$(LC_ALL=C dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n'); then
        error='Échec de lecture de la base dpkg'; rc=2; return
    fi
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        rest=${line//$'\t'/}; tabs=$((${#line}-${#rest}))
        IFS=$'\t' read -r status name full arch <<< "$line"
        if [[ $tabs != 3 || -z $status || -z $name ]]; then
            error='Réponse dpkg invalide ou incomplète'; rc=2; return
        fi
        [[ $status == installed ]] || continue
        if [[ -z $full || -z $arch ]]; then error='Réponse dpkg invalide'; rc=2; return; fi
        epoch=0; version=$full; release=''
        if [[ $version == *:* ]]; then epoch=${version%%:*}; version=${version#*:}; fi
        if [[ $version == *-* ]]; then release=${version##*-}; version=${version%-*}; fi
        if [[ ! $epoch =~ ^[0-9]{1,9}$ || -z $version ]]; then error='Version Debian invalide'; rc=2; return; fi
        packages+="$separator"'{"package_manager":'"$(json_string "$manager")"',"name":'"$(json_string "$name")"',"epoch":'"$(json_number "$epoch")"',"version":'"$(json_string "$version")"',"release":'"$(json_string "$release")"',"architecture":'"$(json_string "$arch")"',"version_full":'"$(json_string "$full")"',"installed_at_unix":null}'
        separator=','; ((count+=1))
    done <<< "$output"
    if (( ! count )); then error='Inventaire dpkg vide : aucune collecte certifiée'; rc=2; fi
}
collect_node_packages() {
    local manager=rpm rpm_error='' fallback_used=false
    local output='' packages='' separator='' count=0 rc=0 error=''
    local name epoch version release arch installed extra line tabs rest
    printf '\n=== Paquets RPM : %s ===\n' "${HOSTNAME:-serveur}"
    if ! command -v rpm >/dev/null 2>&1; then
        error='Commande rpm absente : inventaire RHEL impossible'; rc=2
    elif output=$(LC_ALL=C rpm -qa --queryformat '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{INSTALLTIME}\n'); then
        if [[ -z $output ]]; then
            error='Inventaire RPM vide : aucune collecte certifiée'; rc=2
        else
            while IFS= read -r line; do
                # Six champs non vides ; ne pas accepter une réponse tronquée.
                rest=${line//$'\t'/}; tabs=$((${#line}-${#rest}))
                IFS=$'\t' read -r name epoch version release arch installed extra <<< "$line"
                if [[ $tabs != 5 || -z $name || -z $version || -z $release || -z $arch ||
                      ! $epoch =~ ^[0-9]+$ || ! $installed =~ ^[0-9]+$ ]]; then
                    error='Réponse RPM invalide ou incomplète'; rc=2; break
                fi
                packages+="$separator"'{"package_manager":'"$(json_string "$manager")"',"name":'"$(json_string "$name")"',"epoch":'"$(json_number "$epoch")"',"version":'"$(json_string "$version")"',"release":'"$(json_string "$release")"',"architecture":'"$(json_string "$arch")"',"installed_at_unix":'"$(json_number "$installed")"'}'
                separator=','; ((count+=1))
            done <<< "$output"
        fi
    else
        error='Échec de lecture de la base RPM'; rc=2
    fi
    if ((rc)); then
        rpm_error=$error; fallback_used=true
        printf 'AVERTISSEMENT RPM : %s ; repli vers les paquets APT/dpkg\n' "$rpm_error"
        collect_debian_packages
    fi
    if ((rc)); then
        # Ne pas présenter un inventaire partiel comme complet.
        packages=''; count=0
        printf 'ERREUR %s\n' "$error"
    fi
    printf 'Nombre de paquets : %s\n' "$count"
    printf '[%s]\n' "$packages" >&3
    return "$rc"
}
collect_node() {
    local rpms='[]' packages_rc=0
    local include_args=${1:-0} rc=0 now host domain='' fqdn='' ip='' os='' redhat='' jdk='' uptime='' load=''
    local key value rest line model='' cpu=0 frequency='' bogomips='' net='' sep='' interface tx rx
    local mt='' mf='' ma='' st='' sf='' mu='' su='' disks='[]' processes='' psep='' raw='' ps_rc columns
    printf -v now '%(%s)T' -1
    host=${HOSTNAME:-}
    if command -v hostname >/dev/null 2>&1; then
        host=$(hostname -s) || rc=2
        # La résolution réseau est bornée ; ne pas déduire un domaine non résolu.
        if command -v timeout >/dev/null 2>&1; then
            fqdn=$(timeout -k 1 5 hostname -f 2>/dev/null) || { fqdn=''; rc=2; }
        fi
        raw=$(hostname -I 2>/dev/null) || { raw=''; rc=2; }
        read -r ip rest <<< "$raw"
    else rc=2; fi
    if [[ -n $fqdn && $fqdn == *.* ]]; then domain=${fqdn#*.}; fi
    os=$(uname -rm) || rc=2
    if [[ -r /etc/redhat-release ]]; then
        IFS= read -r redhat < /etc/redhat-release || [[ -n $redhat ]] || rc=2
    elif [[ -r /etc/os-release ]]; then
        while IFS='=' read -r key value; do
            if [[ $key == PRETTY_NAME ]]; then value=${value#\"}; redhat=${value%\"}; fi
        done < /etc/os-release
    else rc=2; fi
    if command -v java >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            raw=$(LC_ALL=C timeout -k 1 5 java -version 2>&1)
            if (( $? == 0 )); then
                while IFS= read -r line; do
                    case "$line" in *' version '*|openjdk\ [0-9]*|java\ [0-9]*) jdk=$line; break ;; esac
                done <<< "$raw"
                [[ -n $jdk ]] || rc=2
            else rc=2; fi
        else rc=2; fi
    fi
    if [[ -r /proc/uptime ]]; then read -r uptime rest < /proc/uptime || rc=2; else rc=2; fi
    if [[ -r /proc/loadavg ]]; then
        local l1 l5 l15
        read -r l1 l5 l15 rest < /proc/loadavg || rc=2
        load="$l1 $l5 $l15"
    else rc=2; fi
    if [[ -r /proc/cpuinfo ]]; then
        while IFS=: read -r key value; do
            key=${key//[[:space:]]/}; value=${value#"${value%%[![:space:]]*}"}
            case "$key" in
                processor) ((cpu+=1)) ;;
                modelname|Processor|cpu) [[ -n $model ]] || model=$value ;;
                cpuMHz) [[ -n $frequency ]] || frequency=$value ;;
                bogomips|BogoMIPS) [[ -n $bogomips ]] || bogomips=$value ;;
            esac
        done < /proc/cpuinfo
        ((cpu)) || rc=2
    else rc=2; fi
    if [[ -r /proc/meminfo ]]; then
        while read -r key value rest; do
            case "$key" in MemTotal:) mt=$value ;; MemFree:) mf=$value ;; MemAvailable:) ma=$value ;; SwapTotal:) st=$value ;; SwapFree:) sf=$value ;; esac
        done < /proc/meminfo
    else rc=2; fi
    for value in "$mt" "$mf" "$ma" "$st" "$sf"; do [[ $value =~ ^[0-9]+$ ]] || rc=2; done
    if [[ $mt =~ ^[0-9]+$ && $ma =~ ^[0-9]+$ ]]; then mu=$((mt-ma)); fi
    if [[ $st =~ ^[0-9]+$ && $sf =~ ^[0-9]+$ ]]; then su=$((st-sf)); fi
    if [[ ! -d /sys/class/net ]]; then rc=2; fi
    for interface in /sys/class/net/*; do
        [[ -d $interface ]] || continue
        tx=''; rx=''
        if ! { IFS= read -r tx < "$interface/statistics/tx_bytes"; } 2>/dev/null; then rc=2; fi
        if ! { IFS= read -r rx < "$interface/statistics/rx_bytes"; } 2>/dev/null; then rc=2; fi
        net+="$sep"'{"nom":'"$(json_string "${interface##*/}")"',"tx":'"$(json_string "$tx")"',"rx":'"$(json_string "$rx")"'}'; sep=','
    done
    raw=$(LC_ALL=C df -Pk) || rc=2
    disks=$(nodes_disks_json "$raw") || rc=2
    # -C utilise le nom du processus, sans grep ni auto-détection du script.
    columns='pmem=,pid=,user=,comm='
    ((include_args)) && columns='pmem=,pid=,user=,args='
    if command -v ps >/dev/null 2>&1; then
        raw=$(LC_ALL=C ps -C java,java.bin -o "$columns" 2>&1); ps_rc=$?
        if ((ps_rc > 1)) || { ((ps_rc == 1)) && [[ -n $raw ]]; }; then
            printf 'ERREUR Lecture des processus Java impossible\n' >&2; rc=2; raw=''
        fi
        while IFS= read -r line; do
            [[ -n $line ]] || continue
            line=${line#"${line%%[![:space:]]*}"}
            processes+="$psep$(json_string "$line")"; psep=','
        done <<< "$raw"
    else rc=2; fi
    rpms=$(collect_node_packages 3>&1 1>&2); packages_rc=$?
    (( packages_rc == 0 )) || rc=2
    printf 'NODE %s : CPU=%s, RAM=%s kio, code=%s\n' "$host" "$cpu" "${mt:-inconnue}" "$rc"
    {
        printf '{"lastUpdate":%s,"hostname":' "$now"; json_string "$host"
        printf ',"domain":'; json_string "$domain"
        printf ',"fqdn":'; json_string "$fqdn"
        printf ',"ip":'; json_string "$ip"
        printf ',"system":{"nameOS":'; json_string "$os"
        printf ',"versionRedHat":'; json_string "$redhat"
        printf ',"versionJDK":'; json_string "$jdk"
        printf ',"upTime":'; json_string "$uptime"
        printf ',"load":'; json_string "$load"
        printf '},"processes":[%s],"cpu":{"model":' "$processes"; json_string "$model"
        printf ',"nbProc":'; json_string "$cpu"
        printf ',"frqProc":'; json_string "$frequency"
        printf ',"bogomips":'; json_string "$bogomips"
        printf '},"memory":{"memTotal":'; json_number "$mt"
        printf ',"memFree":'; json_number "$mf"
        printf ',"memUsed":'; json_number "$mu"
        printf ',"swapTotal":'; json_number "$st"
        printf ',"swapFree":'; json_number "$sf"
        printf ',"swapUsed":'; json_number "$su"
        printf '},"network":[%s],"disks":%s,"rpms":%s}\n' "$net" "$disks" "$rpms"
    } >&3
    return "$rc"
}
main() {
    local mode='' inventory='' report='nodes.json' include_args=0 id='' oid='' uuid uuid2 now data rc result=0 nodes='' sep='' payload i
    local -a hosts=() users=() ports=() options=()
    while (( $# )); do
        case "$1" in
            --localhost) [[ -z $mode ]] || { usage >&2; return 2; }; mode=local; shift ;;
            --inventory) [[ -z $mode && $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; mode=remote; inventory=$2; shift 2 ;;
            --json|--id|--oid)
                [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }
                case "$1" in --json) report=$2 ;; --id) id=$2 ;; --oid) oid=$2 ;; esac; shift 2 ;;
            --include-command-line) include_args=1; shift ;;
            --help|-h) usage; return 0 ;;
            *) usage >&2; return 2 ;;
        esac
    done
    [[ -n $mode ]] || { usage >&2; return 2; }
    [[ -z $oid || $oid =~ ^[0-9a-fA-F]{24}$ ]] || { printf 'ERREUR --oid : 24 chiffres hexadécimaux attendus\n' >&2; return 2; }
    if [[ $mode == local ]]; then hosts=(localhost); users=(''); ports=(22); else load_inventory "$inventory" || return 2; fi
    # Identifiants neufs pour ce document, sans copier ceux du modèle utilisateur.
    if [[ -z $id || -z $oid ]]; then
        IFS= read -r uuid < /proc/sys/kernel/random/uuid || return 2
        IFS= read -r uuid2 < /proc/sys/kernel/random/uuid || return 2
        uuid=${uuid//-/}; uuid2=${uuid2//-/}
        [[ -n $id ]] || id=${uuid}${uuid2:0:8}
        printf -v now '%(%s)T' -1
        if [[ -z $oid ]]; then printf -v oid '%08x%s' "$now" "${uuid2:0:16}"; fi
    fi
    if ! (set -o noclobber; : > "$report") 2>/dev/null; then
        printf 'ERREUR Rapport existant ou inaccessible : %s\n' "$report" >&2; return 2
    fi
    for ((i=0; i<${#hosts[@]}; i++)); do
        printf '\nCible : %s\n' "${hosts[i]}"
        case "${hosts[i]}" in
            localhost|127.0.0.1|::1) data=$(collect_node "$include_args" 3>&1 1>&2); rc=$? ;;
            *)
                options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -p "${ports[i]}")
                [[ -z ${users[i]} ]] || options+=(-l "${users[i]}")
                payload="$(declare -f json_string json_number nodes_disks_json collect_debian_packages collect_node_packages collect_node)"$'\n'
                printf -v payload '%scollect_node %q 3>&1 1>&2\n' "$payload" "$include_args"
                data=$(ssh "${options[@]}" "${hosts[i]}" 'bash -s' <<< "$payload"); rc=$? ;;
        esac
        case "$rc" in
            0|2) if [[ -n $data ]]; then nodes+="$sep$data"; sep=','; else result=2; fi ;;
            *) printf 'ERREUR Collecte impossible pour %s (code %s), nœud omis\n' "${hosts[i]}" "$rc" >&2 ;;
        esac
        ((rc == 0)) || result=2
    done
    {
        printf '{"_id":{"$oid":'; json_string "$oid"
        printf '},"appModules":[],"appServers":[],"datasources":[],"fluxes":[],"id":'; json_string "$id"
        printf ',"info":{},"jobs":[],"licences":[],"metadatas":{},"nodes":[%s],"readme":{},"referentiels":[],"tablespaces":{}}\n' "$nodes"
    } > "$report" || return 2
    printf 'Rapport nodes : %s ; code global : %s\n' "$report" "$result"
    return "$result"
}
main "$@"
