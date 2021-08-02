#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Updates the BIOS on Dell Computers
.DESCRIPTION
    Checks the Dell catalog for BIOS updates. Will download and install updated BIOS package if needed.
.EXAMPLE
    PS C:\> Update-DellBIOS.ps1
    This script does not take any arguments. Defualt usage is to call script by name. Doing so will check for new BIOS version and install if an update is found.  
.OUTPUTS
    Outputs status info to host window
.NOTES
    May not work for all Dell computers. Venue tablet is unlikely to update successfully using this script. 
#>

# Functions
function Get-SystemId 
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [CimInstance]
        $SystemInfo
    )
    $_oemStringArray = $SystemInfo.OEMStringArray
    $_systemId = $_oemStringArray[1].Substring($_oemStringArray[1].IndexOf('[') + 1, $_oemStringArray[1].IndexOf(']') - 2)
    return $_systemId
}

function Get-ModelNumber
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $FullModelString
    )
    $matchCondition = "[A-Z]?[0-9]{4}[a-zA-Z]?"
    $compModel = Select-String -Pattern $matchCondition -InputObject $FullModelString
    return $compModel.Matches.Value
}

function DownloadFile 
{
    param([string]$URI, [string]$DownloadLocation)
    $_webClient = New-Object System.Net.WebClient
    try
    {
        $_webClient.DownloadFile($URI, $DownloadLocation)
    }
    catch
    {
        throw "Failed to download the file."
    }
    finally
    {
        $_webClient.Dispose()
    }
}

function Convert-BiosVersionStringToNumber 
{
    param (
        [string]$BiosVersionString
    )
    if(!$BiosVersionString.Contains(".") -and $BiosVersionString.Length -eq 3)
    {
        $BiosVersionString = $BiosVersionString.Replace("A", "").Insert(1, ".") 
    }
    try 
    {
        $version = [version]$BiosVersionString
    }
    catch 
    {
        Write-Host "Could not convert version string to version object." -ForegroundColor Red -BackgroundColor Black
    }
    
    return $version
}

# Global variables
$dellDownloadsUrl = "http://downloads.dell.com/catalog/"
$dellDownloadsBaseUrl = "http://downloads.dell.com/"
$downloadPath = $env:TEMP
$cimBiosElement = Get-CimInstance -ClassName CIM_BIOSElement
$cimComputerSystem = Get-CimInstance -ClassName CIM_ComputerSystem
$model = $cimComputerSystem.Model
$biosVersion = $cimBiosElement.SMBIOSBIOSVersion
$skuNumber = $cimComputerSystem.SystemSKUNumber
if ($null -eq $skuNumber) { # If SystemSKUNumber has no value fall back to OEMStringArray
    $systemId = Get-SystemId -SystemInfo $cimComputerSystem
}
else {
    $systemId = $skuNumber
}
$catalogFile = "CatalogIndexPC.cab"

# Main logic

# Download CatalogIndexPC.cab
$url = "$dellDownloadsUrl\$catalogFile"
$filePath = Join-Path -Path $downloadPath -ChildPath $catalogFile
DownloadFile -URI $url -DownloadLocation $filePath

# Expand CatalogIndexPC.cab
$xmlFileName = $catalogFile.Replace(".cab", ".xml")
$extractTo = Join-Path -Path $downloadPath -ChildPath $xmlFileName
expand.exe $filePath -F:$xmlFileName $extractTo

# Parse CatalogIndexPC.xml for a system ID that matches the running system
[xml]$catalogIndexPC = Get-Content -Path $extractTo
$groupManifests = $catalogIndexPC.ManifestIndex.GroupManifest
$modelCatalog = $groupManifests | Where-Object -FilterScript { $PSItem.SupportedSystems.Brand.Model.systemID -eq $systemId }
$modelCabPath = $modelCatalog.ManifestInformation.path

# If no model cab path is returned, assume the model is not listed in the xml, else continue to process the code
if($null -eq $modelCabPath)
{
    Write-Host -ForegroundColor Red -BackgroundColor Black "This computer model is not supported. The system ID, $systemId, could not be found in the XML."
    Pause
}
else
{
    # Download the cab file that corresponds to the system ID
    $cabFile = Split-Path -Path $modelCabPath -Leaf
    $cabUrl = "$dellDownloadsBaseUrl$modelCabPath"
    $cabFilePath = Join-Path -Path $downloadPath -ChildPath $cabFile
    DownloadFile -URI $cabUrl -DownloadLocation $cabFilePath

    # Expand the downloaded cab file
    $modelXmlFileName = $cabFile.Replace(".cab", ".xml")
    $extractToPath = Join-Path -Path $downloadPath -ChildPath $modelXmlFileName
    expand.exe $cabFilePath -F:$modelXmlFileName $extractToPath

    # Parse the xml file to find the latest BIOS package.
    [xml]$modelXmlFile = Get-Content -Path $extractToPath
    $softwareComponents = $modelXmlFile.Manifest.SoftwareComponent
    $modelNumber = Get-ModelNumber -FullModelString $model
    $biosPackages = $softwareComponents | 
        Where-Object -FilterScript { $PSItem.ComponentType.value -eq "BIOS" -and $($PSItem.SupportedDevices.Device.Display.'#cdata-section').Contains($modelNumber) }
    if($null = $biosPackages) # Fallback in case there is something goofy like 7X90 in SupportedDevices
    {
        $biosPackages = $softwareComponents | 
            Where-Object -FilterScript { $PSItem.ComponentType.value -eq "BIOS" -and $($PSItem.SupportedSystems.Brand.Model.Display.'#cdata-section').Contains($modelNumber) }
    }
    $biosPackage = $biosPackages[$biosPackages.Length - 1]

    # Check if the BIOS version in the xml is newer than the version installed on the computer.
    $biosVersionObject = Convert-BiosVersionStringToNumber -BiosVersionString $biosVersion
    $xmlVersionObject = Convert-BiosVersionStringToNumber -BiosVersionString $biosPackage.dellVersion

    if($($biosVersionObject.CompareTo($xmlVersionObject)) -ge 0) 
    {
        Write-Host "The BIOS is already the latest version, nothing to do." -ForegroundColor Green -BackgroundColor Black
        Pause
    }
    else 
    {
        # Download the BIOS Package
        $biosFileUrl = "$dellDownloadsBaseUrl$($biosPackage.path)"
        $biosFileName = Split-Path -Path $biosPackage.path -Leaf
        $biosFilePath = Join-Path -Path $downloadPath -ChildPath $biosFileName
        DownloadFile -URI $biosFileUrl -DownloadLocation $biosFilePath

        # Run the BIOS Package as admin.
        $flags = "/s /r" # Silent, Restart
        Start-Process -FilePath $biosFilePath -ArgumentList $flags -Verb runAs
    }    
}

