# Copy to $HOME\.exports.ps1 and fill in values. Never commit the real file.
#
# This is the PowerShell analogue of the POSIX `.exports` file. The managed
# block that install.ps1 adds to your $PROFILE dot-sources $HOME\.exports.ps1
# if it exists, so anything you set here is available in every session.

# GitHub personal access token (used by some scripts / gh).
# $env:GHPAT = ""
