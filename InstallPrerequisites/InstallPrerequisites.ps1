# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Install prerequisite tools
.DESCRIPTION
    This Powershell script is used to download and install prerequisite software dependencies for Protocol Test Framework.
.PARAMETER ConfigPath
    The ConfigPath is used to specify prerequisites configure file path, default value is ".\PrerequisitesConfig.xml".

.EXAMPLE
    C:\PS>.\InstallPrerequisites.ps1 -ConfigPath ".\PrerequisitesConfig.xml"
    The PS script will get all tools defined in PrerequisitesConfig.xml, then download and install these tools.
#>
Param
(
    [parameter(Mandatory=$false, ValueFromPipeline=$true, HelpMessage="The ConfigPath is used to specify prerequisites configure file path")]
    [String]$ConfigPath
)

if(-not $ConfigPath)
{
	Write-Host "Use the default value '.\PrerequisitesConfig.xml' as ConfigPath is not set"
	$ConfigPath = ".\PrerequisitesConfig.xml"
}

$Category = "PTF"

# Check if the required .NET framework version is installed on current machine
Function CheckIfNet47IsInstalled{
    $isInstalled = $false

    if(-not (Test-Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"))
    {
        return $false
    }
    else
    {
        try
        {
            $NetVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Version).Version

            if($NetVersion)
            {
                $majorVersion = [int]$NetVersion.Substring(0,1)
                if($majorVersion -gt 4)
                {
                    $isInstalled = $true
                }
                elseif ($majorVersion -eq 4)
                {
                    $minorVersion = [int]$NetVersion.Substring(2,3)
                    if ($minorVersion -ge 7)
                    {
                        $isInstalled = $true
                    }
                }
            }
        }
        catch
        {
            $isInstalled = $false
        }
    }
    return $isInstalled;
}

# Check if application is installed on current machine.
Function CheckIfAppInstalled{
    Param (
		[string]$AppName,	# Application Name
		[string]$Version,	# Application Version
		[bool]$Compatible	# Is support backward compatible
	)

    #check if the required software is installed on current machine
    if ([IntPtr]::Size -eq 4) {
        $regpath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    }
    else {
        $regpath = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
    }
	
    $app = Get-ItemProperty $regpath | .{process{if($_.DisplayName -and $_.UninstallString) { $_ } }} | Where-Object {$_.DisplayName -match $AppName} | Select DisplayName, DisplayVersion -First 1
    
    if($app){
		if($Compatible){
            return ([System.Version]$app.DisplayVersion -ge [System.Version]$Version);
		}else{
			return ([System.Version]$app.DisplayVersion -eq [System.Version]$Version);
		}
    }else{
		if($AppName -match "Microsoft Agents for Visual Studio"){
			#If Test Agent was not installed we also need check if Visual Studio installed.
			$app = Get-ItemProperty $regpath | .{process{if($_.DisplayName -and $_.UninstallString) { $_ } }} | Where-Object {$_.DisplayName -match "Microsoft Visual Studio \d{4} Devenv"} | Sort-Object -Property DisplayVersion -Descending | Select DisplayName, Version, DisplayVersion -First 1
			if($app){
				return $true;
			}
		}
		return $false;
    }
}

# Mount ISO and return application path searched from ISO
Function MountISOAndGetAppPath{
    Param (
        [string]$AppName,
        [string]$ISOPath
       )
    # Mount ISO and get drive letter
    $iso = Mount-DiskImage -ImagePath $ISOPath -StorageType ISO -PassThru
    $driveLetter = ($iso | Get-Volume).DriveLetter

    # Find application in ISO
    $driveLetter = $driveLetter + ":"

    $appPath = Get-ChildItem -Path $driveLetter -Filter $AppName -Recurse
    if(-not $appPath)
    {
        $content = $AppName + "cannot be found in ISO"
        Write-Host $content -ForegroundColor Red
        retun "";
    }else
    {
        return $appPath.FullName;
    }
}

# Reject app Disk
Function UnmountDisk{
    Param (
        [string]$AppPath
       )

    $DriveLetter = (Get-Item $appPath).PSDrive.Name
    $ShellApplication = New-Object -ComObject Shell.Application
    Write-Host "Eject DVD Drive: "$DriveLetter
    $ShellApplication.Namespace(17).ParseName($DriveLetter+":").InvokeVerb("Eject")
}

# Get tools to be downloaded from Config file by Category
Function GetDownloadTools{
    Param(
        [string]$DpConfigPath,
        [string]$ToolCategory
    )

    Write-Host "Reading Prerequisites Configure file..."
    [xml]$toolXML = Get-Content -Path $DpConfigPath #".\PrerequisitesConfig.xml"

    # Check if Category exists.
    $CategoryItem = $toolXML.Dependency.$ToolCategory.tool;
    if(-not ($CategoryItem))
    {
        $error = "Category $ToolCategory does not exist";
        throw $error
    }

    $tools = New-Object System.Collections.ArrayList;

    Write-Host "Get information of all the Prerequisite tools from Configure file"
    foreach($item in $toolXML.Dependency.tools.tool)
    {
        $tool = '' | select Name,FileName,AppName,Version,URL,Arguments,InstallFileName,NeedRestart,BackwardCompatible

        $tool.Name = $item.name;
        $tool.FileName = $item.FileName;
        $tool.AppName = $item.AppName;
        $tool.Version = $item.version;
        $tool.URL = $item.url;
        $tool.InstallFileName = $item.InstallFileName;
        $tool.NeedRestart = $false
		$tool.BackwardCompatible = $true
		
        if($item.NeedRestart)
        {
            $tool.NeedRestart = [bool]$item.NeedRestart;
        }
		if($item.BackwardCompatible)
        {
            $tool.BackwardCompatible = [bool]$item.BackwardCompatible;
        }
        $tool.Arguments = $item.arguments;

        $index = $tools.Add($tool)
    }

    Write-Host "Get the tools to be downloaded from the specified category"
    $downloadList = New-Object System.Collections.ArrayList;
    foreach($item in $toolXML.Dependency.$ToolCategory.tool)
    {
        $ndTool = $tools | Where-Object{$_.Name -eq $item} | Select-Object $_
        $index = $downloadList.Add($ndTool)
    }

    $tools.Clear();
    return $downloadList;
}

# Create a tempoary folder under current folder, which is used to store downloaded files.
Function CreateTemporaryFolder{
    #create temporary folder for downloading tools
    $tempPath = (get-location).ToString() + "\" + [system.guid]::newguid().ToString()
    Write-Host "Create temporary folder for downloading files"
    $outFile = New-Item -ItemType Directory -Path $tempPath
    Write-Host "Temporary folder $outFile is created"

    return $outFile.FullName
}

# Download and install prerequisite tool
Function DownloadAndInstallApplication
{
    param(
        [int]$PSVersion,
        $AppItem,
        [string]$OutputPath
    )
    # Check if Powershell version greate than 3.0, if not then use WebClient to download file, otherwise use Invoke-WebRequest.
    if($psVersion -ge 3)
    {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $AppItem.URL -OutFile $OutputPath
    }else
    {
        (New-Object System.Net.WebClient).DownloadFile($AppItem.URL, $OutputPath)
    }
            
    $content = "Downloading " + $AppItem.Name + " completed. Path:" + $OutputPath
    Write-Host $content

    # Check if the downloaded file is ISO
    if($AppItem.FileName.ToLower().EndsWith("iso"))
    {
        if($psVersion -ge 3)
        {
            Write-Host "Mounting ISO image";
            $OutputPath = MountISOAndGetAppPath -AppName $AppItem.InstallFileName -ISOPath $OutputPath
            Write-Host $OutputPath
        }
        else
        {
            $content = "Your system does not support Mount-DiskImage command. Please install " + $AppItem.AppName;

            Write-Host "Your system does not support Mount-DiskImage command. Please mount and install manually";
        }
    }
            
    # start to Install file
    $content = "Installing " + $AppItem.Name + ". Please wait..."
    Write-Host $content

    $FLAGS  = $AppItem.Arguments

    $ExitCode = (Start-Process -FILEPATH $OutputPath $FLAGS -Wait -PassThru).ExitCode
    if ($ExitCode -EQ 0)
    {
        $content = "Application " + $AppItem.Name +" is successfully installed on current machine"
        Write-Host $content -ForegroundColor Green
    }
    else
    {
        $failedList += $AppItem.Name
        $content = "Installing " + $AppItem.Name +" failed, Error Code:" + $ExitCode
        Write-Host "ERROR $ExitCode"; 
    }

    # If the file is ISO, unmount it.
    if($AppItem.FileName.ToLower().EndsWith("iso"))
    {
        UnmountDisk -AppPath $OutputPath
    }
}

# Start get all needed tools from configure file.
$downloadList = GetDownloadTools -DpConfigPath $ConfigPath -ToolCategory $Category
$tempFolder = CreateTemporaryFolder
$failedList = @();
$IsNeedRestart = $false;

# Check PowerShell version

$psVer = [int](Get-Host).Version.ToString().Substring(0,1)

foreach($item in $downloadList)
{
    $isInstalled = $false;

    if($item.Name.ToLower().Equals("net471"))
    {
        $isInstalled = CheckIfNet47IsInstalled

        if(-not $isInstalled)
        {
            $content = ".NET Framework 4.7.1 is not installed"
        }
    }
    else
    {
        $isInstalled = CheckIfAppInstalled -AppName $item.AppName -Version $item.version -Compatible $item.BackwardCompatible
        if(-not $isInstalled)
        {
            $content = "Application: " +$item.AppName + " is not installed"
        }
    }

    if ($item.Name.ToLower().Equals("vs2017community"))
    {
        cmd.exe /C "InstallVs2017Community.cmd"
    }
    else
    {
        if(-not $IsInstalled)
        {
            Write-Host $content -ForegroundColor Yellow
            
            $content = "Downloading file " + $item.Name + ". Please wait..."
            Write-Host $content
            $outputPath = $tempFolder + "\" + $item.FileName

            try
            {
                DownloadAndInstallApplication -PSVersion $psVer -AppItem $item -OutputPath $outputPath
            }
            catch
            {
                $failedList += $item.Name
                $IsInstalled = $false;
                $ErrorMessage = $_.Exception.Message
                Write-Host $ErrorMessage -ForegroundColor Red
                Break;
            }

            if($item.NeedRestart)
            {
                $IsNeedRestart = $true;
            }
        }
    }
}

if($psVersion -ge 3)
{
    $downloadList.Clear();
}
else{
    $downloadList = @();
}
