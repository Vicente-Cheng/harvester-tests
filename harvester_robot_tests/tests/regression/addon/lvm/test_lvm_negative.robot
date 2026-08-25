*** Settings ***
Documentation    LVM negative paths: provisioning that must fail has to fail
...              cleanly - clear pending state while alive, and no stuck PV
...              or backend leftovers after cleanup.
Test Tags        regression    addon    lvm    negative

Resource         ../../../../keywords/lvm.resource
Resource         ../../../../keywords/workload.resource
Resource         ../../../../keywords/lvm_driver.resource

Suite Setup      Local Suite Setup
Suite Teardown   Local Suite Teardown


*** Variables ***
${LVM_SC_NAME}               ${EMPTY}
${LVM_STRIPED_SC_NAME}       ${EMPTY}
${LVM_HUGE_VOLUME_NAME}      ${EMPTY}
${LVM_SRC_VOLUME_NAME}       ${EMPTY}
${LVM_SMALL_RESTORE_NAME}    ${EMPTY}
${LVM_SNAPSHOT_NAME}         ${EMPTY}
${LVM_NODE_NAME}             ${EMPTY}
# Far beyond the 50GiB test disk, so striped allocation always fails.
${LVM_OVERSIZED_REQUEST}     500Gi
# How long a must-not-provision PVC is observed before declaring success.
${PENDING_OBSERVATION}       60s


*** Test Cases ***
Oversized Volume Fails And Cleans Up
    [Documentation]    A striped volume far beyond the VG capacity must never
    ...    bind, and deleting it must leave no stuck PV behind. Uses the
    ...    striped type deliberately: dm-thin allows overprovisioning, so
    ...    only striped allocation fails deterministically.
    [Tags]    p1
    Create Volume
    ...    ${LVM_HUGE_VOLUME_NAME}
    ...    ${LVM_OVERSIZED_REQUEST}
    ...    storage_class=${LVM_STRIPED_SC_NAME}
    ...    volume_mode=Block
    ...    access_mode=ReadWriteOnce
    Create Pending Consumer Pod    ${POD_HUGE}    ${LVM_HUGE_VOLUME_NAME}
    Sleep    ${PENDING_OBSERVATION}
    Volume Phase Is Pending    ${LVM_HUGE_VOLUME_NAME}
    Delete Workload Pod    ${POD_HUGE}
    Delete Volume    ${LVM_HUGE_VOLUME_NAME}
    No PV Should Reference Claim    ${LVM_HUGE_VOLUME_NAME}

Undersized Snapshot Restore Fails And Cleans Up
    [Documentation]    Restoring a snapshot into a PVC smaller than the
    ...    snapshot size must be rejected (never bind) instead of producing
    ...    a truncated volume, and cleanup must leave no stuck PV.
    [Tags]    p1
    Create Consumed Volume    ${LVM_SRC_VOLUME_NAME}
    Create Volume Snapshot    ${LVM_SRC_VOLUME_NAME}    ${LVM_SNAPSHOT_NAME}    lvm-snapshot
    Wait Until Snapshot Is Ready    ${LVM_SNAPSHOT_NAME}
    Restore Volume From Snapshot
    ...    ${LVM_SRC_VOLUME_NAME}
    ...    ${LVM_SNAPSHOT_NAME}
    ...    ${LVM_SMALL_RESTORE_NAME}
    ...    storage_class=${LVM_SC_NAME}
    ...    access_mode=ReadWriteOnce
    ...    size=1Gi
    Create Pending Consumer Pod    ${POD_RESTORE}    ${LVM_SMALL_RESTORE_NAME}
    Sleep    ${PENDING_OBSERVATION}
    Volume Phase Is Pending    ${LVM_SMALL_RESTORE_NAME}
    Delete Workload Pod    ${POD_RESTORE}
    Delete Volume    ${LVM_SMALL_RESTORE_NAME}
    No PV Should Reference Claim    ${LVM_SMALL_RESTORE_NAME}

Snapshot Outlives Deleted Source Volume
    [Documentation]    Deleting the source volume first must not wedge the
    ...    snapshot: the VolumeSnapshot has to remain deletable afterwards,
    ...    and the backend LV must be removed as well - with the source PV
    ...    gone the driver has to resolve node/vg from its snapshot-location
    ...    record. The shipped driver fails the CSI DeleteSnapshot outright
    ...    when the source PV is missing, leaving the snapshot object stuck.
    [Tags]    p1
    Skip    Pending harvester/csi-driver-lvm#64 (DeleteSnapshot survives a missing source PV by falling back to the snapshot-location record)
    Create Consumed Volume    ${LVM_SRC_VOLUME_NAME}
    Create Volume Snapshot    ${LVM_SRC_VOLUME_NAME}    ${LVM_SNAPSHOT_NAME}    lvm-snapshot
    Wait Until Snapshot Is Ready    ${LVM_SNAPSHOT_NAME}
    ${handle}=    Get Snapshot Handle    ${LVM_SNAPSHOT_NAME}
    Cleanup Workload Pods
    Delete Volume    ${LVM_SRC_VOLUME_NAME}
    Delete Volume Snapshot    ${LVM_SRC_VOLUME_NAME}    ${LVM_SNAPSHOT_NAME}
    Snapshot LV Should Not Exist On Node    ${LVM_NODE_NAME}    ${LVM_VG_NAME}    ${handle}


*** Keywords ***
Create Pending Consumer Pod
    [Arguments]    ${pod_name}    ${volume_name}
    [Documentation]    Start a consumer pod without waiting for Running:
    ...    with WaitForFirstConsumer it only has to trigger provisioning,
    ...    and in these tests neither pod nor PVC is ever expected to
    ...    become ready.
    Run Keyword And Ignore Error
    ...    Create Workload Pod With Volume    ${pod_name}    ${volume_name}    Block

Create Consumed Volume
    [Arguments]    ${volume_name}
    ${exists}=    Run Keyword And Return Status    Wait Until Volume Is Active    ${volume_name}
    IF    ${exists}    RETURN
    Create Volume
    ...    ${volume_name}
    ...    ${LVM_VOLUME_SIZE}
    ...    storage_class=${LVM_SC_NAME}
    ...    volume_mode=Block
    ...    access_mode=ReadWriteOnce
    Create Workload Pod With Volume    ${POD_SRC}    ${volume_name}    Block
    Wait Until Volume Is Active    ${volume_name}

Local Suite Setup
    ${suffix}=    Generate Unique Name    lvm-negative
    Set Suite Variable    ${LVM_SC_NAME}               lvm-sc-${suffix}
    Set Suite Variable    ${LVM_STRIPED_SC_NAME}       lvm-striped-sc-${suffix}
    Set Suite Variable    ${LVM_HUGE_VOLUME_NAME}      lvm-huge-${suffix}
    Set Suite Variable    ${LVM_SRC_VOLUME_NAME}       lvm-src-${suffix}
    Set Suite Variable    ${LVM_SMALL_RESTORE_NAME}    lvm-small-${suffix}
    Set Suite Variable    ${LVM_SNAPSHOT_NAME}         lvm-snap-${suffix}
    Set Suite Variable    ${POD_HUGE}                  pod-huge-${suffix}
    Set Suite Variable    ${POD_RESTORE}               pod-restore-${suffix}
    Set Suite Variable    ${POD_SRC}                   pod-src-${suffix}
    ${node}=    Initialize LVM Workload Suite
    Set Suite Variable    ${LVM_NODE_NAME}    ${node}
    Create LVM Storage Class
    ...    ${LVM_SC_NAME}
    ...    ${LVM_VG_NAME}
    ...    ${LVM_VG_TYPE}
    ...    ${LVM_NODE_NAME}
    # Same VG, striped type: used to make over-allocation fail for real.
    Create LVM Storage Class
    ...    ${LVM_STRIPED_SC_NAME}
    ...    ${LVM_VG_NAME}
    ...    striped
    ...    ${LVM_NODE_NAME}

Local Suite Teardown
    Run Keyword And Ignore Error    Cleanup Workload Pods
    Run Keyword And Ignore Error
    ...    Delete Volume Snapshot    ${LVM_SRC_VOLUME_NAME}    ${LVM_SNAPSHOT_NAME}
    Run Keyword And Ignore Error    Delete Volume    ${LVM_SMALL_RESTORE_NAME}
    Run Keyword And Ignore Error    Delete Volume    ${LVM_HUGE_VOLUME_NAME}
    Run Keyword And Ignore Error    Delete Volume    ${LVM_SRC_VOLUME_NAME}
    Run Keyword And Ignore Error    Delete Storage Class    ${LVM_STRIPED_SC_NAME}
    Run Keyword And Ignore Error    Delete Storage Class    ${LVM_SC_NAME}
