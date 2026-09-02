<#






.SYNOPSIS





    ps-parse-count.ps1 — L1 helper: считает ошибки парсинга ps1 парсером PowerShell.





.DESCRIPTION





    Использование: pwsh -NoProfile -File ps-parse-count.ps1 <file.ps1>





    Печатает число ошибок парсинга в stdout; тексты ошибок — в stderr.





#>





param()











$targetFile = $args[0]





if (-not $targetFile) {





    [Console]::Error.WriteLine("usage: ps-parse-count.ps1 <file.ps1>")





    exit 2





}





$errs = $null





$tokens = $null





$null = [System.Management.Automation.Language.Parser]::ParseFile($targetFile, [ref]$tokens, [ref]$errs)





foreach ($e in $errs) { [Console]::Error.WriteLine(("PS-PARSE: {0}" -f $e.Message)) }





Write-Output $errs.Count





