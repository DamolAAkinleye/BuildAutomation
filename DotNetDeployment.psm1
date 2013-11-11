# Interrogates Package file for evidence of NServiceBus.
# Returns $true if the pachage contains NServiceBus libraries, $false otherwise
function IsNServiceBusService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package file.")]
		[System.IO.FileInfo]$packageFile		
	)
	[string[]]$msdeployArgs = @(
	  "-verb:dump",
	  "-xml",
	  "-source:package='$packageFile'")
	  
	$xml = InvokeMsDeploy $msdeployArgs	
	
	if ($lastexitcode -ne 0) {
		throw ("Error inspecting $packageFile!")
	}
	
	$node = ([Xml]$xml).SelectSingleNode("//filePath[@path='NServiceBus.Host.exe']")
	return ($node -ne $null)
}

# Query KeePass using KPScript
# KeePass manages Name Value Pairs by Group, Title, and Field.  Group and Title are user defined.  Field is KeePass
# defined (e.g. UserName, Password, etc.)
function QueryKeePass {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the group containing the Title to Query for")]
		[String]$groupName,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the Title to query for")]
		[String]$title,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The name of the Field to query for")]
		[String]$fieldName
	)
	
	#TODO: Update paths with production locations.  Will also need to deal with how to securely access the keepass password
	# Keypass parameters
	$kpscriptPath = "C:\Program Files (x86)\KeePass Password Safe 2\kpscript.exe"
	$keepassDataBase = "C:\Users\brooksm\Documents\TestDatabase.kdbx"
	$keepassKeyFile = "C:\Users\brooksm\Documents\TestDatabase.key"
	$keepassPassword = "Halle2003"
	
	[String[]]$kpsArgs = @(
		"-c:GetEntryString",
		"`"$keepassDataBase`"",
		"-pw:`"$keepassPassword`"",
		"-keyfile:`"$keepassKeyFile`"",
		"-ref-Title:`"$title`"",
		"-Field:$fieldName",
		"-GroupName:`"$groupName`""
		)
	
	$output = @(cmd.exe /C $("`"`"$kpscriptPath`" $kpsArgs`""))
	if ($lastexitcode -ne 0) {
		$output
		throw ("Error executing KPScript!")
	}
	
	if ($output[$output.Length - 1] -eq "OK: Operation completed successfully.") {
		#copy all elements except the last to the new array
		[String[]]$newArray = @()
		for($i=0; $i -lt $output.Length - 1; $i++) {
			$newArray += $output[$i]
		}
		$newArray
	}
	else {
		throw ("Error occurred while querying KeePass - $output")
	}
}

function InvokeMsDeploy {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="MsDeploy parameters defined as a string array.")]
		[String[]]$parameters
	)
	$msdeploy_path = "C:\Program Files (x86)\IIS\Microsoft Web Deploy V3\msdeploy.exe"
	$output = cmd.exe /C $("`"`"$msdeploy_path`" $parameters`"")
	$output
}

function GetInstallationPath {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The MsDeploy 'DestManifext.xml' file.")]
		[System.IO.FileInfo]$destManifest
	)
	
	[xml]$xml = Get-Content $destManifest
	$path = $xml.sitemanifest.contentPath.path
	$path
}

# Function to deploy a regular Windows Service
# This functions does the following:
# 1. Stops and Removes the service if it already exists
# 2. Deploys the files via WebDeploy
# 3. Reinstalls and restarts the service
function DeployDotNetWindowsService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package folder to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the computer to install the service on.")]
		[string]$computerName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The name of the windows service")]
		[string]$serviceName,
		[parameter(Mandatory=$true, Position=3, HelpMessage="The username to create the service under")]
		[AllowEmptyString()]
		[string]$userName,
		[parameter(Mandatory=$true, Position=4, HelpMessage="The password of the username")]
		[AllowEmptyString()]
		[string]$password
	)

	# Stop the service
	StopService $computerName $serviceName $true

	# Deploy the new service files
	$fileNoExt = [System.IO.Path]::GetFileNameWithoutExtension($packageFile)	
	$destManifestFile = "$($packageFile.DirectoryName)\$($fileNoExt).DestManifest.xml"
	$settingsFile = "$($packageFile.DirectoryName)\$($fileNoExt).SetParameters.xml"
	$destinationRoot = GetInstallationPath $destManifestFile
	$destinationPath = "$($destinationRoot)\bin\$($fileNoExt).exe"

	[string[]]$msdeployArgs = @(
	  "-verb:sync",
	  "-source:package='$packageFile'",
	  "-dest:manifest=`"$destManifestFile`",computerName=`"$computerName`",authtype=`"NTLM`",includeAcls=`"False`"",
	  "-disableLink:AppPoolExtension",
	  "-disableLink:ContentExtension",
	  "-disableLink:CertificateExtension"
	  "-setParamFile:`"$settingsFile`"" 
	  "-enableRule:DoNotDeleteRule"
	  "-allowUntrusted"
	  "-verbose"
	  )
	  
	InvokeMsDeploy $msdeployArgs
	if ($lastexitcode -ne 0) {
		throw ("Error deploying $($packageFile)!")
	}

	# Create the service
	$Wmi = [wmiclass]("\\$computerName\ROOT\CIMV2:Win32_Service")
	if ($Wmi -eq $null) {
		throw "Error accessing 'Root\Cimv2' Namespace on $($computerName)"
	}	

	$inparams = $Wmi.PSBase.GetMethodParameters("Create")
	$inparams.DesktopInteract = $false
	$inparams.DisplayName = $serviceName
	$inparams.ErrorControl = 0
	$inparams.LoadOrderGroup = $null
	$inparams.LoadOrderGroupDependencies = $null
	$inparams.Name = $serviceName
	$inparams.PathName = $destinationPath
	$inparams.ServiceDependencies = $null
	$inparams.ServiceType = 16
	$inparams.StartMode = "Manual"
	$inparams.StartName = if ([string]::IsNullOrEmpty($userName) -eq $true) { $null } else { $userName }
	$inparams.StartPassword = if ([string]::IsNullOrEmpty($password) -eq $true) { $null } else { $password }
	
	$result = $Wmi.PSBase.InvokeMethod("Create", $inparams, $null)
	if ($result.ReturnValue -ne 0) {
		throw ("Unable to create windows service on $($computerName)! ReturnValue = $($result.ReturnValue)")
	}
	
	# Start the service
	#TODO:  Uncomment out once credential management issues have been resolved
	#StartService $computerName $serviceName
}

function DeployNServiceBusWindowsService {
	#TODO: Implement Function
}

function DeployDotNetWebApplication {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package file to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the MsDeploy Settings file to be used at deployment.")]
		[System.IO.FileInfo]$settingsFile,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The name of the server to install the web application.")]
		[string]$serverName,
		[parameter(Mandatory=$true, Position=3, HelpMessage="The web site name to deploy to")]
		[string]$siteName,
		[parameter(Mandatory=$true, Position=4, HelpMessage="The virtual path to deploy to")]
		[string]$applicationPath,
		[parameter(Mandatory=$true, Position=5, HelpMessage="The username to create the service under")]
		[AllowEmptyString()]
		[string]$userName,
		[parameter(Mandatory=$true, Position=6, HelpMessage="The password of the username")]
		[AllowEmptyString()]
		[string]$password
		)

		[string[]]$msdeployArgs = @(
		  "-verb:sync",
		  "-source:package='$packageFile'",
		  "-dest:auto,computerName=`"https://$($serverName):8172/msdeploy.axd?site=$($siteName)`",authtype=`"Basic`",username=`"$($userName)`",password=`"$($password)`",includeAcls=`"True`"",
		  "-retryAttempts:5",
		  "-retryInterval:3000",
		  "-setParam:name=`"IIS Web Application Name`",value=`"$($applicationPath)`"", 
		  "-enableLink:AppPoolExtension",
		  "-disableLink:ContentExtension",
		  "-disableLink:CertificateExtension"
		  "-setParamFile:`"$settingsFile`"" 
		  "-enableRule:DoNotDeleteRule"
		  "-allowUntrusted"
		  "-verbose"
		)
		
		InvokeMsDeploy $msdeployArgs
		if ($lastexitcode -ne 0) {
			throw ("Error deploying $($packageFolder.Name)!")
		}
}

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
		if ($service.State -eq "Running") { $service.StopService() }
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
			#TODO:  Uncomment throw once credential management issues are resolved
			#throw ("Unable to start service $($serviceName)! ReturnValue = $($startResult.ReturnValue)")
			"Unable to start service $($serviceName)! ReturnValue = $($startResult.ReturnValue)"
		}
		"Service $($serviceName) successfully started on $($computerName)!"
	}
	else {
		throw "Unable to start $($serviceName)!"
	}
}