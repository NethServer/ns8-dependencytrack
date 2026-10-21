*** Settings ***
Library    SSHLibrary
Resource    api.resource

*** Variables ***
${SCENARIO}    install
${ADMIN_USER}    admin
${ADMIN_PASSWORD}    Nethesis,1234
${PROJECT}    trivy-test

*** Keywords ***
Retry test
    [Arguments]    ${keyword}
    Wait Until Keyword Succeeds    60 seconds    1 second    ${keyword}

Login to cluster-admin
    New Page    https://${NODE_ADDR}/cluster-admin/
    Fill Text    text="Username"    ${ADMIN_USER}
    Click    button >> text="Continue"
    Fill Text    text="Password"    ${ADMIN_PASSWORD}
    Click    button >> text="Log in"
    Wait For Elements State    css=#main-content    visible    timeout=10s

Backend URL is reachable
    ${rc} =    Execute Command    curl -f ${backend_url}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

API answers
    ${rc} =    Execute Command    curl -sf -o /dev/null ${dt_api}/version
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Login to Dependency-Track
    ${token}  ${rc} =    Execute Command    curl -sf -X POST --data-urlencode username=admin --data-urlencode password='${ADMIN_PASSWORD}' ${dt_api}/v1/user/login
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Set Suite Variable    ${dt_token}    ${token}

Set the Dependency-Track admin password
    ${rc} =    Execute Command    curl -sf -o /dev/null -X POST --data-urlencode username=admin --data-urlencode password=admin --data-urlencode newPassword='${ADMIN_PASSWORD}' --data-urlencode confirmPassword='${ADMIN_PASSWORD}' ${dt_api}/v1/user/forceChangePassword
    ...    return_rc=True  return_stdout=False
    # forceChangePassword works only once: on a reused instance the password is already set.
    IF    ${rc} != 0
        Login to Dependency-Track
    END

Enable the Trivy analyzer
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    ${rc} =    Execute Command    curl -sf -o /dev/null -H 'Authorization: Bearer ${dt_token}' ${dt_api}/v2/secrets/trivy-token
    ...    return_rc=True  return_stdout=False
    IF    ${rc} != 0
        ${rc} =    Execute Command    curl -sf -o /dev/null -X POST -H 'Authorization: Bearer ${dt_token}' -H 'Content-Type: application/json' -d '{"name":"trivy-token","value":"${config['trivy_token']}"}' ${dt_api}/v2/secrets
        ...    return_rc=True  return_stdout=False
        Should Be Equal As Integers    ${rc}  0
    END
    ${rc} =    Execute Command    curl -sf -o /dev/null -X PUT -H 'Authorization: Bearer ${dt_token}' -H 'Content-Type: application/json' -d '{"config":{"enabled":true,"apiUrl":"${config['trivy_url']}","apiToken":"trivy-token","scanLibrary":true,"scanOs":true,"ignoreUnfixed":false}}' ${dt_api}/v2/extension-points/vuln-analyzer/extensions/trivy/config
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

BOM is processed
    [Arguments]    ${token}
    ${output}  ${rc} =    Execute Command    curl -sf -H 'Authorization: Bearer ${dt_token}' ${dt_api}/v1/bom/token/${token}
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    ${status} =    Evaluate    json.loads($output)    modules=json
    Should Not Be True    ${status['processing']}

Upload the test BOM
    [Arguments]    ${version}
    ${output}  ${rc} =    Execute Command    curl -sf -X POST -H 'Authorization: Bearer ${dt_token}' -F autoCreate=true -F projectName=${PROJECT} -F projectVersion=${version} -F bom=@/tmp/trivy-bom.json ${dt_api}/v1/bom
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    ${response} =    Evaluate    json.loads($output)    modules=json
    Wait Until Keyword Succeeds    5 minutes    5 seconds    BOM is processed    ${response['token']}

Project has Trivy findings
    [Arguments]    ${version}
    ${output}  ${rc} =    Execute Command    curl -sf -H 'Authorization: Bearer ${dt_token}' '${dt_api}/v1/project/lookup?name=${PROJECT}&version=${version}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    ${project} =    Evaluate    json.loads($output)    modules=json
    ${output}  ${rc} =    Execute Command    curl -sf -H 'Authorization: Bearer ${dt_token}' ${dt_api}/v1/finding/project/${project['uuid']}
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    # The vulnerability database keeps changing, so expect at least one finding, not an exact count.
    ${count} =    Evaluate    len([f for f in json.loads($output) if f['attribution']['analyzerIdentity'] == 'trivy'])    modules=json
    Should Be True    ${count} > 0    no Trivy finding for ${PROJECT} ${version}


*** Test Cases ***
Check if dependencytrack is installed correctly
    IF    '${SCENARIO}' == 'update'
        ${output}  ${rc} =    Execute Command    add-module dependencytrack 1
        ...    return_rc=True
    ELSE
        ${output}  ${rc} =    Execute Command    add-module ${IMAGE_URL} 1
        ...    return_rc=True
    END
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Check if dependencytrack can be configured
    ${rc} =    Execute Command    api-cli run module/${module_id}/configure-module --data '{"host": "dp.fqdn.test","lets_encrypt": false}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Retrieve dependencytrack backend URL
    # Assuming the test is running on a single node cluster
    ${response} =    Run task     module/traefik1/get-route    {"instance":"${module_id}"}
    Set Suite Variable    ${backend_url}    ${response['url']}

Check if dependencytrack works as expected
    Retry test    Backend URL is reachable

Check if Trivy finds vulnerabilities in a BOM
    Set Suite Variable    ${dt_api}    ${backend_url.rstrip('/')}/api
    Wait Until Keyword Succeeds    10 minutes    5 seconds    API answers
    Wait Until Keyword Succeeds    2 minutes    5 seconds    Set the Dependency-Track admin password
    Login to Dependency-Track
    Enable the Trivy analyzer
    Put File    ${CURDIR}/trivy-bom.json    /tmp/trivy-bom.json    mode=0644
    Upload the test BOM    1.0
    # Trivy downloads its database on first start, about one minute with good egress.
    Wait Until Keyword Succeeds    10 minutes    10 seconds    Project has Trivy findings    1.0

Check if dependencytrack survives the update
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    ${rc} =    Execute Command    api-cli run update-module --data '{"force":true,"module_url":"${IMAGE_URL}","instances":["${module_id}"]}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    Should Be Equal    ${config['host']}    dp.fqdn.test
    Retry test    Backend URL is reachable

Check if Trivy still works after the update
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    Wait Until Keyword Succeeds    10 minutes    5 seconds    API answers
    Wait Until Keyword Succeeds    2 minutes    5 seconds    Login to Dependency-Track
    Project has Trivy findings    1.0
    Upload the test BOM    2.0
    Wait Until Keyword Succeeds    10 minutes    10 seconds    Project has Trivy findings    2.0

Verify dependencytrack frontend title
    ${output} =    Execute Command    curl -s ${backend_url}
    Should Contain    ${output}    <title>Dependency-Track</title>

Take screenshots
    [Tags]    ui
    Import Library    Browser
    New Browser    chromium    headless=True
    New Context    ignoreHTTPSErrors=True
    Login to cluster-admin
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}
    Wait For Elements State    iframe >>> h2 >> text="Status"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/1._Status.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=settings
    Wait For Elements State    iframe >>> h2 >> text="Settings"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/2._Settings.png
    Close Browser

Check if dependencytrack is removed correctly
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
