# dev2smb

**Universal SMB deployment engine for Windows.**

dev2smb is a lightweight, declarative PowerShell script that batch-provisions SMB shares, local accounts, NTFS permissions, and Windows Firewall rules for network devices such as MFPs, scanners, PCs, and other clients that write files over SMB.

## WARNING: DESTRUCTIVE OPERATION

This tool uses a **wipe and rebuild** model. Read this section before running `dev2smb.ps1`.

1. **It wipes every resource that carries the configured `tag`**, including SMB shares, local accounts, and firewall rules. The wipe is matched by `tag`, not by `prefix`. If you change `prefix`, old resources with the same `tag` are still wiped.
2. **There is no dry-run mode and no automatic rollback.** If the script fails midway, the system may be left partially configured. Fix the cause and run the script again to converge to the desired state.
3. **Re-running is not seamless.** Between the wipe and the rebuild, the affected shares are unavailable. Passwords are not recovered from the system, so you must supply the correct passwords in `config.psd1` before every run.
4. **Back up `config.psd1` manually** before each run. The `.snapshot` files that the script generates are device inventory references only. Their passwords are `CHANGE_ME`, and their `suffix` values may contain the full name. Do not use them to restore.
5. **Make sure `tag` belongs only to this tool.** Never use a generic tag that might match other resources on the machine.

## Features

- **Declarative:** Define the whole fleet in one `config.psd1`. The script converges the system to match it.
- **Idempotent:** Running it repeatedly with the same config produces the same result.
- **Namespace protection:** Detects conflicts with external resources that match the `prefix` namespace. (See the note under Quick Start about what it does and does not check.)
- **Zero dependencies:** Pure Windows PowerShell 5.1+, using the built-in SMB, NTFS, and firewall cmdlets.

## Requirements

- Windows with PowerShell 5.1 or later
- Run as Administrator
- Local machine only. This tool does not manage Samba or other operating systems.

## Naming Rules

For each device entry, the script derives these names:

| Item | Name |
| --- | --- |
| SMB share | `{prefix}-{suffix}` |
| Local account | `{prefix}-{suffix}` |
| Firewall rule | `{prefix}-{suffix}` |
| Shared folder | `{script directory}\{suffix}` |

Rules for `suffix`:

- 1 to 16 characters
- Only `[a-z0-9._-]`
- Use the short name only, such as `aurora-3f`. Do not include the prefix.
- `prefix + '-' + suffix` must be 20 characters or fewer, because of the Windows account name limit.

`ip` is used as the `RemoteAddress` of the firewall rule.

## Quick Start

### 1. Prepare the config

1. Copy `config.psd1.example` to `config.psd1`.
2. Fill in every device.
3. Replace every `CHANGE_ME` with a strong, unique password. Passwords are stored in plain text in `config.psd1`. See Security Notes.
4. Check that `prefix` matches the names of the existing resources you want to keep under management. A different `prefix` creates new resources with the new name, and the tagged old resources are still wiped.
5. Check that `suffix` values are short names, not full names.

### 2. Pre-flight checks (manual)

Before running, confirm the following by hand:

- [ ] No `CHANGE_ME` remains in `config.psd1`
- [ ] Every `pw` is the real password for that device
- [ ] `prefix` matches the existing shares, for example with `Get-SmbShare`
- [ ] No duplicate `suffix` or `ip`
- [ ] Every `suffix` is a short name, and `prefix-suffix` is 20 characters or fewer
- [ ] The `tag` belongs only to this tool
- [ ] `config.psd1` has been backed up manually

### 3. Deploy

Open PowerShell as Administrator and run:

```powershell
.\dev2smb.ps1
```

Read the `cfg - detail` and `system tagged - detail` output before typing `COMMIT`. Confirm that every entry you expect to be wiped carries the `tag`.

### 4. Verify

After the run:

```powershell
Get-SmbShare | Where-Object Name -like '{prefix}-*'
Get-LocalUser | Where-Object Name -like '{prefix}-*'
Get-NetFirewallRule -DisplayName '{prefix}-*'
```

Then run a test scan from each device.

## Configuration Example

```powershell
@{
  prefix  = 'd2s'
  tag     = '[dev2smb]'
  devices = @(
    @{ suffix = 'aurora-3f';  ip = '192.168.1.240'; pw = 'CHANGE_ME' }
    @{ suffix = 'canon-2f';   ip = '192.168.1.241'; pw = 'CHANGE_ME' }
    @{ suffix = 'ad289s-hr';  ip = '192.168.1.242'; pw = 'CHANGE_ME' }
  )
}
```

Always use single quotes for passwords. Double quotes expand `$` variables.

## Security Notes

- **IP restriction and MAC binding are not authentication.** The firewall rule matches on IP, and an IP or MAC address can be changed on a laptop. These measures only prevent accidental misuse. The real access control is the SMB account password.
- **Use long, random, unique passwords.** Do not reuse them and do not use simple patterns.
- **`config.psd1` contains plain-text passwords.** Protect the file with NTFS permissions, and never commit it. Add it to `.gitignore`:

  ```gitignore
  config.psd1
  config.psd1.*
  ```

- **The export command does not export real passwords.** The `system tagged - psd1` output contains `CHANGE_ME`. It is useful for reviewing the structure, but it cannot be used as a restore source.
- **Scanned files may be sensitive.** Decide how long files are kept, who can read the shared folders, and whether they are cleaned up on a schedule. The folder is a temporary landing zone, not a permanent archive.
- **Passwords printed on device web panels are separate.** If a password is set on a printer or MFP, update it in both places whenever you change it here.

## Limitations

- Not atomic. A failure midway can leave the system partially configured.
- No dry-run. Review the detail output carefully before `COMMIT`.
- No password recovery. Existing passwords are not read back from the system.
- Folder paths are derived from the script directory. Moving the script changes the physical path of every share.

## License

TBD