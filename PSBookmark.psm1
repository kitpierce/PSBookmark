#TODO: Don't like this method; will update this without breaking the module later
$DataFile = "PSBookmarkData.ps1"
$BasePath = Split-Path $profile.CurrentUserAllHosts
$DataPath = Join-Path $BasePath $DataFile

#region Bookmark Functions
function Add-BookmarkLocation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position=0)]
        [string] $Alias,

        [Parameter(Position=1)]
        [String] $Location = $(Get-Location).Path
    )

    # Import existing bookmarks
    try {
        $locationHash = Get-BookmarkLocations -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed 'Get-BookmarkLocations' - exception: $($_.Exception.Message)"
    }

    # Resolve user-provided 'Location' to paths
    try {
        [System.Management.Automation.PathInfo[]]$resolvedPath = Resolve-Path -Path $Location
    }
    catch {
        Write-Warning "Failed 'Resolve-Path' for location: '$Location'"
        Return
    }

    # If 'Resolve-Path' returns multiple matches, prompt user for desired single location
    if ($resolvedPath.Count -gt 1) {
        Write-Warning "Provided location resolves to multiple paths: '$Location'"
        $resolvedPath = $resolvedPath | Out-GridView -Title "Select Path For '$Alias' Bookmark" -OutputMode Single
    }

    # If no paths are resolved, generate warning and return
    if ($resolvedPath.Count -lt 1) {
        Write-Warning "Unable to resolve provided location to valid path: '$Location'"
        Return
    }
    else {
        $bmPath = $resolvedPath | Select-Object -First 1 -ExpandProperty Path

        # Check if bookmark hash currently has existing alias
        if ($locationHash[$Alias]) {
            $currentBmPath = $locationHash[$Alias]
            # If pending bookmark creation already exists, generate message and return
            if ($currentBmPath -like $bmPath) {
                Write-Verbose "Bookmark '$alias' already exists for path: '$currentBmPath'"
                Return
            }
            else {
                # Prompt user whether to replace existing bookmark
                Write-Warning "Bookmark already exists for '$Alias' at path: '$currentBmPath'"
                $response = Read-Host "Replace existing '$alias' bookmark with path: '$bmPath' [Y/N]"
                if ($response.ToCharArray()[0] -notlike 'Y') {
                    Write-Verbose "User declined bookmark update"
                    Return
                }
                else {
                    # Remove existing bookmark
                    Write-Verbose "Removing existing '$alias' bookmark: '$currentBmPath'"
                    $locationHash.Remove($Alias)
                }
            }
        }

        # Add bookmark to hashtable & save to file
        Write-Verbose "Adding bookmark '$Alias' for path: '$($bmPath)'"
        $locationHash.Add($Alias,$bmPath)
        Convert-DictionaryOrHashToString -Hash $locationHash | Out-File -FilePath $dataPath -Force
    }
}

function ConvertTo-BookmarkSorted {
    [CmdletBinding()]
    param (
        [Parameter(Position=0)]
        [ValidateSet('Name','Value')]
        [String]$SortBy = 'Name',

        [Parameter(Position=1)]
        [Switch]$Descending
    )

    # Import bookmarks
    try {
        $locationHash = Get-BookmarkLocations -ErrorAction Stop
    }
    catch {
        Write-Warning "Error importing bookmarks - excecption: $($_.Exception.Message)"
        throw $_.Exception.Message
    }

    $sortedBookmarks = $locationHash | Convert-HashtableToOrderedDictionary -SortBy $SortBy -Descending:$Descending
    Convert-DictionaryOrHashToString -Object $sortedBookmarks | Out-File -FilePath $dataPath -Force

}

function Set-BookmarkLocationAsPWD {
    [CmdletBinding(SupportsShouldProcess)]
    param ()

    DynamicParam {
        if (Test-Path -Path $dataPath)
        {
            $locationHash = Get-BookmarkLocations -ErrorAction SilentlyContinue
            return (New-DynamicParameter -Name 'Alias' -actionObject $locationHash)
        }
    }

    begin {
        $alias = $PsBoundParameters['Alias']
    }

    process {
        if ($locationHash[$alias]) {
            $bmPath = $locationHash[$alias]
            if (Test-Path -Path $bmPath -PathType Container) {
                Set-Location -Path $locationHash[$alias]
            }
            else {
                Write-Warning "Bookmark exists, but path does not: '$BmPath'"
            }
        }
        else {
            Write-Warning "No such bookmark defined: '$alias'"
        }
    }
}


function Get-BookmarkLocations {
    [CmdletBinding()]
    param (
        # Specifies a path to one or more locations.
        [Parameter(Position=0, HelpMessage="Path to bookmark file.")]
        [Alias("PSPath","BookmarkFile")]
        [ValidateScript({Test-Path -Path $_ -PathType Leaf})]
        [string] $Path = $DataPath
    )

    if (Test-Path -Path $Path -PathType Leaf) {
        try {
            $locationHash = Get-Content $Path -Raw | Invoke-Expression
            $bmCount = $($locationHash.GetEnumerator() | Measure-Object -ErrorAction SilentlyContinue).Count
            Write-Verbose "Imported $bmCount bookmark(s) from path: '$DataPath'"
            return $locationHash
        }
        catch {
            Write-Warning "Error importing bookmarks from path: '$Path' -exception: $($_.Exception.Message)"
            throw $_.Exception.Message
        }
    }
    else {
        Write-Verbose "Bookmark data file does not exist: '$Path'"
        Write-Warning -Message "No location bookmarks found. Invoke 'Save-LocationBookmark' to create one."
    }
}

function Remove-BookmarkLocation {
    [CmdletBinding(SupportsShouldProcess)]
    param ()

    DynamicParam {
        if (Test-Path -Path $dataPath -PathType Leaf) {
            $locationHash = Get-BookmarkLocations -ErrorAction SilentlyContinue
            return (New-DynamicParameter -Name 'Alias' -ActionObject $locationHash)
        }
    }

    begin {
        $alias = $PsBoundParameters['Alias']
    }

    process {
        $bmPath = $locationHash[$alias]
        if ($bmPath) {
            try {
                Write-Verbose "Removing bookmark '$alias' with path: '$bmPath'"
                $locationHash.Remove($alias)
                Convert-DictionaryOrHashToString -Object $locationHash | Out-File -FilePath $dataPath -Force
            }
            catch {
                Write-Warning "Error removing bookmark '$alias' - exception: $($_.Exception.Message)"
            }
        }
        else {
            Write-Verbose "No bookmark matching alias: '$alias'"
        }
    }
}
#endregion

#region Background Functions
#Credit: Exteneded on work by June Blender - https://www.sapien.com/blog/2014/10/21/a-better-tostring-method-for-hash-tables/
function Convert-DictionaryOrHashToString {
    [CmdletBinding()]
    param (
        [Parameter(Position=0,Mandatory=$true,ValueFromPipeline=$true)]
        [Alias('Hashtable','Dictionary','Hash','InputObject')]
        $Object,

        [Parameter(Position=1)]
        [ValidateSet('Hashtable','Dictionary')]
        $ExportType = 'Dictionary',

        [Switch]$Flat
    )
    begin {
        $tempDictionary = [ORDERED]@{}
    }

    process {
        ForEach ($inObject in $Object) {
            $inType = $inObject.GetType().FullName

            if (@('System.Collections.Hashtable','System.Collections.Specialized.OrderedDictionary' -notcontains $inType)) {
                Write-Warning "Invalid input object type: '$inType'"
            }
            else {
                $inObject.GetEnumerator() | ForEach-Object {
                    if ($tempDictionary[$($_.Name)]) {
                        Write-Warning "Collection already contains key: '$($_.Name)'"
                    }
                    else {
                        $tempDictionary.Add($_.Name,$_.Value)
                    }
                }
            }
        }
    }
    end {
        if ($ExportType -like 'Dictionary') {
            $hashstr = "[ORDERED]@{"
        }
        else {
            $hashstr = "@{"
        }

        foreach ($key in $tempDictionary.Keys) {
            $value = $tempDictionary[$key]
            if ($Flat -ne $true) { $hashstr += "`n`t" }

            $hashstr += "`"$key`"" + "=" + "`"$value`"" + ";"
        }

        if ($flat -ne $true) { $hashstr += "`n" }
        $hashstr += "}"
        return $hashstr
    }
}

function Convert-HashtableToOrderedDictionary {
    [CmdletBinding()]
    param (
        [Parameter(Position=0)]
        [ValidateSet('Name','Value')]
        [String]$SortBy = 'Name',

        [Parameter(Position=1)]
        [Switch]$Descending,

        [Parameter(Position=2,ValueFromPipeline=$true,Mandatory=$true)]
        [System.Collections.Hashtable] $Hashtable


    )
    begin {
        [ARRAY]$tempArray = @()

    }
    process {
        $hashtable.GetEnumerator() | ForEach-Object {
            [ARRAY]$tempArray += $_
        }

        if ($Descending -eq $true) {
            Write-Verbose "Sort descending $($tempArray.Count) objects by '$SortBy'"
            [ARRAY]$sortedArray = $tempArray | Sort-Object -Property $SortBy -Descending
        }
        else {
            Write-Verbose "Sort ascending $($tempArray.Count) objects by '$SortBy'"
            [ARRAY]$sortedArray = $tempArray | Sort-Object -Property $SortBy
        }
    }
    end {
        $sortedDictionary = [ORDERED]@{}
        $sortedArray | ForEach-Object { $sortedDictionary.Add($_.Name,$_.Value) }
        Return $sortedDictionary
    }
}

function New-DynamicParameter {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [String] $Name,

        [Parameter()]
        $actionObject
    )

        $ParameterName = $Name
        $RuntimeParameterDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
        $AttributeCollection = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
        $ParameterAttribute = New-Object System.Management.Automation.ParameterAttribute
        $ParameterAttribute.Mandatory = $true
        $ParameterAttribute.Position = 0

        $AttributeCollection.Add($ParameterAttribute)

        $arrSet = $actionObject.Keys
        $ValidateSetAttribute = New-Object System.Management.Automation.ValidateSetAttribute($arrSet)

        $AttributeCollection.Add($ValidateSetAttribute)

        $RuntimeParameter = New-Object System.Management.Automation.RuntimeDefinedParameter($ParameterName, [string], $AttributeCollection)
        $RuntimeParameterDictionary.Add($ParameterName, $RuntimeParameter)
        return $RuntimeParameterDictionary
}
#endregion

Set-Alias -Name save -Value Add-BookmarkLocation
Set-Alias -Name goto -Value Set-BookmarkLocationAsPWD
Set-Alias -Name glb -Value Get-BookmarkLocations
Set-Alias -Name rlb -Value Remove-BookmarkLocation
Set-Alias -Name bmadd -Value Add-BookmarkLocation
Set-Alias -Name bmget -Value Get-BookmarkLocations
Set-Alias -Name bmdelete -Value Remove-BookmarkLocation
Set-Alias -Name bmsort -Value ConvertTo-BookmarkSorted

Export-ModuleMember -Function *Bookmark* -Alias *
