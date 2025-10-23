[CmdletBinding()]
param (
	# Where to find the uproject file. Defaults to the current working directory or
	# $EngineRoot/$ProjectName for native projects with -ProjectName
	[Parameter()]
	[System.IO.FileInfo]$ProjectRoot,

	# Name of the uproject file to build. Tries to find one in the $ProjectRoot
	# by default
	[Parameter()]
	[string]$ProjectName,
	
	# Name of the build target. Defaults to $ProjectName
	[Parameter()]
	[string]$TargetName = $TargetName,
	
	# Type of target that will get built. Only used to find the output directory
	[Parameter()]
	[ValidateSet('Game', 'Client', 'Server')]
	[string]$TargetType = 'Game',

	# Target configuration. Debug and Test are only supported in source builds
	[Parameter()]
	[ValidateSet('Debug', 'DebugGame', 'Development', 'Test', 'Shipping')]
	[string]$Configuration = 'Development',

	# Platform to build and cook
	[Parameter()]
	[ValidateSet('Win64', 'Linux', 'LinuxArm64')]
	[string]$Platform = 'Win64',

	# If set, will bundle UE prereqs either as an installer or local DLLs
	[Parameter()]
	[Alias("Prereqs")]
	[ValidateSet('Installer', 'Local')]
	[string]$Prerequisites,

	# If set, will include the crash reporter in the build
	[Parameter()]
	[Alias("CrashReporter")]
	[switch]$IncludeCrashReporter,

	# Where to output the build. Defaults to $ProjectRoot/ArchivedBuilds.
	[Parameter()]
	[System.IO.FileInfo]$ArchiveRoot,

	# If set, will output the builds to `$ArchiveRoot\$TargetName-$Configuration+yyyymmddThhmm`
	# instead of just `$ArchiveRoot`.
	[Parameter()]
	[switch]$TimestampedArchiveFolder,

	# Unreal version that is used. Only used for launcher installs auto-root
	# folder "detection". Defaults to finding the one in the .uproject file
	[Parameter(ParameterSetName = 'LauncherInstall')]
	[string]$EngineVersion,

	# Whether this is a native project
	[Parameter(ParameterSetName = 'NativeProject', Mandatory = $true)]
	[switch]$NativeProject,

	# Path to Unreal Engine. Defaults to C:/Program Files/Epic Games/UE_$EngineVersion
	# for launcher installs, or tries to find one in the folder path for native installs
	[Parameter(ParameterSetName = 'LauncherInstall')]
	[Parameter(ParameterSetName = 'NativeProject')]
	[System.IO.FileInfo]$EngineRoot,

	# Whether to upload the game to itch using butler. See https://itch.io/docs/butler/
	[Parameter(ParameterSetName = 'Itch', Mandatory = $true)]
	[switch]$PublishToItch,

	# Enables uploading of non-shipping games
	[Parameter(ParameterSetName = 'Itch')]
	[switch]$AllowPublishNonShipping,

	# Username under which the game is hosted. See https://itch.io/docs/butler/pushing.html
	[Parameter(ParameterSetName = 'Itch', Mandatory = $true)]
	[string]$ItchUsername,

	# Name of the game being uploaded. See https://itch.io/docs/butler/pushing.html
	[Parameter(ParameterSetName = 'Itch', Mandatory = $true)]
	[string]$ItchGame,

	# Name of the channel where it should upload. See https://itch.io/docs/butler/pushing.html
	[Parameter(ParameterSetName = 'Itch')]
	[string]$ItchChannel,

	# If set, will use a custom credentials file. Useful if you need multiple users. See https://itch.io/docs/butler/login.html
	[Parameter(ParameterSetName = 'Itch')]
	[System.IO.FileInfo]$ItchCredentialsPath
)

# Prevent uploads of non-shipping builds by default
if ($PublishToItch -And !$AllowPublishNonShipping -And $Configuration -ne 'Shipping') {
	Write-Error 'Cannot publish non-Shipping builds to itch.' -Category InvalidArgument
	Exit 1
}

# Based on https://github.com/XistGG/UnrealXistTools/blob/main/UProjectFile.ps1
function Find-UProject {
	$Result = $null
	$FoundProjects = Get-ChildItem -Path $ProjectRoot -File `
	| Where-Object { $_.Extension -ieq '.uproject' }

	if ($FoundProjects.count -eq 1) {
		$Result = $FoundProjects[0]
	}
	elseif ($FoundProjects.count -gt 1) {
		# If we don't have a -ProjectName param, error.
		# User needs to tell us explicitly.
		if (!$ProjectName) {
			foreach ($ProjectFile in $FoundProjects) {
				Write-Warning "Ambiguous .uproject: $ProjectFile"
			}

			throw "Cannot auto-select a .uproject file in a directory with multiple .uproject; You must specify the -ProjectName parameter"
		}

		foreach ($ProjectFile in $FoundProjects) {
			if ($ProjectName -ieq $ProjectFile.BaseName) {
				$Result = $ProjectFile
			}
		}

		if (!$Result) {
			throw "Could not find $ProjectName.uproject file in $ProjectRoot; Please check your -ProjectName parameter"
		}
	}
	else {
		throw "Not an Unreal Engine project directory; no .uproject files in: $ProjectRoot"
	}

	return $Result
}

### Mostly imported from https://github.com/XistGG/UnrealXistTools/blob/main/Modules/UE.psm1 ###
function UE_ListCustomEngines_LinuxMac {
	[CmdletBinding()]
	param()

	$result = [System.Collections.ArrayList]@()

	$iniFile = $IsLinux ? $LinuxInstallIni : $MacInstallIni

	$installationPairs = & INI_ReadSection -Filename $iniFile -Section "Installations" -MayNotExist

	if ($installationPairs -and $installationPairs.Count -gt 0) {
		for ($i = 0; $i -lt $installationPairs.Count; $i++) {
			$iniPair = $installationPairs[$i]
			$result += [PSCustomObject]@{
				Name = $iniPair.Name
				Root = $iniPair.Value
			}
		}
	}

	return $result
}

function UE_ListCustomEngines_Windows {
	[CmdletBinding()]
	param()

	Write-Debug "Reading custom engines from Registry::$WindowsBuildsRegistryKey"

	$registryBuilds = Get-Item -Path "Registry::$WindowsBuildsRegistryKey" 2> $null
	$result = [System.Collections.ArrayList]@()

	if (!$registryBuilds) {
		Write-Warning "Build Registry Not Found: $WindowsBuildsRegistryKey"
		return $result
	}

	# Must iterate to Length; registry key does not have a Count
	for ($i = 0; $i -lt $registryBuilds.Length; $i++) {
		$propertyList = $registryBuilds[$i].Property

		# propertyList is an actual array, it has a Count
		if ($propertyList -and $propertyList.Count -gt 0) {
			for ($p = 0; $p -lt $propertyList.Count; $p++) {
				$buildName = $propertyList[$p]
				if ($buildName) {
					# Get the ItemPropertyValue for this $buildName
					$value = Get-ItemPropertyValue -Path "Registry::$WindowsBuildsRegistryKey" -Name $buildName

					# Append the build to the $result array
					$result += [PSCustomObject]@{
						Name = $buildName
						Root = $value
					}
				}
			}
		}
	}

	return $result
}

function UE_ListCustomEngines {
	[CmdletBinding()]
	param()

	if ($IsLinux -or $IsMacOS) {
		return & UE_ListCustomEngines_LinuxMac
	}

	return & UE_ListCustomEngines_Windows
}

function UE_SelectCustomEngine {
	[CmdletBinding()]
	param(
		[string]$Name,
		[string]$Root
	)

	# List all available custom engines
	$customEngines = & UE_ListCustomEngines

	foreach ($engine in $customEngines) {
		if ($Name) {
			Write-Debug "Compare desired -Name `"$Name`" with `"$($engine.Name)`""
			if ($engine.Name -eq $Name) {
				Write-Debug "Found custom engine match on -Name `"$Name`""
				return $engine
			}
		}
	}

	# This happens on build servers with unregistered engines in random locations.
	Write-Debug "Query for Custom Engine (`"$Name`") failed to find a match"
	return $null
}

function UE_GetEngineByAssociation {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[string]$EngineAssociation
	)

	$result = & UE_SelectCustomEngine -Name $EngineAssociation
	if ($result) {
		return $result.Root
	}

	return "C:\Program Files\Epic Games\UE_$EngineAssociation"
}
### End import(ish) from https://github.com/XistGG/UnrealXistTools/blob/main/Modules/UE.psm1 ###

function Build-Project {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[System.IO.FileInfo]
		$ProjectFile
	)

	if (!$ProjectName -And !$TargetName) {
		$TargetName = $ProjectFile.BaseName
	}
	
	$RunUATArgs = New-Object System.Collections.Generic.List[System.String]
	$RunUATArgs.AddRange([System.String[]]("-project=${ProjectFile}", "-configuration=${Configuration}", "-targetplatform=${Platform}"))
	$RunUATArgs.AddRange([System.String[]]("-build", "-target=${TargetName}"))
	$RunUATArgs.AddRange([System.String[]]("-cook", "-unversionedcookedcontent", "-pak", "-compressed", "-package", "-iostore"))

	if ($Prerequisites -eq 'Installer') {
		$RunUATArgs.Add("-prereqs")
	}
	elseif ($Prerequisites -eq 'Local') {
		$RunUATArgs.Add("-applocaldirectory=${EngineRoot}/Engine/Binaries/ThirdParty/AppLocalDependencies")
	}

	if ($IncludeCrashReporter) {
		$RunUATArgs.Add("-CrashReporter")
	}

	$RunUATArgs.AddRange([System.String[]]("-stage", "-archive", "-archivedirectory=${ArchiveRoot}"))
	$RunUATArgs.AddRange([System.String[]]("-utf8output", "-buildmachine", "-unattended", "-noP4", "-nosplash", "-stdout"))

	# Clear the output directory before building
	if (Test-Path $OutputDir) {
		Remove-Item -Recurse $OutputDir
	}

	Write-Host "----------------------------------------"
	Write-Host "Building target ${TargetName} in ${Configuration} configuration`n"
	& $EngineRoot/Engine/Build/BatchFiles/RunUAT.bat BuildCookRun $RunUATArgs
}

function Find-Butler {
	if (Get-Command "butler" -ErrorAction SilentlyContinue) {
		return "butler"
	}
	
	if (Test-Path -PathType Leaf "${ButlerAutoDownloadPath}/butler.exe") {
		return "${ButlerAutoDownloadPath}/butler.exe"
	}

	return $null
}

function Install-Butler {
	$ButlerVersion = '15.24.0'

	If (!(Test-Path -PathType Container $ButlerAutoDownloadPath)) {
		New-Item -ItemType Directory -Path $ButlerAutoDownloadPath | Out-Null
	}

	Write-Host "The butler tool was not found, downloading butler $ButlerVersion from broth.itch.ovh"
	Invoke-WebRequest -Uri "https://broth.itch.zone/butler/windows-amd64/15.24.0/archive/default" -OutFile "${ButlerAutoDownloadPath}/butler-${ButlerVersion}.zip"

	Write-Host "Extracting butler-${ButlerVersion}.zip"
	Expand-Archive -LiteralPath "${ButlerAutoDownloadPath}/butler-${ButlerVersion}.zip" -DestinationPath $ButlerAutoDownloadPath -Force

	# Make sure the user is logged in
	$ButlerCmd = "${ButlerAutoDownloadPath}/butler.exe"
	$ButlerArgs = New-Object System.Collections.Generic.List[System.String]
	if ($ItchCredentialsPath) {
		$ButlerArgs.Add("--identity=${ItchCredentialsPath}")
	}
	Write-Host "Waiting for butler login..."
	$(& $ButlerCmd login $ButlerArgs) | Out-Null # powershell adds this to the function's return vars if not Out-Null

	return "${ButlerAutoDownloadPath}/butler.exe"
}

function Publish-To-Itch {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]
		$ButlerCmd
	)

	$ButlerArgs = New-Object System.Collections.Generic.List[System.String]

	# Use custom butler credentials if specified
	if ($ItchCredentialsPath) {
		$ButlerArgs.Add("--identity=${ItchCredentialsPath}")
	}
	
	# Ignore debugging symbols to reduce build size
	if ($Platform -eq 'Win64') {
		$ButlerArgs.Add("--ignore=*.pdb")
	}
	elseif ($Platform -eq 'Linux') {
		$ButlerArgs.AddRange([System.String[]]("--ignore=*.sym", "--ignore=*.debug"))
	}

	# Default ignores
	$ButlerArgs.AddRange([System.String[]]("--ignore=StagedBuild_*.ini", "--ignore=Manifest_*.txt"))

	Write-Host "`n`n----------------------------------------"
	Write-Host "Uploading to itch.io at ${ItchUsername}/${ItchGame}:${ItchChannel}`n"
	& $ButlerCmd push $ButlerArgs $OutputDir "${ItchUsername}/${ItchGame}:${ItchChannel}"
}

if (-not $EngineRoot -and $NativeProject) {
	$EngineRoot = [System.IO.Path]::GetFullPath($PWD)

	while ($true) {
		if (Test-Path "${EngineRoot}/Engine") {
			break
		}
		if (-not (Get-Item $EngineRoot).Parent) {
			throw "Could not find an Engine folder in any parent folder."
		}
		$EngineRoot = [System.IO.Path]::GetFullPath((Get-Item $EngineRoot).Parent)
	}
}

# Set default project root
if (-not $ProjectRoot) {
	if ($NativeProject -And $ProjectName) {
		$ProjectRoot = "${EngineRoot}/${ProjectName}"
	}
	else {
		$ProjectRoot = [System.IO.Path]::GetFullPath($PWD)
	}
}
else {
	$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot, $PWD)
}

# Move to the project folder in case some paths are relative to it
Push-Location $ProjectRoot

$UProjectFile = $null

try {
	$UProjectFile = Find-UProject
}
catch {
	Pop-Location
	exit
}

# Set default engine root to default launcher install location using the version
if (-not $EngineRoot) {
	if (-not $EngineVersion) {
		$UProject = Get-Content -Raw $UProjectFile | ConvertFrom-Json

		if (Get-Member -InputObject $UProject -Name "EngineAssociation" -MemberType Properties) {
			$EngineRoot = UE_GetEngineByAssociation $UProject.EngineAssociation
		}
	}
	else {
		$EngineRoot = "C:/Program Files/Epic Games/UE_${EngineVersion}"
	}
}

# Set default archive root and clear it
if (-not $ArchiveRoot) {
	$ArchiveRoot = "${ProjectRoot}/ArchivedBuilds"
}
else {
	$ArchiveRoot = [System.IO.Path]::GetFullPath($ArchiveRoot, $PWD)
}

if ($TimestampedArchiveFolder) {
	$ArchiveRoot += "/${TargetName}-${Configuration}+$(Get-Date -Format "yyyyMMddTHHmm")"
}

# Set the correct platform output directory, for itch.
$OutputDir = $ArchiveRoot.FullName
$OutputDir += "/${Platform}"

if ($TargetType -eq 'Server') {
	$OutputDir += 'Server'
}

# Set the correct itch channel
if ($Platform -eq 'Win64') {
	$ItchChannel = 'windows'
}
elseif ($Platform -eq 'Linux') {
	$ItchChannel = 'linux'
}

# Path to auto-downloaded butler
$ButlerAutoDownloadPath = "${ProjectRoot}/Intermediate/Juniper-BuildScript-Butler"

try {
	Build-Project $UProjectFile
	
	if ($PublishToItch) {
		$ButlerCmd = Find-Butler
		if (!$ButlerCmd) {
			$ButlerCmd = Install-Butler
		}
		Publish-To-Itch $ButlerCmd
	}
}
finally {
	# Return to original location
	Pop-Location
}
