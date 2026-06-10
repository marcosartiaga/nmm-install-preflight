#Requires -Version 5.1
<#
.SYNOPSIS
    Nerdio Manager for MSP (NMM) pre-install region eligibility checker.

.DESCRIPTION
    Surfaces the Azure regions that offer BOTH resources the NMM Azure Marketplace
    deployment needs, so an SE can tell a partner on a live call which regions are
    safe to pick in the deployment wizard:

        1. App Service Plan  : Basic Medium (B2), Windows  <- "Basic VM SKU app service quota" pain point
        2. Azure SQL Database: Standard tier / S1 (DTU)     <- "can't deploy managed SQL" pain point

    The script cross-references the two and prints a clean table plus a plain-English
    "these are the regions you could select" summary line. Optionally writes a CSV.

    IMPORTANT CAVEAT (App Service): `az appservice list-locations` reports where the B1
    SKU is *offered*, not live capacity. The "No availability of Basic VM SKU app service
    quota" error can still occasionally hit an offered region when Microsoft is capacity-
    constrained. There is no public API to pre-check live App Service capacity. If a
    deploy fails in an "Eligible" region, switch to another eligible region or open an
    Azure support request to lift the App Service quota in that region.

.PARAMETER AppServiceSku
    App Service plan SKU to test. Default B2 (NMM default, Windows). Accepts B1, B2, B3, S1, etc.

.PARAMETER SqlEdition
    Azure SQL Database edition/tier to test. Default Standard (NMM default).

.PARAMETER SqlServiceObjective
    SQL service objective (performance level) to test. Default S1 (NMM default, 20 DTU).

.PARAMETER Regions
    Optional shortlist of region slugs (e.g. eastus,westus2,westeurope) to limit the check.
    Faster, and lets you answer "why can't we use <region the partner asked for>?" because
    requested regions are checked for BOTH gates even if App Service excludes them.
    If omitted, the script checks every region that offers the App Service SKU.

.PARAMETER SubscriptionId
    Optional subscription to target. Defaults to the current `az` context.

.PARAMETER OutFile
    Optional path to write a CSV of the full result table.

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1
    Check all App Service B1 regions for Standard/S1 SQL and print eligible regions.

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1 -Regions eastus,eastus2,centralus,westus2 -OutFile result.csv
    Only check the partner's candidate regions and save a CSV.

.NOTES
    Run in Azure Cloud Shell (PowerShell mode) -- already authenticated -- or in local
    PowerShell with Azure CLI installed and `az login` completed.
#>

[CmdletBinding()]
param(
    [string]$AppServiceSku       = 'B2',
    [string]$SqlEdition          = 'Standard',
    [string]$SqlServiceObjective = 'S1',
    [string[]]$Regions,
    [string]$SubscriptionId,
    [string]$OutFile
)

# NOTE: deliberately NOT 'Stop'. The Azure CLI writes harmless warnings to stderr, and
# under 'Stop' PowerShell 5.1 promotes native stderr to a terminating error. Error handling
# here is explicit (throw / try-catch), which terminates regardless of this preference.
$ErrorActionPreference = 'Continue'

function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

# --- 0. Pre-flight: az present + authenticated -----------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Run this in Azure Cloud Shell, or install the Azure CLI locally."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
}

$ctx = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $ctx) {
    throw "Not logged in to Azure. Run 'az login' (not needed in Cloud Shell) and try again."
}

Write-Banner "Nerdio Manager for MSP (NMM) - Region Eligibility Check"
Write-Host ("Subscription : {0}" -f $ctx.name)
Write-Host ("Sub ID       : {0}" -f $ctx.id)
Write-Host ("Checking for : App Service '{0}'  +  Azure SQL '{1}/{2}'" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective)
Write-Host ''

# --- 1. Authoritative region map (displayName -> slug) ----------------------
Write-Host "Loading Azure region list..." -ForegroundColor DarkGray
$allLocations = az account list-locations --only-show-errors 2>$null | ConvertFrom-Json
$physical     = $allLocations | Where-Object { $_.metadata.regionType -eq 'Physical' }

# displayName ("East US") -> slug ("eastus")
$nameToSlug = @{}
foreach ($loc in $physical) { $nameToSlug[$loc.displayName] = $loc.name }
# slug -> displayName, for friendly output
$slugToName = @{}
foreach ($loc in $physical) { $slugToName[$loc.name] = $loc.displayName }

function Resolve-Slug {
    param([string]$DisplayName)
    if ($nameToSlug.ContainsKey($DisplayName)) { return $nameToSlug[$DisplayName] }
    # fallback: normalize "West US 2" -> "westus2"
    return ($DisplayName -replace '\s', '').ToLower()
}

# --- 2. App Service regions (Windows; no --linux-workers-enabled flag) ------
Write-Host ("Querying App Service regions that offer the '{0}' SKU..." -f $AppServiceSku) -ForegroundColor DarkGray
$appSvcRaw   = az appservice list-locations --sku $AppServiceSku --only-show-errors 2>$null | ConvertFrom-Json
$appSvcSlugs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $appSvcRaw) { [void]$appSvcSlugs.Add( (Resolve-Slug $r.name) ) }
Write-Host ("  -> {0} regions offer App Service {1}." -f $appSvcSlugs.Count, $AppServiceSku) -ForegroundColor DarkGray

# --- 3. Determine candidate regions to evaluate -----------------------------
if ($Regions) {
    $candidates = $Regions | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
    Write-Host ("Limiting check to {0} requested region(s)." -f $candidates.Count) -ForegroundColor DarkGray
}
else {
    # No shortlist: a region must offer App Service B1 to be viable, so only those are worth a SQL call.
    $candidates = @($appSvcSlugs) | Sort-Object
    Write-Host ("Checking SQL availability across all {0} App Service-eligible regions (this can take ~1 min)..." -f $candidates.Count) -ForegroundColor DarkGray
}

# --- 4. Evaluate each candidate (SQL Standard/S1 availability) --------------
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($slug in $candidates) {
    $i++
    Write-Progress -Activity "Checking SQL availability" -Status $slug -PercentComplete ([int](($i / $candidates.Count) * 100))

    $appOk = $appSvcSlugs.Contains($slug)

    # SQL: --available filters to what is actually deployable in this region for this subscription.
    $sqlOk = $false
    try {
        $editions = az sql db list-editions -l $slug `
                        --edition $SqlEdition `
                        --service-objective $SqlServiceObjective `
                        --available -o json --only-show-errors 2>$null | ConvertFrom-Json
        if ($editions) {
            $slo = $editions | ForEach-Object { $_.supportedServiceLevelObjectives } |
                   Where-Object { $_.name -eq $SqlServiceObjective }
            $sqlOk = [bool]$slo
        }
    }
    catch {
        # An invalid region slug or an unsupported location throws; treat as "not available".
        $sqlOk = $false
    }

    $display = if ($slugToName.ContainsKey($slug)) { $slugToName[$slug] } else { $slug }

    $results.Add([pscustomobject]@{
        Region      = $slug
        DisplayName = $display
        AppService  = if ($appOk) { 'Yes' } else { 'No' }
        SqlDb       = if ($sqlOk) { 'Yes' } else { 'No' }
        Eligible    = if ($appOk -and $sqlOk) { 'YES' } else { 'no' }
    })
}
Write-Progress -Activity "Checking SQL availability" -Completed

# --- 5. Output --------------------------------------------------------------
$sorted   = $results | Sort-Object @{E={$_.Eligible -eq 'YES'};Descending=$true}, DisplayName
$eligible = $sorted | Where-Object { $_.Eligible -eq 'YES' }

Write-Banner "Results"
$sorted | Format-Table -AutoSize

Write-Banner "RECOMMENDATION"
if ($eligible.Count -gt 0) {
    Write-Host "Based on what we found, these are the regions you could select for the" -ForegroundColor Green
    Write-Host "NMM deployment (App Service $AppServiceSku + Azure SQL $SqlEdition/$SqlServiceObjective both available):" -ForegroundColor Green
    Write-Host ''
    $eligible | ForEach-Object { Write-Host ("   - {0}  ({1})" -f $_.DisplayName, $_.Region) -ForegroundColor Green }
}
else {
    Write-Host "No checked region offers BOTH App Service $AppServiceSku and SQL $SqlEdition/$SqlServiceObjective." -ForegroundColor Yellow
    Write-Host "Widen the search (drop -Regions to scan all regions) or consider a different App Service SKU / SQL tier." -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Note: App Service availability above reflects where the $AppServiceSku SKU is OFFERED, not live capacity." -ForegroundColor DarkGray
Write-Host "If a deploy still fails with a Basic quota error in an eligible region, switch to another" -ForegroundColor DarkGray
Write-Host "eligible region or open an Azure support request to raise the App Service quota there." -ForegroundColor DarkGray

# --- 6. Optional CSV --------------------------------------------------------
if ($OutFile) {
    $sorted | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host ("Full result table written to: {0}" -f $OutFile) -ForegroundColor Cyan
}
