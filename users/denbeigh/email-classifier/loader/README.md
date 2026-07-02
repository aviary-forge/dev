# email-loader

Downloads emails from IMAP (Exchange Online / Outlook) to local `.eml` files +
a SQLite index, using OAuth2 (XOAUTH2 SASL) via MSAL client-credentials flow.

## Setup

### 1. Azure AD app registration

1. Go to <https://portal.azure.com> → App registrations → New registration
2. Name it, choose "Accounts in this organizational directory only"
3. Under **Certificates & secrets**, create a client secret

### 2. API permissions

1. **API Permissions** → Add permission → **APIs my organization uses**
2. Search for **"Office 365 Exchange Online"** → **Application permissions**
3. Select **`IMAP.AccessAsApp`** → Add permissions
4. **Grant admin consent** (you need to be a tenant admin)

### 3. Exchange Online PowerShell

The app's service principal must be registered in Exchange Online:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline

# Register the service principal
$appId = "<your-client-id>"
$sp = Get-AzureADServicePrincipal -Filter "appId eq '$appId'"
New-ServicePrincipal -AppId $sp.AppId -ObjectId $sp.ObjectId `
    -DisplayName "email-loader"

# Grant mailbox access
$exoSp = Get-ServicePrincipal -Identity "email-loader"
Add-MailboxPermission -Identity "you@domain.com" `
    -User $exoSp.Identity -AccessRights FullAccess
```

### 4. Configuration

```bash
cp config.yaml.template config.yaml
```

Fill in:

```yaml
imap:
  host: outlook.office365.com
  port: 993
  username: "you@domain.com"
  oauth2:
    client_id: "11111111-2222-3333-4444-555555555555"
    client_secret: "your-client-secret"
    tenant_id: "22222222-3333-4444-5555-666666666666"
```

### 5. Run

```bash
uv run --directory loader email-loader
```

The token is cached to `~/.local/share/email-classifier/msal_token_cache.bin`.
If you change API permissions, delete that file to force a fresh token.

### Dry run

```bash
uv run --directory loader email-loader --dry-run
```

### Sync a specific folder

```bash
uv run --directory loader email-loader --folder INBOX --limit 50
```
