<#
.SYNOPSIS
Configures multiple SQL Server Always On Availability Groups with database mapping.

.DESCRIPTION
This script:
- Checks whether the host servers are part of a domain
- If not part of a domain, checks to see whether certificate-based authentication is configured
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
# First, set $params
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
    @{Name="AG1"; Databases=@("DB1", "DB2"); ListenerName="AG1Listener"; ListenerIPAddresses=@("192.168.1.100"); SubnetMasks=@("255.255.255.0"); ListenerPort=1433; IsMultiSubnet=$false; AvailabilityMode="SynchronousCommit"; FailoverMode="Automatic"; BackupPreference="Secondary"},
    @{Name="AG2"; Databases=@("DB3"); ListenerName="AG2Listener"; ListenerIPAddresses=@("192.168.1.101", "192.168.2.101"); SubnetMasks=@("255.255.255.0", "255.255.255.0"); IsMultiSubnet=$true; AvailabilityMode="AsynchronousCommit"; FailoverMode="Manual"; BackupPreference="Primary"}
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
    [Parameter(Mandatory=$false)][bool]$EnableAndRestart = $false,
    [Parameter(Mandatory=$false)][string[]]$logLevel = @("INFO", "WARNING", "ERROR", "SUCCESS", "FATAL")  # Default includes all but DEBUG
)

# Generate log file name with datetime stamp
$logFileName = Join-Path -Path $ScriptEventLogPath -ChildPath "ConfigureAlwaysOnAGsLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG", "VERBOSE", "FATAL")]
        [string]$Level = "INFO"
    )
    
    if ($Level -in $logLevel) {  # Check if the log level is in the allowed levels
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$timestamp [$Level] $Message" | Out-File -FilePath $logFileName -Append
    }
}

Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$AGConfigurations is $($AGConfigurations | ConvertTo-Json -Compress)." -Level "DEBUG"
Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$TargetInstances is $($TargetInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

if ($TargetInstances -isnot [array] -or $TargetInstances.Count -eq 0) {
    Write-Log -Message "TargetInstances must be an array with at least one element." -Level "ERROR"
    throw "Invalid TargetInstances parameter."
}

# Function to check if server is part of a domain
function IsServerOnDomain {
    param (
        [string]$ServerName
    )

    try {
        $computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $ServerName -ErrorAction Stop
        return $computerInfo.PartOfDomain
    }
    catch {
        Write-Log -Message "Failed to check domain status for server $($ServerName): $_" -Level "ERROR"
        throw "Failed to check domain status."
    }
}

# Function to check if certificate-based authentication is configured for HADR
function CheckCertificateAuthForHADR {
    param (
        [string]$Instance,
        [PSCredential]$Credential
    )

    $query = @"
    SELECT COUNT(*) AS CertAuthCount 
    FROM sys.database_mirroring_endpoints 
    WHERE name = 'hadr_endpoint' AND connection_auth_desc = 'CERTIFICATE'
"@
    try {
        $result = Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $Credential -Query $query | Select-Object -ExpandProperty CertAuthCount
        return $result -gt 0
    }
    catch {
        Write-Log -Message "Failed to check HADR endpoint authentication for server $($Instance): $_" -Level "ERROR"
        throw "Failed to check HADR endpoint authentication."
    }
}

function EnsureDatabasesInFullRecoveryMode {
    param (
        [string]$Instance,
        [PSCredential]$Credential,
        [string[]]$Databases
    )

    Write-Log -Message "Ensuring databases are in FULL recovery mode on $Instance." -Level "INFO"

    foreach ($db in $Databases) {
        try {
            # Check the database recovery model
            $dbInfo = Get-DbaDatabase -SqlInstance $Instance -SqlCredential $Credential -Database $db | Select-Object Name, RecoveryModel

            if ($null -eq $dbInfo) {
                Write-Log -Message "Database $db does not exist on $Instance." -Level "ERROR"
                throw "Database $db not found on $Instance."
            }

            if ($dbInfo.RecoveryModel -ne "Full") {
                Write-Log -Message "Changing recovery model for database $db from $($dbInfo.RecoveryModel) to Full." -Level "INFO"
                
                # Change the database to FULL recovery model
                $alterQuery = "ALTER DATABASE [$db] SET RECOVERY FULL;"
                $result = Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $Credential -Query $alterQuery -EnableException
                Write-Log -Message "Database $db recovery model set to FULL." -Level "SUCCESS"
            } else {
                Write-Log -Message "Database $db is already in FULL recovery mode." -Level "INFO"
            }
        }
        catch {
            Write-Log -Message "Failed to ensure FULL recovery mode for database $db on $($Instance): $_" -Level "ERROR"
            throw
        }
    }

    Write-Log -Message "All databases checked and set to FULL recovery mode on $Instance." -Level "SUCCESS"
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

function CreateAvailabilityGroup {
    param (
        [string]$PrimaryInstance,
        [string]$AGName,
        [array]$SecondaryInstances,
        [PSCredential]$Credential,
        [hashtable]$agConfig
    )

    if ($SecondaryInstances -isnot [array] -or $SecondaryInstances.Count -eq 0) {
        Write-Log -Message "No secondary instances provided for AG $AGName." -Level "ERROR"
        throw "No secondary instances provided for AG $AGName."
    }
    $secondaryServers = @($SecondaryInstances) | ForEach-Object {
        if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" }
    }
    
    Write-Log -Message "Creating and Configuring Availability Group $AGName on $PrimaryInstance." -Level "INFO"

    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$SecondaryInstances is $($SecondaryInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

    $agType = Check-EditionForAGType -Instance $PrimaryInstance -Credential $Credential
    $agParams = @{
        Primary = $PrimaryInstance
        Name = $AGName
        Secondary = $secondaryServers
        PrimarySqlCredential = $Credential
        SecondarySqlCredential = $Credential
        Confirm = $false
        EnableException = $true
    }

    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$SecondaryInstances is $($SecondaryInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

    # Basic AG configuration
    if ($agType -eq "Basic") {
        $agParams['Basic'] = $true
        Write-Log -Message "Creating Basic Availability Group due to SQL Server Edition." -Level "INFO"
    } elseif ($agType -eq "Unsupported") {
        Write-Log -Message "Unsupported SQL Server edition for Availability Groups." -Level "ERROR"
        throw "Unsupported SQL Server edition for Availability Groups."
    }

    # AG properties configuration
    $agParams['AvailabilityMode'] = $agConfig.AvailabilityMode
    $agParams['FailoverMode'] = $agConfig.FailoverMode
    $agParams['BackupPriority'] = 50  # Example, adjust as needed
    $agParams['ConnectionModeInPrimaryRole'] = 'AllowAllConnections'  # Adjust if needed
    $agParams['ConnectionModeInSecondaryRole'] = 'AllowNoConnections' # Adjust if needed
    $agParams['SeedingMode'] = 'Manual'

    # Listener configuration
    $agParams['IPAddress'] = $agConfig.ListenerIPAddresses
    $agParams['Port'] = if ($agConfig.ContainsKey('ListenerPort')) { $agConfig.ListenerPort } else { 1433 }

    try {
        New-DbaAvailabilityGroup @agParams
        Write-Log -Message "Availability Group $AGName created and configured successfully." -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to create and configure Availability Group ${AGName}: ${_}" -Level "ERROR"
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
        [string]$NetworkShare,
        [ValidateSet('Manual', 'Automatic')][string]$SeedingMode
    )

    # Check if databases exist
    $existingDbs = Get-DbaDatabase -SqlInstance $Instance -SqlCredential $Credential -Database $Databases
    $missingDbs = $Databases | Where-Object { $_ -notin $existingDbs.Name }

    if ($missingDbs) {
        Write-Log -Message "The following databases do not exist on ${Instance}: ($($missingDbs -join ', '))." -Level "ERROR"
        throw "Database validation failed for AG $AGName."
    }

    foreach ($db in $Databases) {
        Write-Log -Message "Adding database $db to Availability Group $AGName with ${SeedingMode} seeding." -Level "INFO"
        try {
            if ($SeedingMode -eq 'Automatic') {
                # Automatic seeding - SQL Server handles synchronization
                $joinResult = Add-DbaAgDatabase -SqlInstance $Instance -Database $db -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
                Write-Log -Message "Database $db automatically seeded and joined to Availability Group $AGName successfully." -Level "SUCCESS"
            }
            else {  # Manual seeding
                # Backup on primary
                $backupResult = Backup-DbaDatabase -SqlInstance $Instance -Database $db -SqlCredential $Credential -Path $NetworkShare -Type Full -EnableException
                Write-Log -Message "Database $db backed up successfully." -Level "INFO"

                # Restore on secondaries with NORECOVERY
                $secondaryInstances = $TargetInstances | ForEach-Object { if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" } }
                foreach ($secondary in $secondaryInstances) {
                    $restoreParams = @{
                        SqlInstance = $secondary
                        SqlCredential = $Credential
                        Database = $db
                        Path = $NetworkShare
                        NoRecovery = $true
                        EnableException = $true
                    }
                    Restore-DbaDatabase @restoreParams
                    Write-Log -Message "Database $db restored on secondary ${secondary} with NORECOVERY." -Level "INFO"
                }

                # Join the database to AG
                $joinResult = Add-DbaAgDatabase -SqlInstance $Instance -Database $db -AvailabilityGroup $AGName -SqlCredential $Credential -EnableException
                Write-Log -Message "Database $db manually seeded and joined to Availability Group $AGName successfully." -Level "SUCCESS"
            }
        }
        catch {
            Write-Log -Message "Failed to add database $db to Availability Group ${AGName} with ${SeedingMode} seeding: ${_}" -Level "ERROR"
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

    if ($null -eq $Instances -or $Instances.Count -eq 0) {
        Write-Log -Message "No instances provided for failover testing of AG $AGName." -Level "WARNING"
        return
    }

    foreach ($instance in $Instances) {
        $instanceName = if ($instance.Instance -eq "MSSQLSERVER") { $instance.HostServer } else { "$($instance.HostServer)\$($instance.Instance)" }
        
        Write-Log -Message "Initiating failover to $instanceName for Availability Group $AGName." -Level "INFO"
        try {
            $failoverStart = Get-Date

            # Initiate failover
            $failoverTime = Measure-Command {
                Invoke-DbaAgFailover -SqlInstance $instanceName -AvailabilityGroup $AGName -SqlCredential $Credential -Confirm:$false -EnableException
            }
            Write-Log -Message "Failover to $instanceName completed in $($failoverTime.TotalSeconds) seconds." -Level "SUCCESS"

            # Initiate failback to the original primary
            Write-Log -Message "Initiating failback to $SourceInstance for Availability Group $AGName." -Level "INFO"
            $failbackTime = Measure-Command {
                Invoke-DbaAgFailover -SqlInstance $SourceInstance -AvailabilityGroup $AGName -SqlCredential $Credential -Confirm:$false -EnableException
            }
            Write-Log -Message "Failback to $SourceInstance completed in $($failbackTime.TotalSeconds) seconds." -Level "SUCCESS"

            # Total time for failover and failback
            $totalTime = (Get-Date) - $failoverStart
            Write-Log -Message "Total time for failover and failback cycle: $($totalTime.TotalSeconds) seconds." -Level "INFO"

            # Additional health check after failback
            $healthCheckTime = Measure-Command {
                Test-DbaAvailabilityGroup -SqlInstance $SourceInstance -AvailabilityGroup $AGName -SqlCredential $Credential -Confirm:$false -EnableException
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
    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$AGConfigurations is $($AGConfigurations | ConvertTo-Json -Compress)." -Level "DEBUG"
    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$TargetInstances is $($TargetInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

    # Collect Windows Credential for each host server - Need to update this if host servers are part of domain and user is using domain credentials.
    $ServerCredentials = @{}
    $hosts = @($SourceInstance) + ($TargetInstances | ForEach-Object { $_.HostServer })
    foreach ($server in $hosts) {
        $serverName = $server.Split('\')[0]  # Get just the server name if it's an instance
        $ServerCredentials[$serverName] = Get-Credential -Message "Enter local admin credentials for $serverName"
    }
    
    # Ensure Always On is enabled on all instances
    $instancesToCheck = @($SourceInstance) + ($TargetInstances | ForEach-Object { if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" } })
    $isDomainEnvironment = $true
    foreach ($instance in $instancesToCheck) {
        Write-Log -Message "Debug: Instance being checked: $instance" -Level "DEBUG"
        $serverName = $instance.Split('\')[0]
        if ($EnableAndRestart) {
            # Check and enable HADR if necessary
            $isHadrEnabled = Invoke-DbaQuery -SqlInstance $instance -SqlCredential $myCredential -Query "SELECT SERVERPROPERTY('IsHadrEnabled');" | Select-Object -ExpandProperty Column1
            if (-not $isHadrEnabled) {
                Write-Log -Message "Enabling HADR on $instance." -Level "INFO"
                try {
                    Enable-DbaAgHadr -SqlInstance $instance -SqlCredential $myCredential -EnableException
                    Write-Log -Message "HADR configuration command executed. SQL Server service restart is required." -Level "INFO"
                    Restart-DbaService -SqlInstance $instance -Credential $ServerCredentials[$serverName] -Type Engine -EnableException | Out-Null
                    Write-Log -Message "SQL Server service on $instance has been restarted." -Level "INFO"
                }
                catch {
                    Write-Log -Message "Failed to enable HADR on $($instance): $_" -Level "ERROR"
                    throw "Failed to enable HADR on $instance. The script cannot proceed."
                }
            } else {
                Write-Log -Message "HADR is already enabled on $instance." -Level "INFO"
            }
        } else {
            # Only check if HADR is enabled, throw an error if not
            Enable-AlwaysOn -Instance $instance -SqlCredential $myCredential
        }

        # Check if server is part of domain
        if (-not (IsServerOnDomain -ServerName $serverName)) {
            $isDomainEnvironment = $false
        }
    }

    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$AGConfigurations is $($AGConfigurations | ConvertTo-Json -Compress)." -Level "DEBUG"
    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$TargetInstances is $($TargetInstances | ConvertTo-Json -Compress)." -Level "DEBUG"
    
    # If not in a domain environment, check for certificate-based authentication
    if (-not $isDomainEnvironment) {
        foreach ($instance in $instancesToCheck) {
            $serverName = $instance.Split('\')[0]
            $serviceAccount = (Get-DbaService -ComputerName $serverName -Credential $ServerCredentials[$serverName] | Where-Object {$_.ServiceType -eq 'Engine'}).StartName
            if ($serviceAccount -like "NT *") {  # Assuming NT SERVICE or SYSTEM accounts are built-in
                if (-not (CheckCertificateAuthForHADR -Instance $instance -Credential $myCredential)) {
                    Write-Log -Message "Certificate-based authentication is not configured for HADR on $instance. This is required when using built-in accounts in a workgroup environment." -Level "FATAL"
                    throw "Certificate-based authentication for HADR is not configured. Cannot proceed."
                }
            }
        }
    }

    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$AGConfigurations is $($AGConfigurations | ConvertTo-Json -Compress)." -Level "DEBUG"
    Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$TargetInstances is $($TargetInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

    # Process each AG configuration
    foreach ($agConfig in $AGConfigurations) {
        $agName = $agConfig.Name
        $databases = $agConfig.Databases
        $seedingMode = $agParams['SeedingMode']  # Assuming $agParams is still in scope

        # Check if AG already exists
        $existingAGs = Get-DbaAvailabilityGroup -SqlInstance $SourceInstance -SqlCredential $myCredential | Select-Object -ExpandProperty Name
        if ($agName -in $existingAGs) {
            Write-Log -Message "Availability Group $agName already exists. Skipping creation." -Level "INFO"
            # You might want to check the configuration state here in the future
            continue
        }

        Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$AGConfigurations is $($AGConfigurations | ConvertTo-Json -Compress)." -Level "DEBUG"
        Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$TargetInstances is $($TargetInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

        # Check the edition to determine AG type
        $agType = Check-EditionForAGType -Instance $SourceInstance -Credential $myCredential

        # Create and Configure Availability Group
        Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): Before creating AG $agName, secondary instances are: $($TargetInstances | ConvertTo-Json -Compress)." -Level "DEBUG"
        CreateAvailabilityGroup -PrimaryInstance $SourceInstance -AGName $agName -SecondaryInstances $TargetInstances -Credential $myCredential -agConfig $agConfig

        # Before adding databases to AG
        EnsureDatabasesInFullRecoveryMode -Instance $SourceInstance -Credential $myCredential -Databases $databases

        # Add databases to AG after validation
        Add-DatabasesToAG -Instance $SourceInstance -AGName $agName -Databases $databases -Credential $myCredential -NetworkShare $NetworkShare

        Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$AGConfigurations is $($AGConfigurations | ConvertTo-Json -Compress)." -Level "DEBUG"
        Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$TargetInstances is $($TargetInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

        Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): The value of `$allInstances is $($allInstances | ConvertTo-Json -Compress)." -Level "DEBUG"
        Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): All Instances for testing are: $($allInstances | ConvertTo-Json -Compress)." -Level "DEBUG"

        # Test failover and failback for each AG
        try {
            if ($null -eq $TargetInstances -or $TargetInstances.Count -eq 0) {
                Write-Log -Message "TargetInstances is null or empty when trying to test failover for AG $agName." -Level "ERROR"
                throw "No target instances provided for failover testing."
            }
            $allInstances = @($TargetInstances) + @(@{HostServer=$SourceInstance; Instance="MSSQLSERVER"})
            Write-Log -Message "Line $($PSCmdlet.MyInvocation.ScriptLineNumber): After creating `$allInstances, its value is: $($allInstances | ConvertTo-Json -Compress)." -Level "DEBUG"
    
            if ($allInstances -and $allInstances.Count -gt 0) {  # Check if $allInstances is not null and has elements
                Test-Failover -AGName $agName -Instances $allInstances -Credential $myCredential
            } else {
                Write-Log -Message "No instances found to test failover for AG $agName." -Level "WARNING"
            }
        } catch {
            Write-Log -Message "Failover test for AG $agName failed: $_" -Level "WARNING"
        }
    }

    Write-Log -Message "All Availability Groups configuration, testing completed." -Level "SUCCESS"
}
catch {
    Write-Log -Message "An error occurred during multiple AG configuration: $_" -Level "ERROR"
}