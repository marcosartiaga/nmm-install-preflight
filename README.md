# NMM Install Pre-Flight

Pre-install readiness checks for deploying **Nerdio Manager for MSP (NMM)** from the Azure Marketplace.

NMM's marketplace deployment can silently fail late in the wizard when the subscription isn't set up correctly. `Check-NMMRegionEligibility.ps1` runs through these phases in one pass to catch the most common blockers before the partner starts the install — and can optionally file the Azure support tickets needed to clear them:

| Phase | What it checks |
|---|---|
| **0 — Permissions** | The signed-in account holds Subscription **Owner** *and* Entra ID **Global Administrator**. Missing either will fail the install. Reports PASS / FAIL per check. |
| **1 — Resource providers** | All 14 providers NMM requires are **Registered**. Pass `-RegisterProviders` to register any that aren't and poll until they finish. |
| **2 — Region eligibility** | Which regions offer **both** core resources NMM needs (below) — so you can de-risk region choice live on a partner call. |
| **3 — Support tickets** *(optional)* | Pass `-OpenTicket` to file Azure quota support tickets for SQL regions flagged as provisioning-restricted in Phase 2 — one per region, without leaving the call. Requires a paid Azure support plan. |

The two recurring region offenders:

1. **App Service Plan — Basic Medium (B2), Windows.** Some regions report *"No availability of Basic VM SKU app service quota."*
2. **Azure SQL Database — Standard tier / S1 (20 DTU).** Some regions have the SKU in the catalog but it isn't deployable in *your* subscription right now (often regions that only offer the vCore model, or are capacity-constrained).

---

## ⚠️ Run it in the *partner's* subscription

The SQL availability check and App Service quota are **per-subscription**. The only result that matters is the one from the tenant where NMM is actually being installed. So run this in the **partner's** Azure Cloud Shell (screen-share and dictate the one-liner), not your own.

---

## Quick start (Azure Cloud Shell — PowerShell)

Open Cloud Shell at <https://shell.azure.com> (or the `>_` icon in the Azure portal), make sure it's in **PowerShell** mode, and paste:

```powershell
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1
```

It checks permissions and providers, then (with no region arguments) **asks where the partner is located** and checks just that geography — so you don't need to know region slugs:

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

To also **register any missing providers automatically** (Phase 1), add `-RegisterProviders`:

```powershell
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1 -RegisterProviders
```

Already know the region answer? Skip the prompt:

```powershell
# Just the US:
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1 -Geography US

# Or specific regions the partner named:
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1 -Regions eastus,centralus,westus2
```

To also **file Azure support tickets** for SQL provisioning-restricted regions (Phase 3 — needs a paid Azure support plan), add `-OpenTicket`:

```powershell
irm https://raw.githubusercontent.com/marcosartiaga/nmm-install-preflight/main/Check-NMMRegionEligibility.ps1 -OutFile nmm.ps1; ./nmm.ps1 -OpenTicket
```

> First-time Cloud Shell users get a one-time "set up storage" prompt (~30s) — or just pick the ephemeral/no-storage session. Either works.

---

## What you'll see

```
======================================================
  Phase 0: Permission Check
======================================================
  Subscription Owner                            PASS
  Entra ID Global Administrator                 PASS
  All required permissions confirmed.

======================================================
  Phase 1: Resource Provider Registration
======================================================
  (all 14 providers listed) ... All required providers are Registered.

======================================================
  Phase 2: Region Eligibility
======================================================
Region     DisplayName  AppService  SqlDb  Eligible
centralus  Central US   Yes         Yes    YES
westus2    West US 2    Yes         Yes    YES
eastus     East US      Yes         No     no

RECOMMENDATION
   - Central US  (centralus)
   - West US 2   (westus2)
```

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-RegisterProviders` | *(off)* | Register any unregistered providers in Phase 1 and poll until complete. Phases 0–2 are read-only; this and `-OpenTicket` are the only switches that change anything. |
| `-ProviderTimeoutMinutes` | `15` | How long Phase 1 waits for registration to finish. |
| `-OpenTicket` | *(off)* | Phase 3: prompt to file Azure support tickets for SQL provisioning-restricted regions. Requires a paid Azure support plan (Developer+). Enter the partner's time zone as a **Windows** name (e.g. `Eastern Standard Time`), not IANA. |
| `-Geography` | *(prompts)* | Limit Phase 2 to a geography without knowing slugs: `US`, `Canada`, `NorthAmerica`, `Europe`, `UK`, `AsiaPacific`, `MiddleEast`, `Africa`, `SouthAmerica`, `Mexico`, `All`. If omitted (and no `-Regions`), the script prompts interactively. |
| `-Regions` | *(geography/all)* | Comma-separated region slugs (e.g. `eastus,westus2`). Overrides `-Geography`. Named regions are checked for **both** gates, so you can answer "why *not* the region the partner asked for?" |
| `-AppServiceSku` | `B2` | NMM default (Basic Medium, Windows). |
| `-SqlEdition` | `Standard` | NMM default SQL tier. |
| `-SqlServiceObjective` | `S1` | NMM default performance level (20 DTU). |
| `-SubscriptionId` | *(current `az` context)* | Target a specific subscription. |
| `-OutFile` | *(none)* | Write the full Phase 2 result table to a CSV. |

---

## How it works

- **Phase 0 — Permissions:** Subscription Owner via `az role assignment list` (includes group-inherited and management-group-scoped assignments); Global Administrator via the Microsoft Graph `transitiveMemberOf` directory-roles endpoint, matched on the well-known GA role template GUID.
- **Phase 1 — Providers:** `az provider show` per provider; `-RegisterProviders` calls `az provider register` for any not yet Registered, then polls to completion.
- **Phase 2 — App Service gate:** `az appservice list-locations --sku B2` — regions that *offer* the SKU (Windows workers).
- **Phase 2 — SQL gate:** the `Microsoft.Sql/locations/<region>/capabilities` REST API. It reports whether the Standard/S1 objective is offered **and** returns the human-readable **reason** when a region is blocked (e.g. *"Provisioning is restricted in this region… open a support request with Issue type of 'Service and subscription limits'"*). Those reasons are shown in a **"Why these regions were excluded"** section so you can explain the block to the partner.
- **Speed:** on PowerShell 7+ (Azure Cloud Shell) the per-region SQL calls run in parallel (`-ThrottleLimit 15`); Windows PowerShell 5.1 runs them sequentially.
- **Phase 3 — Support tickets (`-OpenTicket`):** for each SQL region Phase 2 flags as provisioning-restricted, the script resolves the Azure support service + problem classification dynamically (no hardcoded GUIDs), collects partner contact details once, and files a quota ticket via the Azure Support REST API (`PUT` → 202 async → poll → `GET` to confirm). Requires a paid support plan (Developer+); on a Free plan Azure rejects creation and the script falls back to the manual Portal path. Enter the time zone as a **Windows** name (Microsoft Time Zone Index Values, e.g. `Pacific Standard Time`) — IANA names are rejected by the create API.

### ⚠️ Availability ≠ quota — what Phase 2 does and doesn't prove

Phase 2 tells you whether each SKU is **available / offered** to the subscription in a region. It does **not** confirm the subscription has the **quota headroom** to actually provision it:

- The Azure Quota API (`Microsoft.Quota`) only covers Compute, Azure ML, Networking, HPC Cache, Storage, and Purview — **not** App Service (`Microsoft.Web`) and **not** Azure SQL. So live quota for these two resources **cannot be pre-checked by any public API**.
- Quota is only enforced at **deploy time**, and raised via a support request.

So **"Eligible" means "both SKUs are available in the region," not "guaranteed to deploy."** If a deploy fails on a quota/capacity error (e.g. *"No availability of Basic VM SKU app service quota"*) in an Eligible region:

1. Pick another **Eligible** region from the list, **or**
2. Open an Azure support request — issue type **"Service and subscription limits (quotas)"** — for that region.

---

## Requirements

- Azure Cloud Shell (PowerShell mode) — already authenticated — **or** local PowerShell 5.1+ with the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and `az login` completed.
- The script is **read-only by default**. Two switches make changes: `-RegisterProviders` registers resource providers (requires Owner/Contributor on the subscription), and `-OpenTicket` files Azure support tickets (requires a paid support plan).
