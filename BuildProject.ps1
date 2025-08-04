[CmdletBinding()]
param (
	# Where to find the uproject file. Defaults to the script's directory or
	# $EngineRoot/$ProjectName for native projects with -ProjectName
	[Parameter()]
	[string]$ProjectRoot,

	# Name of the uproject file to build. Tries to find one in the $ProjectRoot
	# by default
	[Parameter()]
	[string]$ProjectName,
	
	# Name of the build target. Defaults to $ProjectName
	[Parameter()]
	[string]$TargetName = $ProjectName,
	
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
	[ValidateSet('Win64', 'Linux')]
	[string]$Platform = 'Win64',

	# If set, will bundle UE prereqs either as an installer or local DLLs
	[Parameter()]
	[ValidateSet('Installer', 'Local')]
	[string]$Prereqs,

	# Where to output the build. Defaults to $ProjectRoot/ArchivedBuilds.
	[Parameter()]
	[string]$ArchiveRoot,

	# If set, will archive builds to $ArchiveRoot/$TargetName-$Configuration+YYYYMMDDTHHMM
	[Parameter()]
	[switch]$TimestampedArchiveFolder,

	# Unreal version that is used. Only used for launcher installs auto-root
	# folder "detection". Defaults to 5.6
	[Parameter(ParameterSetName = 'LauncherInstall')]
	[string]$EngineVersion = '5.6',

	# Whether this is a native project
	[Parameter(ParameterSetName = 'NativeProject', Mandatory = $true)]
	[switch]$NativeProject,

	# Path to Unreal Engine. Defaults to C:/Program Files/Epic Games/UE_$EngineVersion
	# for launcher installs and $ProjectRoot/.. for native installs
	[Parameter(ParameterSetName = 'LauncherInstall')]
	[Parameter(ParameterSetName = 'NativeProject')]
	[string]$EngineRoot,

	# Whether to upload the game to itch using butler. See https://itch.io/docs/butler/
	[Parameter(ParameterSetName = 'NativeProject')]
	[Parameter(ParameterSetName = 'Itch', Mandatory = $true)]
	[switch]$PublishToItch,

	# Enables uploading of non-shipping games
	[Parameter(ParameterSetName = 'NativeProject')]
	[Parameter(ParameterSetName = 'Itch')]
	[switch]$AllowPublishNonShipping,

	# Username under which the game is hosted. See https://itch.io/docs/butler/pushing.html
	[Parameter(ParameterSetName = 'NativeProject')]
	[Parameter(ParameterSetName = 'Itch', Mandatory = $true)]
	[string]$ItchUsername,

	# Name of the game being uploaded. See https://itch.io/docs/butler/pushing.html
	[Parameter(ParameterSetName = 'NativeProject')]
	[Parameter(ParameterSetName = 'Itch', Mandatory = $true)]
	[string]$ItchGame,

	# Name of the channel where it should upload. See https://itch.io/docs/butler/pushing.html
	[Parameter(ParameterSetName = 'NativeProject')]
	[Parameter(ParameterSetName = 'Itch')]
	[string]$ItchChannel,

	# If set, will use a custom credentials file. Useful if you need multiple users. See https://itch.io/docs/butler/login.html
	[Parameter(ParameterSetName = 'NativeProject')]
	[Parameter(ParameterSetName = 'Itch')]
	[string]$ItchCredentialsPath
)

# Set default engine root to default launcher install location using the version
if (!$EngineRoot) {
	if ($NativeProject) {
		$EngineRoot = "${PSScriptRoot}/.."
	}
	else {
		$EngineRoot = "C:/Program Files/Epic Games/UE_${EngineVersion}"
	}
}

# Set default project root
if (!$ProjectRoot) {
	if ($NativeProject -And $ProjectName) {
		$ProjectRoot = "${EngineRoot}/${ProjectName}"
	}
	else {
		$ProjectRoot = $PSScriptRoot
	}
}

# Set default archive root and clear it
if (!$ArchiveRoot) {
	$ArchiveRoot = "${ProjectRoot}/ArchivedBuilds"
}

if ($TimestampedArchiveFolder) {
	$ArchiveRoot += "/${TargetName}-${Configuration}+$(Get-Date -Format "yyyyMMddTHHmm")"
}

# Set the correct platform output directory, for itch.
$OutputDir = $ArchiveRoot
if ($Platform -eq 'Win64') {
	$OutputDir += '/Windows'
}
elseif ($Platform -eq 'Linux') {
	$OutputDir = '/Linux'
}

if ($TargetType -eq 'Server') {
	$OutputDir += 'Server'
}

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

			Write-Error "Cannot auto-select a .uproject file in a directory with multiple .uproject; You must specify the -ProjectName parameter"
			Exit 1
		}

		foreach ($ProjectFile in $FoundProjects) {
			if ($ProjectName -ieq $ProjectFile.BaseName) {
				$Result = $ProjectFile
			}
		}

		if (!$Result) {
			Write-Error "Could not find $ProjectName.uproject file in $ProjectRoot; Please check your -ProjectName parameter"
			Exit 1
		}
	}
	else {
		Write-Error "Not an Unreal Engine project directory; no .uproject files in: $ProjectRoot"
		Exit 1
	}

	return $Result
}

function Build-Project {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]
		$ProjectFile
	)

	$RunUATArgs = ''
	$RunUATArgs += " -project='${ProjectFile}' -configuration='${Configuration}' -targetplatform='${Platform}'"
	$RunUATArgs += " -build -target='${TargetName}'"
	$RunUATArgs += " -cook -unversionedcookedcontent -pak -compressed -package -iostore"

	if ($Prereqs -eq 'Installer') {
		$RunUATArgs += " -prereqs"	
	}
	elseif ($Prereqs -eq 'Local') {
		$RunUATArgs += " -applocaldirectory='${EngineRoot}/Engine/Binaries/ThirdParty/AppLocalDependencies'"	
	}

	$RunUATArgs += " -stage -archive -archivedirectory='${ArchiveRoot}'"
	$RunUATArgs += " -utf8output -buildmachine -unattended -noP4 -nosplash -stdout"

	# Clear the output directory before building
	if (Test-Path -Path $OutputDir) {
		Remove-Item -Recurse $OutputDir
	}

	Write-Host "----------------------------------------"
	Write-Host "Building target ${TargetName} in ${Configuration} configuration`n"
	Invoke-Expression "& '${EngineRoot}/Engine/Build/BatchFiles/RunUAT.bat' BuildCookRun ${RunUATArgs}"
}

function Publish-To-Itch {
	$ButlerArgs = ''

	# Use custom butler credentials if specified
	if ($ItchCredentialsPath) {
		$ButlerArgs += " --identity=${ItchCredentialsPath}"
	}
	
	# Ignore debugging symbols to reduce build size
	if ($Platform -eq 'Win64') {
		$ButlerArgs += " --ignore '*.pdb'"
	}
	elseif ($Platform -eq 'Linux') {
		$ButlerArgs += " --ignore '*.sym' --ignore '*.debug'"
	}

	# Default ignores
	$ButlerArgs += " --ignore 'StagedBuild_*.ini' --ignore 'Manifest_*.txt'"

	Write-Host "`n`n----------------------------------------"
	Write-Host "Uploading to itch.io at ${ItchUsername}/${ItchGame}:${ItchChannel}`n"
	Invoke-Expression "& butler push ${ButlerArgs} '${OutputDir}' '${ItchUsername}/${ItchGame}:${ItchChannel}'"
}

# Move to the project folder in case some paths are relative to it
Push-Location $ProjectRoot

Build-Project $(Find-UProject)

if ($PublishToItch) {
	Publish-To-Itch
}

# Return to original location
Pop-Location
