<#
  brandfetch-loop.ps1
  Infinite loop script that:
   - reads Data.json next to the script to get outputPath
   - ensures logos/ and json/ subfolders exist
   - asks user for storeIdentifier (prompt text required)
   - attempts up to 4 Brandfetch URLs in a specific order
   - downloads the first successful response
   - marks SVG downloads in green, non-SVG in yellow
   - if non-SVG was downloaded ask user to proceed or restart
   - asks for storeName and appends a JSON entry into stores.json in json/
   - then loops back to ask for another brand
#>

# === Helper functions ===

function Get-ScriptDir {
    # Works when running as .ps1 or in console. Falls back to current location.
    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrEmpty($scriptPath)) {
        return (Get-Location).ProviderPath
    } else {
        return Split-Path -Parent $scriptPath
    }
}

function Sanitize-FileName {
    param([string]$name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    foreach ($c in $invalid) { $name = $name -replace [regex]::Escape($c), '_' }
    return $name
}

function Try-HttpGet {
    param(
        [string]$url
    )
    # Returns a hashtable: Success(bool), StatusCode(int), IsSvg(bool), Bytes(byte[]), ContentType(string), Message(string)
    $result = @{
        Success = $false
        StatusCode = 0
        IsSvg = $false
        Bytes = $null
        ContentType = $null
        Message = ""
    }

    try {
        $client = New-Object System.Net.Http.HttpClient
        # Add a simple user agent
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("PowerShellScript/1.0")
        $task = $client.GetAsync($url)
        $task.Wait()
        $response = $task.Result

        $result.StatusCode = [int]$response.StatusCode

        if ($response.Content -ne $null) {
            $ctHeader = $response.Content.Headers.ContentType
            $result.ContentType = if ($ctHeader) { $ctHeader.MediaType } else { $null }
            $readTask = $response.Content.ReadAsByteArrayAsync()
            $readTask.Wait()
            $bytes = $readTask.Result
            $result.Bytes = $bytes
        }

        if ($response.IsSuccessStatusCode) {
            # Try detect SVG by content-type or by content text
            $isSvg = $false
            if ($result.ContentType -and $result.ContentType -like "image/svg*") {
                $isSvg = $true
            } else {
                # attempt to decode a small chunk as UTF8/ASCII and look for "<svg"
                try {
                    if ($result.Bytes -ne $null -and $result.Bytes.Length -gt 0) {
                        $text = [System.Text.Encoding]::UTF8.GetString($result.Bytes)
                        if ($text -match "<svg\b") { $isSvg = $true }
                    }
                } catch {
                    # ignore decoding errors
                }
            }
            $result.Success = $true
            $result.IsSvg = $isSvg
            $result.Message = "HTTP {0} OK" -f $result.StatusCode
        } else {
            $result.Success = $false
            $result.Message = "HTTP {0} - {1}" -f $result.StatusCode, $response.ReasonPhrase
        }
    } catch {
        $ex = $_.Exception
        # Try to get a numeric status from inner response if available
        $status = 0
        if ($ex.Response -and $ex.Response.StatusCode) {
            $status = [int]$ex.Response.StatusCode
        }
        $result.StatusCode = $status
        $result.Success = $false
        $result.Message = "Request failed: $($_.Exception.Message)"
    }

    return $result
}

# === Main loop ===

$scriptDir = Get-ScriptDir

# Data.json location
$dataJsonPath = Join-Path $scriptDir "Data.json"

if (-not (Test-Path $dataJsonPath)) {
    Write-Host "ERROR: Data.json not found in script folder: $scriptDir" -ForegroundColor Red
    Write-Host "Please ensure a Data.json file exists next to this script with {`"outputPath`": `"<your path>`"}" -ForegroundColor Yellow
    # Keep running but wait for user to press Enter to continue check (script is supposed to never close)
    while (-not (Test-Path $dataJsonPath)) {
        Read-Host "Press Enter to retry checking for Data.json (or Ctrl+C to exit)"
    }
}

# Read Data.json (we'll read inside the loop to allow updates while script runs)
while ($true) {

    # Read Data.json each loop (allows updating path without restarting script)
    try {
        $raw = Get-Content -Path $dataJsonPath -Raw -ErrorAction Stop
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.outputPath) {
            Write-Host "ERROR: Data.json found but 'outputPath' property is missing or empty." -ForegroundColor Red
            Read-Host "Fix Data.json then press Enter to retry"
            continue
        }
        $outputPath = $data.outputPath
    } catch {
        Write-Host "ERROR reading Data.json: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Fix Data.json then press Enter to retry"
        continue
    }

    # Ensure outputPath exists
    try {
        if (-not (Test-Path $outputPath)) {
            New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
        }
    } catch {
        Write-Host "ERROR: Could not create or access outputPath '$outputPath': $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Fix permissions/path then press Enter to retry"
        continue
    }

    # Ensure logos and json folders
    $logosDir = Join-Path $outputPath "logos"
    $jsonDir  = Join-Path $outputPath "json"
    New-Item -Path $logosDir -ItemType Directory -Force | Out-Null
    New-Item -Path $jsonDir -ItemType Directory -Force | Out-Null

    # Ask user for store identifier
    $storeIdentifier = Read-Host "Please enter a store by domain, brand id, ISIN or stock ticker"

    if ([string]::IsNullOrWhiteSpace($storeIdentifier)) {
        Write-Host "No identifier entered. Restarting..." -ForegroundColor Yellow
        continue
    }

    # Prepare the URL list in the required order
    $cparam = "c=1bxid64Mup7aczewSAYMX"
    $urls = @(
        "https://cdn.brandfetch.io/$($storeIdentifier)/theme/dark/fallback/404/symbol.svg?$cparam",
        "https://cdn.brandfetch.io/$($storeIdentifier)/theme/dark/fallback/404/logo.svg?$cparam",
        "https://cdn.brandfetch.io/$($storeIdentifier)/theme/dark/fallback/404/symbol?$cparam",
        "https://cdn.brandfetch.io/$($storeIdentifier)/theme/dark/fallback/404/logo?$cparam"
    )

    $downloadedAny = $false
    $downloadedIsSvg = $false
    $downloadedFile = $null
    $downloadedLabel = $null  # e.g. "symbol.svg" or "logo" etc.

    for ($i = 0; $i -lt $urls.Count; $i++) {
        $url = $urls[$i]
        $label = switch ($i) {
            0 {"symbol.svg"}
            1 {"logo.svg"}
            2 {"symbol"}
            3 {"logo"}
        }

        Write-Host "Attempting: $url" -ForegroundColor DarkCyan
        $res = Try-HttpGet -url $url

        if ($res.Success) {
            # Save file
            # --- Updated naming logic: use website/domain-style name in lowercase ---
            # Extract base name (everything before first dot if looks like domain, otherwise full identifier)
            $baseName = $storeIdentifier.ToLower()

            # If it looks like a domain (e.g., carrefour.com), strip everything after first dot
            if ($baseName -match "^[a-z0-9-]+\.[a-z0-9.-]+$") {
                $baseName = ($baseName -split '\.')[0]
            }

            # Clean invalid chars for file name
            $baseName = Sanitize-FileName $baseName

            # Determine file extension - prefer .svg if IsSvg true; otherwise infer from content type
            $ext = ".bin"
            if ($res.IsSvg) { 
                $ext = ".svg" 
            }
            elseif ($res.ContentType) {
                if ($res.ContentType -like "image/png*") {
                    $ext = ".png"
                }
                elseif ($res.ContentType -like "image/jpeg*" -or $res.ContentType -like "image/jpg*") {
                    $ext = ".jpg"
                }
                elseif ($res.ContentType -like "image/webp*") {
                    $ext = ".webp"
                }
                elseif ($res.ContentType -like "image/*") {
                    $ext = ".img"
                }
                else {
                    $ext = ".bin"
                }
            }

            # Build final file name like carrefour.svg, tesco.png, etc.
            $fileName = "$baseName$ext"
            $outFile = Join-Path $logosDir $fileName


            try {
                [System.IO.File]::WriteAllBytes($outFile, $res.Bytes)
                $downloadedAny = $true
                $downloadedIsSvg = $res.IsSvg
                $downloadedFile = $outFile
                $downloadedLabel = $label

                if ($res.IsSvg) {
                    Write-Host "Downloaded $label and detected SVG -> saved to: $outFile" -ForegroundColor Green
                } else {
                    Write-Host "Downloaded $label but content is NOT SVG -> saved to: $outFile" -ForegroundColor Yellow
                }
                break
            } catch {
                Write-Host "Failed to save file: $($_.Exception.Message)" -ForegroundColor Red
                # continue trying next URL
            }
        } else {
            Write-Host "Request failed: $($res.Message)" -ForegroundColor DarkRed
        }
    }

    if (-not $downloadedAny) {
        Write-Host "Zero calls succeeded for '$storeIdentifier'. Starting over." -ForegroundColor Yellow
        continue
    }

    # If a non-SVG file was downloaded, ask user if they want to proceed
    if (-not $downloadedIsSvg) {
        while ($true) {
            $yn = Read-Host "Downloaded file is NOT SVG. Do you want to proceed? (Y/N)"
            if ($yn -match '^[Yy]') {
                break
            } elseif ($yn -match '^[Nn]') {
                Write-Host "User chose not to proceed. Restarting." -ForegroundColor Yellow
                continue 2  # continue outer while loop (restart)
            } else {
                Write-Host "Please answer Y or N." -ForegroundColor DarkYellow
            }
        }
    }

    # Ask for store name
    $storeName = Read-Host "Please enter the store name"

    if ([string]::IsNullOrWhiteSpace($storeName)) {
        Write-Host "No store name entered. Restarting." -ForegroundColor Yellow
        continue
    }

    # Prepare stores.json
    $storesJsonPath = Join-Path $jsonDir "stores.json"
    $stores = @()
    if (Test-Path $storesJsonPath) {
        try {
            $existing = Get-Content -Path $storesJsonPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($existing)) {
                # If file exists but contains a single object (not array), attempt to normalize to array
                try {
                    $parsed = $existing | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed -is [System.Array]) {
                        $stores = $parsed
                    } else {
                        # single object -> convert to array with that object
                        $stores = ,$parsed
                    }
                } catch {
                    Write-Host "Warning: could not parse existing stores.json, will overwrite with a new array." -ForegroundColor Yellow
                    $stores = @()
                }
            } else {
                $stores = @()
            }
        } catch {
            Write-Host "Warning: could not read stores.json: $($_.Exception.Message)" -ForegroundColor Yellow
            $stores = @()
        }
    } else {
        # create empty file
        try { Set-Content -Path $storesJsonPath -Value "[]" -Force } catch {}
        $stores = @()
    }

    # Build the new entry
    $entry = [PSCustomObject]@{
        name = $storeName
        backgroundColor = "ffffff"
        source = $storeIdentifier
        aliases = $null
        category = ""
        barcodeFormat = "CODE_128"
    }

    # Append
    $stores = $stores + $entry

    # Save pretty-printed JSON
    try {
        $jsonOut = $stores | ConvertTo-Json -Depth 10 -Compress:$false
        # ConvertTo-Json in PS 7+ supports -Compress:$false; if failing, just call without parameter
    } catch {
        # fallback
        $jsonOut = $stores | ConvertTo-Json -Depth 10
    }

    try {
        Set-Content -Path $storesJsonPath -Value $jsonOut -Encoding UTF8
        Write-Host "Store entry added to stores.json -> $storesJsonPath" -ForegroundColor Green
    } catch {
        Write-Host "Failed to write stores.json: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "SUCCESS: Done for '$storeIdentifier' / '$storeName'." -ForegroundColor Green
    Write-Host "Looping back to start..." -ForegroundColor DarkCyan
    Write-Host
}
