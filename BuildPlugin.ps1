[CmdletBinding()]
param (
	# Where to find the .uplugin file. Defaults to the current working directory
	[Parameter()]
	[System.IO.FileInfo]
	$PluginRoot,

	# Name of the .uplugin file to build. Tries to find one in the $PluginRoot
	# by default
	[Parameter()]
	[string]
	$PluginName,

	# Platforms to build and cook
	[Parameter()]
	[ValidateSet('Win64', 'Linux')]
	[string[]]
	$Platforms = 'Win64',

	# Where to output the build. Defaults to $PluginRoot/ArchivedBuilds.
	[Parameter()]
	[string]
	$ArchiveRoot,

	# If set, will output the builds to `$ArchiveRoot/$PluginName+yyyymmddThhmm`
	# instead of just `$ArchiveRoot`.
	[Parameter()]
	[switch]
	$TimestampedArchiveFolder,

	# Unreal version that is used. Only used for launcher installs auto-root
	# folder "detection". Defaults to 5.6
	[Parameter()]
	[string]
	$EngineVersion = '5.6',

	# Path to Unreal Engine. Defaults to C:/Program Files/Epic Games/UE_$EngineVersion
	[Parameter()]
	[string]
	$EngineRoot
)

# Set default engine root to default launcher install location using the version
if (-not $EngineRoot) {
	$EngineRoot = "C:/Program Files/Epic Games/UE_${EngineVersion}"
}

# Set default plugin root to current directory
if (-not $PluginRoot) {
	$PluginRoot = [System.IO.Path]::GetFullPath($PWD)
}
else {
	$PluginRoot = [System.IO.Path]::GetFullPath($PluginRoot, $PWD)
}

# Set default archive root and clear it
if (-not $ArchiveRoot) {
	$ArchiveRoot = "${PluginRoot}/ArchivedBuilds"
}
else {
	$ArchiveRoot = [System.IO.Path]::GetFullPath($ArchiveRoot, $PWD)
}

# Based on https://github.com/XistGG/UnrealXistTools/blob/main/UProjectFile.ps1
function Find-UPlugin {
	$Result = $null
	$FoundPlugins = Get-ChildItem -Path $PluginRoot -File `
	| Where-Object { $_.Extension -ieq '.uplugin' }

	if ($FoundPlugins.count -eq 1) {
		$Result = $FoundPlugins[0]
	}
	elseif ($FoundPlugins.count -gt 1) {
		# If we don't have a -PluginName param, error.
		# User needs to tell us explicitly.
		if (!$PluginName) {
			foreach ($UPluginFile in $FoundPlugins) {
				Write-Warning "Ambiguous .uplugin: $UPluginFile"
			}

			Write-Error "Cannot auto-select a .uplugin file in a directory with multiple .uplugin; You must specify the -PluginName parameter"
			Exit 1
		}

		foreach ($UPluginFile in $FoundPlugins) {
			if ($PluginName -ieq $PluginFile.BaseName) {
				$Result = $UPluginFile
			}
		}

		if (!$Result) {
			Write-Error "Could not find $PluginName.uplugin file in $PluginRoot; Please check your -PluginName parameter"
			Exit 1
		}
	}
	else {
		Write-Error "Not an Unreal Engine plugin directory; no .uplugin files in: $PluginRoot"
		Exit 1
	}

	return $Result
}

function Get-Plugin-Version {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[System.IO.FileInfo]
		$PluginFile
	)

	$UPlugin = Get-Content -Raw $UPluginFile | ConvertFrom-Json

	if (Get-Member -InputObject $UPlugin -Name "VersionName" -MemberType Properties) {
		return $UPlugin.VersionName
	}

	throw "Cannot build plugin $($UPluginFile.BaseName); $($UPluginFile.Name) does not have a VersionName property in it."
}

function Build-Plugin {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[System.IO.FileInfo]
		$UPluginFile
	)

	$PluginVersion = Get-Plugin-Version $UPluginFile

	$PackageDir = $ArchiveRoot
	$PackageDir += "/$($UPluginFile.BaseName)-v${PluginVersion}+${EngineVersion}"

	$RunUATArgs = New-Object System.Collections.Generic.List[System.String]
	$RunUATArgs.AddRange([System.String[]]("-plugin=${UPluginFile}", "-targetplatforms=$($Platforms -join '+')"))
	$RunUATArgs.Add("-package=${PackageDir}")
	$RunUATArgs.Add("-rocket")

	Write-Host "----------------------------------------"
	Write-Host "Building plugin $($UPluginFile.BaseName) for Unreal Engine ${EngineVersion} configuration`n"
	& $EngineRoot/Engine/Build/BatchFiles/RunUAT.bat BuildPlugin $RunUATArgs
}

# Move to the plugin folder in case some paths are relative to it
Push-Location $PluginRoot

try {
	Build-Plugin $(Find-UPlugin)
}
finally {
	Pop-Location
}
