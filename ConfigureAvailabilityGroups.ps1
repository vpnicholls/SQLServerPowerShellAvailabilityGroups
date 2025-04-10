﻿<#
.SYNOPSIS
Configures multiple SQL Server Always On Availability Groups with database mapping.

.DESCRIPTION
This script:
- Checks whether the host servers are part of a domain
- If not part of a domain, checks to see whether certificate-based authentication is configured
- Enables Always On on SQL Server instances.
- Checks for existing Availability Groups and skips creation if they already exist.
- Creates one or more Availability Groups.
- Creates the associated Availability Group Listeners.
- Adds specified databases to their corresponding Availability Groups.
- Configures replicas.
- Validates database existence before adding them to AGs.
- Checks the HostRecordTTL (To be developed).
- Cleans up backup files from the network share at the end of execution.

It does not test or benchmark failovers. This will be developed in a separate script.

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

.PARAMETER HasDomainAccount
Optional parameter, defaulted to TRUE, to indicate that a domain account will be used to access all host servers.
Set to FALSE to import saved credentials from .\Credentials\<HostServerName>.xml (where . is the directory you have this script saved to).

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
    @{Name="AG1"; Databases=@("DB1", "DB2"); ListenerName="AG1Listener"; ListenerIPAddresses=@("192.168.1.100"); SubnetMasks=@("255.255.255.0"); ListenerPort=1433; IsMultiSubnet=$false; AvailabilityMode="SynchronousCommit"; FailoverMode="Automatic"; BackupPreference="Secondary"},
    @{Name="AG2"; Databases=@("DB3"); ListenerName="AG2Listener"; ListenerIPAddresses=@("192.168.1.101", "192.168.2.101"); SubnetMasks=@("255.255.255.0", "255.255.255.0"); IsMultiSubnet=$true; AvailabilityMode="AsynchronousCommit"; FailoverMode="Manual"; BackupPreference="Primary"}
    )
}

# Then call the script:
.\ConfigureAvailabilityGroups.ps1 @params

.NOTES
- Ensure SQL Server instances are prepared for Always On (Windows Server Failover Clustering, matching SQL Server versions, matching drive layouts, etc.).
- The script assumes that SQL Server instances have been joined to the same WSFC and have the necessary permissions.
- The script will attempt to enable Always On on the instances if not already enabled.
- Backup and restore operations are used to seed data to secondary replicas; ensure permissions and connectivity are correctly set up.
#>

#requires -module dbatools

#################
### The Setup ###
#################

param (
    [Parameter(Mandatory=$true)][PSCredential]$myCredential,
    [Parameter(Mandatory=$true)][string]$ScriptEventLogPath,
    [Parameter(Mandatory=$true)][string]$SourceInstance,
    [Parameter(Mandatory=$true)][array]$TargetInstances,
    [Parameter(Mandatory=$true)][array]$AGConfigurations,
    [Parameter(Mandatory=$true)][string]$NetworkShare,
    [Parameter(Mandatory=$false)][bool]$EnableAndRestart = $false,
    [Parameter(Mandatory=$false)][bool]$HasDomainAccount = $true
)

# Generate log file name with datetime stamp
$logFileName = Join-Path -Path $ScriptEventLogPath -ChildPath "ConfigureAlwaysOnAGsLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Define function for log writer
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

# Import SQL credentials
if (-not $HasDomainAccount) {
    try {
        $myCredential = Import-Clixml -Path ".\Credentials\myCredentials.xml"
    }
    catch {
        Write-Log -Message "Failed to import SQL credentials from .\Credentials\myCredentials.xml: $_" -Level "ERROR"
        throw "SQL Credential import failed. Please ensure the credentials file is present and accessible."
    }
}

# Collect Windows Credential for each host server if not using domain account
$ServerCredentials = @{}
if (-not $HasDomainAccount) {
    $hosts = @($SourceInstance) + ($TargetInstances | ForEach-Object { 
        if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" }
    })
    foreach ($server in $hosts) {
        $serverName = $server.Split('\')[0]  # Get just the server name if it's an instance
        try {
            $ServerCredentials[$serverName] = Import-Clixml -Path ".\Credentials\$serverName.xml"
        }
        catch {
            Write-Log -Message "Failed to import Windows credentials for $serverName from .\Credentials\$serverName.xml: $_" -Level "ERROR"
            throw "Windows Credential import for $serverName failed. Please ensure the credential file is present and accessible."
        }
    }
}
else {
    # For users with domain account, we don't need to collect credentials for each server
    # Just use the SQL credential if necessary or leave $ServerCredentials empty for domain scenarios where no local credentials are needed
}

# Define function to check if server is part of a domain
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

# Define function to check for any requested Availabilty Groups that already exist.
function Check-ExistingAGs {
    param (
        [string]$Instance,
        [PSCredential]$Credential,
        [string[]]$AGNames
    )

    [string[]]$existingAGs = Get-DbaAvailabilityGroup -SqlInstance $Instance -SqlCredential $Credential | Select-Object -ExpandProperty Name

    $nonExistingAGs = @()
    foreach ($agName in $AGNames) {
        if ($agName -in $existingAGs) {
            Write-Log -Message "Availability Group $agName already exists on $Instance. Skipping creation." -Level "WARNING"
        } else {
            $nonExistingAGs += $agName
        }
    }
    return $nonExistingAGs
}

# Define function to check that all databases are in FULL recovery mode
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

# Define function to decide which type of Availability group will be created, based on SQL Server Edition
function Check-EditionForAGType {
    param (
        [string]$Instance,
        [PSCredential]$Credential
    )

    $editionQuery = "SELECT SERVERPROPERTY('Edition') AS Edition"
    $edition = Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $Credential -Query $editionQuery | Select-Object -ExpandProperty Edition

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

    if (-not $alreadyLoggedEdition) {
        Write-Log -Message "SQL Server Edition: $edition" -Level "INFO"
        Write-Log -Message "Availability Group type for this edition: $agType" -Level "INFO"
        $script:alreadyLoggedEdition = $true
    }
    return $agType
}

# Define function to create the Availability Group
function CreateAvailabilityGroup {
    param (
        [string]$PrimaryInstance,
        [string]$AGName,
        [array]$SecondaryInstances,
        [PSCredential]$Credential,
        [hashtable]$agConfig
    )

    Write-Log -Message "Creating and Configuring Availability Group $AGName on $PrimaryInstance." -Level "INFO"
    
    $secondaryServers = $SecondaryInstances | ForEach-Object {
        if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" }
    }

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
    $agParams['SeedingMode'] = 'Automatic'  # Automatic seeding, adjust if manual is preferred

    # Listener configuration
    $agParams['IPAddress'] = $agConfig.ListenerIPAddresses
    $agParams['Port'] = if ($agConfig.ContainsKey('ListenerPort')) { $agConfig.ListenerPort } else { 1433 }

    try {
        New-DbaAvailabilityGroup @agParams
        Write-Log -Message "Availability Group $AGName created and configured successfully." -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "Failed to create and configure Availability Group $($AGName): $_" -Level "ERROR"
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

######################
### Main execution ###
######################

try {
    # Ensure Always On is enabled on all instances
    $instancesToCheck = @($SourceInstance) + ($TargetInstances | ForEach-Object { if ($_.Instance -eq "MSSQLSERVER") { $_.HostServer } else { "$($_.HostServer)\$($_.Instance)" } })
    $isDomainEnvironment = $true
    foreach ($instance in $instancesToCheck) {
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

    $allAGNames = $AGConfigurations | ForEach-Object { $_.Name }
    $agNamesToCreate = Check-ExistingAGs -Instance $SourceInstance -Credential $myCredential -AGNames $allAGNames

    # Process each AG configuration that doesn't already exist
    foreach ($agConfig in $AGConfigurations) {
        $agName = $agConfig.Name
        if ($agName -in $agNamesToCreate) {
            $databases = $agConfig.Databases

            # Check the edition to determine AG type
            $agType = Check-EditionForAGType -Instance $SourceInstance -Credential $myCredential

            # Create and Configure Availability Group
            CreateAvailabilityGroup -PrimaryInstance $SourceInstance -AGName $agName -SecondaryInstances $TargetInstances -Credential $myCredential -agConfig $agConfig | Out-Null

            # Before adding databases to AG
            EnsureDatabasesInFullRecoveryMode -Instance $SourceInstance -Credential $myCredential -Databases $databases

            # Add databases to AG after validation
            Add-DatabasesToAG -Instance $SourceInstance -AGName $agName -Databases $databases -Credential $myCredential -NetworkShare $NetworkShare | Out-Null
        }
    }

    Write-Log -Message "All Availability Groups configuration, testing completed." -Level "SUCCESS"
}
catch {
    Write-Log -Message "An error occurred during multiple AG configuration: $_" -Level "ERROR"
}
finally {
    # Clean up backup files from the network share
    Write-Log -Message "Cleaning up backup files from the network share." -Level "INFO"
    try {
        # Pattern for backup files like "DatabaseName_yyyyMMddhhmm.bak"
        $backupFiles = Get-ChildItem -Path $NetworkShare -Filter "*_*.bak"
        if ($backupFiles) {
            foreach ($file in $backupFiles) {
                # Check if the filename matches the specific pattern
                if ($file.Name -match "^(.+)_(\d{12})\.bak$") {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    Write-Log -Message "Removed backup file: $($file.Name)" -Level "INFO"
                }
            }
        } else {
            Write-Log -Message "No backup files found to clean up." -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "Failed to clean up backup files: $_" -Level "ERROR"
    }
}