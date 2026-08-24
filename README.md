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

### Upgrading from Dependency-Track v4 to v5

Dependency-Track v5 is not an in-place upgrade of v4: the v5 API server must never start
against a v4 database schema. When an instance still running v4 is updated, the module
migrates the database automatically during `update-module`, with the official
[v4-migrator](https://dependencytrack.github.io/docs/next/guides/administration/migrating-from-v4/)
tool:

- the pod is stopped, so nothing writes to the database,
- the v4 data is dumped to `state/backup-v4/dependencytrack-v4.pg_dump` and kept there,
- the data is copied offline into a fresh v5 database, then verified,
- the `postgres-data` volume is replaced with the migrated database and the pod is started.

The same migration runs during `restore-module`, because a backup taken before the upgrade
restores a v4 database into the v5 module. There the schema is always inspected, since the
recorded schema version describes the instance before the restore, not the data that was just
loaded.

The migration runs only when a v4 schema is found. Fresh installs and already migrated
instances are left untouched, and the module records `DT_SCHEMA_MAJOR=5` in its state so the
check is not repeated on later updates.

If the migration fails the services are left stopped on purpose and the error is reported in
the journal. Until the migrated database is swapped in, the original data is untouched; from
that point on it is the `state/backup-v4/dependencytrack-v4.pg_dump` copy and the migrated dump
that carry it, and the next run resumes the swap. Either way, fix the cause and run
`update-module` again, or restore the module again if the failure happened during a restore.

After the migration, some settings have to be entered again. v5 stores secrets in a new
database-backed keystore and cannot decrypt what v4 encrypted, so the migrator wipes them
rather than carry unreadable values:

- **the Trivy analyzer is reconfigured by the module**. v5 turned it into a plugin whose
  runtime configuration the migrator does not map, so it would come back disabled and silent.
  Since the module owns the Trivy token, the migration seeds an API key for itself, stores the
  token in the v5 secret manager and points the analyzer at it. The Settings page says whether
  it worked; if it did not, take the URL and token from that same page and enter them by hand.
- authenticated repositories lose their password and are disabled,
- analyzer tokens, SMTP and LDAP passwords and integration keys are cleared,
- notification rules arrive disabled, their publisher configuration having been rebuilt.

Everything else is migrated: projects, components, vulnerabilities, findings, policies, users,
teams and permissions.

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
dependencytrack-apiserver   docker.io/dependencytrack/apiserver:5.0.4
trivy-app                   docker.io/aquasec/trivy:0.74.0
dependencytrack-nginx       docker.io/library/nginx:1.30.4-alpine
dependencytrack-frontend    docker.io/dependencytrack/frontend:5.0.4
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
