*** Settings ***
Library    SSHLibrary
Resource    api.resource
# The stable release is already v5, so the v4 migration needs its own suite. It doubles the run time, keep it to one leg.
Suite Setup    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, the v4 migration runs on the update leg

*** Variables ***
${SCENARIO}    install
# Last 1.x release: the v4 instance the migration starts from.
${V4_IMAGE_URL}    ghcr.io/nethserver/dependencytrack:1.0.11
${DT_PASSWORD}    Upgrade,1234
${PROJECT}    upgrade-test

*** Keywords ***
API answers
    ${rc} =    Execute Command    curl -sf -o /dev/null ${api}/version
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Change the default admin password
    ${rc} =    Execute Command    curl -sf -o /dev/null -X POST --data-urlencode username=admin --data-urlencode password=admin --data-urlencode newPassword='${DT_PASSWORD}' --data-urlencode confirmPassword='${DT_PASSWORD}' ${api}/v1/user/forceChangePassword
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Login as admin
    ${token}  ${rc} =    Execute Command    curl -sf -X POST --data-urlencode username=admin --data-urlencode password='${DT_PASSWORD}' ${api}/v1/user/login
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    RETURN    ${token}

*** Test Cases ***
Install the last v4 release
    ${output}  ${rc} =    Execute Command    add-module ${V4_IMAGE_URL} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Configure the v4 instance
    ${rc} =    Execute Command    api-cli run module/${module_id}/configure-module --data '{"host": "dt-upgrade.fqdn.test","lets_encrypt": false}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    ${response} =    Run task     module/traefik1/get-route    {"instance":"${module_id}"}
    Set Suite Variable    ${api}    ${response['url'].rstrip('/')}/api

Create a project on v4
    Wait Until Keyword Succeeds    10 minutes    5 seconds    API answers
    Wait Until Keyword Succeeds    2 minutes    5 seconds    Change the default admin password
    ${token} =    Login as admin
    ${rc} =    Execute Command    curl -sf -o /dev/null -X PUT -H 'Authorization: Bearer ${token}' -H 'Content-Type: application/json' -d '{"name":"${PROJECT}","version":"1.0"}' ${api}/v1/project
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Migrate the v4 database
    Put File    ${CURDIR}/../migration/upgrade2V5.sh    /tmp/upgrade2V5.sh    mode=0644
    ${stderr}  ${rc} =    Execute Command    runagent -m ${module_id} bash /tmp/upgrade2V5.sh --yes
    ...    return_rc=True  return_stdout=False  return_stderr=True
    Should Be Equal As Integers    ${rc}  0    ${stderr}

Update to the tested image
    ${rc} =    Execute Command    api-cli run update-module --data '{"module_url":"${IMAGE_URL}","instances":["${module_id}"],"force":true}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Start the v5 instance
    ${stderr}  ${rc} =    Execute Command    runagent -m ${module_id} bash /tmp/upgrade2V5.sh start
    ...    return_rc=True  return_stdout=False  return_stderr=True
    Should Be Equal As Integers    ${rc}  0    ${stderr}

Find the v4 project on v5
    Wait Until Keyword Succeeds    10 minutes    5 seconds    API answers
    ${token} =    Wait Until Keyword Succeeds    2 minutes    5 seconds    Login as admin
    ${output}  ${rc} =    Execute Command    curl -sf -H 'Authorization: Bearer ${token}' '${api}/v1/project/lookup?name=${PROJECT}&version=1.0'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Contain    ${output}    "name":"${PROJECT}"

Remove the upgraded instance
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
