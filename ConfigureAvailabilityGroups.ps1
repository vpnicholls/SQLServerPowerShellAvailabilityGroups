<#
.SYNOPSIS
Configures multiple SQL Server Always On Availability Groups with database mapping.

.DESCRIPTION
This script:
- Enables Always On on SQL Server instances.
- Creates one or more Availability Groups.
- Creates the associated Availability Group Listeners.
- Adds specified databases to their corresponding Availability Groups.
- Configures replicas.
- Performs failover and failback tests for each AG.
- Validates database existence before adding them to AGs.

.PARAMETER myCredential
Credentials used to connect to SQL Server instances.

.PARAMETER ScriptEventLogPath
Directory where script logs will be stored.

.PARAMETER SourceInstance
The primary SQL Server instance for the Availability Groups.

.PARAMETER TargetInstances
Array of hashtables specifying secondary SQL Server instances.

.PARAMETER AGConfigurations
Array of hashtables where each hashtable specifies an AG name and its databases.

.PARAMETER NetworkShare
A network share for backup and restore operations.

.PARAMETER EnableAndRestart
A boolean, where $true instructs the script to attempt to enable the Always On feature and restart the service on all host servers. 
Use $False if you've already had the the feature enabled and services restarted by other means.

.EXAMPLE
$params = @{
    myCredential = (Get-Credential -Message "Please enter your password for the SQL Server instances.")
    ScriptEventLogPath = "$env:userprofile\Documents\Scripts\PowerShell\Migration\Logs"
    SourceInstance = "SQLPRIMARY"
    TargetInstances = @(
        @{HostServer="SQLSECONDARY1"; Instance="MSSQLSERVER"},
        @{HostServer="SQLSECONDARY2"; Instance="MSSQLSERVER"}
    )
    NetworkShare = "\\myserver\SQLBackups"
    AGConfigurations = @(
        @{Name="AG1"; Databases=@("DB1", "DB2"); ListenerName="AG1Listener"; ListenerIPAddresses=@("192.168.1.100"); IsMultiSubnet=$false; AvailabilityMode="SynchronousCommit"; FailoverMode="Automatic"; BackupPreference="Secondary"},
        @{Name="AG2"; Databases=@("DB3"); ListenerName="AG2Listener"; ListenerIPAddresses=@("192.168.1.101", "192.168.2.101"); IsMultiSubnet=$true; AvailabilityMode="AsynchronousCommit"; FailoverMode="Manual"; BackupPreference="Primary"}
    )
}

# Then call the script:
.\ConfigureAvailabilityGroups.ps1 @params

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
    [Parameter(Mandatory=$true)][array]$AGConfigurations,
    [Parameter(Mandatory=$true)][string]$NetworkShare,
    [Parameter(Mandatory=$false)][bool]$EnableAndRestart = $false
)

# Generate log file name with datetime stamp
$logFileName = Join-Path -Path $ScriptEventLogPath -ChildPath "ConfigureAlwaysOnAGsLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

# Collect Windows Credential only if needed
if ($EnableAndRestart) {
    $WindowsCredential = Get-Credential -Message "Please enter your password for the Windows Hosts. Needed for service restart."
} else {
    Write-Log -Message "Windows credential not required as service restart is disabled." -Level "INFO"
}

# Function to check and enable Always On if not enabled
function Enable-AlwaysOn {
    param (
        [string]$Instance,
        [PSCredential]$SqlCredential
    )

    Write-Log -Message "Checking if Always On is enabled on $Instance." -Level "INFO"
    $isHadrEnabled = Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $SqlCredential -Query "SELECT SERVERPROPERTY('IsHadrEnabled');" | Select-Object -ExpandProperty Column1

    if (-not $isHadrEnabled) {
        Write-Log -Message "Always On is not enabled on $Instance. Manual configuration required." -Level "WARNING"
        throw "HADR is not enabled on $Instance. Please enable it manually and restart the service."
    } else {
        Write-Log -Message "Always On is already enabled on $Instance." -Level "INFO"
    }
}

function Check-EditionForAGType {
    param (
        [string]$Instance,
        [PSCredential]$Credential
    )

    $editionQuery = "SELECT SERVERPROPERTY('Edition') AS Edition"
    $edition = Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $Credential -Query $editionQuery | Select-Object -ExpandProperty Edition
    Write-Log -Message "SQL Server Edition: $edition" -Level "INFO"

    if ($edition -like "*Enterprise*" -or $edition -like "*Developer*") {
        $agType = "Advanced"
        if ($edition -like "*Developer*") {
            Write-Log -Message "You are using Developer Edition. If you intend using Standard Edition in Production, be aware that Basic Availability Groups are not available in Developer Edition." -Level "WARNING"
        }
    } elseif ($edition -like "*Standard*") {
        $agType = "Basic"
    } else {
        # Handle other editions like Express, Web, or any future editions
        $agType = "Unsupported"
        Write-Log -Message "This edition ($edition) does not support Availability Groups." -Level "WARNING"
    }

    Write-Log -Message "AG Type for this edition: $agType" -Level "INFO"
    return $agType
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
        PrimarySqlCredential = $Credential
        SecondarySqlCredential = $Credential
        EnableException = $true
    }

    if ($basicAG) {
        $agParams['Basic'] = $true
        Write-Log -Message "Creating Basic Availability Group(s) due to SQL Server Edition." -Level "INFO"
    }

    try {
        New-DbaAvailabilityGroup @agParams
        Write-Log -Message "Availability Group $AGName created successfully." -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to create Availability Group $($AGName): $_" -Level "ERROR"
        throw
    }
}

# Function to configure Availability Group properties
function Configure-AvailabilityGroup {
    param (
        [string]$Instance,
        [string]$AGName,
        [PSCredential]$Credential,
        [string]$ListenerName,
        [string[]]$ListenerIPAddresses,
        [int]$ListenerPort = 1433,
        [bool]$IsMultiSubnet = $false,
        [string]$AvailabilityMode = 'SynchronousCommit',  # SynchronousCommit or AsynchronousCommit
        [string]$FailoverMode = 'Automatic',  # Automatic or Manual
        [string]$BackupPreference = 'Secondary'  # Primary, Secondary, or None
    )

    Write-Log -Message "Configuring properties for Availability Group $AGName." -Level "INFO"

    try {
        # Configure Listener
        $listenerParams = @{
            SqlInstance = $Instance
            AvailabilityGroup = $AGName
            SqlCredential = $Credential
            Name = $ListenerName
            Port = $ListenerPort
            EnableException = $true
        }

        if ($IsMultiSubnet) {
            $listenerParams['IP'] = $ListenerIPAddresses
            New-DbaAgListener @listenerParams -EnableMultiSubnetFailover
        } else {
            $listenerParams['IP'] = $ListenerIPAddresses[0]  # Assuming single subnet for simplicity
            New-DbaAgListener @listenerParams
        }
        Write-Log -Message "Listener for AG $AGName configured." -Level "SUCCESS"

        # Configure Availability Mode
        Set-DbaAgReplica -SqlInstance $Instance -AvailabilityGroup $AGName -SqlCredential $Credential -AvailabilityMode $AvailabilityMode -EnableException
        Write-Log -Message "Availability Mode set to $AvailabilityMode for AG $AGName." -Level "SUCCESS"

        # Configure Failover Mode
        Set-DbaAgReplica -SqlInstance $Instance -AvailabilityGroup $AGName -SqlCredential $Credential -FailoverMode $FailoverMode -EnableException
        Write-Log -Message "Failover Mode set to $FailoverMode for AG $AGName." -Level "SUCCESS"

        # Configure Backup Preference
        Set-DbaAgReplica -SqlInstance $Instance -AvailabilityGroup $AGName -SqlCredential $Credential -BackupPriority 50 -ReadonlyRoutingUrl "TCP://$($Instance):$ListenerPort" -BackupPreference $BackupPreference -EnableException
        Write-Log -Message "Backup Preference set to $BackupPreference for AG $AGName." -Level "SUCCESS"

    }
    catch {
        Write-Log -Message "Failed to configure properties for AG $($AGName): $_" -Level "ERROR"
        throw
    }
}

# Function to validate and add databases to AG
function Add-DatabasesToAG {
    param (
        [string]$Instance,
        [string]$AGName,
        [string[]]$Databases,
        [PSCredential]$Credential,
        [string]$NetworkShare
    )

    # Check if databases exist
    $existingDbs = Get-DbaDatabase -SqlInstance $Instance -SqlCredential $Credential -Database $Databases
    $missingDbs = $Databases | Where-Object { $_ -notin $existingDbs.Name }

    if ($missingDbs) {
        Write-Log -Message "The following databases do not exist on $($Instance): ($($missingDbs -join ', '))." -Level "ERROR"
        throw "Database validation failed for AG $AGName."
    }

    foreach ($db in $Databases) {
        Write-Log -Message "Adding database $db to Availability Group $AGName." -Level "INFO"
        try {
            $backupResult = Backup-DbaDatabase -SqlInstance $Instance -Database $db -SqlCredential $Credential -Path $NetworkShare -Type Full -EnableException
            Write-Log -Message "Database $db backed up successfully." -Level "INFO"

            $joinResult = Add-DbaAgDatabase -SqlInstance $Instance -Database $db -AvailabilityGroup $AGName -SqlCredential $Credential -SharedPath $NetworkShare -EnableException
            Write-Log -Message "Database $db added to Availability Group $AGName successfully." -Level "SUCCESS"
        }
        catch {
            Write-Log -Message "Failed to add database $db to Availability Group $($AGName): $_" -Level "ERROR"
            throw
        }
    }
}

# Function to test failover and failback for an AG, recording time taken for each state change, to provide a benchmark for failovers
function Test-Failover {
    param (
        [string]$AGName,
        [array]$Instances,
        [PSCredential]$Credential
    )

    foreach ($instance in $Instances) {
        $instanceName = if ($instance.Instance -eq "MSSQLSERVER") { $instance.HostServer } else { "$($instance.HostServer)\$($instance.Instance)" }
        
        Write-Log -Message "Initiating failover to $instanceName for Availability Group $AGName." -Level "INFO"
        try {
            $failoverStart = Get-Date

            # Initiate failover
            $failoverTime = Measure-Command {
                Invoke-DbaAgFailover -SqlInstance $instanceName -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
            }
            Write-Log -Message "Failover to $instanceName completed in $($failoverTime.TotalSeconds) seconds." -Level "SUCCESS"

            # Initiate failback to the original primary
            Write-Log -Message "Initiating failback to $SourceInstance for Availability Group $AGName." -Level "INFO"
            $failbackTime = Measure-Command {
                Invoke-DbaAgFailover -SqlInstance $SourceInstance -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
            }
            Write-Log -Message "Failback to $SourceInstance completed in $($failbackTime.TotalSeconds) seconds." -Level "SUCCESS"

            # Total time for failover and failback
            $totalTime = (Get-Date) - $failoverStart
            Write-Log -Message "Total time for failover and failback cycle: $($totalTime.TotalSeconds) seconds." -Level "INFO"

            # Additional health check after failback
            $healthCheckTime = Measure-Command {
                Test-DbaAvailabilityGroup -SqlInstance $SourceInstance -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
            }
            Write-Log -Message "Health check after failback completed in $($healthCheckTime.TotalSeconds) seconds." -Level "INFO"
        }
        catch {
            Write-Log -Message "Failed to test failover/failback for AG $($AGName): $_" -Level "ERROR"
            throw
        }
    }
}

# Main execution
try {
    # Ensure Always On is enabled on all instances, but don't enable if not set in the script parameter
    $instancesToCheck = @($SourceInstance) + ($TargetInstances | ForEach-Object { if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" } })
    foreach ($instance in $instancesToCheck) {
        if ($EnableAndRestart) {
            # Check and enable HADR if necessary
            $isHadrEnabled = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $myCredential -Query "SELECT SERVERPROPERTY('IsHadrEnabled');" | Select-Object -ExpandProperty Column1
            if (-not $isHadrEnabled) {
                Write-Log -Message "Enabling HADR on $instance." -Level "INFO"
                Invoke-DbaQuery -SqlInstance $instance -SqlCredential $myCredential -Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'hadr enabled', 1; RECONFIGURE;"
                Write-Log -Message "HADR configuration command executed. SQL Server service restart is required." -Level "INFO"
                Restart-DbaService -SqlInstance $instance -Credential $WindowsCredential -Type Engine -EnableException | Out-Null
                Write-Log -Message "SQL Server service on $instance has been restarted." -Level "INFO"
            } else {
                Write-Log -Message "HADR is already enabled on $instance." -Level "INFO"
            }
        } else {
            # Only check if HADR is enabled, throw an error if not
            Enable-AlwaysOn -Instance $instance -SqlCredential $myCredential
        }
    }

    # Process each AG configuration
    foreach ($agConfig in $AGConfigurations) {
        $agName = $agConfig.Name
        $databases = $agConfig.Databases
        $listenerName = $agConfig.ListenerName
        $listenerIPAddresses = $agConfig.ListenerIPAddresses
        $isMultiSubnet = $agConfig.IsMultiSubnet -as [bool]
        $availabilityMode = if ($null -ne $agConfig.AvailabilityMode) { $agConfig.AvailabilityMode } else { 'SynchronousCommit' }
        $failoverMode = if ($null -ne $agConfig.FailoverMode) { $agConfig.FailoverMode } else { 'Automatic' }
        $backupPreference = if ($null -ne $agConfig.BackupPreference) { $agConfig.BackupPreference } else { 'Primary' }

        # Create Availability Group
        Create-AvailabilityGroup -PrimaryInstance $SourceInstance -AGName $agName -SecondaryInstances $TargetInstances -Credential $myCredential

        # Configure AG properties including listener, availability mode, etc.
        Configure-AvailabilityGroup -Instance $SourceInstance -AGName $agName -Credential $myCredential -ListenerName $listenerName -ListenerIPAddresses $listenerIPAddresses -IsMultiSubnet $isMultiSubnet -AvailabilityMode $availabilityMode -FailoverMode $failoverMode -BackupPreference $backupPreference

        # Add databases to AG after validation
        Add-DatabasesToAG -Instance $SourceInstance -AGName $agName -Databases $databases -Credential $myCredential -NetworkShare $NetworkShare

        # Test failover and failback for each AG
        $allInstances = @($TargetInstances) + @(@{HostServer=$SourceInstance; Instance="MSSQLSERVER"})
        Test-Failover -AGName $agName -Instances $allInstances -Credential $myCredential
    }

    Write-Log -Message "All Availability Groups configuration, testing completed." -Level "SUCCESS"
}
catch {
    Write-Log -Message "An error occurred during multiple AG configuration: $_" -Level "ERROR"
}