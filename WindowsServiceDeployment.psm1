

# Generic function to stop a service and optionally uninstall
function StopService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the computer that the service is on.")]
		[string]$computerName,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the windows service")]
		[string]$serviceName,
		[parameter(Position=2, HelpMessage="The name of the computer that the service is on.")]
		[Boolean]$remove = $false
	)
	
	# Stop the service (if running) and delete it
	$service = Get-WmiObject -Class Win32_Service -ComputerName $computerName -Filter "Name = '$serviceName'"
	if ($service -ne $null) 
	{ 
		if ($service.State -eq "Running") 
		{ 
			$processId = $service.ProcessID
			$service.StopService() 
			"$serviceName is $($service.State)"
			"Verify Process $($processId) has stopped on $($computerName)"
			$runningCheck = { Get-WmiObject -Class Win32_Process -Filter "ProcessId='$processId'" -ComputerName $computerName -ErrorAction SilentlyContinue }

			while ($null -ne (& $runningCheck))
			{
			 Start-Sleep -s 2
			}
			"Process $($processId) has stopped."
		}
	    if ($remove -eq $true) { $service.Delete() | out-null }
	}
}

# Generic function to start a service
function StartService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the computer that the service is on.")]
		[string]$computerName,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the windows service")]
		[string]$serviceName
	)
	
	# Start the service
	$service = Get-WmiObject -Class Win32_Service -ComputerName $computerName -Filter "Name = '$serviceName'"
	if ($service -ne $null) { 
		$startResult = $service.StartService()
		if ($startResult.ReturnValue -ne 0) {
			throw ("Unable to start service $($serviceName)! ReturnValue = $($startResult.ReturnValue)")			
		}
		"Service $($serviceName) successfully started on $($computerName)!"
	}
	else {
		throw "Unable to start $($serviceName)!"
	}
}