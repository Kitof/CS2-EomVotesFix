# CS2 Workshop Thumbnails Fix - Refactored Version
# Improved structure, error handling, and performance optimizations

param(
    [Parameter(Position = 0)]
    [string]$CollectionID,
    
    [Parameter()]
    [switch]$SkipOfficialMaps,
    
    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$WorkingDir
)

# Configuration
$Script:Config = @{
    ThumbnailSize = @{ Width = 640; Height = 360 }
    PrefixPriority = @("de_", "aim_", "cs_", "ar_")
    ExcludedSuffixes = @("skybox", "lighting", "props", "instances", "nav", "radar")
    RetryCount = 3
    SteamAPIUrl = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
    SteamCMDUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
    CSGOCollectionFootprint = '<span class="breadcrumb_separator">&gt;&nbsp;</span><a data-panel="{&quot;noFocusRing&quot;:true}" href="https://steamcommunity.com/workshop/browse/?section=collections&appid=730">'
    
    # GitHub Release Tools Configuration
    GitHubTools = @{
        Source2Viewer = @{
            Repository = "ValveResourceFormat/ValveResourceFormat"
            AssetPattern = "cli-windows-x64.zip"
            InstallSubDir = "ValveResourceFormat"
            ExecutableName = "Source2Viewer-CLI.exe"
            ToolName = "Source2Viewer-CLI"
        }
        VPKEdit = @{
            Repository = "craftablescience/VPKEdit"
            AssetPattern = "VPKEdit-Windows-Standalone-CLI-msvc-Release.zip"
            InstallSubDir = "vpkedit"
            ExecutableName = "vpkeditcli.exe"
            ToolName = "VPKEdit-CLI"
        }
    }
}

# Global variables
$Script:WorkingDir = if ($WorkingDir) { $WorkingDir } else { Get-Location }
$Script:LibPath = Join-Path $Script:WorkingDir "lib"
$Script:TemplatesPath = Join-Path $Script:WorkingDir "templates"
$Script:BuildPath = Join-Path $Script:WorkingDir "build"
$Script:MapsJsonPath = Join-Path $Script:WorkingDir "bin\maps.json"
$Script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

#region Utility Functions

function Write-ColoredMessage {
    param(
        [string]$Message,
        [string]$Color = "White",
        [string]$Prefix = ""
    )
    
    if ($Prefix) {
        Write-Host "$Prefix " -NoNewline
    }
    Write-Host $Message -ForegroundColor $Color
}

function Write-SuccessMessage {
    param([string]$Message)
    Write-ColoredMessage $Message "Green"
}

function Write-WarningMessage {
    param([string]$Message)
    Write-ColoredMessage $Message "Yellow"
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-ColoredMessage $Message "Red"
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = $Script:Config.RetryCount,
        [int]$DelaySeconds = 1
    )
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($i -eq $MaxRetries) {
                throw
            }
            Write-WarningMessage "Attempt $i failed, retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function New-DirectoryIfNotExists {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-DirectoryIfExists {
    param([string]$Path)
    
    if (Test-Path $Path) {
        Remove-Item $Path -Force -Recurse
    }
}

#endregion

#region Validation Functions

function Get-ValidatedCollectionID {
    param([string]$InputID)
    
    if ([string]::IsNullOrWhiteSpace($InputID)) {
        $InputID = Read-Host "Enter the Steam Workshop Collection ID"
    }
    
    if ($InputID -notmatch '^\d+$') {
        throw "Invalid collection ID format."
    }
    
    return $InputID
}

function Test-CS2Collection {
    param([string]$CollectionID)
    
    $collectionURL = "https://steamcommunity.com/sharedfiles/filedetails/?id=$CollectionID"
    
    try {
        $response = Invoke-WebRequest -Uri $collectionURL -UseBasicParsing
        if ($response.Content -notmatch [Regex]::Escape($Script:Config.CSGOCollectionFootprint)) {
            throw "The provided ID does not match a CS2 collection."
        }
        Write-SuccessMessage "Validated CS2 Workshop collection: $collectionURL"
        return $collectionURL
    }
    catch {
        throw "Failed to validate collection: $($_.Exception.Message)"
    }
}

#endregion

#region Prerequisites Functions

function Install-PowerShellPrerequisites {
    Write-Host "`nInstalling PowerShell prerequisites..."
    
    try {
        Install-PackageProvider -Name NuGet -Confirm:$false -Force | Out-Null
        
        if (-not (Get-InstalledModule -Name PowerHTML -ErrorAction SilentlyContinue)) {
            Install-Module -Name PowerHTML -Confirm:$false -Force | Out-Null
        }
        
        Add-Type -AssemblyName System.Drawing
        Import-Module PowerHTML
        
        Write-SuccessMessage "PowerShell dependencies installed"
    }
    catch {
        throw "Failed to install PowerShell prerequisites: $($_.Exception.Message)"
    }
}

function Find-CS2Installation {
    Write-Host "Locating CS2 installation..."
    
    # Try registry first
    $csgoInstallDir = $null
    if (Test-Path "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App 730") {
        $csgoInstallDir = (Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App 730").InstallLocation
    }
    
    # Fallback to Steam library folders
    if (-not $csgoInstallDir) {
        $csgoInstallDir = Find-CS2InSteamLibraries
    }
    
    if (-not $csgoInstallDir) {
        throw "Unable to locate CS2 installation."
    }
    
    Write-SuccessMessage "CS2 installation detected at $csgoInstallDir"
    return $csgoInstallDir
}

function Find-CS2InSteamLibraries {
    try {
        $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam").SteamPath
        $pathsFile = Join-Path $steamPath "steamapps\libraryfolders.vdf"
        
        if (-not (Test-Path -Path $pathsFile -PathType Leaf)) {
            return $null
        }
        
        $libraries = @($steamPath)
        $pathVDF = Get-Content -Path $pathsFile
        $pathRegex = [Regex]::new('"(([^"]*):\\([^"]*))"')
        
        foreach ($line in $pathVDF) {
            if ($pathRegex.IsMatch($line)) {
                $match = $pathRegex.Matches($line)[0].Groups[1].Value
                $libraries += $match.Replace('\\', '\')
            }
        }
        
        foreach ($lib in $libraries) {
            $csgoPath = Join-Path $lib "steamapps\common\Counter-Strike Global Offensive"
            Write-Host "[Debug] $csgoPath"
            if (Test-Path (Join-Path $csgoPath "game")) {
                return $csgoPath
            }
        }
        
        return $null
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $null
    }
}

function Install-SteamCMD {
    param([string]$InstallPath)
    
    Write-Host "Installing SteamCMD..."
    $steamcmdPath = Join-Path $InstallPath "steamcmd"
    $steamcmdExe = Join-Path $steamcmdPath "steamcmd.exe"
    
    if (Test-Path $steamcmdExe) {
        Write-SuccessMessage "SteamCMD already installed at $steamcmdPath"
        return $steamcmdExe
    }
    
    try {
        New-DirectoryIfNotExists $steamcmdPath
        
        $tempZip = Join-Path $env:TEMP "steamcmd.zip"
        Invoke-WebRequest -Uri $Script:Config.SteamCMDUrl -OutFile $tempZip
        Expand-Archive $tempZip -DestinationPath $steamcmdPath -Force
        Remove-Item $tempZip -Force
        
        Write-SuccessMessage "SteamCMD installed at $steamcmdPath"
        return $steamcmdExe
    }
    catch {
        throw "Failed to install SteamCMD: $($_.Exception.Message)"
    }
}

function Test-WorkshopTools {
    param([string]$CS2InstallDir)
    
    Write-Host "Checking Workshop Tools..."
    $compilerPath = Join-Path $CS2InstallDir "game\bin\win64\resourcecompiler.exe"
    
    if (-not (Test-Path $compilerPath)) {
        throw @"
Workshop Tools not detected. Please install CS2 Workshop Tools.
Link: https://developer.valvesoftware.com/wiki/Counter-Strike_2_Workshop_Tools/Installing_and_Launching_Tools
"@
    }
    
    Write-SuccessMessage "CS2 Workshop Tools detected"
    return $compilerPath
}

function Install-GitHubRelease {
    param(
        [string]$Repository,
        [string]$AssetPattern,
        [string]$InstallDir,
        [string]$ExecutableName,
        [string]$ToolName
    )
    
    $exe = Get-ChildItem -Path $InstallDir -Filter $ExecutableName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if ($exe) {
        Write-SuccessMessage "$ToolName detected at $($exe.FullName)"
        return $exe.FullName
    }
    
    Write-Host "Installing $ToolName..."
    
    try {
        New-DirectoryIfNotExists $InstallDir
        
        $releaseInfo = Invoke-RestMethod "https://api.github.com/repos/$Repository/releases/latest"
        $asset = $releaseInfo.assets | Where-Object { $_.name -like "*$AssetPattern*" }
        
        if (-not $asset) {
            throw "Unable to find asset matching pattern: $AssetPattern"
        }
        
        $tempZip = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZip
        Expand-Archive -Path $tempZip -DestinationPath $InstallDir -Force
        Remove-Item $tempZip -Force
        
        $exe = Get-ChildItem -Path $InstallDir -Filter $ExecutableName -Recurse | Select-Object -First 1
        
        if (-not $exe) {
            throw "Executable not found after installation"
        }
        
        Write-SuccessMessage "$ToolName installed at $($exe.FullName)"
        return $exe.FullName
    }
    catch {
        throw "Failed to install $ToolName : $($_.Exception.Message)"
    }
}

function Install-Prerequisites {
    param([string]$CS2InstallDir)
    
    Write-Host "`nChecking and installing prerequisites..."
    
    Install-PowerShellPrerequisites
    
    New-DirectoryIfNotExists $Script:LibPath
    
    $steamcmdExe = Install-SteamCMD $Script:LibPath
    $compilerPath = Test-WorkshopTools $CS2InstallDir
    
    # Install GitHub tools using configuration
    $tools = @{}
    
    foreach ($toolKey in $Script:Config.GitHubTools.Keys) {
        $toolConfig = $Script:Config.GitHubTools[$toolKey]
        $installDir = Join-Path $Script:LibPath $toolConfig.InstallSubDir
        
        $toolPath = Install-GitHubRelease -Repository $toolConfig.Repository -AssetPattern $toolConfig.AssetPattern -InstallDir $installDir -ExecutableName $toolConfig.ExecutableName -ToolName $toolConfig.ToolName
        
        $tools[$toolKey] = $toolPath
    }
    
    return @{
        SteamCMD = $steamcmdExe
        Compiler = $compilerPath
        Source2Viewer = $tools.Source2Viewer
        VPKEdit = $tools.VPKEdit
    }
}

#endregion

#region Map Processing Functions

function Get-MapInfoFromCollection {
    param(
        [string]$CollectionURL,
        [string]$SteamCMDPath,
        [string]$Source2ViewerPath
    )
    
    Write-Host "`nRetrieving map information from collection..."
    
    try {
        try {
            $ie = New-Object -ComObject "InternetExplorer.Application"
        } catch {
            throw "Failed to initiate headless browser. It's happen sometimes, you need to reboot."
        }

        $ie.Visible = $false
        $ie.Navigate($CollectionURL)
        while ($ie.Busy -eq $true -or $ie.ReadyState -ne 4) {
            Start-Sleep -Milliseconds 500
        }
        $document = $ie.Document
        $cards = $document.getElementsByTagName('div') | Where-Object { $_.className -eq 'workshopItem' }

        $mapList = @()
        $totalItems = $cards.Count
        $currentItem = 0
        
        foreach ($card in $cards) {
            $currentItem++
            $link = $card.getElementsByTagName('a') | Select-Object -First 1
            if ((-not $link) -or (-not $link.href -like '*steamcommunity.com/sharedfiles/filedetails/?id=*')) {
                continue
            }
            $id = $link.href.Split('=')[1]
            
            Write-Progress -Activity "Processing Maps" -Status "Map $currentItem of $totalItems (ID: $id)" -PercentComplete (($currentItem / $totalItems) * 100)
            Write-Host "`nProcessing map [$id]"
            
            # Check if map is incompatible (CSGO map)

            $incompatible = $card.getElementsByClassName('incompatible')
            if ($incompatible.length -gt 0) {
                Write-WarningMessage "[$id] is a CSGO map. Ignoring."
                continue
            }
            Write-SuccessMessage "[$id] is a CS2 map. Processing..."
            
            try {
                $mapEntry = Get-MapDetails -MapID $id -SteamCMDPath $SteamCMDPath -Source2ViewerPath $Source2ViewerPath
                if ($mapEntry) {
                    $mapList += $mapEntry
                }
            }
            catch {
                Write-ErrorMessage "[$id] Failed to process: $($_.Exception.Message)"
                continue
            }
        }
        
        Write-Progress -Activity "Processing Maps" -Completed
        
        if ($mapList.Count -eq 0) {
            throw "No valid maps found in the collection."
        }
        
        Write-SuccessMessage "Retrieved $($mapList.Count) map(s) from workshop collection."
        return $mapList
    }
    catch {
        throw "Failed to retrieve map information: $($_.Exception.Message)"
    }
}

function Get-MapDetails {
    param(
        [string]$MapID,
        [string]$SteamCMDPath,
        [string]$Source2ViewerPath
    )
    
    # Get map details from Steam API
    $params = "itemcount=1&publishedfileids[0]=$MapID"
    $response = Invoke-WebRequest -Uri $Script:Config.SteamAPIUrl -Method POST -Body $params
    $json = $response.Content | ConvertFrom-Json
    $file = $json.response.publishedfiledetails[0]
    
    $mapName = $null
    
    if ($file.filename) {
        $mapName = [System.IO.Path]::GetFileNameWithoutExtension($file.filename)
        Write-SuccessMessage "[$MapID] Map name from API: $mapName"
    }
    else {
        $mapName = Get-MapNameFromCache -MapID $MapID
        
        if (-not $mapName) {
            $mapName = Get-MapNameFromVPK -MapID $MapID -SteamCMDPath $SteamCMDPath -Source2ViewerPath $Source2ViewerPath
            Set-MapNameInCache -MapID $MapID -MapName $mapName
        }
    }
    
    if (-not $mapName) {
        throw "Unable to determine map name for ID $MapID"
    }
    
    # Generate friendly title
    $friendlyTitle = Get-FriendlyMapTitle -MapName $mapName -OriginalTitle $file.title
    
    return [PSCustomObject]@{
        ID = $MapID
        Title = $friendlyTitle
        MapName = $mapName
        Filename = "$mapName.vpk"
        Thumbnail = $file.preview_url
    }
}

function Get-MapNameFromCache {
    param([string]$MapID)
    
    if (Test-Path $Script:MapsJsonPath) {
        try {
            $maps = Get-Content $Script:MapsJsonPath -Raw | ConvertFrom-Json
            if ($maps.PSObject.Properties.Name -contains $MapID) {
                Write-SuccessMessage "[$MapID] Map name from cache: $($maps.$MapID)"
                return $maps.$MapID
            }
        }
        catch {
            Write-WarningMessage "Failed to read maps cache"
        }
    }
    
    return $null
}

function Set-MapNameInCache {
    param(
        [string]$MapID,
        [string]$MapName
    )
    
    try {
        $maps = @{}
        if (Test-Path $Script:MapsJsonPath) {
            $maps = Get-Content $Script:MapsJsonPath -Raw | ConvertFrom-Json
        }
        
        $maps | Add-Member -MemberType NoteProperty -Name $MapID -Value $MapName -Force
        $jsonOut = $maps | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($Script:MapsJsonPath, $jsonOut, $Script:Utf8NoBom)
    }
    catch {
        Write-WarningMessage "Failed to save map name to cache"
    }
}

function Get-MapNameFromVPK {
    param(
        [string]$MapID,
        [string]$SteamCMDPath,
        [string]$Source2ViewerPath
    )
    
    Write-Host "        [$MapID] Downloading VPK to extract map name..."
    
    try {
        # Download VPK
        $downloadArgs = @("+login", "anonymous", "+workshop_download_item", "730", $MapID, "+quit")
        $process = Start-Process -FilePath $SteamCMDPath -ArgumentList $downloadArgs -NoNewWindow -Wait -PassThru
        
        if ($process.ExitCode -ne 0) {
            throw "SteamCMD download failed with exit code $($process.ExitCode)"
        }
        
        $vpkDir = Join-Path (Split-Path $SteamCMDPath) "steamapps/workshop/content/730/$MapID"
        $vpkFiles = Get-ChildItem -Path $vpkDir -Filter "*.vpk" -ErrorAction SilentlyContinue
        
        if ($vpkFiles.Count -eq 0) {
            throw "No VPK files found in $vpkDir"
        }
        
        # Prefer _dir.vpk files, otherwise largest file
        $vpkFile = $vpkFiles | Where-Object { $_.Name -like "*_dir.vpk" } | Select-Object -First 1
        if (-not $vpkFile) {
            $vpkFile = $vpkFiles | Sort-Object Length -Descending | Select-Object -First 1
        }
        
        # Extract map name from VPK contents
        $output = & $Source2ViewerPath -i $vpkFile.FullName --vpk_dir
        $mapName = Get-MapNameFromVPKOutput -Output $output
        
        # Cleanup
        Remove-Item $vpkDir -Force -Recurse -ErrorAction SilentlyContinue
        
        Write-SuccessMessage "[$MapID] Map name from VPK: $mapName"
        return $mapName
    }
    catch {
        throw "Failed to extract map name from VPK: $($_.Exception.Message)"
    }
}

function Get-MapNameFromVPKOutput {
    param([string[]]$Output)
    
    $paths = $Output | ForEach-Object { $_.Split()[0] }
    $mapPaths = $paths | Where-Object { $_ -match '^maps/.*\.vpk$' -and $_ -notmatch '_skybox\.vpk$' }
    $names = $mapPaths | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Split()[0]) }
    
    # Try to find map with priority prefixes
    foreach ($prefix in $Script:Config.PrefixPriority) {
        $match = $names | Where-Object { $_ -like "$prefix*" } | Sort-Object Length | Select-Object -First 1
        if ($match) {
            return $match
        }
    }
    
    # Fallback to any map with underscore
    $underscoreMap = $names | Where-Object { $_ -like "*_*" } | Sort-Object Length | Select-Object -First 1
    if ($underscoreMap) {
        return $underscoreMap
    }
    
    # Final fallback
    return $names | Sort-Object Length | Select-Object -First 1
}

function Get-FriendlyMapTitle {
    param(
        [string]$MapName,
        [string]$OriginalTitle
    )
    
    if (-not [string]::IsNullOrWhiteSpace($OriginalTitle)) {
        $cleanTitle = Get-CleanTitleFromOriginal -OriginalTitle $OriginalTitle
        
        if (-not [string]::IsNullOrWhiteSpace($cleanTitle)) {
            return $cleanTitle
        }
    }
    
    $segments = $MapName -split "_"
    if ($segments.Count -ge 2) {
        $rootName = $segments[1]
        if ($rootName -in $Script:Config.ExcludedSuffixes) {
            $rootName = $segments[0]
        }
        return $rootName.Substring(0,1).ToUpper() + $rootName.Substring(1)
    }
    
    return $MapName.Substring(0,1).ToUpper() + $MapName.Substring(1)
}

function Get-CleanTitleFromOriginal {
    param([string]$OriginalTitle)
    
    $beforeParenthesis = $OriginalTitle
    $parenthesisIndex = $OriginalTitle.IndexOf('(')
    
    if ($parenthesisIndex -gt 0) {
        $beforeParenthesis = $OriginalTitle.Substring(0, $parenthesisIndex)
    }
    
    $cleanTitle = $beforeParenthesis.Trim()
    if ($cleanTitle -cnotmatch '[A-Z]') {
        return ""
    }
    $wordCount = ($cleanTitle -split '\s+').Count
    if ($wordCount -gt 3) {
        return ""
    }
    if ($cleanTitle.Length -gt 15) {
        return ""
    }
    return $cleanTitle
}
#endregion

#region Thumbnail Processing Functions

function Invoke-MapThumbnailProcessing {
    param(
        [array]$MapList,
        [string]$CollectionID,
        [string]$CS2InstallDir,
        [string]$CompilerPath
    )
    
    Write-Host "`nProcessing map thumbnails..."
    
    $addonsPath = Join-Path $CS2InstallDir "content\csgo_addons\workshop_thumbnails_$CollectionID"
    $materialsPath = Join-Path $addonsPath "materials\thumbnails"
    $thumbnailsPath = Join-Path $Script:WorkingDir "workshop_thumbnail_$CollectionID\panorama\images\map_icons\screenshots\360p"
    
    New-DirectoryIfNotExists $addonsPath
    New-DirectoryIfNotExists $materialsPath
    New-DirectoryIfNotExists $thumbnailsPath
    
    $totalMaps = $MapList.Count
    $currentMap = 0
    
    foreach ($map in $MapList) {
        $currentMap++
        Write-Progress -Activity "Processing Thumbnails" -Status "Map $currentMap of $totalMaps ($($map.MapName))" -PercentComplete (($currentMap / $totalMaps) * 100)
        
        try {
            $success = Invoke-SingleThumbnailProcessing -Map $map -MaterialsPath $materialsPath -ThumbnailsPath $thumbnailsPath -CompilerPath $CompilerPath -CS2InstallDir $CS2InstallDir -CollectionID $CollectionID
            
            if ($success) {
                Write-SuccessMessage "[$($map.ID)-$($map.MapName)] Thumbnail processed successfully"
            }
        }
        catch {
            Write-ErrorMessage "[$($map.ID)-$($map.MapName)] Failed to process thumbnail: $($_.Exception.Message)"
        }
    }
    
    Write-Progress -Activity "Processing Thumbnails" -Completed
}

function Invoke-SingleThumbnailProcessing {
    param(
        [PSCustomObject]$Map,
        [string]$MaterialsPath,
        [string]$ThumbnailsPath,
        [string]$CompilerPath,
        [string]$CS2InstallDir,
        [string]$CollectionID
    )
    
    $pngPath = Join-Path $MaterialsPath "$($Map.MapName)_png.png"
    $vtexPath = Join-Path $MaterialsPath "$($Map.MapName)_png.vtex"
    $compiledPath = Join-Path $CS2InstallDir "game\csgo_addons\workshop_thumbnails_$CollectionID\materials\thumbnails\$($Map.MapName)_png.vtex_c"
    $finalPath = Join-Path $ThumbnailsPath "$($Map.MapName)_png.vtex_c"
    
    # Skip if already processed
    if ((Test-Path $finalPath) -and -not $Force) {
        Write-Host "        [$($Map.ID)-$($Map.MapName)] Thumbnail already exists, skipping"
        return $true
    }
        
    if (-not (Test-Path $compiledPath) -and -not $Force) {
        # Download and resize thumbnail
        if (-not (Test-Path $pngPath) -or $Force) {
            if (-not $Map.Thumbnail) {
                Write-WarningMessage "[$($Map.ID)-$($Map.MapName)] No thumbnail URL available"
                return $false
            }
            
            Get-ResizedThumbnail -Url $Map.Thumbnail -OutputPath $pngPath -Width $Script:Config.ThumbnailSize.Width -Height $Script:Config.ThumbnailSize.Height
        }
        
        # Create VTEX file
        New-VTEXFile -PngPath $pngPath -VtexPath $vtexPath -MaterialsPath $MaterialsPath
        
        # Compile VTEX to VTEX_C
        Invoke-VTEXCompilation -VtexPath $vtexPath -CompilerPath $CompilerPath -CS2InstallDir $CS2InstallDir
    } else {
        Write-Host "        [$($Map.ID)-$($Map.MapName)] Compiled Thumbnail already exists."
    }

    # Copy to final location
    if (Test-Path $compiledPath) {
        Copy-Item -Path $compiledPath -Destination $finalPath -Force
        return $true
    }
    
    return $false
}

function Get-ResizedThumbnail {
    param(
        [string]$Url,
        [string]$OutputPath,
        [int]$Width,
        [int]$Height
    )
    
    $image = $null
    $resizedImage = $null
    $imageStream = $null
    
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
        $imageBytes = $response.Content
        $imageStream = [IO.MemoryStream]::new($imageBytes)
        $image = [System.Drawing.Image]::FromStream($imageStream)
        
        $resizedImage = $image.GetThumbnailImage($Width, $Height, $null, [System.IntPtr]::Zero)
        $ms = [System.IO.MemoryStream]::new()
        $resizedImage.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        
        $ms.ToArray() | Set-Content -Path $OutputPath -Encoding Byte
    }
    catch {
        throw "Failed to download/resize thumbnail: $($_.Exception.Message)"
    }
    finally {
        if ($image) { $image.Dispose() }
        if ($resizedImage) { $resizedImage.Dispose() }
        if ($imageStream) { $imageStream.Dispose() }
    }
}

function New-VTEXFile {
    param(
        [string]$PngPath,
        [string]$VtexPath,
        [string]$MaterialsPath
    )
    
    $templatePath = Join-Path $Script:TemplatesPath "map_thumbnail.vtex.template"
    if (-not (Test-Path $templatePath)) {
        throw "VTEX template not found at $templatePath"
    }
    
    $relativePath = "materials/thumbnails/" + [System.IO.Path]::GetFileName($PngPath)
    $template = Get-Content $templatePath -Raw
    $vtexContent = $template -replace "{{PNG_FULL_NAME}}", $relativePath
    
    [System.IO.File]::WriteAllText($VtexPath, $vtexContent, $Script:Utf8NoBom)
}

function Invoke-VTEXCompilation {
    param(
        [string]$VtexPath,
        [string]$CompilerPath,
        [string]$CS2InstallDir
    )
    
    $compileArgs = @(
        "-game", "`"$(Join-Path $CS2InstallDir "game\csgo")`"",
        "-i", "`"$VtexPath`""
    )
    
    $process = Start-Process -FilePath $CompilerPath -ArgumentList $compileArgs -NoNewWindow -Wait -PassThru
    
    if ($process.ExitCode -ne 0) {
        throw "VTEX compilation failed with exit code $($process.ExitCode)"
    }
}

#endregion

#region VPK Creation Functions

function New-CustomVPK {
    param(
        [array]$MapList,
        [string]$CollectionID,
        [string]$CS2InstallDir,
        [string]$Source2ViewerPath,
        [string]$VPKEditPath,
        [bool]$IncludeOfficialMaps
    )
    
    Write-Host "`nCreating custom VPK..."
    
    $customPakPath = Join-Path $Script:WorkingDir "workshop_thumbnail_$CollectionID"
    Remove-DirectoryIfExists $customPakPath
    New-DirectoryIfNotExists $customPakPath
    
    # Create directory structure
    $thumbnailsPath = Join-Path $customPakPath "panorama\images\map_icons\screenshots\360p"
    New-DirectoryIfNotExists $thumbnailsPath
    
    # Copy compiled thumbnails
    Copy-CompiledThumbnails -MapList $MapList -CollectionID $CollectionID -CS2InstallDir $CS2InstallDir -ThumbnailsPath $thumbnailsPath
    
    # Modify game files
    Update-GamemodesFile -MapList $MapList -CustomPakPath $customPakPath -CS2InstallDir $CS2InstallDir -Source2ViewerPath $Source2ViewerPath
    Update-LanguageFiles -MapList $MapList -CustomPakPath $customPakPath -CS2InstallDir $CS2InstallDir -Source2ViewerPath $Source2ViewerPath
    
    # Create final VPK
    $clientPath = Join-Path $Script:BuildPath "client"
    New-DirectoryIfNotExists $clientPath
    
    $vpkPath = Join-Path $clientPath "packages\workshop_thumbnails_$($CollectionID)_dir.vpk"
    
    $output = & $VPKEditPath $customPakPath -o $vpkPath
    
    if (-not (Test-Path $vpkPath)) {
        throw "Failed to create VPK file"
    }
    
    Write-SuccessMessage "Custom VPK created: $vpkPath"
    
    # Copy installation script
    Copy-InstallationScript -ClientPath $clientPath
    
    # Create server configuration
    New-ServerConfiguration -MapList $MapList -IncludeOfficialMaps $IncludeOfficialMaps -CS2InstallDir $CS2InstallDir
    
    # Cleanup
    Remove-DirectoryIfExists $customPakPath
    
    Write-SuccessMessage "Build completed successfully!"
}

function Copy-CompiledThumbnails {
    param(
        [array]$MapList,
        [string]$CollectionID,
        [string]$CS2InstallDir,
        [string]$ThumbnailsPath
    )
    
    $compiledDir = Join-Path $CS2InstallDir "game\csgo_addons\workshop_thumbnails_$CollectionID\materials\thumbnails"
    
    foreach ($map in $MapList) {
        $compiledFile = Join-Path $compiledDir "$($map.MapName)_png.vtex_c"
        if (Test-Path $compiledFile) {
            Copy-Item -Path $compiledFile -Destination $ThumbnailsPath -Force
        }
    }
}

function Update-GamemodesFile {
    param(
        [array]$MapList,
        [string]$CustomPakPath,
        [string]$CS2InstallDir,
        [string]$Source2ViewerPath
    )
    
    Write-Host "    Updating gamemodes.txt..."
    
    $pak01Path = Join-Path $CS2InstallDir "game\csgo\pak01_dir.vpk"
    $gamemodesPath = Join-Path $CustomPakPath "gamemodes.txt"
    
    # Extract gamemodes.txt
    $output = & $Source2ViewerPath -i $pak01Path --vpk_dir -f "gamemodes.txt" -o $CustomPakPath
    
    if (-not (Test-Path $gamemodesPath)) {
        throw "Failed to extract gamemodes.txt"
    }
    
    # Modify gamemodes.txt
    $lines = Get-Content $gamemodesPath -Encoding UTF8
    
    # Find maps block
    $startIndex = -1
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i].Trim() -eq '"maps"' -and $lines[$i + 1].Trim() -eq '{') {
            $startIndex = $i + 1
            break
        }
    }
    
    $endIndex = ($lines | Select-String '^\s*//\s*Classic Maps').LineNumber
    
    if (-not $startIndex -or -not $endIndex) {
        throw "Could not find map block boundaries in gamemodes.txt"
    }
    
    # Insert workshop maps
    $mapLines = $MapList | ForEach-Object { 
        "       `"$($_.MapName)`" {`"nameID`" `"#SFUI_Map_$($_.MapName)`"}" 
    }
    
    $updatedLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $updatedLines += $lines[$i]
        if ($i -eq $endIndex - 2) {
            $updatedLines += $mapLines
        }
    }
    
    [System.IO.File]::WriteAllLines($gamemodesPath, $updatedLines, $Script:Utf8NoBom)
    Write-SuccessMessage "gamemodes.txt updated"
}

function Update-LanguageFiles {
    param(
        [array]$MapList,
        [string]$CustomPakPath,
        [string]$CS2InstallDir,
        [string]$Source2ViewerPath
    )
    
    Write-Host "    Updating language files..."
    
    $pak01Path = Join-Path $CS2InstallDir "game\csgo\pak01_dir.vpk"
    
    # Extract language files
    $output = & $Source2ViewerPath -i $pak01Path -o $CustomPakPath -f "resource\csgo_" -e "txt"
    
    $langFiles = Join-Path $CustomPakPath "resource"
    if (-not (Test-Path $langFiles)) {
        throw "Failed to extract language files"
    }
    
    # Generate language entries
    $langLines = $MapList | ForEach-Object { 
        "      `"SFUI_Map_$($_.MapName)`" `"$($_.Title)`"" 
    }
    
    # Update all language files
    Get-ChildItem -Path $langFiles -Filter "csgo_*.txt" | ForEach-Object {
        $langFile = $_.FullName
        $lines = Get-Content $langFile -Encoding UTF8
        
        $result = $lines | Select-String "^\s*//\s*nice map names" | Select-Object -First 1
        
        if ($result) {
            $insertIndex = $result.LineNumber - 1
            $before = $lines[0..($insertIndex - 1)]
            $after = $lines[$insertIndex..($lines.Count - 1)]
            $newContent = $before + $langLines + $after
            
            [System.IO.File]::WriteAllText($langFile, ($newContent -join "`r`n"), $Script:Utf8NoBom)
            Write-SuccessMessage "Updated $($_.Name)"
        }
        else {
            Write-WarningMessage "Could not update $($_.Name) - marker not found"
        }
    }
}

function Copy-InstallationScript {
    param([string]$ClientPath)
    
    $templatePath = Join-Path $Script:TemplatesPath "install_workshop_thumbnails.ps1.template"
    New-DirectoryIfNotExists (Join-Path $ClientPath "bin")

    $destPath = Join-Path $ClientPath "bin/install_workshop_thumbnails.ps1"
    
    if (Test-Path $templatePath) {
        Copy-Item -Path $templatePath -Destination $destPath -Force
    }
    else {
        throw "Installation script install_workshop_thumbnails.ps1.template not found"
    }

    $installBatPath = Join-Path $Script:TemplatesPath "install.bat.template"
    $installBatPathDestPath = Join-Path $ClientPath "install.bat"
    
    if (Test-Path $installBatPath) {
        Copy-Item -Path $installBatPath -Destination $installBatPathDestPath -Force
    }
    else {
        throw "Installation script install.bat.template not found"
    }

    $uninstallBatPath = Join-Path $Script:TemplatesPath "uninstall.bat.template"
    $uninstallBatPathDestPath = Join-Path $ClientPath "uninstall.bat"
    
    if (Test-Path $uninstallBatPath) {
        Copy-Item -Path $uninstallBatPath -Destination $uninstallBatPathDestPath -Force
    }
    else {
        throw "Installation script uninstall.bat.template not found"
    }
    Write-SuccessMessage "Installation scripts copied"
}

function Get-OfficialMaps {
    param([string]$CS2InstallDir)
    
    $officialMapsPath = Join-Path $CS2InstallDir "game\csgo\maps"
    
    if (-not (Test-Path $officialMapsPath)) {
        return @()
    }
    
    $validMaps = Get-ChildItem -Path $officialMapsPath -Filter "*.vpk" | Where-Object {
        $mapName = $_.BaseName
        $hasValidPrefix = $false
        
        # Check if map has any of the priority prefixes
        foreach ($prefix in $Script:Config.PrefixPriority) {
            if ($mapName -like "$prefix*") {
                $hasValidPrefix = $true
                break
            }
        }
        
        # Include if has valid prefix and doesn't contain vanity
        return $hasValidPrefix -and $mapName -notmatch "_vanity"
    } | ForEach-Object { $_.BaseName }
    
    return $validMaps
}

function New-ServerConfiguration {
    param(
        [array]$MapList,
        [bool]$IncludeOfficialMaps,
        [string]$CS2InstallDir
    )
    
    Write-Host "    Creating server configuration..."
    
    $serverPath = Join-Path $Script:BuildPath "server"
    New-DirectoryIfNotExists $serverPath
    
    $templatePath = Join-Path $Script:TemplatesPath "gamemodes_server.txt.template"
    $serverConfigPath = Join-Path $serverPath "gamemodes_server.txt"
    
    if (-not (Test-Path $templatePath)) {
        Write-WarningMessage "Server configuration template not found"
        return
    }
    
    # Get workshop and official maps
    $workshopMaps = $MapList | ForEach-Object { '               "{0}"' -f $_.MapName }
    $officialMaps = @()
    
    if ($IncludeOfficialMaps) {
        $officialMaps = Get-OfficialMaps -CS2InstallDir $CS2InstallDir | ForEach-Object { '"{0}"' -f $_ }
        Write-Host "        Added $($officialMaps.Count) official maps"
    }
    
    # Create server configuration
    $lines = Get-Content $templatePath -Encoding UTF8
    $result = $lines | Select-String "^\s*//\s*INSERT HERE" | Select-Object -First 1
    
    if ($result) {
        $insertIndex = $result.LineNumber - 1
        $before = $lines[0..($insertIndex - 1)]
        $after = $lines[$insertIndex..($lines.Count - 1)]
        
        $allMaps = $officialMaps + $workshopMaps
        $newContent = ($before + $allMaps + $after) -join "`r`n"
        
        [System.IO.File]::WriteAllText($serverConfigPath, $newContent, $Script:Utf8NoBom)
        Write-SuccessMessage "Server configuration created"
    }
    else {
        Write-WarningMessage "Could not create server configuration - marker not found"
    }
}

#endregion

#region Main Functions

function Show-Summary {
    param(
        [string]$CollectionID,
        [array]$MapList,
        [bool]$IncludeOfficialMaps
    )
    
    Write-Host "FIX FOR CS2 WORKSHOP THUMBNAILS - SUMMARY" -ForegroundColor Cyan
    
    Write-Host "`nCollection ID: $CollectionID" -ForegroundColor White
    Write-Host "Workshop Maps: $($MapList.Count)" -ForegroundColor Green
    Write-Host "Official Maps: $(if ($IncludeOfficialMaps) { 'Included' } else { 'Excluded' })" -ForegroundColor $(if ($IncludeOfficialMaps) { 'Green' } else { 'Yellow' })
    
    Write-Host "`nWorkshop Maps Processed:" -ForegroundColor Yellow
    $MapList | ForEach-Object {
        Write-Host "  - $($_.MapName) - $($_.Title)" -ForegroundColor Gray
    }
    
    Write-Host "`nOutput Files:" -ForegroundColor Yellow
    Write-Host "  - Files to send to all players: build/client/*" -ForegroundColor Gray
    Write-Host "  - File to put to the dedicated Server game/csgo : build/server/gamemodes_server.txt" -ForegroundColor Gray

}

function Confirm-OfficialMapsInclusion {
    param([string]$CS2InstallDir)
    
    if ($SkipOfficialMaps) {
        return $false
    }
    
    $officialMaps = Get-OfficialMaps -CS2InstallDir $CS2InstallDir
    
    if ($officialMaps.Count -eq 0) {
        Write-WarningMessage "No official maps found"
        return $false
    }
    
    Write-Host "`nDetected $($officialMaps.Count) official maps:" -ForegroundColor Cyan
    $officialMaps | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    
    Write-Host "`nInclude official maps in server configuration? [Y/n]" -ForegroundColor Cyan -NoNewline
    $response = Read-Host
    
    return ([string]::IsNullOrWhiteSpace($response) -or $response.ToLower() -eq "y")
}

function Start-Main {
    try {
        Write-Host "CS2 Workshop Thumbnails Fix by @Kitof" -ForegroundColor Cyan
        
        if ($WorkingDir) {
            if (-not (Test-Path $WorkingDir)) {
                throw "Specified working directory does not exist: $WorkingDir"
            }
            
            $Script:WorkingDir = Resolve-Path $WorkingDir
            Write-Host "Using working directory: $Script:WorkingDir" -ForegroundColor Cyan
        }

        # Step 1: Validate input
        $validatedCollectionID = Get-ValidatedCollectionID -InputID $CollectionID
        $collectionURL = Test-CS2Collection -CollectionID $validatedCollectionID
        
        # Step 2: Find CS2 installation
        $cs2InstallDir = Find-CS2Installation
        
        # Step 3: Install prerequisites
        $tools = Install-Prerequisites -CS2InstallDir $cs2InstallDir
        
        # Step 4: Process maps
        $mapList = Get-MapInfoFromCollection -CollectionURL $collectionURL -SteamCMDPath $tools.SteamCMD -Source2ViewerPath $tools.Source2Viewer
        
        # Step 5: Process thumbnails
        Invoke-MapThumbnailProcessing -MapList $mapList -CollectionID $validatedCollectionID -CS2InstallDir $cs2InstallDir -CompilerPath $tools.Compiler
        
        # Step 6: Ask about official maps
        $includeOfficialMaps = Confirm-OfficialMapsInclusion -CS2InstallDir $cs2InstallDir
        
        # Step 7: Create VPK
        New-CustomVPK -MapList $mapList -CollectionID $validatedCollectionID -CS2InstallDir $cs2InstallDir -Source2ViewerPath $tools.Source2Viewer -VPKEditPath $tools.VPKEdit -IncludeOfficialMaps $includeOfficialMaps
        
        # Step 8: Show summary
        Show-Summary -CollectionID $validatedCollectionID -MapList $mapList -IncludeOfficialMaps $includeOfficialMaps
        
        Write-Host "`nScript completed successfully!" -ForegroundColor Green
    }
    catch {
        Write-Host "`nScript failed: $($_.Exception.Message)" -ForegroundColor Red
        
        if ($_.Exception.InnerException) {
            Write-Host "Inner exception: $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
        
        Write-Host "`nStack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
        
        exit 1
    }
}

#endregion

# Script execution
if ($MyInvocation.InvocationName -ne '.') {
    Start-Main
}