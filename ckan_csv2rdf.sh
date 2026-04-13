#!/usr/bin/env bash
# =============================================================================
# ckan_csv2rdf.sh
# Converte i CSV di un'organizzazione CKAN in RDF/Turtle via CSV-to-RDF API
# e li carica come risorse aggiuntive sui rispettivi dataset.
#
# Uso:
#   ./ckan_csv2rdf.sh [config_file]
#   Se config_file non specificato, cerca ./ckan_csv2rdf.conf
#
# Dipendenze: curl, jq
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configurazione di default (sovrascrivibile dal file .conf)
# ---------------------------------------------------------------------------
CKAN_URL=""
CKAN_API_KEY=""
CKAN_ORG=""
CSV2RDF_API="https://csv2rdf.datigovit.workers.dev"
# Fallback titolare: usati SOLO se il dataset non ha holder_name/holder_identifier
# (campi DCAT-AP_IT standard). Per portali federati con N enti lasciarli vuoti:
# lo script legge holder_name/holder_identifier direttamente da ogni dataset.
PA_NAME_FALLBACK=""
PA_IPA_FALLBACK=""
# Suffisso aggiunto al nome CSV per identificare la risorsa TTL
TTL_NAME_SUFFIX=" (RDF/Turtle)"
# Secondi di attesa tra una chiamata e l'altra (evita rate-limit)
SLEEP_BETWEEN=1
# Modalità dry-run: se "true" non scrive nulla su CKAN
DRY_RUN="false"
# Log file (vuoto = solo stdout)
LOG_FILE=""
# Genera e carica anche RDF/XML oltre al TTL (default: false)
RDF_XML="false"

# ---------------------------------------------------------------------------
# Carica config
# ---------------------------------------------------------------------------
CONFIG_FILE="${1:-./ckan_csv2rdf.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    echo "[INFO] Configurazione caricata da: $CONFIG_FILE"
else
    echo "[ERRORE] File di configurazione non trovato: $CONFIG_FILE"
    echo "         Crea il file oppure passa il percorso come argomento."
    echo "         Esempio: ./ckan_csv2rdf.sh /percorso/mio.conf"
    exit 1
fi

# ---------------------------------------------------------------------------
# Validazione parametri obbligatori
# ---------------------------------------------------------------------------
for var in CKAN_URL CKAN_API_KEY CKAN_ORG; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERRORE] Variabile obbligatoria non impostata nel config: $var"
        exit 1
    fi
done

# Rimuovi trailing slash da CKAN_URL
CKAN_URL="${CKAN_URL%/}"

# ---------------------------------------------------------------------------
# Funzione di log
# ---------------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Controllo dipendenze
# ---------------------------------------------------------------------------
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log "[ERRORE] Dipendenza mancante: $cmd"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Funzione: chiama l'API CSV-to-RDF e salva il TTL direttamente su file
# $1 = URL del CSV
# $2 = holder_name (nome PA titolare del dataset)
# $3 = holder_identifier (codice IPA o CF del titolare)
# $4 = percorso file di output
# ---------------------------------------------------------------------------
convert_csv_to_ttl() {
    local csv_url="$1"
    local pa_name="$2"
    local pa_ipa="$3"
    local out_file="$4"

    # URL-encode dei parametri
    local enc_csv enc_pa
    enc_csv=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$csv_url")
    enc_pa=$(python3  -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$pa_name")

    # Il worker accetta: ?url=…&ipa=<codice_ipa>&pa=<nome_pa>
    local api_url="${CSV2RDF_API}?url=${enc_csv}&ipa=${pa_ipa}&pa=${enc_pa}"

    # Scrivi direttamente su file: evita di caricare risposte enormi in memoria
    # --max-time 300: CSV grandi (>10k righe) possono richiedere più tempo
    local http_code
    http_code=$(curl -s -w "%{http_code}"         --max-time 300         -o "$out_file"         "$api_url")

    if [[ "$http_code" != "200" ]]; then
        echo "__ERROR__:HTTP $http_code" >&2
        return 1
    fi

    # Controlla che il file contenga triple TTL valide (non solo commenti)
    if ! grep -q "^@prefix\|^@base\|^<http" "$out_file"; then
        # Distingui: ontologia non rilevata (TTL vuoto) vs risposta non valida
        if grep -q "^# Ontologie:" "$out_file"; then
            local onto
            onto=$(grep "^# Ontologie:" "$out_file" | head -1)
            if [[ "$onto" == "# Ontologie: " || "$onto" == "# Ontologie:" ]]; then
                echo "__SKIP__:nessuna ontologia rilevata per questo CSV (colonne non mappate)" >&2
            else
                echo "__SKIP__:TTL generato senza triple (${onto})" >&2
            fi
        else
            echo "__ERROR__:risposta non valida dal worker (prime righe: $(head -3 "$out_file"))" >&2
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Funzione: carica un file TTL su CKAN come risorsa con metadati completi
# I metadati licenza/availability/rights vengono ereditati dalla risorsa CSV
# sorgente per garantire coerenza e qualità DCAT-AP_IT.
#
# $1 = dataset_id
# $2 = resource_name (nome TTL)
# $3 = file_path (TTL locale)
# $4 = csv_resource_json (JSON della risorsa CSV sorgente, base64)
# $5 = existing_ttl_id (opzionale: ID risorsa TTL da aggiornare)
# ---------------------------------------------------------------------------
upload_ttl_to_ckan() {
    local dataset_id="$1"
    local resource_name="$2"
    local file_path="$3"
    local csv_res_json
    csv_res_json=$(echo "${4:-}" | base64 --decode)
    local existing_id="${5:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [DRY-RUN] Salto upload: $resource_name (dataset: $dataset_id)"
        return 0
    fi

    # --- Eredita metadati dalla risorsa CSV sorgente ---
    # Licenza: i tre campi devono essere allineati tra loro
    local lic     lic_id     lic_type
    lic=$(     echo "$csv_res_json" | jq -r '.license      // ""')
    lic_id=$(  echo "$csv_res_json" | jq -r '.license_id   // ""')
    lic_type=$(echo "$csv_res_json" | jq -r '.license_type // ""')

    # Availability e rights (accesso)
    local availability rights
    availability=$(echo "$csv_res_json" | jq -r '.availability // "https://publications.europa.eu/resource/authority/planned-availability/STABLE"')
    rights=$(      echo "$csv_res_json" | jq -r '.rights       // "http://publications.europa.eu/resource/authority/access-right/PUBLIC"')

    # Costanti per RDF/Turtle (non si ereditano dal CSV: sono specifici del formato)
    local fmt="RDF_TURTLE"
    local mime="https://iana.org/assignments/media-types/text/turtle"
    local desc="Conversione automatica RDF/Turtle generata da CSV-to-RDF (ontologie dati-semantic-assets / schema.gov.it)"

    local endpoint action resp success
    if [[ -n "$existing_id" ]]; then
        endpoint="${CKAN_URL}/api/3/action/resource_update"
        action="aggiornamento"
        resp=$(curl -s -X POST "$endpoint"             -H "Authorization: ${CKAN_API_KEY}"             -F "id=${existing_id}"             -F "name=${resource_name}"             -F "format=${fmt}"             -F "distribution_format=${fmt}"             -F "mimetype=${mime}"             -F "description=${desc}"             -F "license=${lic}"             -F "license_id=${lic_id}"             -F "license_type=${lic_type}"             -F "availability=${availability}"             -F "rights=${rights}"             -F "upload=@${file_path};type=text/turtle")
    else
        endpoint="${CKAN_URL}/api/3/action/resource_create"
        action="creazione"
        resp=$(curl -s -X POST "$endpoint"             -H "Authorization: ${CKAN_API_KEY}"             -F "package_id=${dataset_id}"             -F "name=${resource_name}"             -F "format=${fmt}"             -F "distribution_format=${fmt}"             -F "mimetype=${mime}"             -F "description=${desc}"             -F "license=${lic}"             -F "license_id=${lic_id}"             -F "license_type=${lic_type}"             -F "availability=${availability}"             -F "rights=${rights}"             -F "upload=@${file_path};type=text/turtle")
    fi

    success=$(echo "$resp" | jq -r '.success // "false"' 2>/dev/null || echo "false")
    if [[ "$success" == "true" ]]; then
        log "  [OK] $action risorsa TTL: $resource_name"
        log "       license: ${lic_id:-N/D} | availability: $availability"
    else
        local err
        err=$(echo "$resp" | jq -r '.error | to_entries | map("\(.key): \(.value)") | join(", ")' 2>/dev/null || echo "$resp")
        log "  [WARN] $action fallita per: $resource_name — $err"
    fi
}

# ---------------------------------------------------------------------------
# Funzione: corregge license_id del dataset se è una stringa descrittiva
# invece di uno slug CKAN valido (causa crash di ckanext-dcatapit su .ttl)
# DCAT-AP_IT mette la licenza sulla Distribution, non sul Dataset, ma alcuni
# portali harvested importano il titolo per esteso invece dello slug.
# ---------------------------------------------------------------------------
fix_dataset_license_if_needed() {
    local dataset_id="$1"
    local ds_json="$2"

    local license_url
    license_url=$(echo "$ds_json" | jq -r '.result.license_url // ""')

    # Se license_url è valorizzato, non c'è nulla da fare
    [[ -n "$license_url" ]] && return 0

    # license_url è None/vuoto — tentiamo di mappare license_id allo slug corretto
    local license_id
    license_id=$(echo "$ds_json" | jq -r '.result.license_id // ""')
    [[ -z "$license_id" ]] && return 0

    local new_slug=""
    case "${license_id,,}" in
        *"cc by 4.0"*|*"attribuzione 4"*|*"ccby40"*|*"cc-by 4"*) new_slug="cc-by" ;;
        *"cc by-sa"*|*"condividi allo"*) new_slug="cc-by-sa" ;;
        *"cc zero"*|*"cc0"*|*"public domain"*|*"dominio pubblico"*) new_slug="cc-zero" ;;
        *"odbl"*|*"open database"*) new_slug="odc-odbl" ;;
        *"odc-by"*|*"odc by"*) new_slug="odc-by" ;;
        *"pddl"*) new_slug="odc-pddl" ;;
        *"italian open data"*|*"iodl"*) new_slug="cc-by" ;;
    esac

    if [[ -z "$new_slug" ]]; then
        log "  [WARN] license_id non mappabile a slug CKAN: '$license_id' — dataset potrebbe non serializzare in TTL"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [DRY-RUN] Correggerei license_id: '$license_id' → '$new_slug'"
        return 0
    fi

    local resp
    local payload
    payload=$(python3 -c "import json,sys; print(json.dumps({'id':sys.argv[1],'license_id':sys.argv[2]}))" "$dataset_id" "$new_slug")
    resp=$(curl -s -X POST "${CKAN_URL}/api/3/action/package_patch"         -H "Authorization: ${CKAN_API_KEY}"         -H "Content-Type: application/json"         -d "$payload")

    local ok
    ok=$(echo "$resp" | jq -r '.success // "false"' 2>/dev/null || echo "false")
    if [[ "$ok" == "true" ]]; then
        log "  [FIX] license_id corretto: '${license_id}' → '${new_slug}' (license_url ora valorizzato)"
    else
        local err
        err=$(echo "$resp" | jq -r '.error | to_entries | map("\(.key): \(.value)") | join(", ")' 2>/dev/null || echo "$resp")
        log "  [WARN] Impossibile correggere license_id: $err"
    fi
}

# ---------------------------------------------------------------------------
# Funzione: restituisce lista dataset dell'organizzazione (JSON array di ID)
# ---------------------------------------------------------------------------
get_org_datasets() {
    local result
    result=$(curl -s \
        "${CKAN_URL}/api/3/action/organization_show?id=${CKAN_ORG}&include_datasets=true")

    if [[ "$(echo "$result" | jq -r '.success')" != "true" ]]; then
        log "[ERRORE] Impossibile recuperare l'organizzazione '${CKAN_ORG}'"
        log "         $(echo "$result" | jq -r '.error // .message // "errore sconosciuto"')"
        exit 1
    fi

    echo "$result" | jq -r '.result.packages[].id'
}

# ---------------------------------------------------------------------------
# Funzione: restituisce dettagli di un dataset
# ---------------------------------------------------------------------------
get_dataset() {
    local dataset_id="$1"
    curl -s "${CKAN_URL}/api/3/action/package_show?id=${dataset_id}"
}

# ---------------------------------------------------------------------------
# Funzione: chiama l'API CSV-to-RDF con fmt=rdf e salva il file RDF/XML
# $1 = URL del CSV
# $2 = holder_name
# $3 = holder_identifier
# $4 = percorso file di output (.rdf)
# ---------------------------------------------------------------------------
convert_csv_to_rdf() {
    local csv_url="$1"
    local pa_name="$2"
    local pa_ipa="$3"
    local out_file="$4"

    local enc_csv enc_pa
    enc_csv=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$csv_url")
    enc_pa=$(python3  -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$pa_name")

    local api_url="${CSV2RDF_API}?url=${enc_csv}&ipa=${pa_ipa}&pa=${enc_pa}&fmt=rdf"

    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        --max-time 300 \
        -o "$out_file" \
        "$api_url")

    if [[ "$http_code" != "200" ]]; then
        echo "__ERROR__:HTTP $http_code" >&2
        return 1
    fi

    # Verifica che il file sia RDF/XML valido
    if ! grep -q "<rdf:RDF\|<rdf:Description" "$out_file"; then
        echo "__ERROR__:risposta non valida dal worker (non è RDF/XML)" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Funzione: carica un file RDF/XML su CKAN come risorsa
# $1 = dataset_id
# $2 = resource_name
# $3 = file_path (.rdf)
# $4 = csv_resource_json (base64)
# $5 = existing_rdf_id (opzionale: ID risorsa da aggiornare)
# ---------------------------------------------------------------------------
upload_rdf_to_ckan() {
    local dataset_id="$1"
    local resource_name="$2"
    local file_path="$3"
    local csv_res_json
    csv_res_json=$(echo "${4:-}" | base64 --decode)
    local existing_id="${5:-}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [DRY-RUN] Salto upload RDF/XML: $resource_name (dataset: $dataset_id)"
        return 0
    fi

    # Eredita metadati licenza/availability dalla risorsa CSV sorgente
    local lic lic_id lic_type availability rights
    lic=$(      echo "$csv_res_json" | jq -r '.license      // ""')
    lic_id=$(   echo "$csv_res_json" | jq -r '.license_id   // ""')
    lic_type=$( echo "$csv_res_json" | jq -r '.license_type // ""')
    availability=$(echo "$csv_res_json" | jq -r '.availability // "https://publications.europa.eu/resource/authority/planned-availability/STABLE"')
    rights=$(      echo "$csv_res_json" | jq -r '.rights       // "http://publications.europa.eu/resource/authority/access-right/PUBLIC"')

    local fmt="RDF_XML"
    local mime="https://iana.org/assignments/media-types/application/rdf+xml"
    local desc="Conversione automatica RDF/XML generata da CSV-to-RDF (ontologie dati-semantic-assets / schema.gov.it)"

    local endpoint action resp success
    if [[ -n "$existing_id" ]]; then
        endpoint="${CKAN_URL}/api/3/action/resource_update"
        action="aggiornamento"
        resp=$(curl -s -X POST "$endpoint" \
            -H "Authorization: ${CKAN_API_KEY}" \
            -F "id=${existing_id}" \
            -F "name=${resource_name}" \
            -F "format=${fmt}" \
            -F "distribution_format=${fmt}" \
            -F "mimetype=${mime}" \
            -F "description=${desc}" \
            -F "license=${lic}" \
            -F "license_id=${lic_id}" \
            -F "license_type=${lic_type}" \
            -F "availability=${availability}" \
            -F "rights=${rights}" \
            -F "upload=@${file_path};type=application/rdf+xml")
    else
        endpoint="${CKAN_URL}/api/3/action/resource_create"
        action="creazione"
        resp=$(curl -s -X POST "$endpoint" \
            -H "Authorization: ${CKAN_API_KEY}" \
            -F "package_id=${dataset_id}" \
            -F "name=${resource_name}" \
            -F "format=${fmt}" \
            -F "distribution_format=${fmt}" \
            -F "mimetype=${mime}" \
            -F "description=${desc}" \
            -F "license=${lic}" \
            -F "license_id=${lic_id}" \
            -F "license_type=${lic_type}" \
            -F "availability=${availability}" \
            -F "rights=${rights}" \
            -F "upload=@${file_path};type=application/rdf+xml")
    fi

    success=$(echo "$resp" | jq -r '.success // "false"' 2>/dev/null || echo "false")
    if [[ "$success" == "true" ]]; then
        log "  [OK] $action risorsa RDF/XML: $resource_name"
        log "       license: ${lic_id:-N/D} | availability: $availability"
    else
        local err
        err=$(echo "$resp" | jq -r '.error | to_entries | map("\(.key): \(.value)") | join(", ")' 2>/dev/null || echo "$resp")
        log "  [WARN] $action RDF/XML fallita per: $resource_name — $err"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "======================================================"
log " CSV-to-RDF CKAN Batch Converter"
log " Org: ${CKAN_ORG} | CKAN: ${CKAN_URL}"
log " API worker: ${CSV2RDF_API}"
[[ "$DRY_RUN" == "true" ]] && log " MODALITA: DRY-RUN (nessuna scrittura su CKAN)"
log "======================================================"

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Contatori
TOTAL_CSV=0
CONVERTED_OK=0
CONVERTED_SKIP=0
CONVERTED_ERR=0
UPLOADED_NEW=0
UPLOADED_UPD=0

log "[1/3] Recupero lista dataset per l'organizzazione '${CKAN_ORG}'..."
mapfile -t DATASET_IDS < <(get_org_datasets)
log "      Trovati ${#DATASET_IDS[@]} dataset."

log "[2/3] Analisi risorse CSV per ogni dataset..."
for ds_id in "${DATASET_IDS[@]}"; do
    ds_json=$(get_dataset "$ds_id")
    ds_name=$(echo "$ds_json" | jq -r '.result.name // "?"')
    ds_title=$(echo "$ds_json" | jq -r '.result.title // "?"')

    # Raccogli tutte le risorse CSV del dataset
    mapfile -t CSV_RESOURCES < <(echo "$ds_json" | \
        jq -r '.result.resources[] | select(.format=="CSV" or (.url | test("\\.csv(\\?.*)?$";"i"))) | @base64')

    [[ ${#CSV_RESOURCES[@]} -eq 0 ]] && continue

    # Correggi license_id se è stringa descrittiva invece di slug CKAN
    # (previene crash ckanext-dcatapit su serializzazione .ttl del dataset)
    fix_dataset_license_if_needed "$ds_id" "$ds_json"

    # Leggi titolare dai campi DCAT-AP_IT del dataset; fallback su org o config
    ds_holder_name=$(echo "$ds_json" | jq -r '.result.holder_name // empty' 2>/dev/null || true)
    ds_holder_ipa=$(echo "$ds_json"  | jq -r '.result.holder_identifier // empty' 2>/dev/null || true)
    if [[ -z "$ds_holder_name" ]]; then
        ds_holder_name=$(echo "$ds_json" | jq -r '.result.organization.title // empty' 2>/dev/null || true)
    fi
    if [[ -z "$ds_holder_name" && -n "$PA_NAME_FALLBACK" ]]; then
        ds_holder_name="$PA_NAME_FALLBACK"
    fi
    if [[ -z "$ds_holder_ipa" && -n "$PA_IPA_FALLBACK" ]]; then
        ds_holder_ipa="$PA_IPA_FALLBACK"
    fi

    log ""
    log "Dataset: $ds_title ($ds_name)"
    log "  Titolare: ${ds_holder_name:-N/D} (IPA/CF: ${ds_holder_ipa:-N/D})"

    for csv_b64 in "${CSV_RESOURCES[@]}"; do
        csv_res=$(echo "$csv_b64" | base64 --decode)
        csv_id=$(echo "$csv_res" | jq -r '.id')
        csv_url=$(echo "$csv_res" | jq -r '.url')
        csv_name=$(echo "$csv_res" | jq -r '.name // "CSV"')

        TOTAL_CSV=$((TOTAL_CSV + 1))
        log "  CSV: $csv_name"
        log "       URL: $csv_url"

        # Nome della risorsa TTL attesa
        ttl_name="${csv_name}${TTL_NAME_SUFFIX}"

        # Cerca se esiste già una risorsa TTL corrispondente
        existing_ttl_id=$(echo "$ds_json" | \
            jq -r --arg tname "$ttl_name" \
            '.result.resources[] | select(.name == $tname) | .id' | head -1)

        # Converti — passa titolare letto dai metadati del dataset
        ttl_file="${TMPDIR_WORK}/$(echo "${csv_id}" | tr -d '/-').ttl"
        log "       Conversione in corso..."

        if convert_csv_to_ttl "$csv_url" "$ds_holder_name" "$ds_holder_ipa" "$ttl_file" 2>/tmp/csv2rdf_err.txt; then
            ttl_size=$(wc -c < "$ttl_file")
            log "       TTL generato: ${ttl_size} byte"
            CONVERTED_OK=$((CONVERTED_OK + 1))

            # Upload
            if [[ -n "$existing_ttl_id" ]]; then
                upload_ttl_to_ckan "$ds_id" "$ttl_name" "$ttl_file" "$csv_b64" "$existing_ttl_id"
                UPLOADED_UPD=$((UPLOADED_UPD + 1))
            else
                upload_ttl_to_ckan "$ds_id" "$ttl_name" "$ttl_file" "$csv_b64"
                UPLOADED_NEW=$((UPLOADED_NEW + 1))
            fi
        else
            err_msg=$(cat /tmp/csv2rdf_err.txt 2>/dev/null || echo "errore sconosciuto")
            if [[ "$err_msg" == __SKIP__* ]]; then
                log "  [SKIP] $csv_name — ${err_msg#__SKIP__:}"
                CONVERTED_SKIP=$((CONVERTED_SKIP + 1))
            else
                log "  [WARN] Conversione fallita per: $csv_name"
                log "         Motivo: $err_msg"
                CONVERTED_ERR=$((CONVERTED_ERR + 1))
            fi
        fi

        # --- RDF/XML opzionale ---
        if [[ "${RDF_XML:-false}" == "true" ]] && [[ -f "$ttl_file" ]]; then
            rdf_name="${csv_name} (RDF/XML)"
            rdf_file="${TMPDIR_WORK}/$(echo "${csv_id}" | tr -d '/-').rdf"

            # Cerca risorsa RDF/XML esistente nel dataset
            existing_rdf_id=$(echo "$ds_json" | \
                jq -r --arg rname "$rdf_name" \
                '.result.resources[] | select(.name == $rname) | .id' | head -1)

            log "       Generazione RDF/XML..."
            if convert_csv_to_rdf "$csv_url" "$ds_holder_name" "$ds_holder_ipa" "$rdf_file" 2>/tmp/csv2rdf_err.txt; then
                rdf_size=$(wc -c < "$rdf_file")
                log "       RDF/XML generato: ${rdf_size} byte"
                if [[ -n "$existing_rdf_id" ]]; then
                    upload_rdf_to_ckan "$ds_id" "$rdf_name" "$rdf_file" "$csv_b64" "$existing_rdf_id"
                    UPLOADED_UPD=$((UPLOADED_UPD + 1))
                else
                    upload_rdf_to_ckan "$ds_id" "$rdf_name" "$rdf_file" "$csv_b64"
                    UPLOADED_NEW=$((UPLOADED_NEW + 1))
                fi
            else
                err_msg=$(cat /tmp/csv2rdf_err.txt 2>/dev/null || echo "errore sconosciuto")
                log "  [WARN] Generazione RDF/XML fallita per: $csv_name — $err_msg"
            fi
        fi

        sleep "$SLEEP_BETWEEN"
    done
done

log ""
log "[3/3] Riepilogo"
log "======================================================"
log " CSV analizzati:       $TOTAL_CSV"
log " Conversioni OK:       $CONVERTED_OK"
log " CSV saltati (non mappati): $CONVERTED_SKIP"
log " Conversioni fallite:  $CONVERTED_ERR"
log " Risorse TTL create:   $UPLOADED_NEW"
log " Risorse TTL aggiornate: $UPLOADED_UPD"
log "======================================================"
