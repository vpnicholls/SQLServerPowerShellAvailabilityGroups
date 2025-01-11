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