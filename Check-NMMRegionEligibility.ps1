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

    AVAILABILITY vs. QUOTA -- READ THIS:
    This tool reports whether each SKU is AVAILABLE / OFFERED to the subscription in a
    region. It does NOT (and cannot) confirm the subscription has the QUOTA HEADROOM to
    actually provision it. The Azure Quota API (Microsoft.Quota) does not cover App
    Service (Microsoft.Web) or Azure SQL, so live quota for these two resources cannot be
    pre-checked via any public API -- it is only enforced at deploy time and raised via a
    support request. So "Eligible" here means "both SKUs are available in the region," not
    "guaranteed to deploy." If a deploy fails on a quota/capacity error in an Eligible
    region, either pick another Eligible region or open an Azure support request
    (issue type: "Service and subscription limits (quotas)") for that region.

.PARAMETER Geography
    Optional. Limits the check to one geography so you don't have to know region slugs.
    Accepts: US, Canada, NorthAmerica, Europe, UK, AsiaPacific, MiddleEast, Africa,
    SouthAmerica, All. If neither -Geography nor -Regions is supplied and the session is
    interactive, the script prompts with a menu ("Where is the partner located?").

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
    Prompt for the partner's geography, then check those regions for B2 + Standard/S1.

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1 -Geography US
    Check only US regions (no prompt) -- ideal when the partner just says "we're in the US."

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1 -Regions eastus,eastus2,centralus,westus2 -OutFile result.csv
    Only check the partner's named regions and save a CSV.

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
    [string]$Geography,
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
# slug -> Azure geographyGroup ("US", "Europe", "Asia Pacific", ...)
$slugToGeo = @{}
foreach ($loc in $physical) { $slugToGeo[$loc.name] = $loc.metadata.geographyGroup }

function Resolve-Slug {
    param([string]$DisplayName)
    if ($nameToSlug.ContainsKey($DisplayName)) { return $nameToSlug[$DisplayName] }
    # fallback: normalize "West US 2" -> "westus2"
    return ($DisplayName -replace '\s', '').ToLower()
}

# Friendly geography choice -> set of Azure geographyGroup values.
# $null means "all regions" (no filter).
$geoMenu = [ordered]@{
    'United States'                     = @('US')
    'Canada'                            = @('Canada')
    'North America (US + Canada + Mexico)' = @('US', 'Canada', 'Mexico')
    'Europe (incl. UK)'                 = @('Europe', 'UK')
    'United Kingdom'                    = @('UK')
    'Asia Pacific'                      = @('Asia Pacific')
    'Middle East'                       = @('Middle East')
    'Africa'                            = @('Africa')
    'South America'                     = @('South America')
    'All regions'                       = $null
}

function Resolve-Geography {
    # Maps a -Geography token (spaces/case-insensitive) to a set of geographyGroup values.
    param([string]$Token)
    switch -Regex (($Token -replace '\s', '').ToLower()) {
        '^(us|usa|unitedstates)$'              { return @('US') }
        '^canada$'                             { return @('Canada') }
        '^(northamerica|na)$'                  { return @('US', 'Canada', 'Mexico') }
        '^(europe|eu)$'                        { return @('Europe', 'UK') }
        '^(uk|unitedkingdom)$'                 { return @('UK') }
        '^(asiapacific|apac|asia)$'            { return @('Asia Pacific') }
        '^(middleeast|me)$'                    { return @('Middle East') }
        '^africa$'                             { return @('Africa') }
        '^(southamerica|latam|latinamerica)$'  { return @('South America') }
        '^(mexico|mx)$'                        { return @('Mexico') }
        '^all$'                                { return $null }
        default {
            throw "Unrecognized -Geography '$Token'. Use one of: US, Canada, NorthAmerica, Europe, UK, AsiaPacific, MiddleEast, Africa, SouthAmerica, Mexico, All."
        }
    }
}

function Show-GeographyPrompt {
    # Interactive numbered menu. Returns a set of geographyGroup values, or $null for all.
    Write-Host ''
    Write-Host "Where is the partner / MSP located? (filters which regions to check)" -ForegroundColor Cyan
    $labels = @($geoMenu.Keys)
    for ($n = 0; $n -lt $labels.Count; $n++) {
        Write-Host ("  {0,2}. {1}" -f ($n + 1), $labels[$n])
    }
    try {
        $pick = Read-Host "Enter choice [1]" -ErrorAction Stop
    }
    catch {
        # Non-interactive host (no console for input): don't guess a geography, scan everything.
        Write-Host "(no interactive input available -- scanning all regions; pass -Geography to filter)" -ForegroundColor Yellow
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $labels.Count) {
        Write-Host "Invalid choice; defaulting to United States." -ForegroundColor Yellow
        $idx = 1
    }
    return $geoMenu[$labels[$idx - 1]]
}

# --- 2. App Service regions (Windows; no --linux-workers-enabled flag) ------
Write-Host ("Querying App Service regions that offer the '{0}' SKU..." -f $AppServiceSku) -ForegroundColor DarkGray
$appSvcRaw   = az appservice list-locations --sku $AppServiceSku --only-show-errors 2>$null | ConvertFrom-Json
$appSvcSlugs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $appSvcRaw) { [void]$appSvcSlugs.Add( (Resolve-Slug $r.name) ) }
Write-Host ("  -> {0} regions offer App Service {1}." -f $appSvcSlugs.Count, $AppServiceSku) -ForegroundColor DarkGray

# --- 3. Determine candidate regions to evaluate -----------------------------
# Precedence: explicit -Regions  >  -Geography  >  interactive prompt  >  all regions.
if ($Regions) {
    $candidates = $Regions | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
    Write-Host ("Limiting check to {0} requested region(s)." -f $candidates.Count) -ForegroundColor DarkGray
}
else {
    $geoGroups = $null      # $null = no filter (all regions)
    $geoLabel  = 'All regions'
    if ($Geography) {
        $geoGroups = Resolve-Geography $Geography
        $geoLabel  = $Geography
    }
    elseif ([Environment]::UserInteractive) {
        $geoGroups = Show-GeographyPrompt
        $geoLabel  = if ($null -eq $geoGroups) { 'All regions' } else { ($geoGroups -join ', ') }
    }

    # A region must offer the App Service SKU to be worth a SQL call; then filter by geography.
    $candidates = @($appSvcSlugs)
    if ($null -ne $geoGroups) {
        $candidates = $candidates | Where-Object { $geoGroups -contains $slugToGeo[$_] }
    }
    $candidates = $candidates | Sort-Object
    Write-Host ''
    Write-Host ("Checking {0} region(s) in '{1}' for SQL {2}/{3} availability..." -f $candidates.Count, $geoLabel, $SqlEdition, $SqlServiceObjective) -ForegroundColor DarkGray
}

if (-not $candidates -or @($candidates).Count -eq 0) {
    Write-Host ''
    Write-Host "No candidate regions to check (none offer App Service $AppServiceSku in the selected geography)." -ForegroundColor Yellow
    return
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
Write-Host "AVAILABILITY, NOT QUOTA: 'Eligible' means both SKUs are AVAILABLE to this subscription in" -ForegroundColor DarkGray
Write-Host "the region -- it is NOT a guarantee of quota headroom. Live quota for App Service and Azure" -ForegroundColor DarkGray
Write-Host "SQL can't be pre-checked via any public API; it's enforced at deploy time. If a deploy fails" -ForegroundColor DarkGray
Write-Host "on a quota/capacity error in an Eligible region, pick another Eligible region or open an Azure" -ForegroundColor DarkGray
Write-Host "support request (issue type: 'Service and subscription limits (quotas)') for that region." -ForegroundColor DarkGray

# --- 6. Optional CSV --------------------------------------------------------
if ($OutFile) {
    $sorted | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host ("Full result table written to: {0}" -f $OutFile) -ForegroundColor Cyan
}
