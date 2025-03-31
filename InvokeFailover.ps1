<#
.SYNOPSIS
    Manages SQL Server Failover for Availability Groups.

.DESCRIPTION
    This script provides functions to manage SQL Server Failover for one or more Availability Groups. 
    It includes operations for:
    
    - selecting which Availability Groups to failover
    - updating async Availability Groups to sync
    - performing the failover(s)
    - reverting, where applicable, Availability Groups back to async
    - to and reporting on the health of Availability Group databases post-failover.

.PARAMETER TargetInstance
    The SQL Server instance to that targeted to failover the Availability Groups to.

.PARAMETER ScriptEventLogPath
    The directory where log files will be stored. Defaults to location the script is being run from.

.PARAMETER Timeout
    Specifies the timeout in seconds for various operations like DNS updates. Defaults to 300 seconds (5 minutes).

.EXAMPLE
    .\SQLFailover.ps1 -TargetInstance "ServerA\InstanceA" -ScriptEventLogPath "C:\Scripts\Output" -Timeout 300

.EXAMPLE
    .\SQLFailover.ps1 -TargetInstance "ServerB"
#>

#requires -module dbatools

param (
    [Parameter(Mandatory=$true)][string]$TargetInstance,
    [string]$ScriptEventLogPath = "$($PSScriptRoot)\Logs",
    [int]$Timeout = 300
)

# Run DBATools in Insecure mode otherwise it doesn't trust certificate chain connecting to hosts
Set-DbatoolsInsecureConnection -SessionOnly

# Create necessary directory if it doesn't already exist
if (-not (Test-Path -Path $ScriptEventLogPath)) {
    New-Item -Path $ScriptEventLogPath -ItemType Directory
}

# Generate log file name with datetime stamp
$logFileName = Join-Path -Path $ScriptEventLogPath -ChildPath "FailoverLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Define the function to write to the log file and console
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG", "VERBOSE", "FATAL")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$( $timestamp ) [$( $Level )] $( $Message )"

    # Write to log file
    $logMessage | Out-File -FilePath $logFileName -Append

    # Write to console with appropriate color based on log level
    switch ($Level) {
        "INFO"    { Write-Host $logMessage -ForegroundColor White }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "DEBUG"   { Write-Host $logMessage -ForegroundColor DarkGray }
        "VERBOSE" { Write-Host $logMessage -ForegroundColor Cyan }
        "FATAL"   { Write-Host $logMessage -ForegroundColor Magenta }
        default   { Write-Host $logMessage }  # fallback in case of an unexpected level
    }
}

# Function to get all available Availability Groups not on selected replica
function Get-AGs {
    param (
        [string]$TargetInstance,
        [string]$TargetReplicaType = "Secondary"
    )
    try {
        # Get all Availability Groups on the SQL Server instance
        $allAGs = Get-DbaAvailabilityGroup -SqlInstance $TargetInstance

        $AGsToFailover = @()

        foreach ($AG in $allAGs) {
            $isAsync = $false
            $replicas = $AG.AvailabilityReplicas
            
            foreach ($replica in $replicas) {
                if ($replica.AvailabilityMode -eq 'AsynchronousCommit') {
                    $isAsync = $true
                    break  # Exit the loop if we find one async replica, assuming this is enough to classify the Availability Group as async
                }
            }

            # Check if the local replica is the target for failover
            if ($AG.LocalReplicaRole -eq $TargetReplicaType) {
                $AGsToFailover += [PSCustomObject]@{
                    Name = $AG.Name
                    OriginalMode = if ($isAsync) { 'AsynchronousCommit' } else { 'SynchronousCommit' }
                    Primary = $AG.PrimaryReplica
                    Secondary = $AG.LocalReplicaRole
                    IsAsync = $isAsync
                }
            }
        }

        return $AGsToFailover
    }
    catch {
        Write-Log -Message "Error in Get-AGs: $( $_ )" -Level ERROR
        throw $_
    }
}

# Function to get user input for Availability Groups to failover
function Request-AGsToFailover {
    param (
        [array]$AGs
    )
    try {
        $RequestedAGs = @()
        foreach ($AG in $AGs) {
            $confirmation = Read-Host "Failover Availability Group '$($AG.Name)'? (Y/N)"
            if ($confirmation -ieq 'Y') {
                $RequestedAGs += $AG
            }
        }

        if ($RequestedAGs.Count -eq 0) {
            Write-Log -Message "No Availability Groups were selected for failover." -Level INFO
        } else {
            Write-Log -Message "Selected Availability Groups for failover: $( $RequestedAGs.Name -join ', ' )" -Level INFO
        }

        return $RequestedAGs
    }
    catch {
        Write-Log -Message "Error in Request-AGsToFailover: $( $_ )" -Level ERROR
        throw $_
    }
}

# Function to change Availability Groups to synchronous mode if required
function Change-ToSyncMode {
    param (
        [array]$AGs
    )
    try {
        foreach ($AG in $AGs) {
            if ($AG.IsAsync) {
                $primaryReplica = $AG.Primary
                $replicas = Get-DbaAgReplica -SqlInstance $primaryReplica -AvailabilityGroup $AG.Name
            
                foreach ($replica in $replicas) {
                    Set-DbaAgReplica -SqlInstance $primaryReplica -AvailabilityGroup $AG.Name -Replica $replica.Name -AvailabilityMode SynchronousCommit | Out-Null
                    Write-Log -Message "Changed replica $( $replica.Name ) in Availability Group $( $AG.Name ) to Synchronous Commit mode." -Level INFO
                }
            }
        }
    }
    catch {
        Write-Log -Message "Error in Change-ToSyncMode: $( $_ )" -Level ERROR
        throw $_
    }
}

# Function to wait for Availability Groups to synchronize
function WaitFor-Synchronization {
    param (
        [array]$AGs
    )
    try {
        foreach ($AG in $AGs) {
            $syncStatus = Get-DbaAgDatabase -SqlInstance $TargetInstance -AvailabilityGroup $AG.Name | Where-Object SynchronizationState -ne 'Synchronized'
            $waitCounter = 0
            while ($syncStatus -and $waitCounter -lt ($Timeout / 10)) {
                Write-Log -Message "Waiting for Availability Group $( $AG.Name ) to synchronize..." -Level INFO
                Start-Sleep -Seconds 10
                $syncStatus = Get-DbaAgDatabase -SqlInstance $TargetInstance -AvailabilityGroup $AG.Name | Where-Object SynchronizationState -ne 'Synchronized'
                $waitCounter++
            }
            if ($syncStatus) {
                Write-Log -Message "Availability Group $( $AG.Name ) did not synchronize within the timeout period." -Level FATAL
            } else {
                Write-Log -Message "Availability Group $( $AG.Name ) is synchronized." -Level SUCCESS
            }
        }
    }
    catch {
        Write-Log -Message "Error in WaitFor-Synchronization: $( $_ )" -Level ERROR
        throw $_
    }
}

# Function to initiate failover
function Initiate-Failover {
    param (
        [array]$AGNames,
        [string]$InstanceName = $TargetInstance
    )
    try {
        foreach ($AGName in $AGNames) {
            Write-Log -Message "Attempting to initiate failover for AG $( $AGName )" -Level INFO
            $result = Invoke-DbaAgFailover -SqlInstance $InstanceName -AvailabilityGroup $AGName -EnableException -Confirm:$False
            if ($result) {
                Write-Log -Message "Failover initiated for AG $( $AGName )" -Level SUCCESS
            } else {
                Write-Log -Message "Failover for AG $( $AGName ) did not initiate. Check SQL Server logs." -Level WARNING
            }
        }
    }
    catch {
        Write-Log -Message "Error in Initiate-Failover for AG $( $AGName ): $( $_ )" -Level ERROR
        throw $_
    }
}

# Function to report failover completion of each Availability Group
function Report-FailoverCompletion {
    param (
        [string]$AGName
    )
    try {
        Write-Log -Message "Failover completed for Availability Group $( $AGName )" -Level SUCCESS
    }
    catch {
        Write-Log -Message "Error in Report-FailoverCompletion for AG $( $AGName ): $( $_ )" -Level ERROR
        throw $_
    }
}

# Function to report completion of all selected Availability Groups
function Report-AllAGsCompletion {
    try {
        # TODO: Implement logic to report on all Availability Groups completion
        Write-Log -Message "All selected Availability Groups failover completed" -Level SUCCESS
    }
    catch {
        Write-Log -Message "Error in Report-AllAGsCompletion: $( $_ )" -Level ERROR
        throw $_
    }
}

# Define function to revert Availability Groups to their original mode
function Revert-AGsToOriginalMode {
    param (
        [array]$AGs
    )
    try {
        foreach ($AG in $AGs) {
            if ($AG.OriginalMode -eq 'AsynchronousCommit') {
                # Get all replicas for this Availability Group
                $replicas = Get-DbaAgReplica -SqlInstance $TargetInstance -AvailabilityGroup $AG.Name
                
                foreach ($replica in $replicas) {
                    # Revert the replica to asynchronous mode
                    Set-DbaAgReplica -SqlInstance $TargetInstance -AvailabilityGroup $AG.Name -Replica $replica.Name -AvailabilityMode AsynchronousCommit | Out-Null
                    Write-Log -Message "Reverted replica $( $replica.Name ) in Availability Group $( $AG.Name ) to Asynchronous Commit mode." -Level INFO
                }
            }
        }
    }
    catch {
        Write-Log -Message "Error in Revert-AGsToOriginalMode: $( $_ )" -Level ERROR
        throw $_
    }
}

# Define function to report the Availability Groups' states and health
function Report-AGState {
    param (
        [string]$SqlInstance
    )
    try {
        $Replicas = Get-DbaAgReplica -SqlInstance $SqlInstance | Where-Object {$_.Role -in @("Primary", "Secondary") -and $_.SqlInstance -eq $_.Name}

        foreach ($Replica in $Replicas) {
            
            # Report the properties you're interested in
            $stateMessage = "AG Name: $($Replica.AvailabilityGroup), " +
                            "Role: $($Replica.Role), " +
                            "Failover Mode: $($Replica.FailoverMode), " +
                            "Availability Mode: $($Replica.AvailabilityMode), " +
                            "Connection State: $($Replica.ConnectionState)"
            
            Write-Log -Message $stateMessage -Level INFO
        }
    }
    catch {
        Write-Log -Message "Error in Report-AGState: $( $_ )" -Level ERROR
        throw $_
    }
}

#############################
### Main script execution ###
#############################

try {
    # Get all Availability Groups that fit the criteria
    $AGsToFailover = Get-AGs -TargetInstance $TargetInstance -TargetReplicaType "Secondary"

    # Confirm which Availability Groups to failover
    $confirmedAGs = @(Request-AGsToFailover -AGs $AGsToFailover)

    # Only change to synchronous mode and wait for sync for the confirmed AGs
    if ($confirmedAGs.Count -gt 0) {
        Change-ToSyncMode -AGs $confirmedAGs
        WaitFor-Synchronization -AGs $confirmedAGs

        foreach ($AG in $confirmedAGs) {
            Initiate-Failover -AGNames @($AG.Name)
            Report-FailoverCompletion -AGName $AG.Name
        }

        # Revert Availability Groups back to their original mode
        Revert-AGsToOriginalMode -AGs $confirmedAGs
    }

    # Report completion
    Report-AllAGsCompletion

    # After all operations
    Report-AGState -SQLInstance $TargetInstance

    Read-Host "Press Enter to close"
}
catch {
    Write-Log -Message "An error occurred during script execution: $( $_ )" -Level FATAL
    Read-Host "Press Enter to close"
}
