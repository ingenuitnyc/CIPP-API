# NinjaOne macOS scripts

Standalone automation scripts for use as **NinjaOne** scripts. These are not
part of the CIPP-API Azure Functions app; they live here for convenience.

## Create-macOSLocalUser.sh

Creates a new **local** user account (with a username and password you specify)
on a target Mac. Uses Apple's supported `sysadminctl` tool and verifies the
result. The script is idempotent — if the account already exists it exits
successfully without modifying it.

### Setup in NinjaOne

1. **Administration → Library → Automation → Add → New Script**
2. **Language:** `ShellScript (macOS/Linux)` &nbsp; **Operating System:** `Mac` &nbsp; **Architecture:** `All`
3. Paste the contents of `Create-macOSLocalUser.sh`.
4. Define these **Script Variables** (each is passed to the script as an
   environment variable of the same name):

   | Variable      | Type     | Required | Purpose |
   |---------------|----------|----------|---------|
   | `newUsername` | Text     | Yes      | Short/login name to create |
   | `newPassword` | Text     | Yes      | Account password — **mark as secure/masked** |
   | `fullName`    | Text     | No       | Display name (defaults to the username) |
   | `makeAdmin`   | Checkbox | No       | Grant local administrator rights |
   | `hideUser`    | Checkbox | No       | Hide the account from the login window |

5. Run against a device or deploy via policy. NinjaOne runs the agent as
   `root`, so no extra privileges are needed.

### Local testing (positional arguments)

```bash
sudo ./Create-macOSLocalUser.sh <username> <password> [fullName] [true|false admin] [true|false hide]
# example: standard hidden service account
sudo ./Create-macOSLocalUser.sh svc.backup 'S3cure-P@ss' 'Backup Service' false true
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (created, or already existed) |
| 1 | Missing/invalid parameters |
| 2 | Unsupported macOS version (needs 10.13+) |
| 3 | User creation failed |
| 4 | Post-creation verification failed |

### Security notes

- Store `newPassword` as a **masked/secure** NinjaOne variable so it is not
  shown or logged in clear text.
- `sysadminctl` accepts the password as an argument, so it is briefly visible
  to other root processes via `ps` on the host during creation. This is an
  Apple tooling limitation; the exposure window is short and root-only.
- Only run against machines you are authorized to manage.
