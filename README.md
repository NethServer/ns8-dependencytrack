# ns8-dependencytrack

## Install

Instantiate the module with:

    add-module ghcr.io/nethserver/dependencytrack:latest 1

The output of the command will return the instance name.
Output example:

    {"module_id": "dependencytrack1", "image_name": "dependencytrack", "image_url": "ghcr.io/nethserver/dependencytrack:latest"}

## Configure

Let's assume that the Dependency-Track instance is named `dependencytrack1`.

Launch `configure-module`, by setting the following parameters:
- `host`: a fully qualified domain name for the application
- `lets_encrypt`: enable or disable Let's Encrypt certificate (true/false)


Example:

```
api-cli run configure-module --agent module/dependencytrack1 --data - <<EOF
{
  "host": "dependencytrack.domain.com",
  "lets_encrypt": false
}
EOF
```

The above command will:
- start and configure the dependencytrack instance
- configure a virtual host for traefik to access the instance

## Get the configuration
You can retrieve the configuration with

```
api-cli run get-configuration --agent module/dependencytrack1
```

## Uninstall

To uninstall the instance:

    remove-module --no-preserve dependencytrack1

## Update

To Update the instance:

    api-cli run update-module --data '{"module_url":"ghcr.io/nethserver/dependencytrack:latest","instances":["dependencytrack1"],"force":true}'

## Upgrading from Dependency-Track v4 to v5

This version runs Dependency-Track v5, whose schema is incompatible with v4. It carries
`org.nethserver.min-from=2.0.0`, so the Software Center never offers it to a 1.x instance, and
it holds no migration code.

An existing instance is upgraded with
[`migration/upgrade2V5.sh`](migration/upgrade2V5.sh), which drives the official
[v4-migrator](https://dependencytrack.github.io/docs/next/guides/administration/migrating-from-v4/)
offline. The application is down for the whole procedure.

It migrates the data and nothing else: v5 keeps none of the v4 settings, and the script does
not try to put them back. What is left to reconfigure is listed at the end of this section,
and printed again when the migration finishes.

The script asks you to type `I have a backup` before it touches anything. `--yes` skips the
question, for scripts only.

### 1. Download the script — on the node running the app

Into a directory the module user can read. `/root` is `0700`, so a script left there fails to
open with a bare `Permission denied`. The `stable` tag serves the script of the latest release,
so its migrator matches the version you install in step 3:

    curl -fsSL -o /tmp/upgrade2V5.sh \
      https://raw.githubusercontent.com/NethServer/ns8-dependencytrack/stable/migration/upgrade2V5.sh

### 2. Migrate the database — on the node running the app

    runagent -m dependencytrack1 bash /tmp/upgrade2V5.sh

It stops and disables the pod, keeps the v4 dump in `state/backup-v4/`, migrates into a fresh
v5 database and swaps `postgres-data`. Services are left down, and disabled so a reboot cannot
start a v4 API server against the migrated database.

The update in the next step does not touch `/tmp`, so the same file serves both phases.

### 3. Update — on the leader

`stable` is the latest stable release, the one the script in step 1 came from. An explicit
`update-module` is not subject to `min-from`.

    api-cli run update-module --data '{"module_url":"ghcr.io/nethserver/dependencytrack:stable","instances":["dependencytrack1"],"force":true}'

### 4. Start the instance — on the node running the app

    runagent -m dependencytrack1 bash /tmp/upgrade2V5.sh start

It refuses to run unless the instance is on v5, starts the services, recomputes the metrics
and prints what is left to do by hand.

### 5. Reclaim the disk

The v4 dump is not included in module backups and can be several gigabytes. Once the instance
checks out, back it up from the leader — existing snapshots restore it as it was, on v4 — then
remove it on the node:

    api-cli run run-backup --data '{"id": <backup id>}'
    runagent -m dependencytrack1 rm -rf backup-v4 migrate-v5

### What you have to reconfigure

v5 cannot decrypt what v4 encrypted, and its migrator does not carry the settings over. After
the upgrade, in the Dependency-Track interface:

- every analyzer and vulnerability source is back at the **v5 defaults**, which are not v4's:
  Trivy off, OS scanning off, OSS Index asking for a token where v4 queried anonymously
- **Trivy**: its URL and token are on the module Settings page, to enter under
  Administration, Analyzers, Trivy
- **repository passwords**, and their repository comes back disabled
- **analyzer, vulnerability source and integration tokens**
- **notification rules**, which come back disabled

Projects, components, vulnerabilities, findings, audit history, policies, users, teams,
permissions and API keys are preserved. Portfolio metrics older than 90 days are dropped.

### On failure

Services stay down, the error is in the journal
(`journalctl _UID=$(id -u dependencytrack1) -e`), both dumps stay on disk. Fix the cause and
run the script again.

A run interrupted while the database was being replaced resumes from
`state/dependencytrack-v5.pg_dump`: it does not migrate again and does not ask to confirm.
Until you relaunch it, the instance has no usable database, so relaunching is the way out,
not a manual repair.

If that dump is gone, the script refuses to guess: restore
`state/backup-v4/dependencytrack-v4.pg_dump` into a 1.x instance by hand.

Restoring a backup taken before 2.0.0 is refused: it holds a v4 database. Restore it into a
1.x instance instead.

## Debug

some CLI are needed to debug

- The module runs under an agent that initiate a lot of environment variables (in /home/dependencytrack1/.config/state), it could be nice to verify them
on the root terminal

    `runagent -m dependencytrack1 env`

- you can become runagent for testing scripts and initiate all environment variables
  
    `runagent -m dependencytrack1`

 the path become : 
```
    echo $PATH
    /home/dependencytrack1/.config/bin:/usr/local/agent/pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/usr/
```

- if you want to debug a container or see environment inside
 `runagent -m dependencytrack1`
 ```
podman ps --format "{{.Names}}\t{{.Image}}"
80b8de25945f-infra
postgresql-app              docker.io/library/postgres:17.10-alpine
dependencytrack-apiserver   docker.io/dependencytrack/apiserver:5.0.5
trivy-app                   docker.io/aquasec/trivy:0.74.0
dependencytrack-nginx       docker.io/library/nginx:1.30.4-alpine
dependencytrack-frontend    docker.io/dependencytrack/frontend:5.0.5
```

you can see what environment variable is inside the container
```
podman exec dependencytrack-apiserver env | grep ^DT_
DT_DATASOURCE_URL=jdbc:postgresql://postgresql-app:5432/dependencytrack
DT_DATASOURCE_USERNAME=postgres
DT_DATASOURCE_PASSWORD=...
```

you can run a shell inside the container

```
podman exec -ti   dependencytrack-apiserver sh
/ # 
```
## Testing

Test the module using the `test-module.sh` script:


    ./test-module.sh <NODE_ADDR> ghcr.io/nethserver/dependencytrack:latest

The tests are made using [Robot Framework](https://robotframework.org/)

## UI translation

Translated with [Weblate](https://hosted.weblate.org/projects/ns8/).

To setup the translation process:

- add [GitHub Weblate app](https://docs.weblate.org/en/latest/admin/continuous.html#github-setup) to your repository
- add your repository to [hosted.weblate.org]((https://hosted.weblate.org) or ask a NethServer developer to add it to ns8 Weblate project
