*** Settings ***
Library           SSHLibrary

*** Variables ***
${SSH_KEYFILE}    %{HOME}/.ssh/id_ecdsa

*** Keywords ***
Connect to the node
    Open Connection   ${NODE_ADDR}
    Login With Public Key    root    ${SSH_KEYFILE}
    ${output} =    Execute Command    systemctl is-system-running  --wait
    Should Be True    '${output}' == 'running' or '${output}' == 'degraded'

Enable NethForge
    # The update leg installs the stable release by name, published there, and a new node keeps it disabled.
    ${rc} =    Execute Command    api-cli run cluster/alter-repository --data '{"name":"nethforge","status":true}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

*** Settings ***
Suite Setup       Run Keywords    Connect to the Node    AND    Enable NethForge
