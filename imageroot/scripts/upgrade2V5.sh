#!/bin/bash

#
# Copyright (C) 2026 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

#
# Upgrade this instance from Dependency-Track v4 to v5.
#
# v5 is not an in-place upgrade of v4: the schemas are incompatible and a v5
# apiserver must never boot against a v4 database. The official v4-migrator
# copies the data offline into a fresh v5 database:
#   https://dependencytrack.github.io/docs/next/guides/administration/migrating-from-v4/
#
# This script ships with the v4 module and is gone from 2.0.0. Run it as the
# module user, on the node hosting the instance -- which is not necessarily the
# leader:
#
#   runagent -m dependencytrack1 bash ../scripts/upgrade2V5.sh
#
# It stops there, with the services down, and prints the update-module command
# to run from the leader. Updating to 2.0.0 deletes this file, so phase 1 keeps
# a copy of it under state/ for the second phase:
#
#   runagent -m dependencytrack1 bash upgrade2V5.sh analyzers
#
# On failure both dumps stay on disk and the run is resumable.
#

set -E -e -o pipefail
exec 1>&2 # Redirect any output to the journal (stderr)

SD_ERR='<3>'
SD_WARN='<4>'

if [[ -z "${AGENT_STATE_DIR:-}" || -z "${MODULE_ID:-}" ]]; then
    echo "${SD_ERR}This script must run in the module context:" \
         "runagent -m <instance> bash ../scripts/upgrade2V5.sh"
    exit 2
fi

# Resolved before the cd below, because it is usually a relative path.
SELF=$(readlink -f "$0")

# Callers run from different directories.
cd "${AGENT_STATE_DIR}"

# The v4 module never runs the migrator, so its image is not in
# org.nethserver.images and no *_IMAGE variable holds it. The migrator only has
# to read the v4 schema and write the v5 one: a later apiserver upgrades what it
# produced through Flyway on its first boot.
V4_MIGRATOR_IMAGE="${V4_MIGRATOR_IMAGE:-ghcr.io/dependencytrack/v4-migrator:5.0.4}"
# Pre-pulled to shorten the outage. A mismatch with what 2.0.0 ships costs a
# wasted download and nothing else, so this is never fatal.
V5_APISERVER_IMAGE="${V5_APISERVER_IMAGE:-docker.io/dependencytrack/apiserver:5.0.4}"
V5_FRONTEND_IMAGE="${V5_FRONTEND_IMAGE:-docker.io/dependencytrack/frontend:5.0.4}"

SRC_CTR="dt_migrate_src"
DST_CTR="dt_migrate_dst"
LOAD_CTR="dt_migrate_load"
NET="dt_migrate_net"
DST_VOL="postgres-migrate-v5"
DB="dependencytrack"
BACKUP_DIR="backup-v4"
UNITS=(dependencytrack.service postgresql-app.service dependencytrack-apiserver.service
       dependencytrack-frontend.service dependencytrack-nginx.service trivy-app.service)
TRIVY_URL="http://127.0.0.1:8282"
SECRET_NAME="trivy-api-token"
# Not state/restore/: postgresql-app.service mounts it as
# /docker-entrypoint-initdb.d/, where a leftover restore script would run.
WORK_DIR="migrate-v5"
V4_DUMP="${BACKUP_DIR}/${DB}-v4.pg_dump"
V5_DUMP="${WORK_DIR}/${DB}.pg_dump"
ANALYZERS_ENV="${WORK_DIR}/analyzers.env"
SELF_COPY="upgrade2V5.sh"
# Present means a previous run died while replacing postgres-data, so the next
# run must resume instead of inspecting a volume that is empty at that point.
SWAP_FLAG="${WORK_DIR}/.swap-in-progress"
# Mandatory flag of `run`.
METRICS_RETENTION_DAYS=90

fail() {
    echo "${SD_ERR}$*"
    exit 1
}

read_secret() {
    grep -E "^$1=" secrets.env | cut -d= -f2- || true
}

# `podman volume rm` and `podman network rm` have no --ignore flag, so probe first.
cleanup_temp() {
    podman rm --ignore -f "${SRC_CTR}" "${DST_CTR}" "${LOAD_CTR}" >/dev/null 2>&1 || true
    if podman network exists "${NET}"; then
        podman network rm "${NET}" >/dev/null || true
    fi
    if podman volume exists "${DST_VOL}"; then
        podman volume rm --force "${DST_VOL}" >/dev/null || true
    fi
}

wait_ready() {
    local ctr="$1" tries=0
    until podman exec "${ctr}" pg_isready -U postgres -d "${DB}" >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [[ ${tries} -ge 60 ]]; then
            fail "Timed out waiting for ${ctr} to accept connections"
        fi
        sleep 2
    done
}

run_postgres() {
    local name="$1" volume="$2"
    shift 2
    podman run -d --replace --name "${name}" --network "${NET}" \
        --volume "${volume}:/var/lib/postgresql/data:Z" \
        --env POSTGRES_USER=postgres \
        --env POSTGRES_PASSWORD="${POSTGRES_TOKEN}" \
        --env POSTGRES_DB="${DB}" \
        --env TZ=UTC \
        "${POSTGRES_IMAGE}" "$@" >/dev/null
    wait_ready "${name}"
}

src_query() {
    podman exec "${SRC_CTR}" psql -U postgres -d "${DB}" -tAc "$1"
}

run_migrator() {
    podman run --rm --network "${NET}" --env TZ=UTC "${V4_MIGRATOR_IMAGE}" "$@" \
        --target-url "${JDBC_DST}" --target-user postgres --target-pass "${POSTGRES_TOKEN}"
}

# v5 cannot be given an API key, and the analyzer phase needs one. Format and
# hashing come from Alpine's ApiKeyGenerator.
# Called in an `if !` condition, which turns errexit off for the whole body, so
# every step has to report its own failure.
create_api_key() {
    local pub sec hash
    read -r pub sec hash < <(python3 - <<'EOS'
import hashlib, secrets
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456879"
pub = "".join(secrets.choice(alphabet) for _ in range(8))
sec = "".join(secrets.choice(alphabet) for _ in range(32))
print(pub, sec, hashlib.sha3_256(sec.encode()).hexdigest())
EOS
    ) || return 1
    [[ -n "${pub}" && -n "${sec}" && -n "${hash}" ]] || return 1

    podman exec -i "${DST_CTR}" psql -U postgres -d "${DB}" -v ON_ERROR_STOP=1 -q <<EOS || return 1
DO \$\$
DECLARE team_id bigint; key_id bigint;
BEGIN
    INSERT INTO "TEAM" ("NAME", "UUID")
        VALUES ('NethServer module', gen_random_uuid()::text) RETURNING "ID" INTO team_id;
    INSERT INTO "TEAMS_PERMISSIONS" ("TEAM_ID", "PERMISSION_ID")
        SELECT team_id, "ID" FROM "PERMISSION"
         WHERE "NAME" IN ('SECRET_MANAGEMENT', 'SYSTEM_CONFIGURATION');
    INSERT INTO "APIKEY" ("COMMENT", "CREATED", "SECRET_HASH", "PUBLIC_ID", "IS_LEGACY")
        VALUES ('Used by the NethServer module', now(), '${hash}', '${pub}', false)
        RETURNING "ID" INTO key_id;
    INSERT INTO "APIKEYS_TEAMS" ("TEAM_ID", "APIKEY_ID") VALUES (team_id, key_id);
END
\$\$;
EOS

    DT_API_KEY="odt_${pub}_${sec}" python3 - <<'EOS' || return 1
import os, agent
env = agent.read_envfile("secrets.env")
env["DT_API_KEY"] = os.environ["DT_API_KEY"]
agent.write_envfile("secrets.env", env)
EOS
}

# Same reload idiom as actions/restore-module/40restore_database.
swap_in_migrated_database() {
    cat - >"${WORK_DIR}/${DB}_restore.sh" <<'EOS'
# Read dump file from standard input:
pg_restore --no-owner --no-privileges -U postgres -d dependencytrack
ec=$?
docker_temp_server_stop
exit $ec
EOS

    touch "${SWAP_FLAG}"
    if podman volume exists postgres-data; then
        podman volume rm --force postgres-data >/dev/null
    fi
    podman volume create postgres-data >/dev/null

    podman run --rm --interactive --network=none \
        --volume "./${WORK_DIR}:/docker-entrypoint-initdb.d/:Z" \
        --volume "postgres-data:/var/lib/postgresql/data:Z" \
        --replace --name "${LOAD_CTR}" \
        --env POSTGRES_USER=postgres \
        --env POSTGRES_PASSWORD="${POSTGRES_TOKEN}" \
        --env POSTGRES_DB="${DB}" \
        --env TZ=UTC \
        "${POSTGRES_IMAGE}" <"${V5_DUMP}"

    rm -f "${SWAP_FLAG}" "${V5_DUMP}" "${WORK_DIR}/${DB}_restore.sh"
}

next_step() {
    echo
    echo "The database is migrated and the services are stopped and disabled."
    echo "Now update the instance to 2.0.0. On the leader node, run:"
    echo
    echo "  api-cli run update-module --data '{\"module_url\":" \
         "\"ghcr.io/nethserver/dependencytrack:2.0.0\", \"instances\":" \
         "[\"${MODULE_ID}\"], \"force\":true}'"
    echo
    echo "then come back to this node and run:"
    echo
    echo "  runagent -m ${MODULE_ID} bash ${SELF_COPY} analyzers"
    echo
    echo "That update deletes this script, which is why phase 1 kept a copy at"
    echo "state/${SELF_COPY}."
}

##
## Phase 1: migrate the database, offline, with the module still on v4
##

# Not local to phase_migrate: the EXIT trap fires once that function has returned.
completed=""

phase_migrate() {
    # An ERR trap would miss the `exit 1` of the checks below.
    on_exit() {
        local rc=$?
        cleanup_temp
        if [[ -n "${completed}" ]]; then
            return
        fi
        echo "${SD_ERR}Upgrade to Dependency-Track v5 failed (exit ${rc}). Services are left"
        echo "${SD_ERR}stopped on purpose: a v5 apiserver must not run against a v4 database."
        if [[ -f "${SWAP_FLAG}" && -f "${V5_DUMP}" ]]; then
            echo "${SD_ERR}The database was being replaced. The migrated dump is kept at"
            echo "${SD_ERR}state/${V5_DUMP} and the next run resumes from it."
        fi
        if [[ -f "${V4_DUMP}" ]]; then
            echo "${SD_ERR}The v4 data is dumped at state/${V4_DUMP}"
        fi
        echo "${SD_ERR}Fix the reported error, then run this script again to retry."
    }
    trap on_exit EXIT

    echo
    echo "${SD_WARN}This rewrites the module database. Make sure a backup of ${MODULE_ID} ran"
    echo "${SD_WARN}recently, and run one now if it did not. On the leader node:"
    echo "${SD_WARN}    api-cli run list-backups | jq '.backups[]'"
    echo "${SD_WARN}    api-cli run run-backup --data '{\"id\": <backup id>}'"
    echo

    mkdir -p "${WORK_DIR}"

    # Updating to 2.0.0 removes every file the new image does not ship, this one
    # included, so phase 2 has to run from a copy under state/.
    if [[ "${SELF}" != "$(readlink -f "${SELF_COPY}")" ]]; then
        cp -f "${SELF}" "${SELF_COPY}"
    fi

    # Stopped and disabled: a reboot must not start a v4 apiserver on a migrated
    # database. Every unit has to be disabled, not just the pod: the others are
    # WantedBy=default.target too, and their BindsTo would drag the pod back up.
    systemctl --user disable "${UNITS[@]}" >/dev/null 2>&1 || true
    if systemctl --user --quiet is-active dependencytrack.service; then
        systemctl --user stop dependencytrack.service
    fi

    # postgres-data is empty or half loaded here: inspecting it would conclude
    # "fresh install" and replace a database that is already migrated.
    if [[ -f "${SWAP_FLAG}" ]]; then
        if [[ ! -f "${V5_DUMP}" ]]; then
            fail "A previous run was interrupted while replacing the database, but" \
                 "state/${V5_DUMP} is gone. Restore state/${V4_DUMP} into a v4 instance by hand."
        fi
        echo "Resuming an interrupted migration from state/${V5_DUMP}."
        swap_in_migrated_database
        completed=1
        next_step
        return 0
    fi

    podman pull "${V4_MIGRATOR_IMAGE}"

    cleanup_temp
    podman network create "${NET}" >/dev/null
    run_postgres "${SRC_CTR}" postgres-data

    # v5 tracks its schema with Flyway, v4 with DataNucleus and Liquibase.
    if [[ "$(src_query "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL")" == "t" ]]; then
        fail "This database is already on the v5 schema. If the module is still on v4," \
             "update it to 2.0.0 and run this script again with the analyzers argument."
    fi

    table_count=$(src_query "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
    # An empty string compares equal to 0 with -eq, and would read as a fresh install.
    if [[ ! "${table_count}" =~ ^[0-9]+$ ]]; then
        fail "Could not count the tables of the ${DB} database, got '${table_count}'."
    fi

    if [[ "${table_count}" -eq 0 ]]; then
        fail "This database is empty. Install 2.0.0 directly instead of upgrading."
    fi

    if [[ "$(src_query "SELECT to_regclass('public.\"SCHEMAVERSION\"') IS NOT NULL OR to_regclass('public.\"EVENTSERVICELOG\"') IS NOT NULL")" != "t" ]]; then
        fail "The database holds tables but neither a v4 nor a v5 schema marker." \
             "Refusing to guess: migrate it by hand first."
    fi

    echo "Dependency-Track v4 schema detected, starting the upgrade to v5."

    # v5 turned the analyzers into plugins whose runtime config the migrator does
    # not populate, so every switch below has to be carried over by hand. Read
    # them before the migrator drops them. Defaults are v4's, not v5's: scanOs
    # and ossindex are on in v4 and off in v5.
    read_v4_property() {
        local value
        value=$(src_query "SELECT \"PROPERTYVALUE\" FROM \"CONFIGPROPERTY\"
                            WHERE \"GROUPNAME\" = '$1' AND \"PROPERTYNAME\" = '$2'") || return 1
        echo "${value:-$3}"
    }

    # An unreadable property must stop the run: recording the v4 default as if
    # it were the admin's setting would push a wrong value into v5.
    save_v4_property() {
        local value
        value=$(read_v4_property "$2" "$3" "$4") ||
            fail "Could not read the v4 setting $2/$3 from the database."
        printf '%s=%q\n' "$1" "${value}"
    }

    {
        save_v4_property DT_TRIVY_URL scanner trivy.base.url ""
        save_v4_property DT_TRIVY_ENABLED scanner trivy.enabled false
        save_v4_property DT_TRIVY_IGNORE_UNFIXED scanner trivy.ignore.unfixed false
        save_v4_property DT_TRIVY_SCAN_LIBRARY scanner trivy.scanner.scanLibrary true
        save_v4_property DT_TRIVY_SCAN_OS scanner trivy.scanner.scanOs true
        save_v4_property DT_INTERNAL_ENABLED scanner internal.enabled true
        save_v4_property DT_NVD_ENABLED vuln-source nvd.enabled true
        save_v4_property DT_NVD_FEEDS_URL vuln-source nvd.feeds.url https://nvd.nist.gov/feeds
        save_v4_property DT_OSV_ECOSYSTEMS vuln-source google.osv.enabled ""
        save_v4_property DT_OSV_URL vuln-source google.osv.base.url https://osv-vulnerabilities.storage.googleapis.com
        save_v4_property DT_OSV_ALIAS_SYNC vuln-source google.osv.alias.sync.enabled false
        save_v4_property DT_OSSINDEX_ENABLED scanner ossindex.enabled true
        save_v4_property DT_OSSINDEX_URL scanner ossindex.base.url https://ossindex.sonatype.org
        save_v4_property DT_OSSINDEX_USERNAME scanner ossindex.api.username ""
        save_v4_property DT_OSSINDEX_ALIAS_SYNC scanner ossindex.alias.sync.enabled true
        save_v4_property DT_GITHUB_ENABLED vuln-source github.advisories.enabled false
        save_v4_property DT_GITHUB_URL vuln-source github.advisories.api.url https://api.github.com/graphql
        save_v4_property DT_GITHUB_ALIAS_SYNC vuln-source github.advisories.alias.sync.enabled true
        save_v4_property DT_SNYK_ENABLED scanner snyk.enabled false
        save_v4_property DT_SNYK_URL scanner snyk.base.url https://api.snyk.io
        save_v4_property DT_SNYK_ORG_ID scanner snyk.org.id ""
        save_v4_property DT_SNYK_ALIAS_SYNC scanner snyk.alias.sync.enabled false
        save_v4_property DT_VULNDB_ENABLED scanner vulndb.enabled false
    } >"${ANALYZERS_ENV}"
    echo "v4 analyzer settings saved to state/${ANALYZERS_ENV}"

    mkdir -p "${BACKUP_DIR}"
    podman exec "${SRC_CTR}" pg_dump -U postgres -Fc "${DB}" >"${V4_DUMP}"
    echo "v4 backup written to state/${V4_DUMP}"

    # Both are raised on the migrator preflight's request: the load writes in bulk
    # and attaching the metrics partitions takes many locks in one transaction.
    run_postgres "${DST_CTR}" "${DST_VOL}" \
        -c max_wal_size=4GB -c max_locks_per_transaction=256

    run_migrator bootstrap
    run_migrator verify
    run_migrator run \
        --source-url "${JDBC_SRC}" --source-user postgres --source-pass "${POSTGRES_TOKEN}" \
        --metrics-retention-days "${METRICS_RETENTION_DAYS}"
    run_migrator verify
    run_migrator cleanup

    if ! create_api_key; then
        echo "${SD_WARN}Could not create an API key for the module: the analyzers will have to"
        echo "${SD_WARN}be configured by hand."
    fi

    podman exec "${DST_CTR}" pg_dump -U postgres -Fc "${DB}" >"${V5_DUMP}"
    podman rm --ignore -f "${SRC_CTR}" "${DST_CTR}" >/dev/null

    # Downloaded while the migrated dump is safe on disk but before the swap, so
    # a slow registry does not stretch the window with a half-replaced volume.
    podman pull "${V5_APISERVER_IMAGE}" "${V5_FRONTEND_IMAGE}" || \
        echo "${SD_WARN}Could not pre-pull the v5 images, update-module will fetch them."

    swap_in_migrated_database

    # Keeps dependencytrack-setup.service of 2.0.0 from configuring Trivy on its
    # own defaults before the analyzer phase replays the v4 ones.
    python3 -c 'import agent; agent.set_env("DT_TRIVY_SETUP", "pending-migration")'

    completed=1
    next_step
}

##
## Phase 2: carry the v4 analyzers over, with the module on 2.0.0
##

phase_analyzers() {
    if [[ ! -f "${ANALYZERS_ENV}" ]]; then
        fail "state/${ANALYZERS_ENV} is missing: run the migration phase first."
    fi

    local api_key trivy_token
    api_key=$(read_secret DT_API_KEY)
    trivy_token=$(read_secret TRIVY_TOKEN)
    if [[ -z "${api_key}" ]]; then
        fail "No DT_API_KEY in secrets.env: configure the analyzers by hand."
    fi

    set -a
    # shellcheck disable=SC1090
    . "./${ANALYZERS_ENV}"
    set +a

    systemctl --user enable "${UNITS[@]}"
    # Shipped by 2.0.0 only, and it stands down while DT_TRIVY_SETUP is set.
    systemctl --user enable dependencytrack-setup.service 2>/dev/null || true
    systemctl --user start dependencytrack.service

    local api="http://127.0.0.1:${TCP_PORT}/api"
    # The apiserver runs its init tasks before serving, and the first v5 boot
    # spends minutes in Flyway.
    local ready=""
    for _ in $(seq 1 120); do
        if curl -sf -o /dev/null "${api}/version"; then
            ready=1
            break
        fi
        sleep 5
    done
    if [[ -z "${ready}" ]]; then
        fail "The apiserver did not answer within 10 minutes. Check its journal, then run" \
             "this phase again: it is safe to repeat."
    fi

    call() {
        local method="$1" path="$2" body="$3"
        curl -sS -o /dev/null -w '%{http_code}' -X "${method}" "${api}/v2${path}" \
            -H "X-Api-Key: ${api_key}" \
            -H "Content-Type: application/json" \
            -d "${body}" || true
    }

    # 304 means what we sent is already stored, which happens whenever a v4
    # setting matches the v5 default.
    put_extension_config() {
        local point="$1" extension="$2" body="$3" code
        code=$(call PUT "/extension-points/${point}/extensions/${extension}/config" "${body}")
        case "${code}" in
            200 | 204 | 304) return 0 ;;
        esac
        echo "${SD_WARN}Could not configure ${extension} (HTTP ${code}), do it by hand."
        return 1
    }

    local trivy_state=none
    if [[ -n "${DT_TRIVY_URL}" && "${DT_TRIVY_URL}" != "${TRIVY_URL}" ]]; then
        # Their token is encrypted and gone, so another server means hands off.
        echo "${SD_WARN}Trivy was pointed at ${DT_TRIVY_URL}, not at the server this module runs."
        echo "${SD_WARN}Leaving the analyzer alone: its token cannot be recovered from v4."
    elif [[ -z "${trivy_token}" ]]; then
        echo "${SD_WARN}No Trivy token in secrets.env, leaving the analyzer alone."
    else
        # 409 means the secret survived from an earlier run, which is just as good.
        local secret_body code
        secret_body=$(N="${SECRET_NAME}" V="${trivy_token}" python3 -c \
            'import json,os;print(json.dumps({"name":os.environ["N"],"value":os.environ["V"]}))')
        code=$(call POST /secrets "${secret_body}")
        if [[ "${code}" != "201" && "${code}" != "409" ]]; then
            echo "${SD_WARN}Could not store the Trivy token as a Dependency-Track secret (HTTP ${code})."
            echo "${SD_WARN}Configure the Trivy analyzer by hand, the values are in the module settings."
        else
            local body
            body=$(U="${TRIVY_URL}" N="${SECRET_NAME}" \
                E="${DT_TRIVY_ENABLED}" I="${DT_TRIVY_IGNORE_UNFIXED}" \
                L="${DT_TRIVY_SCAN_LIBRARY}" O="${DT_TRIVY_SCAN_OS}" python3 -c '
import json, os
flag = lambda name: os.environ[name].strip().lower() == "true"
print(json.dumps({"config": {
    "enabled": flag("E"),
    "apiUrl": os.environ["U"],
    "apiToken": os.environ["N"],
    "scanLibrary": flag("L"),
    "scanOs": flag("O"),
    "ignoreUnfixed": flag("I"),
}}))')
            if put_extension_config vuln-analyzer trivy "${body}"; then
                # "prepared": secret and URL in place, but v4 had it off so it stays off.
                if [[ "${DT_TRIVY_ENABLED}" == "true" ]]; then
                    trivy_state=enabled
                else
                    trivy_state=prepared
                fi
            fi
        fi
    fi

    local body
    body=$(E="${DT_INTERNAL_ENABLED}" python3 -c \
        'import json,os;print(json.dumps({"config":{"enabled":os.environ["E"].strip().lower()=="true"}}))')
    put_extension_config vuln-analyzer internal "${body}" || true

    body=$(E="${DT_NVD_ENABLED}" U="${DT_NVD_FEEDS_URL}" python3 -c \
        'import json,os;print(json.dumps({"config":{"enabled":os.environ["E"].strip().lower()=="true","cveFeedsUrl":os.environ["U"]}}))')
    put_extension_config vuln-data-source nvd "${body}" || true

    # v4 stored the OSV ecosystems as a semicolon separated list, empty meaning off.
    # v5 keeps them in an array and refuses an empty one while enabled.
    body=$(L="${DT_OSV_ECOSYSTEMS}" U="${DT_OSV_URL}" A="${DT_OSV_ALIAS_SYNC}" python3 -c '
import json, os
ecosystems = [e.strip() for e in os.environ["L"].split(";") if e.strip()]
config = {
    "enabled": bool(ecosystems),
    "dataUrl": os.environ["U"],
    "aliasSyncEnabled": os.environ["A"].strip().lower() == "true",
}
if ecosystems:
    config["ecosystems"] = ecosystems
print(json.dumps({"config": config}))')
    put_extension_config vuln-data-source osv "${body}" || true

    # These need a token v4 encrypted and the migrator wiped, so v5 would reject
    # them enabled. Store everything else, leaving the token as the only thing to
    # type. VulnDB gets nothing: v4 authenticated with OAuth1, v5 wants OAuth2.
    body=$(U="${DT_OSSINDEX_URL}" N="${DT_OSSINDEX_USERNAME}" A="${DT_OSSINDEX_ALIAS_SYNC}" python3 -c '
import json, os
config = {
    "enabled": False,
    "apiUrl": os.environ["U"],
    "aliasSyncEnabled": os.environ["A"].strip().lower() == "true",
}
if os.environ["N"]:
    config["username"] = os.environ["N"]
print(json.dumps({"config": config}))')
    put_extension_config vuln-analyzer oss-index "${body}" || true

    body=$(U="${DT_GITHUB_URL}" A="${DT_GITHUB_ALIAS_SYNC}" python3 -c '
import json, os
print(json.dumps({"config": {
    "enabled": False,
    "apiUrl": os.environ["U"],
    "aliasSyncEnabled": os.environ["A"].strip().lower() == "true",
}}))')
    put_extension_config vuln-data-source github "${body}" || true

    body=$(U="${DT_SNYK_URL}" O="${DT_SNYK_ORG_ID}" A="${DT_SNYK_ALIAS_SYNC}" python3 -c '
import json, os
config = {
    "enabled": False,
    "apiBaseUrl": os.environ["U"],
    "aliasSyncEnabled": os.environ["A"].strip().lower() == "true",
}
if os.environ["O"]:
    config["orgId"] = os.environ["O"]
print(json.dumps({"config": config}))')
    put_extension_config vuln-analyzer snyk "${body}" || true

    # v4 had these running, v5 wants a token we lost. Everything but their token
    # is already in place, above.
    local pending=""
    add_pending() {
        [[ "${2}" == "true" ]] && pending="${pending:+${pending}, }$1"
        return 0
    }
    add_pending "OSS Index" "${DT_OSSINDEX_ENABLED}"
    add_pending "GitHub Advisories" "${DT_GITHUB_ENABLED}"
    add_pending "Snyk" "${DT_SNYK_ENABLED}"
    add_pending "VulnDB" "${DT_VULNDB_ENABLED}"

    python3 -c 'import agent; agent.set_env("DT_TRIVY_SETUP", "done")'

    echo
    echo "Upgrade complete. Analyzers carried over: trivy=${trivy_state}," \
         "internal=${DT_INTERNAL_ENABLED}, nvd=${DT_NVD_ENABLED}, osv=[${DT_OSV_ECOSYSTEMS}]."
    echo
    echo "${SD_WARN}v5 cannot decrypt what v4 encrypted, so the migrator cleared every secret."
    echo "${SD_WARN}Still to do by hand:"
    if [[ -n "${pending}" ]]; then
        echo "${SD_WARN}  - enter the API token of: ${pending}"
        echo "${SD_WARN}    (everything else about them is already configured)"
    fi
    echo "${SD_WARN}  - re-enter the repository passwords, their repository is disabled"
    echo "${SD_WARN}  - re-enter the integration keys"
    echo "${SD_WARN}  - re-enable the notification rules, they came back disabled"
    echo
    echo "${SD_WARN}Run a backup of ${MODULE_ID} now. Every snapshot taken before this upgrade"
    echo "${SD_WARN}holds a v4 database, which this version refuses to restore. On the leader node:"
    echo "${SD_WARN}    api-cli run run-backup --data '{\"id\": <backup id>}'"
    echo
    echo "state/${V4_DUMP} is kept. Remove it once the instance is proven."
}

##
## Entry point
##

POSTGRES_TOKEN=$(read_secret POSTGRES_TOKEN)
if [[ -z "${POSTGRES_TOKEN}" ]]; then
    fail "POSTGRES_TOKEN is not set in secrets.env"
fi

JDBC_SRC="jdbc:postgresql://${SRC_CTR}:5432/${DB}"
JDBC_DST="jdbc:postgresql://${DST_CTR}:5432/${DB}"

case "${1:-migrate}" in
    migrate) phase_migrate ;;
    analyzers) phase_analyzers ;;
    *) fail "Usage: $0 [migrate|analyzers]" ;;
esac
