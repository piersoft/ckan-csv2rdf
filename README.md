# ckan-csv2rdf

> Conversione automatica da CSV a RDF/Turtle per portali CKAN italiani  
> Automatic CSV to RDF/Turtle conversion for Italian CKAN portals

---

## Italiano

### Descrizione

`ckan_csv2rdf.sh` è uno script Bash che automatizza la conversione dei file CSV presenti su un portale CKAN in formato RDF/Turtle, utilizzando l'API pubblica di [CSV-to-RDF](https://github.com/piersoft/CSV-to-RDF).

Per ogni dataset dell'organizzazione configurata, lo script:

1. Individua le risorse in formato CSV
2. Le converte in RDF/Turtle tramite il worker `csv2rdf.datigovit.workers.dev`
3. Carica il file TTL come nuova risorsa sul dataset CKAN, oppure aggiorna quella esistente
4. Eredita automaticamente i metadati DCAT-AP_IT dalla risorsa CSV sorgente (licenza, availability, rights)
5. Legge il titolare (`dct:rightsHolder`, `dct:identifier`) dai campi `holder_name` / `holder_identifier` di ogni dataset — compatibile con portali federati con N enti diversi

### Requisiti

- `bash` >= 4.0
- `curl`
- `jq`
- `python3` (per l'URL-encoding dei parametri)
- Un portale CKAN con il plugin [ckanext-dcatapit](https://github.com/italia/ckanext-dcatapit) (profilo DCAT-AP_IT)
- Una API key CKAN con permessi di scrittura sull'organizzazione

### Installazione

```bash
git clone https://github.com/piersoft/ckan-csv2rdf.git
cd ckan-csv2rdf
chmod +x ckan_csv2rdf.sh
cp ckan_csv2rdf.conf.example ckan_csv2rdf.conf
```

### Configurazione

Modifica `ckan_csv2rdf.conf` con i dati del tuo portale:

```bash
# URL base del CKAN (senza trailing slash)
CKAN_URL="https://dati.mioente.it"

# API key con permessi di scrittura sull'organizzazione
CKAN_API_KEY="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Slug dell'organizzazione CKAN
CKAN_ORG="comune-di-esempio"
```

I campi `holder_name` e `holder_identifier` vengono letti automaticamente dai metadati di ogni dataset (standard DCAT-AP_IT). È sufficiente configurare i campi `PA_NAME_FALLBACK` / `PA_IPA_FALLBACK` solo se alcuni dataset non hanno questi campi valorizzati.

### Utilizzo

```bash
# Esecuzione normale
./ckan_csv2rdf.sh

# Con file di configurazione personalizzato
./ckan_csv2rdf.sh /percorso/mio.conf

# Dry-run: simula senza scrivere nulla su CKAN
DRY_RUN="true" ./ckan_csv2rdf.sh

# Con log su file
LOG_FILE="/var/log/ckan_csv2rdf.log" ./ckan_csv2rdf.sh
```

### Metadati della risorsa TTL generata

Ogni risorsa TTL viene caricata con metadati completi e conformi a DCAT-AP_IT:

| Campo | Valore |
|---|---|
| `format` | `RDF_TURTLE` |
| `distribution_format` | `RDF_TURTLE` |
| `mimetype` | `https://iana.org/assignments/media-types/text/turtle` |
| `license` | ereditato dalla risorsa CSV sorgente |
| `license_id` | ereditato dalla risorsa CSV sorgente |
| `license_type` | ereditato dalla risorsa CSV sorgente |
| `availability` | ereditato (default: `STABLE`) |
| `rights` | ereditato (default: `PUBLIC`) |

### Automazione (cron)

```cron
# Esegui ogni notte alle 03:00
0 3 * * * /percorso/ckan_csv2rdf.sh /percorso/ckan_csv2rdf.conf >> /var/log/ckan_csv2rdf.log 2>&1
```

### Portali federati

Lo script è progettato per portali CKAN che aggregano dati di più enti (Comuni, Province, Regioni, ecc.). Il titolare viene letto dataset per dataset dai campi DCAT-AP_IT:

- `holder_name` → nome PA (es. `Comune di Mesagne`)
- `holder_identifier` → codice IPA o CF (es. `c_f152`)

Se questi campi mancano, lo script usa `organization.title` come fallback.

---

## English

### Description

`ckan_csv2rdf.sh` is a Bash script that automates the conversion of CSV files on a CKAN portal to RDF/Turtle format, using the public API of [CSV-to-RDF](https://github.com/piersoft/CSV-to-RDF).

For each dataset in the configured organization, the script:

1. Finds resources in CSV format
2. Converts them to RDF/Turtle via the `csv2rdf.datigovit.workers.dev` worker
3. Uploads the TTL file as a new resource on the CKAN dataset, or updates the existing one
4. Automatically inherits DCAT-AP_IT metadata from the source CSV resource (license, availability, rights)
5. Reads the rightsHolder (`dct:rightsHolder`, `dct:identifier`) from each dataset's `holder_name` / `holder_identifier` fields — fully compatible with federated portals hosting N different organizations

### Requirements

- `bash` >= 4.0
- `curl`
- `jq`
- `python3` (for URL-encoding of parameters)
- A CKAN portal with the [ckanext-dcatapit](https://github.com/italia/ckanext-dcatapit) plugin (DCAT-AP_IT profile)
- A CKAN API key with write permissions on the organization

### Installation

```bash
git clone https://github.com/piersoft/ckan-csv2rdf.git
cd ckan-csv2rdf
chmod +x ckan_csv2rdf.sh
cp ckan_csv2rdf.conf.example ckan_csv2rdf.conf
```

### Configuration

Edit `ckan_csv2rdf.conf` with your portal details:

```bash
# CKAN base URL (no trailing slash)
CKAN_URL="https://myportal.example.it"

# API key with write permissions on the organization
CKAN_API_KEY="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# CKAN organization slug
CKAN_ORG="my-organization"
```

The `holder_name` and `holder_identifier` fields are read automatically from each dataset's metadata (DCAT-AP_IT standard). The `PA_NAME_FALLBACK` / `PA_IPA_FALLBACK` fields only need to be set if some datasets are missing these fields.

### Usage

```bash
# Normal execution
./ckan_csv2rdf.sh

# With custom config file
./ckan_csv2rdf.sh /path/to/my.conf

# Dry-run: simulate without writing anything to CKAN
DRY_RUN="true" ./ckan_csv2rdf.sh

# With log file
LOG_FILE="/var/log/ckan_csv2rdf.log" ./ckan_csv2rdf.sh
```

### Metadata of the generated TTL resource

Each TTL resource is uploaded with complete DCAT-AP_IT compliant metadata:

| Field | Value |
|---|---|
| `format` | `RDF_TURTLE` |
| `distribution_format` | `RDF_TURTLE` |
| `mimetype` | `https://iana.org/assignments/media-types/text/turtle` |
| `license` | inherited from source CSV resource |
| `license_id` | inherited from source CSV resource |
| `license_type` | inherited from source CSV resource |
| `availability` | inherited (default: `STABLE`) |
| `rights` | inherited (default: `PUBLIC`) |

### Automation (cron)

```cron
# Run every night at 03:00
0 3 * * * /path/to/ckan_csv2rdf.sh /path/to/ckan_csv2rdf.conf >> /var/log/ckan_csv2rdf.log 2>&1
```

### Federated portals

The script is designed for CKAN portals that aggregate data from multiple organizations (municipalities, provinces, regions, etc.). The rightsHolder is read dataset by dataset from DCAT-AP_IT fields:

- `holder_name` → PA name (e.g. `Comune di Mesagne`)
- `holder_identifier` → IPA or tax code (e.g. `c_f152`)

If these fields are missing, the script falls back to `organization.title`.

---

## Licenza / License

[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) — Francesco Piero Paolicelli (piersoft)
