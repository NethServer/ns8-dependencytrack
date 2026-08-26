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

Module 2.0.0 runs Dependency-Track v5, whose schema is incompatible with v4. It carries
`org.nethserver.min-from=2.0.0`, so it is never offered as an automatic update.

This release ships `scripts/upgrade2V5.sh`, which drives the official
[v4-migrator](https://dependencytrack.github.io/docs/next/guides/administration/migrating-from-v4/)
offline. The application is down for the whole procedure.

The script prints what v5 cannot carry over and asks you to type `I have a backup` before it
touches anything. `--yes` skips the question, for scripts only.

### 1. Find the node

The instance is not necessarily on the leader:

    api-cli run list-installed-modules | jq '.[][] | select(.module == "dependencytrack")'

Open a shell on the node named by `node`, over the cluster VPN: `ssh root@10.5.4.<node>`.

### 2. Update to 1.0.12

From the leader, so the instance has the script. Dependency-Track stays on 4.14.3.

    api-cli run update-module --data '{"module_url":"ghcr.io/nethserver/dependencytrack:1.0.12","instances":["dependencytrack1"],"force":true}'

### 3. Migrate the database

On the node:

    runagent -m dependencytrack1 bash ../scripts/upgrade2V5.sh

It stops and disables the pod, keeps the v4 dump in `state/backup-v4/`, migrates into a fresh
v5 database and swaps `postgres-data`. Services are left down, and disabled so a reboot cannot
start a v4 API server against the migrated database.

### 4. Update to 2.0.0

From the leader. An explicit `update-module` is not subject to `min-from`.

    api-cli run update-module --data '{"module_url":"ghcr.io/nethserver/dependencytrack:2.0.0","instances":["dependencytrack1"],"force":true}'

### 5. Restore the analyzers and start

On the node, from the copy phase 1 left behind:

    runagent -m dependencytrack1 bash upgrade2V5.sh analyzers

It refuses to run unless the instance is on 2.0.0, starts the services, replays the v4
analyzer settings and prints what is left to do by hand.

### 6. Reclaim the disk

The v4 dump is not included in module backups and can be several gigabytes. Once the instance
checks out, back it up — existing snapshots restore it as it was, on v4 — then:

    api-cli run run-backup --data '{"id": <backup id>}'
    runagent -m dependencytrack1 rm -rf backup-v4 upgrade2V5.sh migrate-v5

### What v5 cannot carry over

v5 cannot decrypt what v4 encrypted, so every secret is cleared: repository passwords, with
their repository disabled, analyzer and integration tokens, and notification rules come back
disabled. Portfolio metrics older than 90 days are dropped. Everything else is preserved.

v5 also turned the analyzers into plugins the migrator leaves unconfigured, so the script
applies the v4 settings again:

| Analyzer or source | Carried over |
| --- | --- |
| Internal, NVD, OSV, Trivy | fully, including Trivy's token |
| OSS Index, GitHub Advisories, Snyk | everything but the token, so they stay off until you enter it |
| VulnDB | nothing: v4 used OAuth1, v5 expects OAuth2 |

A Trivy pointed at another server is left alone, its token cannot be recovered either.

### On failure

Services stay down, the error is in the journal
(`journalctl _UID=$(id -u dependencytrack1) -e`), both dumps stay on disk. Fix the cause and
run the script again: it resumes.

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
