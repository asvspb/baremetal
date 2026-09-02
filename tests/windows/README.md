# Windows-уровень тестов (T6, опция — TEST-SPEC §7.5 P-3)

Запускается ТОЛЬКО на Windows-машине (не входит в make test на Linux):

```powershell
# Pester v5: мок Get-Disk/Get-Partition для make-boot-usb.ps1
Install-Module Pester -Scope CurrentUser
Invoke-Pester -Path .\windows\make-boot-usb.Tests.ps1
```

Условие запуска — целевая машина (env:COMPUTERNAME), см. TEST-SPEC §7.5.
На Windows-машинах ручной чек-лист §11 остаётся обязательным.
