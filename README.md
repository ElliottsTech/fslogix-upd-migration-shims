# UPD → FSLogix migration, without Hyper-V

Migrate RDS **User Profile Disks (UPD)** to **FSLogix Profile Containers** on servers that
**don't have the Hyper-V platform installed** — using the (now otherwise unobtainable) Microsoft
`FSLogixMigration` module over a small set of **diskpart-backed shims**.

## Why this exists

Three problems make the "standard" UPD→FSLogix migration impossible on a typical RDS backend
server:

1. **The Microsoft `FSLogixMigration` module is unobtainable.** It shipped as a 2019/2020
   private preview; the download link, the Tech Community attachments era, and the FSLogix.Labs
   GitHub repo are all dead. A community preservation of the original module exists at
   **[gregdod/FSLogixMigration](https://github.com/gregdod/FSLogixMigration)** (`useexistingprofile`
   branch) — that's the module this repo drives. It is *not* included here; it remains its
   authors' code (Dom Ruggeri / Jakub Podoba, Sysgain).

2. **The module requires the Hyper-V PowerShell layer** (`New-VHD`, `Mount-VHD`, …) — and
   `Mount-VHD` specifically needs the Hyper-V *platform* WMI classes, not just the management
   module. Installing the Hyper-V role on your SQL/file/RDS server is usually not an option.
   **The shims in this repo replace those four cmdlets with diskpart**, which needs nothing but
   an elevated built-in tool.

3. **The module needs `Get-ADUser`**, which fails from SSH/network-logon contexts (ADWS
   discovery doesn't work there). The shim version does local SID↔SAM translation via the LSA —
   the only thing the module's active code paths actually need.

### Why not just rename the UPDs?

You'll find plenty of old advice saying you can rename `UVHD-S-<SID>.vhdx` into FSLogix's
naming convention and restructure the disk into a `Profile\` folder. **In our testing against
FSLogix Apps agent 2210 (3.26.826.17182), that does not work**: FSLogix mounts the disk fine
but refuses to adopt the foreign profile and silently *rebuilds a fresh profile in place* —
users get a blank desktop. Even planting the community-known `ProfileData.reg` binding stub
wasn't enough.

What **does** work — reliably, validated with real logons — is what the module does:
**create a brand-new dynamic VHDX per user, robocopy the profile in (`/COPYALL /MIR /XJ`),
apply its ACL pattern (`inheritance:r`, owner, `attrib -H -S`), and write its own binding
registry file.** Every profile converted this way loaded correctly on the first logon.

## Usage

### 0. Prerequisites

- The module: `git clone https://github.com/gregdod/FSLogixMigration` somewhere on the
  conversion server.
- This repo's two scripts in one folder.
- An **elevated** PowerShell on the server that holds the UPDs (everything is local —
  no SMB double-hop issues if you convert where the files live).
- **A copy of your UPDs in a staging folder.** Never convert your only copy.

### 1. Configure FSLogix on the session host(s)

Point FSLogix at a share/folder and make sure the **root ACLs allow users to create folders**
(a classic gotcha — FSLogix create-tests *as the user*; read-only roots produce confusing
"Access denied" attach failures):

```powershell
icacls <FSLogixRoot> /grant "Domain Users:(CI)(AD)" "CREATOR OWNER:(OI)(CI)(IO)F"
```

### 2. Pilot ONE user first

```powershell
.\Convert-UPDtoFSLogixNoHyperV.ps1 `
    -SourcePath 'D:\Staging\UVHD-S-1-5-21-...-1234.vhdx' `
    -Target      'D:\FSLogix' `
    -ModulePath  'C:\Tools\FSLogixMigration\FSLogixMigration.psd1'
```

Then log on as that user on an FSLogix-enabled host and **verify the real profile loads**
(desktop, documents, apps). The event you want in `Microsoft-FSLogix-Apps/Operational` is
`Profile load: Status: 0` — **`Status: 100` means FSLogix created a new profile** (a failed
adoption).

### 3. Batch the rest

```powershell
.\Convert-UPDtoFSLogixNoHyperV.ps1 `
    -SourcePath 'D:\Staging' `
    -Target     'D:\FSLogix' `
    -ModulePath 'C:\Tools\FSLogixMigration\FSLogixMigration.psd1' `
    -DeleteSource
```

`-DeleteSource` removes each UPD **only after** its container is verified present and
reasonably sized (≥25% of source — robocopy legitimately skips locked temp files). This keeps
peak disk usage at roughly one profile instead of doubling the whole set. Re-running the script
is safe: converted users are skipped, their leftover sources cleaned.

### Notes from the field

- Runtime: roughly 60 seconds per profile (1 GB) with the module's built-in 30 s
  verification pause; robocopy skips a handful of `~DF*.TMP`-class files per profile — normal.
- One edge case: an account whose stored profile was **already broken** (e.g. a long-broken
  admin account missing its `UsrClass.dat` classes hive) will convert "successfully" but still
  fail to start the shell with event 1542 — the container faithfully copies the damage. For
  accounts you don't need history on, delete the container and let FSLogix build a fresh
  profile at next logon.
- Keep your original UPD share untouched for at least a week after cutover. Rollback is just
  repointing FSLogix off / UPD back on.

## How the shims work

| Real cmdlet          | Shim implementation                                                          |
|----------------------|------------------------------------------------------------------------------|
| `New-VHD`            | `diskpart create vdisk … type=expandable`                                     |
| `Mount-VHD`          | `diskpart attach vdisk` + before/after `Get-Disk` diff to find the new disk    |
| `Dismount-VHD`       | `diskpart detach vdisk`                                                       |
| `Get-DiskImage`      | path→disk map kept by the shims; falls back to the sole file-backed disk       |
| `Get-ADUser`         | local `SecurityIdentifier.Translate` SID↔SAM (LSA, no ADWS)                    |
| `Get-BitLockerVolume`| stub returning `FullyDecrypted` (module calls it unguarded)                    |

The one non-obvious, load-bearing detail: the shim parameters that receive pipeline input
**must declare `ValueFromPipelineByPropertyName`**. The module pipes objects (not strings) into
`Mount-VHD`; with positional binding only, you get a baffling `"missing mandatory parameters:
Path"` error from deep inside the module. That single attribute was the difference between
four failed attempts and a clean 27/27 migration.

## Credits & license

- `FSLogixMigration` module by Dom Ruggeri & Jakub Podoba (Sysgain) — Microsoft private
  preview, preserved by the community. **Get it from
  [gregdod/FSLogixMigration](https://github.com/gregdod/FSLogixMigration).**
- The 2019 Tech Community thread "Convert UPD to FSLogix container" and Christiaan
  Brinkhoff's migration writeup, which documented the module's method.
- Scripts in this repo: provided as-is by Elliotts Tech, use at your own risk — **test on one
  user before batching**, and always keep your originals.
