# Path to your JSON file
$jsonPath = "C:\cardly-store-catalog\stores.json"

$jsonContent = Get-Content $jsonPath -Raw | ConvertFrom-Json

$newStores = @()
$id = 1
foreach ($store in $jsonContent.stores) {
    $newStore = [ordered]@{
        id = $id
        name = $store.name
        backgroundColor = $store.backgroundColor
        source = $store.source
        aliases = $store.aliases
        category = $store.category
        barcodeFormat = $store.barcodeFormat
    }
    $newStores += [pscustomobject]$newStore
    $id++
}

$jsonContent.stores = $newStores
$jsonContent | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding UTF8

Write-Host "✅ IDs added and ordered successfully!"
