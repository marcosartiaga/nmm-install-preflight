# NMM Install Pre-Flight

Pre-install checks for deploying **Nerdio Manager for MSP (NMM)** from the Azure Marketplace.

NMM's marketplace deployment can silently fail late in the wizard when the chosen Azure region can't actually host one of its core resources. The two recurring offenders:

1. **App Service Plan — Basic Medium (B2), Windows.** Some regions report *"No availability of Basic VM SKU app service quota."*
2. **Azure SQL Database — Standard tier / S1 (20 DTU).** Some regions have the SKU in the catalog but it isn't deployable in *your* subscription right now (often regions that only offer the vCore model, or are capacity-constrained).

`Check-NMMRegionEligibility.ps1` checks **both** gates across Azure regions and prints a plain-English *"these are the regions you could select"* list — so an SE can de-risk region choice live on a partner call before kicking off the install.

---

## ⚠️ Run it in the *partner's* subscription

The SQL availability check (`--available`) and App Service quota are **per-subscription**. The only result that matters is the one from the tenant where NMM is actually being installed. So run this in the **partner's** Azure Cloud Shell (screen-share and dictate the one-liner), not your own.

---

## Quick start (Azure Cloud Shell — PowerShell)

Open Cloud Shell at <https://shell.azure.com> (or the `>_` icon in the Azure portal), make sure it's in **PowerShell** mode, and paste:

```powershell
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1
```

With no arguments it **asks where the partner is located** and checks just that geography — so you don't need to know region slugs:

```
Where is the partner / MSP located? (filters which regions to check)
   1. United States
   2. Canada
   3. North America (US + Canada + Mexico)
   4. Europe (incl. UK)
   5. United Kingdom
   6. Asia Pacific
   ...
  10. All regions
Enter choice [1]:
```

Already know the answer? Skip the prompt:

```powershell
# Just the US:
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1 -Geography US

# Or specific regions the partner named:
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1 -Regions eastus,centralus,westus2
```

> First-time Cloud Shell users get a one-time "set up storage" prompt (~30s) — or just pick the ephemeral/no-storage session. Either works.

---

## What you'll see

```
Region     DisplayName  AppService  SqlDb  Eligible
centralus  Central US   Yes         Yes    YES
westus2    West US 2    Yes         Yes    YES
westus3    West US 3    Yes         Yes    YES
eastus     East US      Yes         No     no
eastus2    East US 2    Yes         No     no

RECOMMENDATION
Based on what we found, these are the regions you could select for the
NMM deployment (App Service B2 + Azure SQL Standard/S1 both available):
   - Central US  (centralus)
   - West US 2   (westus2)
   - West US 3   (westus3)
```

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-Geography` | *(prompts)* | Limit to a geography without knowing slugs: `US`, `Canada`, `NorthAmerica`, `Europe`, `UK`, `AsiaPacific`, `MiddleEast`, `Africa`, `SouthAmerica`, `Mexico`, `All`. If omitted (and no `-Regions`), the script prompts interactively. |
| `-Regions` | *(geography/all)* | Comma-separated region slugs (e.g. `eastus,westus2`). Overrides `-Geography`. Named regions are checked for **both** gates, so you can answer "why *not* the region the partner asked for?" |
| `-AppServiceSku` | `B2` | NMM default (Basic Medium, Windows). |
| `-SqlEdition` | `Standard` | NMM default SQL tier. |
| `-SqlServiceObjective` | `S1` | NMM default performance level (20 DTU). |
| `-SubscriptionId` | *(current `az` context)* | Target a specific subscription. |
| `-OutFile` | *(none)* | Write the full result table to a CSV. |

---

## How it works

- **App Service gate:** `az appservice list-locations --sku B2` — regions that *offer* the SKU (Windows workers; no `--linux-workers-enabled` flag).
- **SQL gate:** `az sql db list-editions -l <region> --edition Standard --service-objective S1 --available` — the `--available` flag is the key: it returns empty when the SKU exists in the catalog but **isn't deployable** in that subscription/region.
- Cross-references the two and reports only regions that pass **both**.

### ⚠️ Availability ≠ quota — what this does and doesn't prove

This tool tells you whether each SKU is **available / offered** to the subscription in a region. It does **not** confirm the subscription has the **quota headroom** to actually provision it:

- The Azure Quota API (`Microsoft.Quota`) only covers Compute, Azure ML, Networking, HPC Cache, Storage, and Purview — **not** App Service (`Microsoft.Web`) and **not** Azure SQL. So live quota for these two resources **cannot be pre-checked by any public API**.
- Quota is only enforced at **deploy time**, and raised via a support request.

So **"Eligible" means "both SKUs are available in the region," not "guaranteed to deploy."** If a deploy fails on a quota/capacity error (e.g. *"No availability of Basic VM SKU app service quota"*) in an Eligible region:

1. Pick another **Eligible** region from the list, **or**
2. Open an Azure support request — issue type **"Service and subscription limits (quotas)"** — for that region.

The only way to *prove* a region will take the deploy is to attempt it (or a validation deployment). This tool removes the regions that will definitely fail, which is most of the value on a live call.

---

## Requirements

- Azure Cloud Shell (PowerShell mode) — already authenticated — **or** local PowerShell 5.1+ with the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and `az login` completed.
- All `az` calls are **read-only**. The script creates nothing and changes nothing.
