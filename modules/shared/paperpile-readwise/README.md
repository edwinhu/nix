# paperpile-readwise (vendored)

`sync.py` is vendored here so nix is the single source of truth for the
Paperpile→Readwise highlight sync service (see `../reader-services.nix`,
`readerServices.enablePaperpile`). Dev history lives in
`~/projects/paperpile-readwise-sync`; to update, edit there then copy the file
here and rebuild. Canonical runtime copy is this one (nix store), NOT Google Drive.
