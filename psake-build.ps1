# Load dependent modules
if (!(Get-Module ".\DotNetDeployment.psm1")) { 
    Import-Module ".\DotNetDeployment.psm1" -ErrorAction Stop
}

Properties {
	#Contants
	$script_file_dir = Split-Path $psake.build_script_file
	$build_artifacts_dir = "$build_dir\BuildArtifacts\"
	$code_dir = $script_file_dir
	$mstest_path = "C:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\IDE\MSTest.exe"
	$msdeploy_path = "C:\Program Files (x86)\IIS\Microsoft Web Deploy V3\msdeploy.exe"
	#MSBuild Variables
	$ProjectsToBuild = "$code_dir\Safe Auto Systems.sln"
	$Configuration = "Debug"
	$Platform = "AnyCPU"
	$OutDir = "$script_file_dir\BuildArtifacts\"
	$deploymentConfig = "Deployment.config"
	$Verbosity = "/v:Normal"
	$MaxCpuCount = 1
	$FileLogger = ""
	$DistributedLogger = ""
	$TFSServerUrl = ""
	$BuildUri = ""
	$TeamProject = ""
	$DestManifest = ""
}

task default -depends CIBuild

task CIBuild -depends Build, CIBuildUnitTest {
}

task DeploymentBuild -depends BuildAndPackage, DeploymentBuildUnitTest, DeployPackages {
}

task Clean {
	Write-Output $ProjectsToBuild
	Write-Output $Configuration
	Write-Output $OutDir
	Write-Output $Verbosity

	if (Test-Path -Path $OutDir) {
		Write-Output "Cleaning $($OutDir) recursively..."
		$dir = Get-Item $OutDir
		$dir.Delete($true)
	}
	
	mkdir $OutDir | Out-Null
	
	Write-Output "Cleaning $ProjectsToBuild"
	Exec { msbuild $ProjectsToBuild /t:Clean /p:Configuration=$Configuration /p:Platform=$Platform $Verbosity }
}

task Build {
	# Parse Projects to Build
	$projectFiles = ParseProjectsToBuild
	# Fix the output dir variable if necessary
	$OutDirPath = FixOutDirForMsBuild
	foreach($projectFile in $projectFiles) {
		Write-Output "Building $projectFile" -ForegroundColor Green
		Exec { msbuild $projectFile /t:Build /p:Configuration=$Configuration /p:Platform=$Platform /p:OutDir=$OutDirPath /m:$MaxCpuCount /nr:false $FileLogger $DistributedLogger $Verbosity} 
	}
}

task BuildAndPackage {
	Write-Output $FileLogger
	Write-Output $DistributedLogger
	# Parse Projects to Build
	$projectFiles = ParseProjectsToBuild
	# Fix the output dir variable if necessary
	$OutDirPath = FixOutDirForMsBuild
	foreach($projectFile in $projectFiles) {
		Write-Output "Building and Packaging $projectFile" -ForegroundColor Green
		Exec { msbuild $projectFile /t:Build /p:Configuration=$Configuration /p:Platform=$Platform /p:OutDir=$OutDirPath /m:$MaxCpuCount /nr:false /p:DeployOnBuild=True /p:DeployTarget=Package /p:DestinationManifestRootPath=$DestManifest $FileLogger $DistributedLogger $Verbosity} 
	}
}

task CIBuildUnitTest -depends Build {
	RunUnitTests
}
#
task DeploymentBuildUnitTest -depends BuildAndPackage {
	RunUnitTests
}

task DeployPackages -depends BuildAndPackage {
	Write-Output "Deploying Packages"
	
	$packages = Get-ChildItem "$OutDir\_PublishedWebsites\*_Package"
	foreach($package in $packages) {
		if (Test-Path "$package\*.DestManifest.xml") {
			DeployWindowsServiceApplication $package	
		}
		else {		
			DeployWebApplication $package
		}
	}
}

# Function to fix the OutDir variable if it contains spaces, it must end in "\\" due to a bug in MSBuild
function FixOutDirForMsBuild {	
	$tempPath = Resolve-Path $OutDir
	if ($tempPath.Path.IndexOf(" ") -ge 0) {
		$path = $tempPath.Path
		if ($path.EndsWith("\")) {
			$path = $path + "\"
		}
		else {
			$path = $path + "\\"
		}
		return ($path)
	}
	return $tempPath.Path
}

function ParseProjectsToBuild {
	return $ProjectsToBuild.split(";")
}

function RunUnitTests {
	$assemblies = Get-ChildItem "$OutDir\*.Tests.dll"
	if ($assemblies.Count -gt 0) {
		Write-Output "Executing Unit Tests"

		# Time Stamp will be added to our test files
		$TimeStamp = (Get-Date -Format "yyyy-MM-dd.hh_mm_ss")
		
		# Add the test results file to the directory
		$TestResultsFile = "`"$OutDir\${TimeStamp}.trx`""
		$TestArgs = @()
		foreach($assembly in $assemblies) {
			$TestArgs += $("/testcontainer:`"$($assembly)`"")
			Write-Output "Adding $assembly to tests"
		}
		$TestArgs += "/flavor:`"$Configuration`""
		$TestArgs += "/platform:`"$Platform`""
		$TestArgs += "/detail:errormessage"
		$TestArgs += "/resultsfile:$TestResultsFile"
		if ($TFSServerUrl -ne "") {
			Write-Output "TFSServerUrl = $TFSServerUrl"
			$TestArgs += "/publish:`"$TFSServerUrl`""
		}
		if ($BuildUri -ne "") {
			Write-Output "BuildUri = $BuildUri"
			$TestArgs += "/publishbuild:`"$BuildUri`""
		}
		if ($TeamProject -ne "") {
			Write-Output "TeamProject = $TeamProject"
			$TestArgs += "/teamproject:`"$TeamProject`""
		}
		
		Write-Output $("`"$mstest_path`" $TestArgs")
		#& $mstest_path $TestArgs /detail:errormessage /resultsfile:$TestResultsFile			
		cmd.exe /C $("`"`"$mstest_path`" $TestArgs`"")
		
		if ($lastexitcode -ne 0) {
			throw ("Error executing Tests!")
		}
		
		$executed = 0
		$passed = 0
		$failed = 0
		
		if (Test-Path $TestResultsFile) {
			$xml = [xml](Get-Content $TestResultsFile)
			$counters = $xml.TestRun.ResultSummary.Counters
			$executed += ($counters | Select total).total
			$passed += ($counters | Select passed).passed
			$failed += ($counters | Select failed).failed
			$failed += ($counters | Select error).error
			$failed += ($counters | Select inconclusive).inconclusive
		}
	
		Write-Output "Tests Executed: $executed"
		Write-Output "Tests Passed: $passed"
		Write-Output "Tests Failed: $failed"
		#TODO: Fail process if tests fail		
	}
}

function DeployWebApplication {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package folder to be deployed.")]
		[System.IO.DirectoryInfo]$packageFolder
	)
	Write-Output "Deploying Web Application $($packageFolder.Name)"
	$settings = GetDeploymentSettings $packageFolder.Name
	if ($settings -ne $null) {
		if ($settings.DeploymentType -eq "Skip") {
			Write-Output "Skipping Package $($packageFolder.Name)"
			return
		}
		Write-Output "Deploying $($packageFolder.Name) to '$($settings.Server)/$($settings.SiteName)'...$($settings.ApplicationPath)..."
		
		$packageFile = "$($packageFolder)\$($settings.Name).zip"
		$settingsFile = "$($packageFolder)\$($settings.Name).SetParameters.xml"
		DeployDotNetWebApplication $packageFile $settingsFile $settings.Server $settings.SiteName $settings.ApplicationPath $settings.UserName $settings.Password	
	}
}

function DeployWindowsServiceApplication {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package folder to be deployed.")]
		[System.IO.DirectoryInfo]$packageFolder
	)
	Write-Output "Deploying Windows Service $($packageFolder.Name)"
	$settings = GetDeploymentSettings $packageFolder.Name
	if ($settings -ne $null) {
		if ($settings.DeploymentType -eq "Skip") {
			Write-Output "Skipping Package $($packageFolder.Name)"
			return
		}
		Write-Output "Deploying $($packageFolder.Name) on $($settings.Server) as $($settings.ServiceName)..."
		
		$userName = $settings.UserName
		$password = $settings.Password
		
		# Lookup credentials from KeePass if a Title is provided
		if ([string]::IsNullOrEmpty($settings.KeePassTitle) -eq $false) {
			$userName = QueryKeePass $settings.KeePassGroup $settings.KeePassTitle "UserName"
			$password = QueryKeePass $settings.KeePassGroup $settings.KeePassTitle "Password"
		}
		
		$packageFile = "$($packageFolder)\$($settings.Name).zip"

		if ((IsNServiceBusService $packageFile) -eq $true) {
			DeployNServiceBusWindowsService
		}
		else {
			DeployDotNetWindowsService $packageFile $settings.Server $settings.ServiceName $userName $password
		}
	}
}

function GetDeploymentSettings {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the application in the Deployment configuration file")]
		[String]$packageFolderName
	)
	$deploymentConfigFile = "$($OutDir)\$($deploymentConfig)"
	
	if (Test-Path $deploymentConfigFile) {
		[Xml]$xml = Get-Content $deploymentConfigFile
		$app = $xml.SelectSingleNode("//Application[PackageFolderName='" + $packageFolderName + "']")
		if ($app -eq $null) {
			#throw ("Unable to find configuration for $packageFolderName")
			Write-Output "Unable to find configuration for $($packageFolderName)"
			return $null
		}
		else {
			# Create custom object for deployment settings
			#TODO: refactor to an array of custom objects
			$server = ""
			$appPath = ""
			$user = ""
			$password = ""
			$sitename = ""
			$serviceName = ""
			$deploymentType = $app.Deployment.DeploymentType
			$name = $app.Name
			$keePassGroup = ""
			$keePassTitle = ""
					
			if ($deploymentType -ne "Skip") {
				$server = $app.Deployment.Servers.Server.Name
				$appPath = $app.Deployment.Servers.Server.InstallationPath
				$user = $app.Deployment.Servers.Server.UserName
				$password = $app.Deployment.Servers.Server.Password
				$sitename = $app.Deployment.Servers.Server.SiteName
				$serviceName = $app.Deployment.Servers.Server.ServiceName
				$keePassGroup = $app.Deployment.Servers.Server.KeePassGroup
				$keePassTitle = $app.Deployment.Servers.Server.KeePassTitle
			}
			
			$settings = New-Object PSObject
			$settings | Add-Member NoteProperty -Name Name -Value $name
			$settings | Add-Member NoteProperty -Name DeploymentType -Value $deploymentType
			$settings | Add-Member NoteProperty -Name Server -Value $server
			$settings | Add-Member NoteProperty -Name ApplicationPath -Value $appPath
			$settings | Add-Member NoteProperty -Name UserName -Value $user
			$settings | Add-Member NoteProperty -Name Password -Value $password
			$settings | Add-Member NoteProperty -Name SiteName -Value $sitename
			$settings | Add-Member NoteProperty -Name ServiceName -Value $serviceName
			$settings | Add-Member NoteProperty -Name KeePassGroup -Value $keePassGroup
			$settings | Add-Member NoteProperty -Name KeePassTitle -Value $keePassTitle

			return $settings
		}
	}
	else {
		throw ("Deployment Configuration file not found at $deploymentConfigFile")
	}

}

