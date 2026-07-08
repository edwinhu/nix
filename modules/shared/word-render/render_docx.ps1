<#
  render_docx.ps1 — faithful docx -> PDF via the real Word engine (COM).
  Runs inside any Windows guest (Win11 ARM under Parallels/UTM now,
  Win11 x64 under KVM later). The ONE thing this buys over LibreOffice/x2t:
  Word recomputes fields — REF/NOTEREF/PAGEREF/TOC — across every story
  (body, footnotes, endnotes, headers, footers), then exports.

  Usage (invoked by the host wrapper over SSH):
    powershell -NoProfile -ExecutionPolicy Bypass -File render_docx.ps1 `
      -In  C:/Users/word/render/in.docx `
      -Out C:/Users/word/render/in.pdf
#>
param(
  [Parameter(Mandatory=$true)][string]$In,
  [Parameter(Mandatory=$true)][string]$Out
)

$ErrorActionPreference = 'Stop'
# wd* enum constants (avoids needing the interop assembly)
$wdAlertsNone            = 0
$wdExportFormatPDF       = 17
$wdExportOptimizeForPrint= 0
$wdExportAllDocument     = 0

# Files arriving via scp carry a mark-of-the-web zone tag -> Word opens them in
# Protected View, which blocks automation. Strip it before opening.
try { Unblock-File -Path $In -ErrorAction SilentlyContinue } catch {}

$word = $null
$doc  = $null
try {
  $word = New-Object -ComObject Word.Application
  $word.Visible       = $false
  $word.DisplayAlerts = $wdAlertsNone
  # Belt-and-suspenders against Protected View for network/temp locations.
  try {
    $word.ProtectedViewWindows # touch collection; settings below are best-effort
    $word.Options.UpdateFieldsAtPrint = $false
  } catch {}

  # Open(FileName, ConfirmConversions=$false, ReadOnly=$true)
  $doc = $word.Documents.Open($In, $false, $true)

  # Update ALL fields, including those living in footnotes/endnotes/headers/
  # footers. $doc.Fields.Update() only touches the main body, so walk every
  # StoryRange and follow its linked-story chain.
  foreach ($story in $doc.StoryRanges) {
    $s = $story
    do {
      try { [void]$s.Fields.Update() } catch {}
      $s = $s.NextStoryRange
    } while ($s -ne $null)
  }
  # Tables of contents / figures / authorities are updated separately.
  foreach ($toc in $doc.TablesOfContents)   { try { $toc.Update() }  catch {} }
  foreach ($tof in $doc.TablesOfFigures)    { try { $tof.Update() }  catch {} }
  foreach ($toa in $doc.TablesOfAuthorities){ try { $toa.Update() }  catch {} }

  # Repaginate so PAGEREF/TOC page numbers settle before export.
  try { $doc.Repaginate() } catch {}

  $doc.ExportAsFixedFormat(
    $Out, $wdExportFormatPDF, $false, $wdExportOptimizeForPrint,
    $wdExportAllDocument
  )
  Write-Output "OK: $Out"
}
finally {
  if ($doc  -ne $null) { try { $doc.Close($false) } catch {} }
  if ($word -ne $null) { try { $word.Quit() }       catch {} }
  # Release COM and reap any orphaned Word process so repeated renders don't leak.
  if ($doc)  { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($doc) }
  if ($word) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($word) }
  [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  Get-Process WINWORD -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq '' } | Stop-Process -Force -ErrorAction SilentlyContinue
}
