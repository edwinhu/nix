<#
  compare_docx.ps1 — real Word redline via Application.CompareDocuments (COM).

  Word's Compare DOES diff footnote-internal text (CompareFootnotes), which is
  the whole reason for driving Word instead of LibreOffice on a footnote-heavy
  manuscript: LibreOffice's compare silently carries the baseline's footnotes
  through and shows every footnote edit as unchanged.

  CompareFormatting is OFF because the two sides of a redline usually come from
  different authoring pipelines (Word vs pandoc-from-Typst), where every
  formatting delta is a pipeline artifact rather than an edit. CompareFields is
  OFF for the same reason: NOTEREF/TOC fields carry cached display text, so
  `supra note N` renumbering would otherwise read as hundreds of edits.

    powershell -NoProfile -ExecutionPolicy Bypass -File compare_docx.ps1 `
      -Base C:/Users/word/render/_cmp_base.docx `
      -Rev  C:/Users/word/render/_cmp_rev.docx `
      -Out  C:/Users/word/render/_cmp_out.docx `
      -Stats C:/Users/word/render/_cmp_stats.txt
#>
param(
  [Parameter(Mandatory=$true)][string]$Base,
  [Parameter(Mandatory=$true)][string]$Rev,
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(Mandatory=$true)][string]$Stats
)

$ErrorActionPreference = 'Stop'
$wdAlertsNone               = 0
$wdGranularityWordLevel     = 1
$wdCompareDestinationNew    = 2
$wdFormatXMLDocument        = 12
$wdRevisionInsert           = 1
$wdRevisionDelete           = 2

foreach ($f in @($Base, $Rev)) {
  try { Unblock-File -Path $f -ErrorAction SilentlyContinue } catch {}
}

$word = $null; $dBase = $null; $dRev = $null; $dOut = $null
try {
  $word = New-Object -ComObject Word.Application
  $word.Visible = $false
  $word.DisplayAlerts = $wdAlertsNone

  $dBase = $word.Documents.Open($Base, $false, $true)
  $dRev  = $word.Documents.Open($Rev,  $false, $true)

  # Positional args, Word 2007+ signature:
  #  Original, Revised, Destination, Granularity, CompareFormatting,
  #  CompareCaseChanges, CompareWhitespace, CompareTables, CompareHeaders,
  #  CompareFootnotes, CompareTextboxes, CompareFields, CompareComments,
  #  CompareMoves, RevisedAuthor, IgnoreAllComparisonWarnings
  $dOut = $word.CompareDocuments(
    $dBase, $dRev,
    $wdCompareDestinationNew,
    $wdGranularityWordLevel,
    $false,   # CompareFormatting  -> OFF (different authoring pipelines)
    $false,   # CompareCaseChanges
    $false,   # CompareWhitespace
    $true,    # CompareTables
    $false,   # CompareHeaders
    $true,    # CompareFootnotes   -> the point of using Word
    $true,    # CompareTextboxes
    $false,   # CompareFields      -> OFF (NOTEREF cached text is not an edit)
    $false,   # CompareComments
    $true,    # CompareMoves
    'Revision',
    $true
  )

  # Count revisions across every story so footnote revisions are included.
  $ins = 0; $del = 0; $oth = 0; $fnIns = 0; $fnDel = 0
  foreach ($story in $dOut.StoryRanges) {
    $s = $story
    do {
      $isFootnote = ($s.StoryType -eq 2)   # wdFootnotesStory
      foreach ($r in $s.Revisions) {
        switch ($r.Type) {
          $wdRevisionInsert { $ins++; if ($isFootnote) { $fnIns++ } }
          $wdRevisionDelete { $del++; if ($isFootnote) { $fnDel++ } }
          default           { $oth++ }
        }
      }
      $s = $s.NextStoryRange
    } while ($s -ne $null)
  }
  $total = $ins + $del + $oth

  $lines = @(
    "TOTAL_REVISIONS=$total",
    "INSERTIONS=$ins",
    "DELETIONS=$del",
    "OTHER=$oth",
    "FOOTNOTE_STORY_INSERTIONS=$fnIns",
    "FOOTNOTE_STORY_DELETIONS=$fnDel",
    "OUT_WORDS=" + $dOut.Words.Count,
    "OUT_FOOTNOTES=" + $dOut.Footnotes.Count
  )
  Set-Content -Path $Stats -Value $lines -Encoding ASCII

  $dOut.SaveAs([ref]$Out, [ref]$wdFormatXMLDocument)
  Write-Output "OK: $Out ($total revisions)"
}
finally {
  foreach ($d in @($dOut, $dRev, $dBase)) {
    if ($d -ne $null) { try { $d.Close($false) } catch {} }
  }
  if ($word -ne $null) { try { $word.Quit() } catch {} }
  [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  Get-Process WINWORD -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq '' } | Stop-Process -Force -ErrorAction SilentlyContinue
}
