<#
.SYNOPSIS
Configures, validates, tests, and benchmarks SQL Server Always On Availability Groups.

.DESCRIPTION
This script:
- Enables Always On on SQL Server instances.
- Creates an Availability Group.
- Adds databases to the Availability Group.
- Configures replicas.
- Performs failover and failback tests.
- Validates and benchmarks the setup.

.PARAMETER myCredential
Credentials used to connect to SQL Server instances.

.PARAMETER ScriptEventLogPath
Directory where script logs will be stored.

.PARAMETER SourceInstance
The primary SQL Server instance for the Availability Group.

.PARAMETER TargetInstances
Array of hashtables specifying secondary SQL Server instances.

.PARAMETER AGName
Name of the Availability Group to be created.

.PARAMETER Databases
Databases to be added to the Availability Group.

.PARAMETER NetworkShare
A network share for backup and restore operations.

.EXAMPLE
$params = @{
    myCredential = (Get-Credential -UserName 'admin' -Message "Please enter your password")
    ScriptEventLogPath = "$env:userprofile\Documents\Logs"
    SourceInstance = "SQLPRIMARY"
    TargetInstances = @(
        @{HostServer="SQLSECONDARY1"; Instance="MSSQLSERVER"},
        @{HostServer="SQLSECONDARY2"; Instance="MSSQLSERVER"}
    )
    AGName = "MyAG"
    Databases = @("DB1", "DB2")
    NetworkShare = "\\myserver\SQLBackups"
}

.\ConfigureAlwaysOn.ps1 @params

.NOTES
- Ensure SQL Server instances are prepared for Always On (Windows Server Failover Clustering, matching SQL Server versions, etc.).
- The script assumes that SQL Server instances have been joined to the same WSFC and have the necessary permissions.
- The script will attempt to enable Always On on the instances if not already enabled.
- Backup and restore operations are used to seed data to secondary replicas; ensure permissions and connectivity are correctly set up.
#>

#requires -module dbatools

param (
    [Parameter(Mandatory=$true)][PSCredential]$myCredential,
    [Parameter(Mandatory=$true)][string]$ScriptEventLogPath,
    [Parameter(Mandatory=$true)][string]$SourceInstance,
    [Parameter(Mandatory=$true)][array]$TargetInstances,
    [Parameter(Mandatory=$true)][string]$AGName,
    [Parameter(Mandatory=$true)][string[]]$Databases,
    [Parameter(Mandatory=$true)][string]$NetworkShare
)

# Generate log file name with datetime stamp
$logFileName = Join-Path -Path $ScriptEventLogPath -ChildPath "ConfigureAlwaysOnLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG", "VERBOSE", "FATAL")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp [$Level] $Message" | Out-File -FilePath $logFileName -Append
}

# Function to check and enable Always On if not enabled
function Enable-AlwaysOn {
    param (
        [string]$Instance,
        [PSCredential]$Credential
    )

    Write-Log -Message "Checking if Always On is enabled on $Instance." -Level "INFO"
    $currentConfig = Get-DbaSpConfigure -SqlInstance $Instance -SqlCredential $Credential -ConfigName 'hadr enabled'
    if ($currentConfig.ConfigValue -ne 1) {
        Write-Log -Message "Enabling Always On on $Instance." -Level "INFO"
        Set-DbaSpConfigure -SqlInstance $Instance -SqlCredential $Credential -ConfigName 'hadr enabled' -Value 1 -EnableException | Out-Null
        Write-Log -Message "Always On has been enabled on $Instance. A SQL Server restart is required." -Level "INFO"
        Restart-DbaService -SqlInstance $Instance -SqlCredential $Credential -Type Engine -EnableException | Out-Null
        Write-Log -Message "SQL Server service on $Instance has been restarted." -Level "INFO"
    } else {
        Write-Log -Message "Always On is already enabled on $Instance." -Level "INFO"
    }
}

# Function to check SQL Server edition for Basic AG support
function Check-EditionForBasicAG {
    param (
        [string]$Instance,
        [PSCredential]$Credential
    )

    $serverInfo = Get-DbaInstance -SqlInstance $Instance -SqlCredential $Credential
    $edition = $serverInfo.Edition
    $basicAGSupported = $edition -like "*Standard*" -or $edition -like "*Express*"
    Write-Log -Message "SQL Server Edition: $edition. Basic AG supported: $basicAGSupported" -Level "INFO"
    return $basicAGSupported
}

# Function to create Availability Group
function Create-AvailabilityGroup {
    param (
        [string]$PrimaryInstance,
        [string]$AGName,
        [array]$SecondaryInstances,
        [PSCredential]$Credential
    )

    Write-Log -Message "Creating Availability Group $AGName on $PrimaryInstance." -Level "INFO"
    $secondaryServers = $SecondaryInstances | ForEach-Object {
        if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" }
    }

    $basicAG = Check-EditionForBasicAG -Instance $PrimaryInstance -Credential $Credential
    $agParams = @{
        Primary = $PrimaryInstance
        Name = $AGName
        Secondary = $secondaryServers
        SqlCredential = $Credential
        EnableException = $true
    }

    if ($basicAG) {
        $agParams['Basic'] = $true
        Write-Log -Message "Creating Basic Availability Group due to SQL Server Edition." -Level "INFO"
    }

    try {
        New-DbaAvailabilityGroup @agParams
        Write-Log -Message "Availability Group $AGName created successfully." -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to create Availability Group: $_" -Level "ERROR"
        throw
    }
}

# Function to add databases to the Availability Group
function Add-DatabasesToAG {
    param (
        [string]$Instance,
        [string]$AGName,
        [string[]]$Databases,
        [PSCredential]$Credential,
        [string]$NetworkShare
    )

    foreach ($db in $Databases) {
        Write-Log -Message "Adding database $db to Availability Group $AGName." -Level "INFO"
        try {
            $backupResult = Backup-DbaDatabase -SqlInstance $Instance -Database $db -SqlCredential $Credential -Path $NetworkShare -Type Full -EnableException
            Write-Log -Message "Database $db backed up successfully." -Level "INFO"

            $joinResult = Add-DbaAgDatabase -SqlInstance $Instance -Database $db -AvailabilityGroup $AGName -SqlCredential $Credential -SharedPath $NetworkShare -EnableException
            Write-Log -Message "Database $db added to Availability Group $AGName successfully." -Level "SUCCESS"
        }
        catch {
            Write-Log -Message "Failed to add database $db to Availability Group: $_" -Level "ERROR"
            throw
        }
    }
}

# Function to test failover and failback
function Test-Failover {
    param (
        [string]$AGName,
        [array]$Instances,
        [PSCredential]$Credential
    )

    foreach ($instance in $Instances) {
        $instanceName = if ($instance.Instance -eq "MSSQLSERVER") { $instance.HostServer } else { "$($instance.HostServer)\$($_.Instance)" }
        
        Write-Log -Message "Initiating failover to $instanceName for Availability Group $AGName." -Level "INFO"
        try {
            Invoke-DbaAgFailover -SqlInstance $instanceName -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
            Write-Log -Message "Failover to $instanceName completed." -Level "SUCCESS"
            
            # Wait for some time to ensure failover has been processed
            Start-Sleep -Seconds 30
            
            # Initiate failback to the original primary
            Write-Log -Message "Initiating failback to $SourceInstance for Availability Group $AGName." -Level "INFO"
            Invoke-DbaAgFailover -SqlInstance $SourceInstance -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
            Write-Log -Message "Failback to $SourceInstance completed." -Level "SUCCESS"

            # Additional health check after failback
            Test-DbaAvailabilityGroup -SqlInstance $SourceInstance -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
        }
        catch {
            Write-Log -Message "Failed to test failover/failback: $_" -Level "ERROR"
            throw
        }
    }
}

# Function to perform benchmarking
function Benchmark-AG {
    param (
        [string]$AGName,
        [string]$Instance,
        [PSCredential]$Credential
    )

    Write-Log -Message "Benchmarking performance of Availability Group $AGName." -Level "INFO"
    try {
        # Example: Measure backup performance
        $backupTime = Measure-Command { Backup-DbaDatabase -SqlInstance $Instance -Database $Databases[0] -SqlCredential $Credential -Path $NetworkShare -Type Full -EnableException }
        Write-Log -Message "Backup time for $($Databases[0]): ($($backupTime.TotalSeconds) seconds)" -Level "INFO"

        # Example: Check replication latency
        $syncCheck = Get-DbaAgReplica -SqlInstance $Instance -AvailabilityGroup $AGName -SqlCredential $Credential
        foreach ($replica in $syncCheck) {
            Write-Log -Message "Replica $($replica.ReplicaServerName) synchronization health: $($replica.SynchronizationHealth)" -Level "INFO"
        }

        # Additional benchmarks can be added here, like read/write performance tests
    }
    catch {
        Write-Log -Message "Benchmarking failed: $_" -Level "ERROR"
        throw
    }
}

# Main execution
try {
    # Ensure Always On is enabled on all instances
    Enable-AlwaysOn -Instance $SourceInstance -Credential $myCredential
    foreach ($instance in $TargetInstances) {
        $instanceName = if ($instance.Instance -eq "MSSQLSERVER") { $instance.HostServer } else { "$($instance.HostServer)\$($instance.Instance)" }
        Enable-AlwaysOn -Instance $instanceName -Credential $myCredential
    }

    # Create Availability Group
    Create-AvailabilityGroup -PrimaryInstance $SourceInstance -AGName $AGName -SecondaryInstances $TargetInstances -Credential $myCredential

    # Add databases to AG
    Add-DatabasesToAG -Instance $SourceInstance -AGName $AGName -Databases $Databases -Credential $myCredential -NetworkShare $NetworkShare

    # Test failover and failback
    $allInstances = @($TargetInstances) + @(@{HostServer=$SourceInstance; Instance="MSSQLSERVER"})
    Test-Failover -AGName $AGName -Instances $allInstances -Credential $myCredential

    # Benchmarking
    Benchmark-AG -AGName $AGName -Instance $SourceInstance -Credential $myCredential

    Write-Log -Message "Always On configuration, testing, and benchmarking completed." -Level "SUCCESS"
}
catch {
    Write-Log -Message "An error occurred during Always On configuration, testing, or benchmarking: $_" -Level "ERROR"
}