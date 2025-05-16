# This script generates a JSON file containing store details from a specified folder of icons.

param (
    [string]$IconsFolder = "$($PSScriptRoot)\icons",
    [string]$CdnBaseUrl = "https://bauda.github.io/cardly-store-catalog/icons",
    [string]$OutputPath = "$($PSScriptRoot)\storew.json"
)

$parent = Split-Path -Path $OutputPath -Parent
if (-not (Test-Path -Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$storeList = @()

Get-ChildItem -Path $IconsFolder -Filter *.png | ForEach-Object {
    $file = $_
    $slug = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $slugWithCapitalLetter = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).Substring(0, 1).ToUpper() + $slug.Substring(1)

    $store = [PSCustomObject]@{
        Id              = [Guid]::NewGuid().ToString()
        DisplayName     = $slugWithCapitalLetter
        FileName        = $slug
        IconUrl         = "$CdnBaseUrl/$($file.Name)"
        BackgroundColor = ""
    }

    $storeList += $store
}

$json = $storeList | ConvertTo-Json -Depth 3
Set-Content -Path $OutputPath -Value $json -Encoding UTF8

Write-Host "Generated JSON with " -NoNewline
Write-Host "$($storeList.Count) entries " -ForegroundColor Yellow -NoNewline
Write-Host "at path " -NoNewline
Write-Host "$OutputPath" -foregroundcolor Yellow
