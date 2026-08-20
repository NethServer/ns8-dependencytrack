# ns8-dependencytrack

## Install

Instantiate the module with:

    add-module ghcr.io/nethserver/dependencytrack:latest 1

The output of the command will return the instance name.
Output example:

    {"module_id": "dependencytrack1", "image_name": "dependencytrack", "image_url": "ghcr.io/nethserver/dependencytrack:latest"}

## Configure

Let's assume that the mattermost instance is named `dependencytrack1`.

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
- configure a virtual host for trafik to access the instance

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

- **the Trivy analyzer must be configured again**. v5 turned it into a plugin whose runtime
  configuration the migrator does not map, and it starts disabled. Take the URL and the token
  from the module Settings page, or from `api-cli run module/<id>/get-configuration`, and
  enter them in Dependency-Track as you did at install time. Until then Trivy reports nothing.
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
podman ps
CONTAINER ID  IMAGE                                      COMMAND               CREATED        STATUS        PORTS                    NAMES
d292c6ff28e9  localhost/podman-pause:4.6.1-1702418000                          9 minutes ago  Up 9 minutes  127.0.0.1:20015->80/tcp  80b8de25945f-infra
d8df02bf6f4a  docker.io/library/postgres:15.5-alpine3.19          --character-set-s...  9 minutes ago  Up 9 minutes  127.0.0.1:20015->80/tcp  postgresql-app
9e58e5bd676f  docker.io/library/nginx:stable-alpine3.17  nginx -g daemon o...  9 minutes ago  Up 9 minutes  127.0.0.1:20015->80/tcp  dependencytrack-apiserver
```

you can see what environment variable is inside the container
```
podman exec  dependencytrack-apiserver env
TERM=xterm
container=podman
NGINX_VERSION=1.24.0
PKG_RELEASE=1
NJS_VERSION=0.7.12
NGINX_IMAGE=docker.io/nginx:stable-alpine3.17
CONFIG_DATABASE_URI="postgresql://postgres:Nethesis,1234@127.0.0.1:5432/toto"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root
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
