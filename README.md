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

## Upgrading to Dependency-Track v5

Version 2.0.0 of the module runs Dependency-Track v5. v5 is not an in-place upgrade of v4:
the schemas are incompatible and a v5 API server must never boot against a v4 database, so
2.0.0 carries `org.nethserver.min-from=2.0.0` and is never offered as an automatic update.

This release ships `imageroot/scripts/upgrade2V5.sh`, which drives the official
[v4-migrator](https://dependencytrack.github.io/docs/next/guides/administration/migrating-from-v4/)
offline. Projects, components, vulnerabilities, findings, policies, users, teams, permissions
and API keys are preserved.

Take a backup of the instance first — the whole procedure takes the application down, and it
rewrites the module database. On the leader node:

    api-cli run list-backups | jq '.backups[]'
    api-cli run run-backup --data '{"id": <backup id>}'

Run another one as soon as the upgrade is over: every snapshot taken before it holds a v4
database, and 2.0.0 refuses to restore one.

### 1. Find the node hosting the instance

The instance is not necessarily on the leader. On the leader node:

    api-cli run list-installed-modules | jq '.[][] | select(.module == "dependencytrack")'

Note the `node` field, then open a shell on that node, for example
`ssh root@10.5.4.<node>` over the cluster VPN.

### 2. Update the module to 1.0.12

From the leader, so the instance has the script:

    api-cli run update-module --data '{"module_url":"ghcr.io/nethserver/dependencytrack:1.0.12","instances":["dependencytrack1"],"force":true}'

This release still runs Dependency-Track 4.14.3. Nothing changes but the added script.

### 3. Migrate the database

On the node hosting the instance:

    runagent -m dependencytrack1 bash ../scripts/upgrade2V5.sh

The script stops and disables the pod, dumps the v4 database to
`state/backup-v4/dependencytrack-v4.pg_dump` and keeps it, saves the v4 analyzer settings
before the migrator wipes them, copies the data into a fresh v5 database and replaces
`postgres-data` with it. It also keeps a copy of itself as `state/upgrade2V5.sh`, because the
next step deletes the original.

Services are left down on purpose, and disabled so a reboot cannot start a v4 API server
against the migrated database.

### 4. Update the module to 2.0.0

Back on the leader node:

    api-cli run update-module --data '{"module_url":"ghcr.io/nethserver/dependencytrack:2.0.0","instances":["dependencytrack1"],"force":true}'

An explicit `update-module` is not subject to `min-from`, so this works while the Software
Center still offers nothing.

### 5. Restore the analyzers and start

On the node hosting the instance, from the copy phase 1 left behind:

    runagent -m dependencytrack1 bash upgrade2V5.sh analyzers

This refuses to run unless the instance really is on 2.0.0, then enables and starts the
services, replays the v4 analyzer settings against the v5 API, and prints what is left to do
by hand.

Portfolio metrics older than 90 days are not carried over. Findings, audit history, policies
and everything else are.

### What v5 cannot carry over

v5 cannot decrypt what v4 encrypted, so the migrator clears every secret. Repository
passwords are cleared and their repository disabled, analyzer and integration tokens are
dropped, and notification rules arrive disabled.

v5 also turned every analyzer and vulnerability source into a plugin whose configuration the
migrator leaves empty, so the script applies the v4 settings again. An analyzer that was on
comes back on, one that was off stays off — except for the four that authenticate, because v5
validates their configuration and refuses to enable them without the API token v4 had
encrypted.

| Analyzer or source | Carried over |
| --- | --- |
| Internal, NVD, OSV, Trivy | fully, including their switches and Trivy's token |
| OSS Index, GitHub Advisories, Snyk | every setting except the token, so they stay off until you enter it |
| VulnDB | nothing: v4 authenticated with OAuth1, v5 expects OAuth2 |

OSS Index is the one that bites: v4 queried it anonymously and had it enabled by default,
while v5 demands a token. A Trivy pointed at some other server is left untouched, since that
token cannot be recovered either.

### On failure

Services stay stopped, the error is in the journal
(`journalctl _UID=$(id -u dependencytrack1) -e`), both dumps stay on disk and the run is
resumable: fix the reported cause and run the script again.

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
