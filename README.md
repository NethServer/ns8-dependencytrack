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

v5 is not an in-place upgrade of v4: its API server must never start against a v4 schema.
Updating an instance still on v4 migrates the database automatically, with the official
[v4-migrator](https://dependencytrack.github.io/docs/next/guides/administration/migrating-from-v4/):
the pod is stopped, the v4 data is dumped to `state/backup-v4/dependencytrack-v4.pg_dump` and
kept there, the data is copied offline into a fresh v5 database, and `postgres-data` is
replaced with it. The same runs during `restore-module`, since a backup taken before the
upgrade restores a v4 database.

Fresh installs and already migrated instances are left alone. On failure the services stay
stopped, the error is in the journal, and the next run resumes; fix the cause and update again.

v5 cannot decrypt what v4 encrypted, so the migrator clears every secret. Repository passwords
are cleared and their repository disabled, analyzer and integration tokens are dropped, and
notification rules arrive disabled. Everything else migrates: projects, components,
vulnerabilities, findings, policies, users, teams and permissions.

v5 also turned every analyzer and vulnerability source into a plugin whose configuration the
migrator does not carry, so the module copies the v4 settings over for the ones that need no
secret: the internal analyzer, NVD, and OSV with its list of ecosystems. Trivy is done too,
since the module owns that token — an analyzer that was off stays off, ready to be switched on,
and one pointed at another Trivy server is left untouched.

An analyzer that was on in v4 comes back on, one that was off stays off. The exception is the
four that authenticate: OSS Index, GitHub Advisories, Snyk and VulnDB. v5 validates their
configuration and refuses to enable them without the API token v4 had encrypted, and that token
is gone. OSS Index is the one that bites, since v4 queried it anonymously and had it enabled by
default.

For those, everything that is not a secret is stored anyway — URLs, the OSS Index username, the
Snyk organisation — so entering the token is the only step left. VulnDB gets nothing: v4
authenticated with OAuth1 and v5 expects OAuth2. The Settings page lists by name the ones that
were running before the upgrade and are waiting for their token.

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
