#!/bin/bash

#
# Copyright (C) 2026 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

#
# Upgrade this instance from Dependency-Track v4 to v5, with the official
# v4-migrator:
#   https://dependencytrack.github.io/docs/next/guides/administration/migrating-from-v4/
#
# Downloaded to a world readable directory, then run twice around an update to
# the stable release, issued from the leader:
#
#   runagent -m dependencytrack1 bash /tmp/upgrade2V5.sh
#   runagent -m dependencytrack1 bash /tmp/upgrade2V5.sh start
#
# Phase 1 leaves the services down. On failure both dumps stay on disk and the
# run is resumable.
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

# Resolved before the cd: it is usually a relative path.
SELF=$(readlink -f "$0")

cd "${AGENT_STATE_DIR}"

# Never past the apiserver the stable release ships: it writes a Flyway head an
# older one refuses. Behind is safe, Flyway catches up on first boot.
V4_MIGRATOR_IMAGE="${V4_MIGRATOR_IMAGE:-ghcr.io/dependencytrack/v4-migrator:5.0.5}"

SRC_CTR="dt_migrate_src"
DST_CTR="dt_migrate_dst"
LOAD_CTR="dt_migrate_load"
NET="dt_migrate_net"
DST_VOL="postgres-migrate-v5"
DB="dependencytrack"
BACKUP_DIR="backup-v4"
UNITS=(dependencytrack.service postgresql-app.service dependencytrack-apiserver.service
       dependencytrack-frontend.service dependencytrack-nginx.service trivy-app.service)
# Not state/restore/: postgresql-app.service mounts that as
# /docker-entrypoint-initdb.d/ and would run whatever is left in it.
WORK_DIR="migrate-v5"
V4_DUMP="${BACKUP_DIR}/${DB}-v4.pg_dump"
V5_DUMP="${WORK_DIR}/${DB}.pg_dump"
# While it is there the volume is unreadable, so the next run resumes instead.
SWAP_FLAG="${WORK_DIR}/.swap-in-progress"
# Mandatory flag of `run`. Only portfolio metrics older than this are dropped.
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

# $1 runs one query and prints the result. Called against the live database
# before anything stops, so a fresh or non-v4 instance is refused while it is
# still serving.
check_schema() {
    local q="$1" tables
    # v5 tracks its schema with Flyway, v4 with DataNucleus and Liquibase.
    if [[ "$(${q} "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL")" == "t" ]]; then
        fail "This database is already on the v5 schema. If the module is still on v4," \
             "update it and run this script again with the start argument."
    fi

    tables=$(${q} "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
    # An empty string equals 0 with -eq, and would read as a fresh install.
    if [[ ! "${tables}" =~ ^[0-9]+$ ]]; then
        fail "Could not count the tables of the ${DB} database, got '${tables}'."
    fi
    if [[ "${tables}" -eq 0 ]]; then
        fail "This database is empty. Install the stable release directly instead."
    fi
    if [[ "$(${q} "SELECT to_regclass('public.\"SCHEMAVERSION\"') IS NOT NULL OR to_regclass('public.\"EVENTSERVICELOG\"') IS NOT NULL")" != "t" ]]; then
        fail "The database holds tables but neither a v4 nor a v5 schema marker." \
             "Refusing to guess: migrate it by hand first."
    fi
    echo "Dependency-Track v4 schema detected."
}

src_query() {
    podman exec "${SRC_CTR}" psql -U postgres -d "${DB}" -tAc "$1"
}

# Migrated metric rows read as zero and nothing recomputes them: v5 only counts
# rows dated within a day of the point they aggregate, and the hourly task skips
# projects that already have a row for today.
refresh_metrics() {
    # UTC: the migrator anchored the daily partitions there, the unit sets no TZ.
    # CONCURRENTLY spares the dashboards a full lock, and needs its own transaction.
    podman exec -i postgresql-app psql -U postgres -d "${DB}" -v ON_ERROR_STOP=1 -q <<'EOS'
SET TIME ZONE 'UTC';
DO $$
DECLARE p uuid;
BEGIN
    FOR p IN SELECT "UUID"::text::uuid FROM "PROJECT" LOOP
        CALL "UPDATE_PROJECT_METRICS"(p);
    END LOOP;
END
$$;
BEGIN;
SET LOCAL TIME ZONE 'UTC';
REFRESH MATERIALIZED VIEW CONCURRENTLY "PORTFOLIOMETRICS_GLOBAL";
COMMIT;
EOS
}

run_migrator() {
    podman run --rm --network "${NET}" --env TZ=UTC "${V4_MIGRATOR_IMAGE}" "$@" \
        --target-url "${JDBC_DST}" --target-user postgres --target-pass "${POSTGRES_TOKEN}"
}


# Same reload idiom as actions/restore-module/40restore_database.
swap_in_migrated_database() {
    cat - >"${WORK_DIR}/${DB}_restore.sh" <<'EOS'
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

# No threshold: the need cannot be guessed from the database size. The admin judges.
report_disk_space() {
    local avail
    avail=$(df -h --output=avail . 2>/dev/null | tail -1 | tr -d ' ') || true
    echo "Disk: ${avail:-an unknown amount} free on ${PWD}. The migration keeps a dump of"
    echo "the v4 database, a full v5 copy of it and a v5 dump on disk at the same time."
    echo
}

# --yes rather than hang on a read nobody sees.
confirm_backup() {
    echo
    echo "This upgrades ${MODULE_ID} to Dependency-Track v5 and rewrites its database"
    echo "in place. Projects, components, findings, audit history, policies, users,"
    echo "teams, permissions and API keys are all carried over."
    echo
    echo "None of its settings are: v5 keeps no v4 configuration, and this script"
    echo "does not put it back. You will have to set again, by hand:"
    echo "  - every analyzer and vulnerability source, Trivy included"
    echo "  - repository passwords, and their repository comes back disabled"
    echo "  - analyzer, vulnerability source and integration tokens"
    echo "  - notification rules, which come back disabled"
    echo
    echo "Going back means restoring a backup snapshot taken before now, which brings"
    echo "the instance back as it is today, on v4. Take one if the last is not recent:"
    echo
    echo "    api-cli run list-backups | jq '.backups[]'"
    echo "    api-cli run run-backup --data '{\"id\": <backup id>}'"
    echo

    report_disk_space

    if [[ -n "${assume_yes}" ]]; then
        echo "Proceeding: --yes was given."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        fail "Not running on a terminal, so the confirmation cannot be asked." \
             "Re-run it from a shell on this node, or pass --yes if you have a backup."
    fi

    local answer=""
    read -r -p "Type 'I have a backup' to continue: " answer
    if [[ "${answer}" != "I have a backup" ]]; then
        fail "Not confirmed, nothing was changed."
    fi
    echo
}


next_step() {
    echo
    echo "The database is migrated and the services are stopped and disabled."
    echo "Now update the instance. On the leader node, run:"
    echo
    echo "  api-cli run update-module --data '{\"module_url\":" \
         "\"ghcr.io/nethserver/dependencytrack:stable\", \"instances\":" \
         "[\"${MODULE_ID}\"], \"force\":true}'"
    echo
    echo "then come back to this node and run:"
    echo
    echo "  runagent -m ${MODULE_ID} bash ${SELF} start"
}

# Not local: the EXIT trap fires once phase_migrate has returned.
completed=""
# Set once the units are down, so a failure before that does not claim they are.

phase_migrate() {
    # An ERR trap would miss the `exit 1` of the checks below.
    on_exit() {
        local rc=$?
        cleanup_temp
        if [[ -n "${completed}" ]]; then
            return
        fi
        echo "${SD_ERR}Upgrade to Dependency-Track v5 failed (exit ${rc})."
        # What is, not what was intended: a stop that failed must not be
        # reported as a deliberate one.
        if systemctl --user --quiet is-active dependencytrack.service; then
            echo "${SD_ERR}The instance is still up."
            echo "${SD_ERR}Fix the reported error, then run this script again."
            return
        fi
        echo "${SD_ERR}Services are left stopped on purpose: a v5 apiserver must not run"
        echo "${SD_ERR}against a v4 database."
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

    # Nothing left to confirm on a resume: the database was already rewritten.
    if [[ -f "${SWAP_FLAG}" ]]; then
        echo
        echo "A previous run was interrupted while replacing the database. This one resumes"
        echo "it from state/${V5_DUMP} and does not migrate again."
    else
        # Before the question: no point asking to confirm an upgrade that is
        # about to be refused.
        check_schema "podman exec postgresql-app psql -U postgres -d ${DB} -tAc"
        confirm_backup
    fi
    mkdir -p "${WORK_DIR}"

    # Every unit, not just the pod: the others are WantedBy=default.target too,
    # and their BindsTo would drag the pod back up after a reboot.
    systemctl --user disable "${UNITS[@]}" >/dev/null 2>&1 || true
    systemctl --user stop "${UNITS[@]}"

    # postgres-data is empty or half loaded here, so it cannot be inspected.
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


    mkdir -p "${BACKUP_DIR}"
    # A dump cut short by a full disk must not take the name we tell them to restore.
    podman exec "${SRC_CTR}" pg_dump -U postgres -Fc "${DB}" >"${V4_DUMP}.tmp"
    mv "${V4_DUMP}.tmp" "${V4_DUMP}"
    echo "v4 backup written to state/${V4_DUMP}"

    # Both raised on the migrator preflight's request.
    run_postgres "${DST_CTR}" "${DST_VOL}" \
        -c max_wal_size=4GB -c max_locks_per_transaction=256

    # Upstream's sequence. The preflight verify logs a PostgreSQL error per
    # staging table nothing has created yet: that is how it reports zero, not a
    # failure. `run` is what gates the migration, verify is advisory either side.
    run_migrator bootstrap
    run_migrator verify
    run_migrator run \
        --source-url "${JDBC_SRC}" --source-user postgres --source-pass "${POSTGRES_TOKEN}" \
        --metrics-retention-days "${METRICS_RETENTION_DAYS}"
    run_migrator verify
    run_migrator cleanup

    # Same reason, and here it also gates the resume path: only a complete dump
    # may be named V5_DUMP, since a resumed run reloads it without asking.
    podman exec "${DST_CTR}" pg_dump -U postgres -Fc "${DB}" >"${V5_DUMP}.tmp"
    mv "${V5_DUMP}.tmp" "${V5_DUMP}"
    podman rm --ignore -f "${SRC_CTR}" "${DST_CTR}" >/dev/null
    # Dropped here rather than in cleanup_temp: lowers peak disk use during the swap.
    if podman volume exists "${DST_VOL}"; then
        podman volume rm --force "${DST_VOL}" >/dev/null
    fi

    swap_in_migrated_database

    completed=1
    next_step
}

phase_start() {
    # Out of order, this would start a v4 apiserver against the migrated database.
    if ! grep -q "^APISERVER_IMAGE=.*:5\." environment; then
        fail "This instance is not on v5 yet. Update it first, then run this phase:" \
             "see the command printed at the end of the migration phase."
    fi

    # Only the pod, as configure-module does: the children stay disabled and
    # start through its Requires=.
    systemctl --user enable dependencytrack.service
    systemctl --user start dependencytrack.service

    local api="http://127.0.0.1:${TCP_PORT}/api"
    # The first v5 boot spends minutes in Flyway before serving.
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

    if ! refresh_metrics; then
        echo "${SD_WARN}Could not recompute the metrics: the dashboards read zero until"
        echo "${SD_WARN}Dependency-Track recomputes them. The data itself is there, the"
        echo "${SD_WARN}project pages show it."
    fi

    echo
    echo "Upgrade complete. The instance is running Dependency-Track v5."
    echo
    echo "${SD_WARN}v5 keeps none of the v4 settings and this script does not put them back."
    echo "${SD_WARN}To set again by hand, in the Dependency-Track interface:"
    echo "${SD_WARN}  - every analyzer and vulnerability source, back at the v5 defaults,"
    echo "${SD_WARN}    which are not v4's: Trivy off, OS scanning off, OSS Index asking for"
    echo "${SD_WARN}    a token where v4 queried anonymously"
    echo "${SD_WARN}  - Trivy: its URL and token are on the module Settings page"
    echo "${SD_WARN}  - repository passwords, and their repository is disabled"
    echo "${SD_WARN}  - analyzer, vulnerability source and integration tokens"
    echo "${SD_WARN}  - notification rules, which came back disabled"
    echo
    echo "Worth a backup once you are happy with the result: the snapshots you already"
    echo "have restore the instance as it was on v4, not as it is now. On the leader node:"
    echo
    echo "    api-cli run run-backup --data '{\"id\": <backup id>}'"
    echo
    local dump_size
    dump_size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
    echo "The v4 database is kept at state/${V4_DUMP}${dump_size:+ (${dump_size})}."
    echo "It is a faster way back than a restore, and module backups do not include it."
    echo "Remove it, and the working directory this phase reads, once you have checked"
    echo "the instance and taken a backup of it:"
    echo
    echo "    runagent -m ${MODULE_ID} rm -rf ${BACKUP_DIR} ${WORK_DIR}"
    echo
}

POSTGRES_TOKEN=$(read_secret POSTGRES_TOKEN)
if [[ -z "${POSTGRES_TOKEN}" ]]; then
    fail "POSTGRES_TOKEN is not set in secrets.env"
fi

JDBC_SRC="jdbc:postgresql://${SRC_CTR}:5432/${DB}"
JDBC_DST="jdbc:postgresql://${DST_CTR}:5432/${DB}"

assume_yes=""
phase="migrate"
for arg in "$@"; do
    case "${arg}" in
        --yes) assume_yes=1 ;;
        migrate | start) phase="${arg}" ;;
        *) fail "Usage: $0 [migrate|start] [--yes]" ;;
    esac
done

case "${phase}" in
    migrate) phase_migrate ;;
    start) phase_start ;;
esac
