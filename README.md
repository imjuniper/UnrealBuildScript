# UnrealBuildScript
Small build script for UE project that can also upload to itch.io

- [Usage](#usage)
	- [Building](#building)
		- [Parameters](#parameters)
	- [Uploading to itch.io](#uploading-to-itchio)
		- [Parameters](#parameters-1)

## Usage

The easiest way to use the script is copying it in your project's directory, opening the terminal and running the following:

```pwsh
.\BuildProject.ps1
```

This will find the `.uproject` file in the script's directory, build the game in the `Development` configuration for the `Win64` platform, and output the build in the `$ProjectRoot/ArchivedBuilds`.

You can find all the command's parameters documented in the file, with `Get-Help .\BuildProject.ps1` or lower in this page.

### Building

#### Parameters

**`-ProjectRoot:<string>`**  
Where to find the `.uproject` file.  
**Default value**: The script's directory (or `$EngineRoot/$ProjectName` for native projects with a `-ProjectName` specified)

**`-ProjectName:<string>`**  
Name of the `.uproject` file to build.  
**Default value**: Will try to find a `.uproject` file in `$ProjectRoot` and will use it's filename.

**`-TargetName:<string>`**  
Name of the build target.  
**Default value**: `$ProjectName`

**`-TargetType:<string>`**  
Type of target that will get built. Only used to find the output directory.  
**Accepted values**: `Game`, `Client`, `Server`  
**Default value**: unset

**`-Configuration:<string>`**  
Target configuration. `Debug` and `Test` are only supported in source builds.  
**Accepted values**: `Debug`, `DebugGame`, `Development`, `Test`, `Shipping`  
**Default value**: `Development`

**`-Platform:<string>`**  
Platform to build and cook  
**Accepted values**: `Win64`, `Linux`  
**Default value**: `Win64`

**`-Prereqs:<string>`**  
If set, will bundle Unreal Engine prerequisites either as an installer or local DLLs.  
**Accepted values**: `Installer`, `Local`

**`-ArchiveRoot:<string>`**  
Where to output the build.  
**Default value**: `$ProjectRoot/ArchivedBuilds`

**`-TimestampedArchiveFolder`**  
If set, will output the builds to `$ArchiveRoot\$TargetName-$Configuration+yyyymmddThhmm` instead of just `$ArchiveRoot`.  
**Default value**: unset

**`-EngineVersion:<string>`**  
Unreal version that is used. Only used for launcher installs auto-root folder "detection".  
**Default value**: 5.6

**`-NativeProject`**  
Whether this is a native project. See [this article](https://dev.epicgames.com/community/learning/knowledge-base/eP9R/unreal-engine-what-s-a-native-project) for more information. If you don't know what this means, you probably don't need it!  
**Default value**: unset

**`-EngineRoot:<string>`**  
Path to Unreal Engine.  
**Default value**: `C:/Program Files/Epic Games/UE_$EngineVersion` (or `$ProjectRoot/..` for native projects)

### Uploading to itch.io

> [!WARNING]
> Currently, the tool requires the [`butler`](https://itchio.itch.io/butler) tool to be available in your `$PATH`, but I am planning on adding an auto-download.

To upload a build in the **Shipping** configuration, to the channel `windows`, run the following command:

```pwsh
.\BuildProject.ps1 -Configuration:Shipping -PublishToItch -ItchUsername:ITCH_USERNAME -ItchGame:ITCH_GAME
```
> [!TIP]
> For game jams, you will probably want to add `-Prereqs:Local` so that the Visual C++ and other dependencies' DLLs are copied alongside the game's exe. You can also use `-Prereqs:Installer` to bundle the installer instead.

> [!IMPORTANT]
> By default, the script will block you from uploading non-Shipping builds to itch.io, to prevent mistakes. You can add the `-AllowPublishNonShipping` parameter to override that behaviour.

See [itch.io's documentation](https://itch.io/docs/butler/pushing.html) for more info about channel names and the pushing process.

#### Parameters

**`-PublishToItch`**  
Whether to upload the game to itch using butler. See the [butler docs](https://itch.io/docs/butler/) to learn about the upload process.  
**Default value**: unset

**`-AllowPublishNonShipping`**  
Enables uploading of non-shipping games.  
**Default value**: unset

**`-ItchUsername:<string>`**  
Username under which the game is hosted. See the [butler docs](https://itch.io/docs/butler/pushing.html) for more info.  
**Required if `-PublishToItch` is set**  
**Default value**: none

**`-ItchGame:<string>`**  
Name of the game being uploaded. See the [butler docs](https://itch.io/docs/butler/pushing.html) for more info.  
**Required if `-PublishToItch` is set**  
**Default value**: none

**`-ItchChannel:<string>`**  
Name of the channel where it should upload. See the [butler docs](https://itch.io/docs/butler/pushing.html) for more info.  
**Default value**: `windows` for the `Win64` platform and `linux` for the `Linux` platform.

**`-ItchCredentialsPath:<string>`**  
If set, will use a custom credentials file. Useful if you need multiple users. See the [butler docs](https://itch.io/docs/butler/login.html) for more info.  
**Default value**: unset
